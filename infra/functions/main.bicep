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
//   - Storage Account         (dedicated backing storage for the Function App)
//   - App Service Plan        (Linux Consumption Y1 — serverless, Dev)
//   - Function App            (func-bridge-{prefix}, System-Assigned MI)
//   - RBAC: MI → Storage      (Blob + Queue + Table Data Contributor)
//   - RBAC: MI → Event Hub    (Azure Event Hubs Data Receiver)
//
// Security model:
//   All connections use Managed Identity — no connection strings or SAS tokens.
//   - Event Hub trigger : EventHubConnection__fullyQualifiedNamespace (MI)
//   - Service Bus sender: ServiceBusConnection__fullyQualifiedNamespace (MI)
//   - Backing storage   : AzureWebJobsStorage__accountName (MI)
//
// Service Bus RBAC (Azure Service Bus Data Sender) is handled by the sibling
// module messaging/servicebus-rbac.bicep. Wire managedIdentityPrincipalId
// output into serviceBusRbac as bridgePrincipalId.
//
// Runtime: .NET 8 isolated worker, Azure Functions v4, Linux Consumption.
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
// CONSUMPTION APP SERVICE PLAN (Linux)
// =============================================================================
// Linux Consumption avoids the Windows-specific WEBSITE_CONTENTAZUREFILECONNECTIONSTRING
// requirement, keeping the configuration clean for MI-only authentication.

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-bridge-${resourcePrefix}'
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'linux'
  properties: {
    reserved: true    // required for Linux plan
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

    siteConfig: {
      linuxFxVersion: 'dotnet-isolated|8.0'    // .NET 8 isolated worker
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
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }

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
  name: guid(bridgeStorage.id, bridgeFunctionApp.identity.principalId, storageBlobDataContributorRoleId)
  scope: bridgeStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: bridgeFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bridgeStorage.id, bridgeFunctionApp.identity.principalId, storageQueueDataContributorRoleId)
  scope: bridgeStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: bridgeFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bridgeStorage.id, bridgeFunctionApp.identity.principalId, storageTableDataContributorRoleId)
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
  name: guid(eventHubNamespace.id, bridgeFunctionApp.identity.principalId, eventHubsDataReceiverRoleId)
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
