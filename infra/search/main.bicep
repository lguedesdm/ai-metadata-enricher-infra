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

@description('Unified index name (must match the canonical contract)')
param indexName string = 'metadata-context-index'

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
//
// INF-013: Admin key authentication replaced with Managed Identity.
// The deployment script's user-assigned MI acquires an Azure AD token for the
// AI Search data-plane scope ("https://search.azure.com") and presents it as
// a Bearer token. No admin keys are retrieved or stored.
//
// RBAC pre-requisite:
//   scriptIdentitySearchRbac grants Search Index Data Contributor on the
//   search service to the script MI before the deployment script runs.

// Load schema content from a fixed, versioned path (compile-time constant)
var indexSchemaContent = loadTextContent('./schemas/metadata-context-index.json')

// Search Index Data Contributor — allows creating and updating indexes (data plane)
var searchIndexDataContributorRoleId = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'

// User-assigned managed identity required by deploymentScripts
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployIndex) {
  name: '${resourcePrefix}-search-index-script-mi'
  location: location
}

// =============================================================================
// RBAC — Script MI → Search Index Data Contributor
// =============================================================================
// Grants the deployment script's MI permission to create and update indexes on
// the search service via Azure AD token (no admin key required).
//
// Must be provisioned before the deployment script runs — enforced via
// dependsOn on the createUnifiedIndex resource.

resource scriptIdentitySearchRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployIndex) {
  name: guid(searchService.id, scriptIdentity.properties.principalId, searchIndexDataContributorRoleId)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributorRoleId)
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
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

# Acquire an Azure AD access token for the AI Search data-plane scope using
# the deployment script Managed Identity. No admin keys are used.
token=$(az account get-access-token --resource "https://search.azure.com" --query accessToken -o tsv)

echo "Creating/updating index: ${INDEX_NAME} on service: ${SEARCH_SERVICE_NAME}"
az rest \
  --method put \
  --url "$url" \
  --headers "Content-Type=application/json" "Authorization=Bearer $token" \
  --body @"$tmpdir/index.json"

echo "Index deployment completed."
'''
  }
  dependsOn: [
    scriptIdentitySearchRbac    // RBAC must be active before the script calls the search data-plane
  ]
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
