// =============================================================================
// Storage Module
// =============================================================================
// Purpose: Azure Storage Account with blob containers for the enrichment pipeline.
//
// Containers:
//   - synergy: Primary storage for enrichment artifacts
//   - zipline: Transient/pipeline storage
//   - documentation: Documentation and reference materials
//   - schemas: JSON schemas and contracts
//
// MVP: Public endpoints, secured via Managed Identity and RBAC.
// FUTURE: Consider Private Endpoints for Test/Prod environments.
// =============================================================================

@description('The resource name prefix')
param resourcePrefix string

@description('The Azure region for resources')
param location string

@description('Tags to apply to resources')
param tags object

@description('Storage Account SKU')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_ZRS'])
param storageSku string = 'Standard_LRS'

@description('Minimum TLS version')
param minimumTlsVersion string = 'TLS1_2'

@description('Unique suffix for globally unique resources (leave empty for auto-generated)')
param uniqueSuffix string = ''

// =============================================================================
// STORAGE ACCOUNT
// =============================================================================

var storageAccountName = uniqueSuffix == '' ? take('${replace(resourcePrefix, '-', '')}st${uniqueString(resourcePrefix)}', 24) : take('${replace(resourcePrefix, '-', '')}st${uniqueSuffix}', 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName  // Storage names: 3-24 chars, alphanumeric only
  location: location
  tags: tags
  sku: {
    name: storageSku
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: minimumTlsVersion
    allowBlobPublicAccess: false  // Enforce private access via RBAC
    publicNetworkAccess: 'Enabled'  // MVP: Public endpoints for Dev
    networkAcls: {
      defaultAction: 'Allow'  // MVP: No firewall restrictions in Dev
      bypass: 'AzureServices'
    }
    encryption: {
      services: {
        blob: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// =============================================================================
// BLOB SERVICE
// =============================================================================
// REATIVADO: Necessário como parent resource para criar Blob Containers (TASK 2)

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7  // MVP: Simple retention for Dev
    }
  }
}

// =============================================================================
// BLOB CONTAINERS
// =============================================================================
// REATIVADO: TASK 2 - Create Blob Containers (synergy, zipline, documentation, schemas)

resource synergyContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'synergy'
  properties: {
    publicAccess: 'None'  // Privado, sem acesso público
  }
}

resource ziplineContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'zipline'
  properties: {
    publicAccess: 'None'  // Privado, sem acesso público
  }
}

resource documentationContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'documentation'
  properties: {
    publicAccess: 'None'  // Privado, sem acesso público
  }
}

resource schemasContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'schemas'
  properties: {
    publicAccess: 'None'  // Privado, sem acesso público
  }
}

// =============================================================================
// RBAC - ROLE ASSIGNMENTS
// =============================================================================
// TASK 3: Apply RBAC for Storage Account access using Managed Identity
// Built-in Azure roles for Storage:
// - Storage Blob Data Reader: 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
// - Storage Blob Data Contributor: ba92f5b4-2d11-453d-a403-e96b0029c9fe (read/write/delete)
//
// MVP Dev Strategy:
// - For now, we grant the Storage Account's own Managed Identity contributor access
//   to demonstrate RBAC pattern and validate access model
// - Future tasks will grant specific roles to Orchestrator, AI Search, etc.
// - No SAS tokens or access keys are used (RBAC-only authentication)

// Storage Blob Data Contributor role for the Storage Account's own Managed Identity
// This demonstrates RBAC setup and will be used for internal operations
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, 'StorageBlobDataContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: storageAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Storage account resource ID')
output storageAccountId string = storageAccount.id

@description('Storage account name')
output storageAccountName string = storageAccount.name

@description('Storage account primary endpoint')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

@description('System-assigned Managed Identity principal ID')
output managedIdentityPrincipalId string = storageAccount.identity.principalId

@description('RBAC role assignment ID for validation')
output roleAssignmentId string = storageRoleAssignment.id

@description('Storage Account resource name for access validation commands')
output storageAccountNameForValidation string = storageAccount.name

@description('Resource group name (derived from resourceId)')
output resourceGroupName string = split(storageAccount.id, '/')[4]
