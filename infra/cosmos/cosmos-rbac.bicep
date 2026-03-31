// =============================================================================
// Cosmos DB RBAC Module
// =============================================================================
// Purpose: Grant the Orchestrator Managed Identity read/write access to
// Cosmos DB data using the Cosmos DB Built-in Data Contributor role.
//
// Role assigned:
//   Cosmos DB Built-in Data Contributor
//   Role ID: 00000000-0000-0000-0000-000000000002
//   Allows: read, write, and delete items and containers (data plane)
//
// Scope: Cosmos DB account level — covers all databases and containers
// in the account (metadata_enricher/state and metadata_enricher/audit).
//
// IMPORTANT — Cosmos DB data plane RBAC vs ARM RBAC:
//   This module uses Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments,
//   which is the Cosmos DB data plane RBAC system. It is SEPARATE from the
//   standard Azure ARM RBAC (Microsoft.Authorization/roleAssignments).
//   ARM role assignments on a Cosmos DB account only control management-plane
//   access (account configuration), NOT data access. Data access requires
//   sqlRoleAssignments regardless of ARM roles assigned.
//
// Assignment is conditional — skipped when orchestratorPrincipalId is empty,
// allowing this module to be deployed before the Container App is provisioned.
//
// Built-in Cosmos DB data plane role IDs (same in all Azure environments):
//   Cosmos DB Built-in Data Reader      : 00000000-0000-0000-0000-000000000001
//   Cosmos DB Built-in Data Contributor : 00000000-0000-0000-0000-000000000002
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Cosmos DB account name (must match the deployed account)')
param cosmosAccountName string

@description('Principal ID of the Orchestrator Managed Identity (Container App). Leave empty to skip assignment.')
param orchestratorPrincipalId string = ''

@description('Principal ID of the Bridge Function App Managed Identity. Leave empty to skip assignment.')
param bridgePrincipalId string = ''

// =============================================================================
// ROLE DEFINITION ID
// =============================================================================

var cosmosBuiltInDataContributorRoleId = '00000000-0000-0000-0000-000000000002'

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' existing = {
  name: cosmosAccountName
}

// =============================================================================
// COSMOS DB DATA PLANE RBAC ASSIGNMENT — Orchestrator → Data Contributor
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the ability to
// read and write documents in all containers (state, audit) under the
// metadata_enricher database.
//
// roleDefinitionId format for built-in Cosmos DB roles:
//   {cosmosAccount.id}/sqlRoleDefinitions/{roleId}
//
// The assignment name is a deterministic GUID derived from the account ID,
// principal ID, and role ID — ensuring idempotent re-deployments.

resource orchestratorDataContributorAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = if (!empty(orchestratorPrincipalId)) {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, orchestratorPrincipalId, cosmosBuiltInDataContributorRoleId)
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/${cosmosBuiltInDataContributorRoleId}'
    principalId: orchestratorPrincipalId
    scope: cosmosAccount.id    // Account-level scope covers all databases and containers
  }
}

// =============================================================================
// COSMOS DB DATA PLANE RBAC ASSIGNMENT — Bridge Function App → Data Contributor
// =============================================================================
// Grants the Purview Bridge Function App's Managed Identity the ability to
// read and write lifecycle and audit documents in Cosmos DB.
// Required by ReviewStatusPollFunction to sync review_status from Purview.

resource bridgeDataContributorAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = if (!empty(bridgePrincipalId)) {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, bridgePrincipalId, cosmosBuiltInDataContributorRoleId)
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/${cosmosBuiltInDataContributorRoleId}'
    principalId: bridgePrincipalId
    scope: cosmosAccount.id    // Account-level scope covers all databases and containers
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Role assignment resource ID (empty if skipped)')
output orchestratorDataContributorAssignmentId string = !empty(orchestratorPrincipalId) ? orchestratorDataContributorAssignment.id : ''

@description('Bridge role assignment resource ID (empty if skipped)')
output bridgeDataContributorAssignmentId string = !empty(bridgePrincipalId) ? bridgeDataContributorAssignment.id : ''
