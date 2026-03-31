// =============================================================================
// Main Bicep Orchestration
// =============================================================================
// Purpose: Orchestrates all infrastructure modules for the AI Metadata Enricher
// platform.
//
// This file is the entry point for deploying the Dev environment.
// It coordinates the deployment of:
//   - Core (resource group, naming, tags)
//   - Storage (blob containers)
//   - Cosmos DB (state and audit containers)
//   - Azure AI Search (search service and index)
//   - Messaging (Service Bus queues)
//   - Messaging RBAC (Service Bus role assignments for bridge and orchestrator)
//   - Compute (Container Apps Environment + Orchestrator Container App)
//   - Event Hub (Namespace + purview-diagnostics hub + bridge consumer group)
//   - Functions (Purview Bridge Function App + plan + backing storage)
//
// Usage:
//   az deployment sub create \
//     --location <location> \
//     --template-file infra/main.bicep \
//     --parameters infra/parameters.dev.bicep
// =============================================================================

targetScope = 'subscription'

// =============================================================================
// PARAMETERS
// =============================================================================

@description('The environment name (dev, test, prod)')
param environment string

@description('The Azure region for all resources')
param location string = 'eastus'

@description('The base project name')
param projectName string = 'ai-metadata'

@description('Storage Account SKU')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_ZRS'])
param storageSku string = 'Standard_LRS'

// Cosmos TTL parameters intentionally omitted in DEV; handled in a future task

@description('Azure AI Search SKU')
@allowed(['free', 'basic', 'standard', 'standard2', 'standard3'])
param searchSku string = 'basic'

@description('Create the unified Azure AI Search index from the frozen schema JSON')
param deploySearchIndex bool = false

@description('Deploy Storage module')
param deployStorage bool = false

@description('Deploy Search module')
param deploySearch bool = false

@description('Service Bus SKU')
@allowed(['Basic', 'Standard', 'Premium'])
param serviceBusSku string = 'Standard'

@description('Unique suffix for globally unique resources (leave empty to auto-generate based on subscription and resource group)')
param uniqueSuffix string = ''

@description('Deploy Cosmos containers (state, audit)')
param deployCosmosContainers bool = false

@description('Principal ID of the Purview Bridge Managed Identity. Leave empty until the Function App is provisioned.')
param bridgePrincipalId string = ''

@description('Principal ID of the Orchestrator Managed Identity. Leave empty — populated automatically when deployCompute=true.')
param orchestratorPrincipalId string = ''

@description('Deploy Compute module (Container Apps Environment + Orchestrator Container App)')
param deployCompute bool = false

@description('Container image reference for the Orchestrator. Required when deployCompute=true.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Azure AI Search endpoint. Required when deployCompute=true and deploySearch=false.')
param searchEndpoint string = ''

@description('Azure AI Search service name. Required when deploySearch=false and the orchestrator RBAC must target a previously deployed service.')
param searchServiceName string = ''

@description('Azure OpenAI endpoint. Leave empty until Azure OpenAI is provisioned.')
param openAiEndpoint string = ''

@description('Azure OpenAI deployment name. Leave empty until Azure OpenAI is provisioned.')
param openAiDeploymentName string = ''

@description('Deploy Azure OpenAI module (account + GPT deployment + RBAC)')
param deployOpenAI bool = false

@description('GPT model name to deploy when deployOpenAI=true.')
@allowed(['gpt-4', 'gpt-4o', 'gpt-4o-mini'])
param openAiModelName string = 'gpt-4o'

@description('GPT model version to deploy when deployOpenAI=true.')
param openAiModelVersion string = '2024-11-20'

@description('Token-per-minute capacity in thousands for the GPT deployment. 10 = 10K TPM (Dev default).')
param openAiCapacityThousands int = 10

@description('Microsoft Purview account name. Leave empty until Purview is provisioned.')
param purviewAccountName string = ''

@description('Declare Purview dependency — validates the account exists and outputs the endpoint. Set true only after the Purview account is pre-provisioned.')
param deployPurview bool = false

@description('Deploy Azure Container Registry module')
param deployRegistry bool = false

@description('Deploy Observability module (Log Analytics workspace + Application Insights)')
param deployObservability bool = false

@description('Log Analytics log retention in days (min 30, max 730). Dev default: 30.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Deploy Event Hub module (Namespace + purview-diagnostics hub + consumer group)')
param deployEventHub bool = false

@description('Event Hubs Namespace SKU')
@allowed(['Basic', 'Standard', 'Premium'])
param eventHubSku string = 'Standard'

@description('Deploy Functions module (Purview Bridge Function App + plan + backing storage)')
param deployFunctions bool = false

