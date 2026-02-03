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
param environment string = 'dev'

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
module cosmosAccountDb 'cosmos/account-db.bicep' = {
  name: 'cosmos-account-db'
  scope: resourceGroup
  params: {
    cosmosAccountName: 'cosmos-ai-metadata-dev'
    databaseName: 'metadata'
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
  }
}

// =============================================================================
// COSMOS CONTAINERS MODULE (PHASE 2)
// =============================================================================
module cosmosContainers 'cosmos/containers.bicep' = if (deployCosmosContainers) {
  name: 'cosmos-containers'
  scope: resourceGroup
  params: {
    accountName: 'cosmos-ai-metadata-dev'
    databaseName: 'metadata'
    partitionKeyPath: '/entityType'
  }
}

// =============================================================================
// MESSAGING MODULE
// =============================================================================
// BLOCKED: Pertence à task "Provision Service Bus"
// module messaging 'messaging/main.bicep' = {
//   name: 'messaging-deployment'
//   scope: resourceGroup
//   params: {
//     resourcePrefix: core.outputs.resourcePrefix
//     location: core.outputs.resourceLocation
//     tags: core.outputs.resourceTags
//     serviceBusSku: serviceBusSku
//   }
// }

// =============================================================================
// OUTPUTS
// =============================================================================
// These outputs provide key resource identifiers and endpoints for validation
// and future application integration

@description('Resource group name')
output resourceGroupName string = resourceGroup.name

@description('Cosmos DB account name')
output cosmosAccountName string = cosmosAccountDb.outputs.cosmosAccountName

// @description('Service Bus namespace name')
// output serviceBusNamespaceName string = messaging.outputs.serviceBusNamespaceName

// @description('Service Bus endpoint')
// output serviceBusEndpoint string = messaging.outputs.serviceBusEndpoint

// @description('Main queue name')
// output mainQueueName string = messaging.outputs.mainQueueName

// @description('Dead-letter queue path')
// output deadLetterQueuePath string = messaging.outputs.deadLetterQueuePath
