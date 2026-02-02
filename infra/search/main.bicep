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

@description('Whether to deploy the unified index from the frozen schema JSON')
param deployIndex bool = false

@description('Unified index name (must be versioned and treated as a contract)')
param indexName string = 'metadata-context-index-v1'

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
// UNIFIED INDEX DEPLOYMENT (Schema-driven via deployment script)
// =============================================================================
// Implements the frozen unified index by consuming a versioned JSON schema in-repo.
// Uses Azure CLI (az rest) to PUT the index to the search service to preserve
// full fidelity for semantic/vector configurations.

// Admin key to authenticate management-plane REST call
var adminKeys = searchService.listAdminKeys()

// Load schema content from a fixed, versioned path (compile-time constant)
var indexSchemaContent = loadTextContent('./schemas/metadata-context-index-v1.json')

// User-assigned managed identity required by deploymentScripts
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployIndex) {
  name: '${resourcePrefix}-search-index-script-mi'
  location: location
}

@description('Create or update the unified Azure AI Search index from the JSON schema')
resource createUnifiedIndex 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (deployIndex) {
  name: '${resourcePrefix}-create-unified-index'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.63.0'
    timeout: 'PT15M'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    environmentVariables: [
      {
        name: 'SEARCH_SERVICE_NAME'
        value: searchService.name
      }
      {
        name: 'SEARCH_ADMIN_KEY'
        secureValue: adminKeys.primaryKey
      }
      {
        name: 'INDEX_NAME'
        value: indexName
      }
      {
        name: 'INDEX_JSON_B64'
        value: base64(indexSchemaContent)
      }
      {
        name: 'SEARCH_API_VERSION'
        value: '2023-11-01'
      }
    ]
    scriptContent: '''
set -euo pipefail

tmpdir=$(mktemp -d)
echo "$INDEX_JSON_B64" | base64 -d > "$tmpdir/index.json"

url="https://${SEARCH_SERVICE_NAME}.search.windows.net/indexes/${INDEX_NAME}?api-version=${SEARCH_API_VERSION}"

echo "Creating/updating index: ${INDEX_NAME} on service: ${SEARCH_SERVICE_NAME}"
az rest \
  --method put \
  --url "$url" \
  --headers "Content-Type=application/json" "api-key=${SEARCH_ADMIN_KEY}" \
  --body @"$tmpdir/index.json"

echo "Index deployment completed."
'''
  }
}

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

@description('Unified index name (deployed when deployIndex=true)')
output unifiedIndexName string = indexName
