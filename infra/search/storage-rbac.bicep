// =============================================================================
// Azure AI Search → Storage RBAC Module
// =============================================================================
// Purpose: Grant the Azure AI Search service's system-assigned Managed Identity
// read access to the Storage Account so that blob indexers can pull documents
// using Managed Identity authentication (no storage keys or SAS tokens).
//
// Role assigned:
//   Storage Blob Data Reader
//   Role ID: 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
//   Allows: read blobs and list containers (data plane)
//
// Scope: Storage account resource — covers all blob containers, including
// synergy, zipline, documentation, and schemas.
//
// This RBAC assignment enables indexer data sources to use the MI connection
// string format:
//   ResourceId=/subscriptions/{sub}/resourceGroups/{rg}/providers/
//              Microsoft.Storage/storageAccounts/{name};
//
// Assignment is conditional — skipped when searchServicePrincipalId is empty,
// allowing this module to be deployed before the Search service is provisioned.
//
// Built-in Azure Storage role IDs (same in all Azure environments):
//   Storage Blob Data Reader      : 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
//   Storage Blob Data Contributor : ba92f5b4-2d11-453d-a403-e96b0029c9fe
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Storage account name (must match the deployed storage account)')
param storageAccountName string

@description('Principal ID of the Azure AI Search service system-assigned Managed Identity. Leave empty to skip assignment.')
param searchServicePrincipalId string = ''

// =============================================================================
// ROLE DEFINITION ID
// =============================================================================

var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

// =============================================================================
// STORAGE BLOB DATA READER RBAC ASSIGNMENT — Search Service MI → Storage
// =============================================================================
// Grants the Azure AI Search service's system-assigned MI the ability to read
// blobs from all containers on this storage account. This is required for blob
// indexers to enumerate and read documents using Managed Identity.
//
// The assignment name is a deterministic GUID derived from the storage account
// ID, principal ID, and role ID — ensuring idempotent re-deployments.

resource searchStorageBlobReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(searchServicePrincipalId)) {
  name: guid(storageAccount.id, searchServicePrincipalId, storageBlobDataReaderRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: searchServicePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Role assignment resource ID (empty if skipped)')
output searchStorageBlobReaderAssignmentId string = !empty(searchServicePrincipalId) ? searchStorageBlobReaderAssignment.id : ''
