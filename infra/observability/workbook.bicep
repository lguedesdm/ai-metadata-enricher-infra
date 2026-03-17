// =============================================================================
// Azure Monitor Workbook — AI Metadata Enricher Pipeline Dashboard
// =============================================================================
// Purpose: Deploys a shared Azure Monitor Workbook that visualises the
// enrichment pipeline's operational telemetry from Application Insights.
//
// The workbook queries the `pipeline_completion` trace event emitted by the
// orchestrator (SKIP path) and enrichment pipeline (SUCCESS, NO_CONTEXT,
// BLOCK, ERROR paths).  Each event carries unified customDimensions:
//   correlationId, elementName, elementType, status, stage, durationMs,
//   hasContext, tokenCount, validationStatus, writebackSuccess
//
// Dashboard sections (Phase 8 — data-agnostic, behaviour-driven):
//   1. System Overview    — KPIs, status distribution pie, execution trend
//   2. Decision Breakdown — business-labelled outcome table with percentages
//   3. Pipeline Performance — latency by stage, LLM token usage
//   4. Reliability         — error/block rate tiles, error trend, failure detail
//   5. Execution Trace     — correlationId explorer with recent executions ref
//
// Business label mapping (data-agnostic — no asset names in queries):
//   SUCCESS    → "Successfully Enriched"
//   SKIP       → "Already Processed"
//   NO_CONTEXT → "Insufficient Context"
//   BLOCK      → "Validation Protected"
//   ERROR      → "Processing Error"
//
// Deployment:
//   This module is referenced from observability/main.bicep (or main.bicep).
//   The workbook JSON is loaded from workbook.json via loadTextContent().
//
// No application code changes required — reads existing App Insights data.
// =============================================================================

@description('Display name for the workbook in the Azure Portal')
param workbookDisplayName string = 'AI Metadata Enricher — Pipeline Dashboard'

@description('Azure region for the workbook resource')
param location string = resourceGroup().location

@description('Resource ID of the Application Insights instance (source)')
param appInsightsId string

@description('Tags to apply to the workbook resource')
param tags object = {}

// ---------------------------------------------------------------------------
// Workbook resource
// ---------------------------------------------------------------------------

resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: guid(resourceGroup().id, workbookDisplayName)
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: loadTextContent('workbook.json')
    sourceId: appInsightsId
    category: 'workbook'
    version: '2.0'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Workbook resource ID')
output workbookId string = workbook.id

@description('Workbook resource name (GUID)')
output workbookName string = workbook.name