@description('Deploy blob indexers and data sources for AI Search (synergy, zipline, documentation)')
param deploySearchIndexers bool = false

@description('Email address for Azure Monitor alert notifications')
param alertEmail string = ''

@description('Enable Cosmos DB free tier (only one free-tier account allowed per subscription)')
param enableFreeTier bool = true

@description('Event Hub namespace name. Required when deployFunctions=true and deployEventHub=false.')
param eventHubNamespaceName string = ''

// =============================================================================
// RESOURCE GROUP
// =============================================================================

resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-${projectName}-${environment}'
  location: location
  tags: {
    environment: environment
    project: projectName
    managedBy: 'bicep'
  }
}

// =============================================================================
// CORE MODULE
// =============================================================================
// Establishes naming conventions, location, and tags for downstream modules

module core 'core/main.bicep' = {
  name: 'core-deployment'
  scope: resourceGroup
  params: {
    environment: environment
    location: location
    projectName: projectName
  }
}

// =============================================================================
// STORAGE MODULE
// =============================================================================
// Deploys Storage Account and blob containers

module storage 'storage/main.bicep' = if (deployStorage) {
  name: 'storage-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    storageSku: storageSku
    uniqueSuffix: uniqueSuffix
  }
}

// =============================================================================
// COSMOS DB MODULE
// =============================================================================
// INF-006: account-db.bicep now creates the account (no longer references
// an existing resource), making the deployment fully reproducible from zero.

module cosmosAccountDb 'cosmos/account-db.bicep' = {
  name: 'cosmos-account-db'
  scope: resourceGroup
  params: {
    cosmosAccountName: 'cosmos-${core.outputs.resourcePrefix}'
    databaseName: 'metadata_enricher'
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    enableFreeTier: enableFreeTier
  }
}

// =============================================================================
// AZURE AI SEARCH MODULE
// =============================================================================
module search 'search/main.bicep' = if (deploySearch) {
  name: 'search-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    searchSku: searchSku
    deployIndex: deploySearchIndex
    deployIndexers: deploySearchIndexers
    storageAccountResourceId: deployStorage ? storage.outputs.storageAccountId : ''
    storageAccountName: deployStorage ? storage.outputs.storageAccountName : ''
  }
}

// =============================================================================
// COSMOS CONTAINERS MODULE (PHASE 2)
// =============================================================================
module cosmosContainers 'cosmos/containers.bicep' = if (deployCosmosContainers) {
  name: 'cosmos-containers'
  scope: resourceGroup
  params: {
    accountName: 'cosmos-${core.outputs.resourcePrefix}'
    databaseName: 'metadata_enricher'
    partitionKeyPath: '/entityType'
  }
}

// =============================================================================
// EVENT HUB MODULE
// =============================================================================
// Provisions the Event Hubs infrastructure required for the Purview diagnostic
// signal pipeline:
//
//   Purview Diagnostic Settings → Event Hub (purview-diagnostics)
//                                       → Consumer Group (bridge-function)
//                                       → Bridge Function → Service Bus
//
// The DiagnosticsSendRule authorization rule is provisioned to enable Purview
// Diagnostic Settings to send events to the namespace. This is a known Azure
// platform limitation — Diagnostic Settings cannot use Managed Identity; a SAS
// authorization rule with Send permission is required by the platform itself.
// The bridge function (reading from the hub) uses Managed Identity exclusively.

module eventHub 'eventhub/main.bicep' = if (deployEventHub) {
  name: 'eventhub-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    eventHubSku: eventHubSku
  }
}

// =============================================================================
// FUNCTIONS MODULE
// =============================================================================
// Provisions the Purview Bridge Function App that forwards Event Hub events
// to the Service Bus purview-events queue.
//
// Event Hub namespace name is sourced from the eventhub module when
// deployEventHub=true, or from the explicit eventHubNamespaceName parameter
// when the Event Hub was deployed in a prior run.
//
// Service Bus Data Sender RBAC is wired automatically when deployFunctions=true,
// replacing the manual bridgePrincipalId parameter in serviceBusRbac.

module functions 'functions/main.bicep' = if (deployFunctions) {
  name: 'functions-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    uniqueSuffix: uniqueSuffix
    eventHubNamespaceName: deployEventHub ? eventHub.outputs.eventHubNamespaceName : eventHubNamespaceName
    serviceBusNamespaceName: messaging.outputs.serviceBusNamespaceName
    purviewAccountName: purviewAccountName
    cosmosEndpoint: cosmosAccountDb.outputs.cosmosEndpoint
  }
}

// =============================================================================
// MESSAGING MODULE
// =============================================================================

