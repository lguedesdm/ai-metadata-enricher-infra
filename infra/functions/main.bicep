// =============================================================================
// Functions Module — Purview Bridge
// =============================================================================
// Purpose: Provisions the Azure Function App that bridges Purview diagnostic
// events from Event Hub into the Service Bus enrichment pipeline.
//
// Event pipeline role:
//   Purview → Event Hub (purview-diagnostics)
//          → Bridge Function App (this module)
//          → Service Bus (purview-events queue)
//          → Orchestrator
//
// Resources created:
//   - Storage Account             (dedicated backing storage for the Function App)
//   - Blob container              (deployment-packages — required by Flex Consumption)
//   - App Service Plan            (Flex Consumption FC1 — serverless, Dev)
//   - Function App                (func-bridge-{prefix}, System-Assigned MI)
//   - RBAC: MI → Storage          (Blob + Queue + Table Data Contributor)
//   - RBAC: MI → Event Hub        (Azure Event Hubs Data Receiver)
//
// Hosting plan note:
//   Originally designed for Consumption Y1 (Dynamic). Migrated to Flex
//   Consumption (FC1) to avoid Dynamic VM quota exhaustion in East US.
//   FC1 uses a container-based runtime and a separate quota pool.
//   The event pipeline, MI auth model, and frozen app settings are unchanged.
//
// Security model:
//   All connections use Managed Identity — no connection strings or SAS tokens.
//   - Event Hub trigger     : EventHubConnection__fullyQualifiedNamespace (MI)
//   - Service Bus sender    : ServiceBusConnection__fullyQualifiedNamespace (MI)
//   - Backing storage       : AzureWebJobsStorage__accountName (MI)
//   - Deployment packages   : functionAppConfig.deployment.storage (MI)
//
// Service Bus RBAC (Azure Service Bus Data Sender) is handled by the sibling
// module messaging/servicebus-rbac.bicep. Wire managedIdentityPrincipalId
// output into serviceBusRbac as bridgePrincipalId.
//
// Runtime: .NET 8 isolated worker, Azure Functions v4, Flex Consumption.
//
// Frozen app setting values (runtime_architecture_contract.yaml):
//   EventHubName    : purview-diagnostics
//   ConsumerGroup   : bridge-function
//   ServiceBusQueueName: purview-events
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Resource name prefix (e.g. ai-metadata-dev)')
param resourcePrefix string

@description('Azure region for all resources')
param location string

@description('Tags to apply to all resources')
param tags object

@description('Event Hub namespace name (e.g. ai-metadata-dev-eh). Used to build the trigger FQDN and RBAC scope.')
param eventHubNamespaceName string

@description('Service Bus namespace name (e.g. ai-metadata-dev-sbus). Used to build the sender FQDN.')
param serviceBusNamespaceName string

@description('Unique suffix for the backing storage account name. Leave empty to auto-generate.')
param uniqueSuffix string = ''

@description('Microsoft Purview account name (e.g. purview-ai-metadata-dev). Used by UpstreamRouterFunction to query the Purview REST API.')
param purviewAccountName string

@description('Cosmos DB account endpoint (e.g. https://cosmos-ai-metadata-dev.documents.azure.com:443/). Used by ReviewStatusPollFunction.')
param cosmosEndpoint string

@description('Cosmos DB database name. Frozen: metadata_enricher.')
param cosmosDatabaseName string = 'metadata_enricher'

@description('Cosmos DB state container name. Frozen: state.')
param cosmosStateContainer string = 'state'

@description('Cosmos DB audit container name. Frozen: audit.')
param cosmosAuditContainer string = 'audit'

// =============================================================================
// LOCAL VARIABLES
// =============================================================================

// Storage account name: alphanumeric only, ≤ 24 chars.
// Pattern: first 10 chars of prefix (hyphens stripped) + "fnst" + 6-char hash.
var resolvedSuffix = empty(uniqueSuffix) ? take(uniqueString(resourceGroup().id, 'bridge'), 6) : uniqueSuffix
var storageAccountName = '${take(replace(resourcePrefix, '-', ''), 10)}fnst${resolvedSuffix}'

