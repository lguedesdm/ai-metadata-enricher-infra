// =============================================================================
// Cosmos DB Containers (DEV)
// =============================================================================
// Scope: Resource Group
// Containers:
// - state  (TTL: 7 days  = 604800 s)
// - audit  (TTL: 180 days = 15552000 s)
// Partition key: /entityType
// Inherit shared throughput from database (no container throughput)
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
      defaultTtl: 604800    // 7 days — state documents expire after one enrichment cycle window
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
      defaultTtl: 15552000    // 180 days — audit records retained for operational review
    }
  }
}

// Outputs
@description('State container name')
output stateContainerName string = stateContainer.name

@description('Audit container name')
output auditContainerName string = auditContainer.name