module messaging 'messaging/main.bicep' = {
  name: 'messaging-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    serviceBusSku: serviceBusSku
  }
}

// =============================================================================
// PURVIEW DEPENDENCY MODULE
// =============================================================================
// Validates the pre-provisioned Purview account exists at deploy time.
// Does NOT create the account — Purview must be provisioned separately.
//
// RBAC NOTE: The orchestrator MI requires the "Purview Data Curator" collection
// role, which cannot be assigned via ARM. Run once after provisioning:
//
//   az purview account add-root-collection-admin \
//     --account-name <purviewAccountName> \
//     --resource-group <resourceGroup> \
//     --object-id <orchestratorManagedIdentityPrincipalId>

module purview 'purview/main.bicep' = if (deployPurview) {
  name: 'purview-dependency'
  scope: resourceGroup
  params: {
    purviewAccountName: purviewAccountName
    eventHubAuthorizationRuleId: deployEventHub ? eventHub.outputs.diagnosticsSendRuleId : ''
    eventHubName: 'purview-diagnostics'
  }
}

// =============================================================================
// AZURE CONTAINER REGISTRY MODULE
// =============================================================================
// Provisions the ACR that stores the Orchestrator container image.
//
// When deployRegistry=true:
//   - acrLoginServer is auto-wired into compute (registries block)
//   - acrRbac grants AcrPull to the orchestrator MI after compute is deployed

module registry 'registry/main.bicep' = if (deployRegistry) {
  name: 'registry-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
  }
}

// =============================================================================
// OBSERVABILITY MODULE
// =============================================================================
// Provisions Log Analytics workspace and Application Insights for operational
// telemetry and log aggregation.
//
// When deployObservability=true:
//   - Log Analytics workspace is linked to the CAE via appLogsConfiguration
//     (routes Container App stdout/stderr JSON logs to the workspace)
//   - Application Insights connection string is wired into compute env vars
//     (enables configure_azure_monitor() in the orchestrator)
//
// The Log Analytics shared key is retrieved via listKeys() here in main.bicep
// and passed as @secure() to the compute module — it never appears in outputs.

module observability 'observability/main.bicep' = if (deployObservability) {
  name: 'observability-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    retentionDays: logRetentionDays
    alertEmail: alertEmail
    serviceBusNamespaceId: messaging.outputs.serviceBusNamespaceId
  }
}

// =============================================================================
// AZURE OPENAI MODULE
// =============================================================================
// Provisions the Azure OpenAI account, GPT model deployment, and the
// "Cognitive Services OpenAI User" RBAC assignment for the Orchestrator MI.
//
// The orchestrator acquires Entra ID tokens for scope
// "https://cognitiveservices.azure.com/.default" via DefaultAzureCredential.
// No API keys are used (disableLocalAuth=true enforces this at the platform level).
//
// When deployOpenAI=true:
//   - openAiEndpoint is auto-wired from the module output into compute
//   - RBAC is assigned when deployCompute=true (orchestrator MI auto-wired)
//
// When deployOpenAI=false and a prior deployment exists:
//   - Pass the existing endpoint via the openAiEndpoint parameter
//   - Pass the deployment name via the openAiDeploymentName parameter

module openAi 'openai/main.bicep' = if (deployOpenAI) {
  name: 'openai-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    modelName: openAiModelName
    modelVersion: openAiModelVersion
    deploymentName: openAiDeploymentName
    capacityThousands: openAiCapacityThousands
  }
}

// =============================================================================
// COMPUTE MODULE
// =============================================================================
// Provisions the Container Apps Environment and the Enrichment Orchestrator
// Container App. Conditional on deployCompute=true.
//
// Service Bus FQDN and Cosmos endpoint are derived from sibling module outputs
// so they remain consistent with deployed resource names.
//
// When deployCompute=true the managedIdentityPrincipalId output is forwarded
// to serviceBusRbac, replacing the manual orchestratorPrincipalId parameter.

module compute 'compute/main.bicep' = if (deployCompute) {
  name: 'compute-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    environment: environment
    containerImage: containerImage
    serviceBusNamespaceFqdn: '${messaging.outputs.serviceBusNamespaceName}.servicebus.windows.net'
    cosmosEndpoint: cosmosAccountDb.outputs.cosmosEndpoint
    acrServer: deployRegistry ? registry.outputs.acrLoginServer : ''
    searchEndpoint: deploySearch ? search.outputs.searchEndpoint : searchEndpoint
    openAiEndpoint: deployOpenAI ? openAi.outputs.openAiEndpoint : openAiEndpoint
    openAiDeploymentName: deployOpenAI ? openAi.outputs.deploymentName : openAiDeploymentName
    purviewAccountName: purviewAccountName
    logAnalyticsWorkspaceCustomerId: deployObservability ? observability.outputs.logAnalyticsCustomerId : ''
    logAnalyticsSharedKey: deployObservability ? listKeys(resourceId(subscription().subscriptionId, 'rg-${projectName}-${environment}', 'Microsoft.OperationalInsights/workspaces', 'log-${projectName}-${environment}'), '2023-09-01').primarySharedKey : ''
    appInsightsConnectionString: deployObservability ? observability.outputs.appInsightsConnectionString : ''
  }
}

