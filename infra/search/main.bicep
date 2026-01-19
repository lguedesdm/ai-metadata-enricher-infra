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
@allowed(['free', 'basic', 'standard', 'standard2', 'standard3'])
param searchSku string = 'basic'

@description('Index name')
param indexName string = 'metadata-index'

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

// =============================================================================
// SEARCH INDEX
// =============================================================================
// NOTE: This is a frozen placeholder schema for the MVP contract.
// The index defines the searchable metadata structure.
//
// Fields:
//   - id: Unique identifier (key)
//   - entityType: Type of metadata entity (filterable)
//   - title: Entity title (searchable)
//   - description: Entity description (searchable)
//   - suggestedDescription: AI-generated description candidate (searchable, filterable)
//   - tags: Metadata tags (searchable, filterable, facetable)
//   - createdAt: Creation timestamp (filterable, sortable)
//   - updatedAt: Last update timestamp (filterable, sortable)
//
// IMPORTANT: This schema is intentionally simple for MVP.
// Expand with domain-specific fields, embeddings, and advanced features as needed.
// =============================================================================

var indexSchema = {
  name: indexName
  fields: [
    {
      name: 'id'
      type: 'Edm.String'
      key: true
      searchable: false
      filterable: false
      sortable: false
      facetable: false
    }
    {
      name: 'entityType'
      type: 'Edm.String'
      searchable: false
      filterable: true
      sortable: true
      facetable: true
    }
    {
      name: 'title'
      type: 'Edm.String'
      searchable: true
      filterable: true
      sortable: true
      facetable: false
      analyzer: 'standard.lucene'
    }
    {
      name: 'description'
      type: 'Edm.String'
      searchable: true
      filterable: false
      sortable: false
      facetable: false
      analyzer: 'standard.lucene'
    }
    {
      name: 'suggestedDescription'
      type: 'Edm.String'
      searchable: true
      filterable: true
      sortable: false
      facetable: false
      analyzer: 'standard.lucene'
    }
    {
      name: 'tags'
      type: 'Collection(Edm.String)'
      searchable: true
      filterable: true
      sortable: false
      facetable: true
    }
    {
      name: 'createdAt'
      type: 'Edm.DateTimeOffset'
      searchable: false
      filterable: true
      sortable: true
      facetable: false
    }
    {
      name: 'updatedAt'
      type: 'Edm.DateTimeOffset'
      searchable: false
      filterable: true
      sortable: true
      facetable: false
    }
  ]
  scoringProfiles: []
  corsOptions: {
    allowedOrigins: ['*']  // MVP: Permissive CORS for Dev
    maxAgeInSeconds: 300
  }
  suggesters: [
    {
      name: 'title-suggester'
      searchMode: 'analyzingInfixMatching'
      sourceFields: ['title']
    }
  ]
}

// NOTE: Index creation via Bicep requires the 'indexes' nested resource.
// However, Bicep does not natively support index creation declaratively.
// For MVP, document the schema here and create the index via:
//   1. Azure Portal
//   2. Azure CLI / PowerShell script
//   3. REST API call during deployment
//
// FUTURE: Consider ARM deployment scripts or post-deployment automation.

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

@description('Index schema (for documentation and manual creation)')
output indexSchemaDefinition object = indexSchema
