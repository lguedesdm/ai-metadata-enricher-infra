// =============================================================================
// Azure Container Registry RBAC Module
// =============================================================================
// Purpose: Grant the Orchestrator Container App's Managed Identity the
// AcrPull role so it can pull container images from the registry.
//
// Role assigned:
//   AcrPull
//   Role ID: 7f951dda-4ed3-4680-a7ca-43fe172d538d
//   Allows: pull images from the registry (read-only, data plane)
//
// This module is declared separately from registry/main.bicep to avoid a
// circular dependency in main.bicep:
//   - registry/main.bicep outputs acrLoginServer (consumed by compute module)
//   - compute module outputs managedIdentityPrincipalId (needed for RBAC)
//   Putting RBAC here breaks the cycle: main.bicep sequences
//   registry → compute → acrRbac with no circular edges.
//
// Assignment is conditional — skipped when orchestratorPrincipalId is empty,
// allowing deployment before the Container App is provisioned.
//
// Assignment name is a deterministic GUID for idempotent re-deployments.
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Azure Container Registry name (must match the deployed registry)')
param acrName string

@description('Principal ID of the Orchestrator Managed Identity (Container App). Leave empty to skip assignment.')
param orchestratorPrincipalId string = ''

// =============================================================================
// ROLE DEFINITION ID
// =============================================================================

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// =============================================================================
// RBAC ASSIGNMENT — Orchestrator MI → AcrPull
// =============================================================================
// Grants the Orchestrator Container App's Managed Identity the ability to
// pull images from this registry. Combined with the registries configuration
// block in the Container App (identity: 'system'), this enables keyless
// image pulls — no admin credentials or pull secrets required.

resource orchestratorAcrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(orchestratorPrincipalId)) {
  name: guid(containerRegistry.id, orchestratorPrincipalId, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: orchestratorPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Role assignment resource ID (empty if skipped)')
output orchestratorAcrPullAssignmentId string = !empty(orchestratorPrincipalId) ? orchestratorAcrPullAssignment.id : ''
