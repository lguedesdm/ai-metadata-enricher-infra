// =============================================================================
// Azure AI Search RBAC Module
// =============================================================================
// Purpose: Grant the Orchestrator Managed Identity read access to the
// Azure AI Search service so it can execute RAG queries.
//
// Role assigned:
//   Search Index Data Reader
//   Role ID: 1407120a-92aa-4202-b7e9-c0e197c71c8f
//   Allows: read documents, run queries, and read index definitions (data plane)
//
// Scope: Search service resource — covers all indexes on the service,
// including the canonical metadata-context-index.
//
// IMPORTANT — Search data plane RBAC vs local auth:
//   Azure AI Search supports two auth models:
//     1. API key (local auth) — disabled by the security model (keys prohibited)
//     2. Azure RBAC (ARM role assignments) — required when using Managed Identity
//   This module provisions the ARM RBAC role assignment that enables
//   DefaultAzureCredential to authenticate SearchClient at runtime.
//
// Assignment is conditional — skipped when orchestratorPrincipalId is empty,
// allowing this module to be deployed before the Container App is provisioned.
//
// Built-in Azure AI Search role IDs (same in all Azure environments):
//   Search Index Data Reader      : 1407120a-92aa-4202-b7e9-c0e197c71c8f
//   Search Index Data Contributor : 8ebe5a00-799e-43f5-93ac-243d3dce84a7
//   Search Service Contributor    : 7ca78c08-252a-4471-8644-bb5ff32d4ba0
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Azure AI Search service name (must match the deployed service)')
param searchServiceName string

@description('Principal ID of the Orchestrator Managed Identity (Container App). Leave empty to skip assignment.')
param orchestratorPrincipalId string = ''

// =============================================================================
// ROLE DEFINITION ID
// =============================================================================

var searchIndexDataReaderRoleId = '1407120a-92aa-4202-b7e9-c0e197c71c8f'

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================

resource searchService 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: searchServiceName
}

// =============================================================================
// SEARCH DATA READER RBAC ASSIGNMENT — Orchestrator → Search Index Data Reader
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the ability to
// query documents across all indexes (including metadata-context-index) on
// this search service using DefaultAzureCredential.
//
// The assignment name is a deterministic GUID derived from the service ID,
// principal ID, and role ID — ensuring idempotent re-deployments.

resource orchestratorSearchReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(orchestratorPrincipalId)) {
  name: guid(searchService.id, orchestratorPrincipalId, searchIndexDataReaderRoleId)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReaderRoleId)
    principalId: orchestratorPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Role assignment resource ID (empty if skipped)')
output orchestratorSearchReaderAssignmentId string = !empty(orchestratorPrincipalId) ? orchestratorSearchReaderAssignment.id : ''
