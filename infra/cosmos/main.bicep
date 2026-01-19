// =============================================================================
// Cosmos DB Module
// =============================================================================
// Purpose: Azure Cosmos DB (NoSQL API) for state management and audit logging.
//
// Database: Shared across containers
// Containers:
//   - state: Transient operational state (TTL = 7 days)
//   - audit: Audit trail and compliance logging (TTL = 180 days)
//
// Partition Key: /entityType (consistent across containers)
//
// MVP: Public endpoints, secured via Managed Identity and RBAC.
// FUTURE: Consider Private Endpoints and advanced indexing policies for Test/Prod.
// =============================================================================

@description('The resource name prefix')
param resourcePrefix string

@description('The Azure region for resources')
param location string

@description('Tags to apply to resources')
param tags object

@description('Cosmos DB account name')
param cosmosAccountName string = '${resourcePrefix}-cosmos'

@description('Unique suffix for globally unique resources (leave empty for auto-generated)')
param uniqueSuffix string = ''

@description('Database name')
param databaseName string = 'enricher-db'

@description('Partition key path (consistent across containers)')
param partitionKeyPath string = '/entityType'

@description('State container TTL in seconds (7 days = 604800 seconds)')
param stateTtlSeconds int = 604800

@description('Audit container TTL in seconds (180 days = 15552000 seconds)')
param auditTtlSeconds int = 15552000

// =============================================================================
// COSMOS DB ACCOUNT
// =============================================================================

var cosmosDbAccountName = uniqueSuffix == '' ? '${cosmosAccountName}-${uniqueString(resourcePrefix)}' : '${cosmosAccountName}-${uniqueSuffix}'

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: take(cosmosDbAccountName, 44)  // Cosmos names: max 44 chars, lowercase alphanumeric and hyphens
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'  // MVP: Session consistency for balance
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false  // MVP: No zone redundancy for Dev
      }
    ]
    publicNetworkAccess: 'Enabled'  // MVP: Public endpoints for Dev
    enableAutomaticFailover: false  // MVP: No automatic failover for Dev
    enableFreeTier: false
    capabilities: [
      {
        name: 'EnableServerless'  // MVP: Serverless for cost optimization in Dev
      }
    ]
  }
}

// =============================================================================
// DATABASE
// =============================================================================

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' = {
  parent: cosmosAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

// =============================================================================
// CONTAINERS
// =============================================================================

// State Container: Transient operational state with 7-day TTL
resource stateContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: database
  name: 'state'
  properties: {
    resource: {
      id: 'state'
      partitionKey: {
        paths: [partitionKeyPath]
        kind: 'Hash'
      }
      defaultTtl: stateTtlSeconds  // Auto-delete after 7 days
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/"_etag"/?'
          }
        ]
      }
    }
  }
}

// Audit Container: Long-term audit trail with 180-day TTL
resource auditContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: database
  name: 'audit'
  properties: {
    resource: {
      id: 'audit'
      partitionKey: {
        paths: [partitionKeyPath]
        kind: 'Hash'
      }
      defaultTtl: auditTtlSeconds  // Auto-delete after 180 days
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/"_etag"/?'
          }
        ]
      }
    }
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Cosmos DB account resource ID')
output cosmosAccountId string = cosmosAccount.id

@description('Cosmos DB account name')
output cosmosAccountName string = cosmosAccount.name

@description('Cosmos DB endpoint')
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint

@description('Database name')
output databaseName string = database.name

@description('System-assigned Managed Identity principal ID')
output managedIdentityPrincipalId string = cosmosAccount.identity.principalId
