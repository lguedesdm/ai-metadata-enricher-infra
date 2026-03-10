// =============================================================================
// Microsoft Purview Dependency Module
// =============================================================================
// Purpose: Declares the dependency on a pre-provisioned Microsoft Purview
// account and validates its existence at deploy time. Outputs the endpoint
// consumed by the Orchestrator Container App as PURVIEW_ACCOUNT_NAME.
//
// WHY THIS MODULE DOES NOT CREATE THE PURVIEW ACCOUNT
// =====================================================
// Microsoft Purview is a governed PaaS service that must be provisioned
// through the Azure Portal or dedicated governance workflows — not via Bicep
// in an application IaC pipeline. Purview accounts carry organizational
// governance policies and cannot be created and destroyed with the
// application lifecycle.
//
// WHY THIS MODULE DOES NOT ASSIGN ARM RBAC
// =========================================
// Microsoft Purview uses its own collection-level RBAC system, which is
// entirely separate from Azure ARM RBAC. The "Purview Data Curator" role
// is a Purview collection role managed within Purview Studio — it is NOT
// a standard Azure built-in role and CANNOT be assigned via
// Microsoft.Authorization/roleAssignments in Bicep.
//
// REQUIRED MANUAL RBAC STEP (run once per environment)
// =====================================================
// Grant the Orchestrator Managed Identity the "Purview Data Curator" role
// at the root collection of the Purview account:
//
//   az purview account add-root-collection-admin \
//     --account-name <purviewAccountName> \
//     --resource-group <resourceGroup> \
//     --object-id <orchestratorManagedIdentityPrincipalId>
//
// Or via Purview Studio:
//   Data Map > Collections > Root Collection > Role Assignments
//   → Add "Data Curator" → paste the orchestrator MI principal ID
//
// This grants the orchestrator MI the ability to:
//   - Read entity metadata (GET /catalog/api/atlas/v2/entity/guid/{guid})
//   - Write Suggested Description (PUT /catalog/api/atlas/v2/entity/guid/{guid})
//
// Token scope used by the runtime: "https://purview.azure.net/.default"
// Auth: DefaultAzureCredential() — compatible with System-Assigned MI
//
// CONTRACT REFERENCE (runtime_architecture_contract.yaml):
//   security.orchestrator_to_purview: MI
//   purview.writebackPolicy.allowed_field: Suggested Description
//   purview.writebackPolicy.official_description: human_approval_required
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Microsoft Purview account name (must be pre-provisioned)')
param purviewAccountName string

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================
// Validates that the Purview account exists at deploy time.
// Deployment fails fast here rather than at runtime if the account is missing.

resource purviewAccount 'Microsoft.Purview/accounts@2021-07-01' existing = {
  name: purviewAccountName
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Purview account name — set as PURVIEW_ACCOUNT_NAME in the orchestrator')
output purviewAccountName string = purviewAccount.name

@description('Purview account endpoint (https://{name}.purview.azure.com)')
output purviewEndpoint string = 'https://${purviewAccount.name}.purview.azure.com'
