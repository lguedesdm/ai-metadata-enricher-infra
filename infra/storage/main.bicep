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

resource synergyContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'synergy'
  properties: {
    publicAccess: 'None'
  }
}

resource ziplineContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'zipline'
  properties: {
    publicAccess: 'None'
  }
}

resource documentationContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'documentation'
  properties: {
    publicAccess: 'None'
  }
}

resource schemasContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'schemas'
  properties: {
    publicAccess: 'None'
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
