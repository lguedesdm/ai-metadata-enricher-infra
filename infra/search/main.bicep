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

@description('Whether to deploy blob indexers and data sources for synergy, zipline, and documentation containers')
param deployIndexers bool = false

@description('Force re-execution of deployment scripts on each deploy. Defaults to current UTC timestamp.')
param scriptForceUpdateTag string = utcNow()

@description('Storage account resource ID. Required when deployIndexers=true (used for MI connection string).')
param storageAccountResourceId string = ''

@description('Storage account name. Required when deployIndexers=true (used for RBAC assignment).')
param storageAccountName string = ''

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
    // Enable AAD token (RBAC) authentication alongside API keys.
    // Required for the deployment script to call the Search data-plane using
    // a Managed Identity Bearer token. Without this, all token requests return 403.
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
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

// User-assigned managed identity required by deploymentScripts (index and/or indexers)
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployIndex || deployIndexers) {
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

resource scriptIdentitySearchRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployIndex || deployIndexers) {
  name: guid(searchService.id, scriptIdentity.id, searchIndexDataContributorRoleId)
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
      {
        name: 'SCRIPT_MI_CLIENT_ID'
        value: scriptIdentity!.properties.clientId
      }
    ]
    scriptContent: '''
set -euo pipefail

# Explicitly authenticate with the User-Assigned MI so az commands use
# the correct identity context inside the ACI container.
az login --identity --username "$SCRIPT_MI_CLIENT_ID"

tmpdir=$(mktemp -d)
echo "$INDEX_JSON_B64" | base64 -d > "$tmpdir/index.json"

url="https://${SEARCH_SERVICE_NAME}.search.windows.net/indexes/${INDEX_NAME}?api-version=${SEARCH_API_VERSION}"

MAX_RETRIES=5
RETRY_WAIT=60

for attempt in $(seq 1 $MAX_RETRIES); do
  echo "Attempt $attempt/$MAX_RETRIES: deploying index ${INDEX_NAME}..."

  if az rest \
    --method put \
    --url "$url" \
    --resource "https://search.azure.com" \
    --headers "Content-Type=application/json" \
    --body @"$tmpdir/index.json"; then
    echo "Index deployment completed successfully."
    exit 0
  fi

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    echo "Attempt $attempt failed. Waiting ${RETRY_WAIT}s..."
    sleep $RETRY_WAIT
  fi
done

echo "All $MAX_RETRIES attempts failed."
exit 1
'''
  }
  dependsOn: [
    scriptIdentitySearchRbac    // RBAC must be active before the script calls the search data-plane
  ]
}

// =============================================================================
// INDEXER DEPLOYMENT (Data sources + Indexers via deployment script)
// =============================================================================
// Provisions 3 blob data sources and 3 indexers against the unified index.
// Uses Managed Identity for blob access (no storage keys).
//
// Data sources use the ResourceId connection string format, which tells
// Azure AI Search to authenticate using its system-assigned MI:
//   ResourceId=/subscriptions/.../storageAccounts/{name};
//
// Each indexer has:
//   - Schedule: PT1H (hourly polling)
//   - Field mappings per ingestion-pipeline-repair-report.md
//   - Parsing mode: jsonArray for synergy/zipline, default for documentation
//
// RBAC pre-requisites (must be active before indexers run):
//   1. scriptIdentitySearchRbac — Script MI → Search Index Data Contributor
//   2. scriptIdentitySearchServiceRbac — Script MI → Search Service Contributor
//   3. searchStorageRbac (in main.bicep) — Search Service MI → Storage Blob Data Reader
//
// The Search Service Contributor role is required because data sources and
// indexers are service-level resources, not index-level resources.

// Storage Blob Data Reader — allows the search service MI to read blobs for indexing
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

// Search Service Contributor — allows creating data sources and indexers (service level)
var searchServiceContributorRoleId = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'

// Reference the existing storage account so we can assign RBAC on it
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = if (deployIndexers) {
  name: storageAccountName
}

