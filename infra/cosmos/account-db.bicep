// =============================================================================
// Cosmos DB Account + Database (DEV)
// =============================================================================
// Scope: Resource Group
// SQL API (Core)
// - Account: cosmos-ai-metadata-dev
// - Database: metadata
// - Throughput: Provisioned 400 RU/s at database level (shared)
// - No containers, no TTL, no RBAC
// =============================================================================

// Location and tags are not used when referencing existing account

@description('Cosmos DB account name (fixed for DEV)')
param cosmosAccountName string = 'cosmos-ai-metadata-dev'

@description('Logical database name')
param databaseName string = 'metadata'

// =============================================================================
// COSMOS DB ACCOUNT (EXISTING)
// =============================================================================

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' existing = {
  name: cosmosAccountName
}

// =============================================================================
// DATABASE (WITH SHARED PROVISIONED THROUGHPUT)
// =============================================================================

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' = {
  parent: cosmosAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
    options: {
      throughput: 400
    }
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Cosmos DB account name')
output cosmosAccountName string = cosmosAccount.name

@description('Database name')
output databaseName string = database.name