// =============================================================================
// BACKING STORAGE ACCOUNT
// =============================================================================
// Dedicated storage for the Function App runtime (checkpoints, state blobs,
// queue/table triggers). Separate from the enrichment data storage account.
// Authenticated via AzureWebJobsStorage__accountName (Managed Identity).

resource bridgeStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'    // MVP: Locally redundant for Dev
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'  // MVP: Public endpoints for Dev
  }
}

// =============================================================================
// DEPLOYMENT PACKAGES BLOB CONTAINER
// =============================================================================
// Flex Consumption requires a dedicated blob container to store deployment
// packages (ZIP). The function runtime pulls code from here on cold start.
// Authenticated via SystemAssignedIdentity — no SAS token required.
// The existing storageBlobDataContributorRoleId RBAC covers this container.

resource bridgeStorageBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: bridgeStorage
}

resource deploymentPackagesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'deployment-packages'
  parent: bridgeStorageBlobService
  properties: {
    publicAccess: 'None'
  }
}

// =============================================================================
// FLEX CONSUMPTION APP SERVICE PLAN
// =============================================================================
// FC1 uses a container-based serverless runtime. Unlike Y1 (Dynamic VMs),
// FC1 draws from a separate quota pool — no Dynamic VM quota required.
// reserved: true is still required for Linux workers in FC1.

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-bridge-${resourcePrefix}'
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true    // required for Linux workers
  }
}

// =============================================================================
// FUNCTION APP — PURVIEW BRIDGE
// =============================================================================
// Background worker: no HTTP ingress, no secrets in config.
// Triggered by Event Hub; forwards events to Service Bus.

resource bridgeFunctionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: 'func-bridge-${resourcePrefix}'
  location: location
  tags: union(tags, { component: 'purview-bridge' })
  kind: 'functionapp,linux'

  // System-Assigned Managed Identity.
  // The principal ID is exported so:
  //   1. messaging/servicebus-rbac.bicep assigns Azure Service Bus Data Sender
  //   2. This module assigns Azure Event Hubs Data Receiver (see below)
  //   3. This module assigns Storage Blob/Queue/Table Data Contributor (see below)
  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true

    // functionAppConfig is required for Flex Consumption (FC1).
    // - runtime      : replaces siteConfig.linuxFxVersion
    // - deployment   : blob container for code packages (MI-authenticated)
    // - scaleAndConcurrency: Dev defaults (40 instances max, 2 GB memory)
    functionAppConfig: {
      runtime: {
        name: 'dotnet-isolated'
        version: '8.0'
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${bridgeStorage.properties.primaryEndpoints.blob}deployment-packages'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40    // Dev default
        instanceMemoryMB: 2048      // Dev default (2 GB)
      }
    }

    siteConfig: {
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'

      appSettings: [
        // ------------------------------------------------------------------
        // Functions runtime
        // ------------------------------------------------------------------
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        // FUNCTIONS_WORKER_RUNTIME is invalid for Flex Consumption (FC1) —
        // runtime is declared in functionAppConfig.runtime above.

        // ------------------------------------------------------------------
        // Backing storage — Managed Identity authentication
        // AzureWebJobsStorage__accountName triggers MI-based auth; no
        // connection string required on Linux Consumption.
        // ------------------------------------------------------------------
        {
          name: 'AzureWebJobsStorage__accountName'
          value: bridgeStorage.name
        }

        // ------------------------------------------------------------------
        // Event Hub trigger — Managed Identity authentication
        // Connection name in code: "EventHubConnection"
        // MI pattern: {ConnectionName}__fullyQualifiedNamespace
        // Source: HeuristicTriggerBridge.cs → [EventHubTrigger("%EventHubName%",
        //           Connection = "EventHubConnection", ConsumerGroup = "%ConsumerGroup%")]
        // ------------------------------------------------------------------
        {
          name: 'EventHubConnection__fullyQualifiedNamespace'
          value: '${eventHubNamespaceName}.servicebus.windows.net'
        }
        {
          name: 'EventHubName'
          value: 'purview-diagnostics'      // frozen: runtime_architecture_contract.yaml
        }
        {
          name: 'ConsumerGroup'
          value: 'bridge-function'          // frozen: eventhub module contract
        }

        // ------------------------------------------------------------------
        // Service Bus sender — Managed Identity authentication
        // Source: HeuristicTriggerBridge.cs →
        //   GetEnvironmentVariable("ServiceBusConnection__fullyQualifiedNamespace")
        //   GetEnvironmentVariable("ServiceBusQueueName")
        // ------------------------------------------------------------------
        {
          name: 'ServiceBusConnection__fullyQualifiedNamespace'
          value: '${serviceBusNamespaceName}.servicebus.windows.net'
        }
        {
          name: 'ServiceBusQueueName'
          value: 'purview-events'           // frozen: runtime_architecture_contract.yaml
        }

        // ------------------------------------------------------------------
        // UpstreamRouterFunction — Purview REST API + enrichment output
        // ------------------------------------------------------------------
        {
          name: 'PurviewEventsQueueName'
          value: 'purview-events'           // frozen: runtime_architecture_contract.yaml
        }
        {
          name: 'PurviewAccountName'
          value: purviewAccountName
        }
        {
          name: 'EnrichmentRequestsQueueName'
          value: 'enrichment-requests'      // frozen: runtime_architecture_contract.yaml
        }

        // ------------------------------------------------------------------
        // ReviewStatusPollFunction — Cosmos DB polling
        // ------------------------------------------------------------------
        {
          name: 'CosmosEndpoint'
          value: cosmosEndpoint
        }
        {
          name: 'CosmosDatabaseName'
          value: cosmosDatabaseName         // frozen: runtime_architecture_contract.yaml
        }
        {
          name: 'CosmosStateContainer'
          value: cosmosStateContainer       // frozen: runtime_architecture_contract.yaml
        }
        {
          name: 'CosmosAuditContainer'
          value: cosmosAuditContainer       // frozen: runtime_architecture_contract.yaml
        }
      ]
    }
  }
}