// =============================================================================
// RBAC — Search Service MI → Storage Blob Data Reader
// =============================================================================
// Grants the search service's system-assigned MI permission to read blobs from
// the storage account. This is validated by Azure AI Search at data source
// creation time — it must be active BEFORE the deployment script runs.
//
// Placed inside this module (not in a sibling module) to guarantee the
// dependsOn chain: RBAC → deployment script.

resource searchStorageBlobReaderRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployIndexers && !empty(storageAccountName)) {
  name: guid(storageAccount.id, searchService.id, storageBlobDataReaderRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource scriptIdentitySearchServiceRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployIndexers) {
  name: guid(searchService.id, scriptIdentity.id, searchServiceContributorRoleId)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributorRoleId)
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Create or update blob data sources and indexers for synergy, zipline, and documentation')
resource createIndexersAndDataSources 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (deployIndexers) {
  name: '${resourcePrefix}-create-indexers'
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
    forceUpdateTag: scriptForceUpdateTag
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
        name: 'STORAGE_RESOURCE_ID'
        value: storageAccountResourceId
      }
      {
        name: 'SEARCH_API_VERSION'
        value: '2023-11-01'
      }
      {
        name: 'SCRIPT_MI_CLIENT_ID'
        value: scriptIdentity!.properties.clientId
      }
    ]
    scriptContent: '''
set -euo pipefail

# Authenticate with the User-Assigned MI
az login --identity --username "$SCRIPT_MI_CLIENT_ID"

SEARCH_URL="https://${SEARCH_SERVICE_NAME}.search.windows.net"
API_VER="api-version=${SEARCH_API_VERSION}"
MI_CONN="ResourceId=${STORAGE_RESOURCE_ID};"

MAX_RETRIES=5
RETRY_WAIT=60

# Helper: PUT a JSON resource to the Search REST API with retry
put_resource() {
  local resource_type="$1"
  local resource_name="$2"
  local json_body="$3"

  local url="${SEARCH_URL}/${resource_type}/${resource_name}?${API_VER}"

  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "[$resource_type/$resource_name] Attempt $attempt/$MAX_RETRIES..."

    if az rest \
      --method put \
      --url "$url" \
      --resource "https://search.azure.com" \
      --headers "Content-Type=application/json" \
      --body "$json_body"; then
      echo "[$resource_type/$resource_name] OK"
      return 0
    fi

    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      echo "[$resource_type/$resource_name] Attempt $attempt failed. Waiting ${RETRY_WAIT}s..."
      sleep $RETRY_WAIT
    fi
  done

  echo "[$resource_type/$resource_name] All $MAX_RETRIES attempts failed."
  return 1
}

# =========================================================================
# DATA SOURCES (3) — Managed Identity connection strings (no storage keys)
# =========================================================================

echo "=== Creating data sources ==="

put_resource "datasources" "blob-metadata-datasource" "{
  \"name\": \"blob-metadata-datasource\",
  \"type\": \"azureblob\",
  \"credentials\": { \"connectionString\": \"${MI_CONN}\" },
  \"container\": { \"name\": \"documentation\" }
}"

put_resource "datasources" "blob-synergy-datasource" "{
  \"name\": \"blob-synergy-datasource\",
  \"type\": \"azureblob\",
  \"credentials\": { \"connectionString\": \"${MI_CONN}\" },
  \"container\": { \"name\": \"synergy\" }
}"

put_resource "datasources" "blob-zipline-datasource" "{
  \"name\": \"blob-zipline-datasource\",
  \"type\": \"azureblob\",
  \"credentials\": { \"connectionString\": \"${MI_CONN}\" },
  \"container\": { \"name\": \"zipline\" }
}"

# =========================================================================
# INDEXERS (3) — PT1H schedule, field mappings per repair report
# =========================================================================

echo "=== Creating indexers ==="

# --- metadata-context-indexer (documentation container, default parsing) ---
put_resource "indexers" "metadata-context-indexer" "{
  \"name\": \"metadata-context-indexer\",
  \"dataSourceName\": \"blob-metadata-datasource\",
  \"targetIndexName\": \"${INDEX_NAME}\",
  \"schedule\": { \"interval\": \"PT1H\" },
  \"parameters\": { \"configuration\": {} },
  \"fieldMappings\": []
}"

# --- synergy-elements-indexer (jsonArray, documentRoot=/elements, 8 mappings) ---
put_resource "indexers" "synergy-elements-indexer" "{
  \"name\": \"synergy-elements-indexer\",
  \"dataSourceName\": \"blob-synergy-datasource\",
  \"targetIndexName\": \"${INDEX_NAME}\",
  \"schedule\": { \"interval\": \"PT1H\" },
  \"parameters\": {
    \"configuration\": {
      \"parsingMode\": \"jsonArray\",
      \"documentRoot\": \"/elements\"
    }
  },
  \"fieldMappings\": [
    { \"sourceFieldName\": \"elementName\", \"targetFieldName\": \"id\", \"mappingFunction\": { \"name\": \"base64Encode\" } },
    { \"sourceFieldName\": \"elementName\", \"targetFieldName\": \"elementName\" },
    { \"sourceFieldName\": \"elementName\", \"targetFieldName\": \"title\" },
    { \"sourceFieldName\": \"elementType\", \"targetFieldName\": \"elementType\" },
    { \"sourceFieldName\": \"description\", \"targetFieldName\": \"description\" },
    { \"sourceFieldName\": \"description\", \"targetFieldName\": \"content\" },
    { \"sourceFieldName\": \"sourceSystem\", \"targetFieldName\": \"sourceSystem\" },
    { \"sourceFieldName\": \"cedsLink\", \"targetFieldName\": \"cedsLink\" }
  ]
}"

# --- zipline-elements-indexer (jsonArray, root-level array, 11 mappings) ---
put_resource "indexers" "zipline-elements-indexer" "{
  \"name\": \"zipline-elements-indexer\",
  \"dataSourceName\": \"blob-zipline-datasource\",
  \"targetIndexName\": \"${INDEX_NAME}\",
  \"schedule\": { \"interval\": \"PT1H\" },
  \"parameters\": {
    \"configuration\": {
      \"parsingMode\": \"jsonArray\"
    }
  },
  \"fieldMappings\": [
    { \"sourceFieldName\": \"id\", \"targetFieldName\": \"id\", \"mappingFunction\": { \"name\": \"base64Encode\" } },
    { \"sourceFieldName\": \"entityType\", \"targetFieldName\": \"elementType\" },
    { \"sourceFieldName\": \"entityName\", \"targetFieldName\": \"elementName\" },
    { \"sourceFieldName\": \"entityName\", \"targetFieldName\": \"title\" },
    { \"sourceFieldName\": \"cedsReference\", \"targetFieldName\": \"cedsLink\" },
    { \"sourceFieldName\": \"businessMeaning\", \"targetFieldName\": \"suggestedDescription\" },
    { \"sourceFieldName\": \"sourceSystem\", \"targetFieldName\": \"sourceSystem\" },
    { \"sourceFieldName\": \"description\", \"targetFieldName\": \"description\" },
    { \"sourceFieldName\": \"content\", \"targetFieldName\": \"content\" },
    { \"sourceFieldName\": \"tags\", \"targetFieldName\": \"tags\" },
    { \"sourceFieldName\": \"lastUpdated\", \"targetFieldName\": \"lastUpdated\" }
  ]
}"

echo "=== All data sources and indexers deployed successfully ==="
'''
  }
  dependsOn: [
    scriptIdentitySearchRbac          // Search Index Data Contributor must be active
    scriptIdentitySearchServiceRbac   // Search Service Contributor must be active
    searchStorageBlobReaderRbac       // Storage Blob Data Reader must be active for MI data sources
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
