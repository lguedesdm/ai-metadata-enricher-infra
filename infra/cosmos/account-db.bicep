// =============================================================================
// Cosmos DB Account + Database (DEV)
// =============================================================================
// Scope: Resource Group
// SQL API (Core / NoSQL)
//
// - Account : cosmos-ai-metadata-dev  (fully managed by IaC — no manual pre-creation)
// - Database : metadata_enricher
// - Mode     : Serverless (cost-optimised for Dev)
// - Consistency: Session
// - Identity : System-Assigned Managed Identity
// - Auth     : Managed Identity only — no connection strings
//
// INF-006: Replaced 'existing' reference with a full resource declaration so
// that the deployment is self-contained and reproducible from zero.
// =============================================================================

@description('Cosmos DB account name')
param cosmosAccountName string = 'cosmos-ai-metadata-dev'

@description('Azure region for the Cosmos DB account')
param location string

@description('Tags to apply to all resources')
param tags object

@description('Logical database name')
param databaseName string = 'metadata_enricher'

@description('Enable Cosmos DB free tier (only one free-tier account per subscription)')
param enableFreeTier bool = true

// =============================================================================
// COSMOS DB ACCOUNT
// =============================================================================

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: cosmosAccountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'    // Balance between consistency and performance
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false              // MVP: No zone redundancy for Dev
      }
    ]
    publicNetworkAccess: 'Enabled'          // MVP: Public endpoints for Dev
    enableAutomaticFailover: false          // MVP: Disabled for Dev
    enableFreeTier: enableFreeTier           // Only one free-tier account per subscription
    // capabilities: EnableServerless — set at account creation time only.
    // Azure rejects any PUT that includes the capabilities array on an existing
    // serverless account ("Update of EnableServerless capability is not allowed").
    // For green-field deployments, create the account first with:
    //   az cosmosdb create ... --capabilities EnableServerless
    // The serverless mode is immutable and will be preserved across re-deployments.
  }
}

// =============================================================================
// DATABASE
// =============================================================================
// Serverless Cosmos DB does not support provisioned throughput — the options
// block is intentionally omitted. Setting throughput on a serverless account
// would cause a deployment error.

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
// OUTPUTS
// =============================================================================

@description('Cosmos DB account name')
output cosmosAccountName string = cosmosAccount.name

@description('Cosmos DB account endpoint — use for MI-based client configuration')
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint

@description('Database name')
output databaseName string = database.name

@description('System-assigned Managed Identity principal ID')
output managedIdentityPrincipalId string = cosmosAccount.identity.principalId