// =============================================================================
// MESSAGING RBAC MODULE
// =============================================================================
// Grants least-privilege Service Bus roles to compute identities.
// Skipped when principal IDs are empty (i.e., before compute is provisioned).
//
//   Bridge (Azure Function)       → Azure Service Bus Data Sender
//   Orchestrator (Container App)  → Azure Service Bus Data Receiver
//
// When deployCompute=true the orchestrator principal ID is sourced directly
// from the compute module output, removing the need for a manual parameter.
// When deployFunctions=true the bridge principal ID is sourced directly
// from the functions module output, removing the need for a manual parameter.

module serviceBusRbac 'messaging/servicebus-rbac.bicep' = {
  name: 'servicebus-rbac-deployment'
  scope: resourceGroup
  params: {
    serviceBusNamespaceName: messaging.outputs.serviceBusNamespaceName
    bridgePrincipalId: deployFunctions ? functions.outputs.managedIdentityPrincipalId : bridgePrincipalId
    orchestratorPrincipalId: deployCompute ? compute.outputs.managedIdentityPrincipalId : orchestratorPrincipalId
  }
}

// =============================================================================
// COSMOS DB RBAC MODULE
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the
// Cosmos DB Built-in Data Contributor role (data plane) on the Cosmos account.
//
// This is required for the Orchestrator to read and write documents in the
// state and audit containers using Managed Identity — no connection strings.
//
// When deployCompute=true the orchestrator principal ID is sourced directly
// from the compute module output, removing the need for a manual parameter.

module cosmosRbac 'cosmos/cosmos-rbac.bicep' = {
  name: 'cosmos-rbac-deployment'
  scope: resourceGroup
  params: {
    cosmosAccountName: cosmosAccountDb.outputs.cosmosAccountName
    orchestratorPrincipalId: deployCompute ? compute.outputs.managedIdentityPrincipalId : orchestratorPrincipalId
    bridgePrincipalId: deployFunctions ? functions.outputs.managedIdentityPrincipalId : bridgePrincipalId
  }
}

// =============================================================================
// SEARCH RBAC MODULE
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the
// Search Index Data Reader role on the Azure AI Search service.
//
// This is required for the Orchestrator to execute RAG queries against the
// metadata-context-index using Managed Identity — no API keys.
//
// Search service name is sourced from the search module when deploySearch=true,
// or from the explicit searchServiceName parameter when Search was deployed in
// a prior run.
//
// When deployCompute=true the orchestrator principal ID is sourced directly
// from the compute module output, removing the need for a manual parameter.

module searchRbac 'search/search-rbac.bicep' = {
  name: 'search-rbac-deployment'
  scope: resourceGroup
  params: {
    searchServiceName: deploySearch ? search.outputs.searchServiceName : searchServiceName
    orchestratorPrincipalId: deployCompute ? compute.outputs.managedIdentityPrincipalId : orchestratorPrincipalId
  }
}

// =============================================================================
// AZURE OPENAI RBAC MODULE
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the
// "Cognitive Services OpenAI User" role on the Azure OpenAI account.
//
// This is required for the Orchestrator to invoke chat completions using
// DefaultAzureCredential with token scope
// "https://cognitiveservices.azure.com/.default" — no API keys.
//
// Declared as a separate module (not inline in openai/main.bicep) to avoid a
// circular dependency: the compute module sources openAiEndpoint from the
// openai module, so the openai module must not reference compute outputs.
//
// OpenAI account name is sourced from the openai module when deployOpenAI=true,
// or from the oai-{resourcePrefix} naming convention when deployed in a prior run.
//
// When deployCompute=true the orchestrator principal ID is sourced directly
// from the compute module output, removing the need for a manual parameter.

module openAiRbac 'openai/openai-rbac.bicep' = {
  name: 'openai-rbac-deployment'
  scope: resourceGroup
  params: {
    openAiAccountName: deployOpenAI ? openAi.outputs.openAiAccountName : 'oai-${core.outputs.resourcePrefix}'
    orchestratorPrincipalId: deployCompute ? compute.outputs.managedIdentityPrincipalId : orchestratorPrincipalId
  }
}

