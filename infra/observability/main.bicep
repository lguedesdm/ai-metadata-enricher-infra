// =============================================================================
// Observability Module — Log Analytics + Application Insights
// =============================================================================
// Purpose: Provisions the observability infrastructure required for operational
// telemetry and log aggregation for the AI Metadata Enricher platform.
//
// Resources created:
//   - Log Analytics Workspace   (log-{resourcePrefix})
//     └── Sink for Container Apps stdout/stderr logs via CAE appLogsConfiguration
//     └── Backing workspace for workspace-based Application Insights
//
//   - Application Insights      (appi-{resourcePrefix})
//     └── Workspace-based (linked to Log Analytics — recommended mode)
//     └── Telemetry endpoint for the Orchestrator's configure_azure_monitor() call
//
// Runtime integration:
//   The Orchestrator reads APPLICATIONINSIGHTS_CONNECTION_STRING from env and
//   passes it to configure_azure_monitor() (azure.monitor.opentelemetry).
//   This exports structured traces, metrics, and logs to App Insights.
//   Console logs (stdout JSON) are captured by the Container Apps Environment
//   which routes them to Log Analytics via the appLogsConfiguration shared key.
//
// Note on appLogsConfiguration shared key:
//   The Container Apps Environment platform requires the Log Analytics workspace
//   customerId + sharedKey at provisioning time to configure its log routing
//   agent. This key is platform infrastructure configuration (not application
//   auth) and does not appear in application code or secrets. The key is
//   retrieved via listKeys() in main.bicep and passed as a @secure() param —
//   it never appears in deployment outputs or history.
//   All application-to-Azure-service connections remain Managed Identity only.
//
// Contract reference (runtime_architecture_contract.yaml):
//   observability.monitoring.platform: Azure Application Insights
//   observability.metrics: llm_token_usage, enrichment_latency,
//                          validation_failures, purview_write_errors,
//                          ai_search_errors
//
// SKU:
//   Log Analytics  : PerGB2018 (pay-per-use — cost-optimised for Dev)
//   App Insights   : No SKU (workspace-based, billing via Log Analytics)
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Resource name prefix (e.g. ai-metadata-dev)')
param resourcePrefix string

@description('Azure region for all resources')
param location string

@description('Tags to apply to all resources')
param tags object

@description('Log retention in days. 30 days is the minimum and default for Dev.')
@minValue(30)
@maxValue(730)
param retentionDays int = 30

// =============================================================================
// LOG ANALYTICS WORKSPACE
// =============================================================================
// Central log sink. Container Apps routes stdout/stderr here via the CAE
// appLogsConfiguration. Application Insights uses this workspace as its
// backend storage (workspace-based mode — the recommended, modern approach).

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${resourcePrefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'    // Pay-per-GB — cost-optimised for Dev
    }
    retentionInDays: retentionDays
    publicNetworkAccessForIngestion: 'Enabled'    // MVP: Public ingestion for Dev
    publicNetworkAccessForQuery: 'Enabled'        // MVP: Public query for Dev
  }
}

// =============================================================================
// APPLICATION INSIGHTS
// =============================================================================
// Workspace-based Application Insights linked to the Log Analytics workspace.
// Workspace-based mode is the current recommended approach (classic is retired).
//
// The Orchestrator uses the connection string for telemetry routing:
//   configure_azure_monitor(connection_string=APPLICATIONINSIGHTS_CONNECTION_STRING)
//
// The connection string is a resource identifier (InstrumentationKey + endpoints),
// not an authentication credential. The azure.monitor.opentelemetry distro sends
// telemetry to the App Insights ingestion endpoint using the connection string
// for routing, independent of the data-plane auth model.

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${resourcePrefix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'                              // Required — web covers all workload types
    WorkspaceResourceId: logAnalyticsWorkspace.id        // Workspace-based mode
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: retentionDays
    DisableLocalAuth: false                              // Connection string routing required for Azure Monitor OpenTelemetry distro
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Log Analytics workspace resource ID — used by compute module for CAE appLogsConfiguration')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

@description('Log Analytics workspace name')
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name

@description('Log Analytics workspace customer ID — used in CAE appLogsConfiguration.customerId')
output logAnalyticsCustomerId string = logAnalyticsWorkspace.properties.customerId

@description('Application Insights resource ID')
output appInsightsId string = appInsights.id

@description('Application Insights name')
output appInsightsName string = appInsights.name

@description('Application Insights connection string — set as APPLICATIONINSIGHTS_CONNECTION_STRING in the orchestrator')
output appInsightsConnectionString string = appInsights.properties.ConnectionString

@description('Application Insights instrumentation key (legacy — prefer connection string)')
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
