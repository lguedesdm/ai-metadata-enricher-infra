// =============================================================================
// Azure AI Search Module
// =============================================================================
// Purpose: Azure AI Search service and index for metadata enrichment.
//
// MVP: Basic search service with a contract-focused index schema.
// Index schema is intentionally frozen for Dev to establish a stable contract.
//
// FUTURE: Expand index schema, add semantic search, vector search, and
// custom analyzers in Test/Prod as enrichment capabilities mature.
// =============================================================================

@description('The resource name prefix')
param resourcePrefix string

@description('The Azure region for resources')
param location string

@description('Tags to apply to resources')
param tags object

@description('Search service SKU')
@allowed(['dev', 'free', 'basic', 'standard', 'standard2', 'standard3'])
param searchSku string = 'dev'

// =============================================================================
// SEARCH SERVICE
// =============================================================================

resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: '${resourcePrefix}-search'
  location: location
  tags: tags
  sku: {
    name: searchSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1  // MVP: Single replica for Dev
    partitionCount: 1  // MVP: Single partition for Dev
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'  // MVP: Public endpoints for Dev
    networkRuleSet: {
      ipRules: []
    }
    encryptionWithCmk: {
      enforcement: 'Unspecified'  // MVP: Platform-managed keys for Dev
    }
  }
}

// Indexes, indexers, data sources, and semantic/vector configs are intentionally out of scope.

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Search service resource ID')
output searchServiceId string = searchService.id

@description('Search service name')
output searchServiceName string = searchService.name

@description('Search service endpoint')
output searchEndpoint string = 'https://${searchService.name}.search.windows.net'

@description('System-assigned Managed Identity principal ID')
output managedIdentityPrincipalId string = searchService.identity.principalId
