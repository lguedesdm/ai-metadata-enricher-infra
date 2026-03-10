// =============================================================================
// Azure OpenAI RBAC Module
// =============================================================================
// Purpose: Grant the Orchestrator Managed Identity the "Cognitive Services
// OpenAI User" role on the Azure OpenAI account so it can invoke LLM
// completions using Managed Identity (DefaultAzureCredential).
//
// Role assigned:
//   Cognitive Services OpenAI User
//   Role ID: 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd
//   Allows: invoke chat completions, read deployments (data plane only)
//
// This module is declared separately from openai/main.bicep to avoid a
// circular dependency in main.bicep:
//   - openai/main.bicep outputs openAiEndpoint (consumed by compute module)
//   - compute module outputs managedIdentityPrincipalId (needed for RBAC)
//   Putting RBAC here breaks the cycle: main.bicep sequences openai → compute
//   → openaiRbac with no circular edges.
//
// Scope: Azure OpenAI account resource level.
//
// Assignment is conditional — skipped when orchestratorPrincipalId is empty,
// allowing this module to be deployed before the Container App is provisioned.
//
// The assignment name is a deterministic GUID for idempotent re-deployments.
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Azure OpenAI account name (must match the deployed account)')
param openAiAccountName string

@description('Principal ID of the Orchestrator Managed Identity (Container App). Leave empty to skip assignment.')
param orchestratorPrincipalId string = ''

// =============================================================================
// ROLE DEFINITION ID
// =============================================================================

var cognitiveServicesOpenAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================

resource openAiAccount 'Microsoft.CognitiveServices/accounts@2023-10-01-preview' existing = {
  name: openAiAccountName
}

// =============================================================================
// RBAC ASSIGNMENT — Orchestrator → Cognitive Services OpenAI User
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the ability to
// invoke chat completions against this Azure OpenAI account using
// DefaultAzureCredential with token scope
// "https://cognitiveservices.azure.com/.default".
//
// This is the minimum role needed — does NOT grant account management,
// fine-tuning, or key retrieval capabilities.

resource orchestratorOpenAiUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(orchestratorPrincipalId)) {
  name: guid(openAiAccount.id, orchestratorPrincipalId, cognitiveServicesOpenAiUserRoleId)
  scope: openAiAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: orchestratorPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Role assignment resource ID (empty if skipped)')
output orchestratorOpenAiUserAssignmentId string = !empty(orchestratorPrincipalId) ? orchestratorOpenAiUserAssignment.id : ''
