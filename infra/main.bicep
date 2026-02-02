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
param projectName string = 'aime'

@description('Storage Account SKU')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_ZRS'])
param storageSku string = 'Standard_LRS'

@description('Cosmos DB State container TTL in seconds (7 days)')
param stateTtlSeconds int = 604800

@description('Cosmos DB Audit container TTL in seconds (180 days)')
param auditTtlSeconds int = 15552000

@description('Azure AI Search SKU')
@allowed(['dev', 'free', 'basic', 'standard', 'standard2', 'standard3'])
param searchSku string = 'dev'

@description('Service Bus SKU')
@allowed(['Basic', 'Standard', 'Premium'])
param serviceBusSku string = 'Standard'

@description('Unique suffix for globally unique resources (leave empty to auto-generate based on subscription and resource group)')
param uniqueSuffix string = ''

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

module storage 'storage/main.bicep' = {
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
// BLOCKED: Pertence à task "Provision Azure Cosmos DB"
// module cosmos 'cosmos/main.bicep' = {
//   name: 'cosmos-deployment'
//   scope: resourceGroup
//   params: {
//     resourcePrefix: core.outputs.resourcePrefix
//     location: core.outputs.resourceLocation
//     tags: core.outputs.resourceTags
//     stateTtlSeconds: stateTtlSeconds
//     auditTtlSeconds: auditTtlSeconds
//     uniqueSuffix: uniqueSuffix
//   }
// }

// =============================================================================
// AZURE AI SEARCH MODULE
// =============================================================================
module search 'search/main.bicep' = {
  name: 'search-deployment'
  scope: resourceGroup
  params: {
    resourcePrefix: core.outputs.resourcePrefix
    location: core.outputs.resourceLocation
    tags: core.outputs.resourceTags
    searchSku: searchSku
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

@description('Storage account name')
output storageAccountName string = storage.outputs.storageAccountName

// BLOCKED: Outputs dos módulos bloqueados
// @description('Cosmos DB account name')
// output cosmosAccountName string = cosmos.outputs.cosmosAccountName

// @description('Cosmos DB endpoint')
// output cosmosEndpoint string = cosmos.outputs.cosmosEndpoint

@description('Search service name')
output searchServiceName string = search.outputs.searchServiceName

@description('Search service endpoint')
output searchEndpoint string = search.outputs.searchEndpoint

// @description('Service Bus namespace name')
// output serviceBusNamespaceName string = messaging.outputs.serviceBusNamespaceName

// @description('Service Bus endpoint')
// output serviceBusEndpoint string = messaging.outputs.serviceBusEndpoint

// @description('Main queue name')
// output mainQueueName string = messaging.outputs.mainQueueName

// @description('Dead-letter queue path')
// output deadLetterQueuePath string = messaging.outputs.deadLetterQueuePath