// =============================================================================
// RBAC — Function App MI → Backing Storage
// =============================================================================
// The Functions runtime requires Blob, Queue, and Table Contributor roles on
// the backing storage account when using AzureWebJobsStorage__accountName.

var storageBlobDataContributorRoleId  = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

resource storageBlobRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bridgeStorage.id, bridgeFunctionApp.id, storageBlobDataContributorRoleId)
  scope: bridgeStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: bridgeFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bridgeStorage.id, bridgeFunctionApp.id, storageQueueDataContributorRoleId)
  scope: bridgeStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: bridgeFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bridgeStorage.id, bridgeFunctionApp.id, storageTableDataContributorRoleId)
  scope: bridgeStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: bridgeFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// RBAC — Function App MI → Event Hub (Data Receiver)
// =============================================================================
// Allows the Function App's system MI to read events from the Event Hub
// namespace using the MI-based EventHubConnection__fullyQualifiedNamespace
// trigger setting.
//
// Built-in role: Azure Event Hubs Data Receiver
// Role ID: a638d3c7-ab3a-418d-83e6-5f17a39d4fde

var eventHubsDataReceiverRoleId = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: eventHubNamespaceName
}

resource eventHubDataReceiverRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, bridgeFunctionApp.id, eventHubsDataReceiverRoleId)
  scope: eventHubNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
    principalId: bridgeFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Function App name')
output functionAppName string = bridgeFunctionApp.name

@description('Function App resource ID')
output functionAppId string = bridgeFunctionApp.id

@description('System-assigned Managed Identity principal ID — wire into messaging/servicebus-rbac.bicep as bridgePrincipalId')
output managedIdentityPrincipalId string = bridgeFunctionApp.identity.principalId

@description('Backing storage account name')
output storageAccountName string = bridgeStorage.name
