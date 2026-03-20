// =============================================================================
// Microsoft Purview Dependency Module
// =============================================================================
// Purpose: Declares the dependency on a pre-provisioned Microsoft Purview
// account and validates its existence at deploy time. Outputs the account
// name consumed by the Orchestrator (PURVIEW_ACCOUNT_NAME) and the Bridge
// Function App (PurviewAccountName).
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
// TWO principals need "Purview Data Curator" at the root collection:
//
// 1. Orchestrator MI (Container App) — writes AI_Enrichment Business Metadata
//   az purview account add-root-collection-admin \
//     --account-name <purviewAccountName> \
//     --resource-group <resourceGroup> \
//     --object-id <orchestratorManagedIdentityPrincipalId>
//
// 2. Bridge Function App MI — reads entities for review status polling
//   az purview account add-root-collection-admin \
//     --account-name <purviewAccountName> \
//     --resource-group <resourceGroup> \
//     --object-id <bridgeFunctionAppManagedIdentityPrincipalId>
//
// Or via Purview Studio:
//   Data Map > Collections > Root Collection > Role Assignments
//   → Add "Data Curator" → paste each MI principal ID
//
// These grants allow:
//   Orchestrator:
//     - Read entity metadata (GET /datamap/api/atlas/v2/entity/guid/{guid})
//     - Write AI_Enrichment Business Metadata (POST .../businessmetadata)
//   Bridge Function App:
//     - Read entity metadata for review_status polling (ReviewStatusPollFunction)
//     - Search and bulk-fetch entities (UpstreamRouterFunction)
//
// MANUAL DATA-PLANE SETUP (run once per environment)
// =====================================================
// In addition to RBAC, the AI_Enrichment Business Metadata Type must be
// created via the Purview REST API before the pipeline can write to it.
// See infra/purview/README.md for the full setup steps.
//
// Token scope used by the runtime: "https://purview.azure.net/.default"
// Auth: DefaultAzureCredential() — compatible with System-Assigned MI
//
// CONTRACT REFERENCE (runtime_architecture_contract.yaml):
//   security.orchestrator_to_purview: MI
//   security.functions_to_purview: Purview Data Curator
//   purview.writebackPolicy.allowed_field: AI_Enrichment.suggested_description
//   purview.writebackPolicy.official_description: human_approval_required
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Microsoft Purview account name (must be pre-provisioned)')
param purviewAccountName string

@description('Event Hub authorization rule resource ID for Diagnostic Settings (SAS Send). Required for diagnostic settings.')
param eventHubAuthorizationRuleId string = ''

@description('Event Hub name that receives Purview diagnostic signals')
param eventHubName string = 'purview-diagnostics'

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================
// Validates that the Purview account exists at deploy time.
// Deployment fails fast here rather than at runtime if the account is missing.

resource purviewAccount 'Microsoft.Purview/accounts@2021-07-01' existing = {
  name: purviewAccountName
}

// =============================================================================
// DIAGNOSTIC SETTINGS (Purview → Event Hub)
// =============================================================================
// Routes Purview scan-status signals to the Event Hub for downstream processing.
// Only deployed when eventHubAuthorizationRuleId is provided (i.e., Event Hub exists).
//
// Azure Diagnostic Settings require a SAS authorization rule — Managed Identity
// is not supported by the platform for this resource type.

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(eventHubAuthorizationRuleId)) {
  name: 'purview-to-eventhub'
  scope: purviewAccount
  properties: {
    eventHubAuthorizationRuleId: eventHubAuthorizationRuleId
    eventHubName: eventHubName
    logs: [
      {
        category: 'ScanStatusLogEvent'
        enabled: true
      }
    ]
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Purview account name — set as PURVIEW_ACCOUNT_NAME in the orchestrator')
output purviewAccountName string = purviewAccount.name

@description('Purview account endpoint (https://{name}.purview.azure.com)')
output purviewEndpoint string = 'https://${purviewAccount.name}.purview.azure.com'
