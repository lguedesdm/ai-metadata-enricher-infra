// =============================================================================
// Cosmos DB Containers (DEV)
// =============================================================================
// Scope: Resource Group
// Containers:
// - state
// - audit
// Partition key: /entityType
// Inherit shared throughput from database (no container throughput)
// No TTL, no custom indexes
// =============================================================================

@description('Cosmos DB account name (existing)')
param accountName string = 'cosmos-ai-metadata-dev'

@description('Logical database name (existing)')
param databaseName string = 'metadata'

@description('Partition key path for containers')
param partitionKeyPath string = '/entityType'

// Existing account & database references
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' existing = {
  name: accountName
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' existing = {
  parent: cosmosAccount
  name: databaseName
}

// Containers (no TTL, no custom indexes)
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
    }
  }
}

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
    }
  }
}

// Outputs
@description('State container name')
output stateContainerName string = stateContainer.name

@description('Audit container name')
output auditContainerName string = auditContainer.name