// =============================================================================
// ACR RBAC MODULE
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the AcrPull role
// so it can pull container images using its system MI — no admin credentials.
//
// Declared separately from registry/main.bicep to avoid a circular dependency:
// compute sources acrLoginServer from the registry module.
//
// ACR name is sourced from the registry module when deployRegistry=true,
// or from the cr{sanitized-prefix} naming convention for prior deployments.

module acrRbac 'registry/acr-rbac.bicep' = {
  name: 'acr-rbac-deployment'
  scope: resourceGroup
  params: {
    acrName: deployRegistry ? registry.outputs.acrName : 'cr${take(replace(core.outputs.resourcePrefix, '-', ''), 20)}'
    orchestratorPrincipalId: deployCompute ? compute.outputs.managedIdentityPrincipalId : orchestratorPrincipalId
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================
// These outputs provide key resource identifiers and endpoints for validation
// and future application integration

@description('Resource group name')
output resourceGroupName string = resourceGroup.name

@description('Cosmos DB account name')
output cosmosAccountName string = cosmosAccountDb.outputs.cosmosAccountName

@description('Service Bus namespace name')
output serviceBusNamespaceName string = messaging.outputs.serviceBusNamespaceName

@description('Service Bus endpoint')
output serviceBusEndpoint string = messaging.outputs.serviceBusEndpoint

@description('Main queue name')
output mainQueueName string = messaging.outputs.mainQueueName

@description('Dead-letter queue path')
output deadLetterQueuePath string = messaging.outputs.deadLetterQueuePath

@description('Purview events queue name')
output purviewEventsQueueName string = messaging.outputs.purviewEventsQueueName

@description('Orchestrator Container App name (empty when deployCompute=false)')
output orchestratorContainerAppName string = deployCompute ? compute.outputs.containerAppName : ''

@description('Orchestrator Managed Identity principal ID (empty when deployCompute=false)')
output orchestratorManagedIdentityPrincipalId string = deployCompute ? compute.outputs.managedIdentityPrincipalId : ''

@description('Container Apps Environment name (empty when deployCompute=false)')
output containerAppsEnvironmentName string = deployCompute ? compute.outputs.containerAppsEnvironmentName : ''

@description('Event Hub namespace name (empty when deployEventHub=false)')
output eventHubNamespaceName string = deployEventHub ? eventHub.outputs.eventHubNamespaceName : ''

@description('Event Hub name for Purview diagnostics (empty when deployEventHub=false)')
output eventHubName string = deployEventHub ? eventHub.outputs.eventHubName : ''

@description('Consumer group for bridge function (empty when deployEventHub=false)')
output bridgeConsumerGroupName string = deployEventHub ? eventHub.outputs.bridgeConsumerGroupName : ''

@description('Authorization rule resource ID for Purview Diagnostic Settings (empty when deployEventHub=false)')
output diagnosticsSendRuleId string = deployEventHub ? eventHub.outputs.diagnosticsSendRuleId : ''

@description('Bridge Function App name (empty when deployFunctions=false)')
output bridgeFunctionAppName string = deployFunctions ? functions.outputs.functionAppName : ''

@description('Bridge Function App Managed Identity principal ID (empty when deployFunctions=false)')
output bridgeManagedIdentityPrincipalId string = deployFunctions ? functions.outputs.managedIdentityPrincipalId : ''

@description('ACR login server (empty when deployRegistry=false)')
output acrLoginServer string = deployRegistry ? registry.outputs.acrLoginServer : ''

@description('ACR name (empty when deployRegistry=false)')
output acrName string = deployRegistry ? registry.outputs.acrName : ''

@description('Log Analytics workspace name (empty when deployObservability=false)')
output logAnalyticsWorkspaceName string = deployObservability ? observability.outputs.logAnalyticsWorkspaceName : ''

@description('Application Insights name (empty when deployObservability=false)')
output appInsightsName string = deployObservability ? observability.outputs.appInsightsName : ''

@description('Azure OpenAI account name (empty when deployOpenAI=false)')
output openAiAccountName string = deployOpenAI ? openAi.outputs.openAiAccountName : ''

@description('Azure OpenAI endpoint (empty when deployOpenAI=false)')
output openAiAccountEndpoint string = deployOpenAI ? openAi.outputs.openAiEndpoint : ''

@description('GPT deployment name (empty when deployOpenAI=false)')
output openAiDeploymentNameOutput string = deployOpenAI ? openAi.outputs.deploymentName : ''
