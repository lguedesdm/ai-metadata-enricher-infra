// =============================================================================
// Compute Module — Orchestrator (Container Apps)
// =============================================================================
// Purpose: Provisions the Container Apps Environment and the Enrichment
// Orchestrator Container App for the AI Metadata Enricher platform.
//
// Resources created:
//   - Container Apps Environment  (cae-{resourcePrefix})
//   - Orchestrator Container App  (ca-orchestrator-{resourcePrefix})
//     └── System-Assigned Managed Identity
//     └── Environment variables (all connections via Managed Identity)
//
// Security model:
//   All downstream service connections use Managed Identity — no secrets,
//   connection strings, or SAS tokens are provisioned here.
//
// RBAC post-deploy (handled by messaging/servicebus-rbac.bicep):
//   The managedIdentityPrincipalId output must be wired into the
//   servicebus-rbac module as orchestratorPrincipalId so the Container App
//   can receive messages from the enrichment-requests queue.
//
// MVP constraints:
//   - No Log Analytics workspace (Dev only — add for Test/Prod)
//   - No ingress (background worker, not a web service)
//   - Single replica (scale 1–1 for Dev determinism)
//   - Minimum resources: 0.25 vCPU / 0.5Gi
//
// Canonical resource names embedded as literals (frozen contracts):
//   Service Bus queue  : enrichment-requests
//   Cosmos database    : metadata_enricher
//   Cosmos state       : state
//   Cosmos audit       : audit
//   AI Search index    : metadata-context-index
//   Semantic config    : default-semantic-config
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

@description('Container image reference (e.g. <acr>.azurecr.io/ai-metadata-orchestrator:dev). Leave empty for placeholder deployment.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('ACR login server (e.g. craimetadatadev.azurecr.io). When provided, the Container App uses its system MI to pull from this registry.')
param acrServer string = ''

@description('Fully qualified Service Bus namespace (e.g. ai-metadata-dev-sbus.servicebus.windows.net). Used for MI-based authentication.')
param serviceBusNamespaceFqdn string

@description('Cosmos DB account endpoint (e.g. https://cosmos-ai-metadata-dev.documents.azure.com:443/). Used for MI-based authentication.')
param cosmosEndpoint string

@description('Azure AI Search endpoint (e.g. https://ai-metadata-dev-search.search.windows.net). Leave empty until Search is deployed.')
param searchEndpoint string = ''

@description('Azure OpenAI endpoint (e.g. https://oai-ai-metadata-dev.openai.azure.com/). Leave empty until Azure OpenAI is provisioned.')
param openAiEndpoint string = ''

@description('Azure OpenAI deployment name (e.g. gpt-4). Leave empty until Azure OpenAI is provisioned.')
param openAiDeploymentName string = ''

@description('Microsoft Purview account name (e.g. purview-ai-metadata-dev). Leave empty until Purview is provisioned.')
param purviewAccountName string = ''

@description('Environment identifier (dev, test, prod)')
param environment string = 'dev'

@description('Log Analytics workspace customer ID. When provided, Container Apps stdout/stderr logs are routed to the workspace.')
param logAnalyticsWorkspaceCustomerId string = ''

@description('Log Analytics workspace shared key (platform infrastructure config — routes CAE agent, not application auth). Leave empty to skip log routing.')
@secure()
param logAnalyticsSharedKey string = ''

@description('Application Insights connection string. Set as APPLICATIONINSIGHTS_CONNECTION_STRING env var. Leave empty until observability is provisioned.')
param appInsightsConnectionString string = ''

@description('Storage Account blob endpoint for onboarding budget (e.g. https://<name>.blob.core.windows.net)')
param onboardingStorageUrl string = ''

@description('Enable daily budget for onboarding (true/false). When false, all REPROCESS decisions proceed without limit.')
param onboardingBudgetEnabled string = 'false'

@description('Maximum number of REPROCESS decisions per day for onboarding asset types. 0 = unlimited.')
param onboardingDailyBudget string = '0'

@description('Comma-separated entity types that count against the onboarding budget (e.g. azure_sql_table). Empty = all types count.')
param onboardingAllowedTypes string = ''

// =============================================================================
// CONTAINER APPS ENVIRONMENT
// =============================================================================
// Linked to Log Analytics when logAnalyticsWorkspaceCustomerId is provided.
// This routes Container Apps stdout/stderr (JSON structured logs) to the
// Log Analytics workspace for aggregation alongside App Insights telemetry.
//
// The sharedKey is a platform infrastructure credential used by the CAE agent
// for log routing — it is not used by application code and is passed as a
// @secure() param so it does not appear in deployment history.

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${resourcePrefix}'
  location: location
  tags: tags
  properties: empty(logAnalyticsWorkspaceCustomerId) ? {} : {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspaceCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
  }
}

// =============================================================================
// ORCHESTRATOR CONTAINER APP
// =============================================================================
// Background worker — no ingress, no secrets, all connections via MI.

resource orchestratorApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-orchestrator-${resourcePrefix}'
  location: location
  tags: union(tags, { component: 'orchestrator' })

  // System-Assigned Managed Identity.
  // The principal ID is exported so messaging/servicebus-rbac.bicep can
  // assign the Azure Service Bus Data Receiver role.
  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    environmentId: containerAppsEnv.id

    configuration: {
      // No HTTP ingress — this is a Service Bus consumer, not a web service.
      ingress: null

      // No secrets block — all service authentication uses Managed Identity.
      // Connection strings and SAS tokens are prohibited by the security model.
      secrets: []

      // ACR pull via system MI — no admin credentials or pull secrets.
      // Requires AcrPull role on the registry (provisioned by registry/acr-rbac.bicep).
      registries: empty(acrServer) ? [] : [
        {
          server: acrServer
          identity: 'system'
        }
      ]
    }

    template: {
      containers: [
        {
          name: 'orchestrator'
          image: containerImage
          resources: {
            cpu: json('0.25')   // MVP: minimum viable allocation for Dev
            memory: '0.5Gi'
          }

          env: [
            // ------------------------------------------------------------------
            // Azure Service Bus — MI authentication
            // Runtime reads: SERVICE_BUS_NAMESPACE (required)
            // ------------------------------------------------------------------
            {
              name: 'SERVICE_BUS_NAMESPACE'
              value: serviceBusNamespaceFqdn
            }
            {
              name: 'SERVICE_BUS_QUEUE_NAME'
              value: 'enrichment-requests'    // canonical: runtime_architecture_contract.yaml
            }

            // ------------------------------------------------------------------
            // Azure Cosmos DB — MI authentication
            // Runtime reads: COSMOS_ENDPOINT (required), COSMOS_DATABASE_NAME,
            //                COSMOS_STATE_CONTAINER, COSMOS_AUDIT_CONTAINER
            // ------------------------------------------------------------------
            {
              name: 'COSMOS_ENDPOINT'
              value: cosmosEndpoint
            }
            {
              name: 'COSMOS_DATABASE_NAME'
              value: 'metadata_enricher'      // canonical: runtime_architecture_contract.yaml
            }
            {
              name: 'COSMOS_STATE_CONTAINER'
              value: 'state'                  // canonical: runtime_architecture_contract.yaml
            }
            {
              name: 'COSMOS_AUDIT_CONTAINER'
              value: 'audit'                  // canonical: runtime_architecture_contract.yaml
            }

            // ------------------------------------------------------------------
            // Azure AI Search — MI authentication
            // Runtime reads: AZURE_SEARCH_ENDPOINT (required for RAG),
            //                AZURE_SEARCH_INDEX_NAME, AZURE_SEARCH_SEMANTIC_CONFIG
            // ------------------------------------------------------------------
            {
              name: 'AZURE_SEARCH_ENDPOINT'
              value: searchEndpoint
            }
            {
              name: 'AZURE_SEARCH_INDEX_NAME'
              value: 'metadata-context-index'         // canonical: runtime_architecture_contract.yaml
            }
            {
              name: 'AZURE_SEARCH_SEMANTIC_CONFIG'
              value: 'default-semantic-config'        // frozen: infra/search/schemas/metadata-context-index.json
            }

            // ------------------------------------------------------------------
            // Azure OpenAI — MI authentication
            // Runtime reads: AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT_NAME,
            //                AZURE_OPENAI_API_VERSION
            // ------------------------------------------------------------------
            {
              name: 'AZURE_OPENAI_ENDPOINT'
              value: openAiEndpoint
            }
            {
              name: 'AZURE_OPENAI_DEPLOYMENT_NAME'
              value: openAiDeploymentName
            }
            {
              name: 'AZURE_OPENAI_API_VERSION'
              value: '2024-06-01'
            }

            // ------------------------------------------------------------------
            // Microsoft Purview — MI authentication
            // Runtime reads: PURVIEW_ACCOUNT_NAME
            // ------------------------------------------------------------------
            {
              name: 'PURVIEW_ACCOUNT_NAME'
              value: purviewAccountName
            }

            // ------------------------------------------------------------------
            // Application Insights — telemetry connection string
            // Runtime reads: APPLICATIONINSIGHTS_CONNECTION_STRING (optional)
            // When set: configure_azure_monitor() exports structured traces,
            // metrics, and logs to the App Insights workspace.
            // When empty: orchestrator falls back to stdout JSON logging only.
            // ------------------------------------------------------------------
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsightsConnectionString
            }

            // ------------------------------------------------------------------
            // Onboarding Budget — daily REPROCESS limiter
            // ------------------------------------------------------------------
            // Controls how many new assets can be enriched per day.
            // Assets that hash-match (SKIP) are never affected by the budget.
            // Only assets whose entity type is in ONBOARDING_ALLOWED_TYPES
            // count against the daily limit. All other types pass freely.
            //
            // The budget state is stored in a JSON blob (onboarding/daily-budget.json)
            // in the storage account. It resets automatically when the UTC date changes.
            //
            // Fail-open: if storage is unreachable, processing proceeds without limit.
            //
            // Rollback: set ONBOARDING_BUDGET_ENABLED=false — no redeploy needed.
            //
            // Typical configurations:
            //   Canary:  ENABLED=true, BUDGET=5,   TYPES=azure_sql_table
            //   Ramp:    ENABLED=true, BUDGET=100, TYPES=azure_sql_table,azure_sql_view
            //   Full:    ENABLED=false (or BUDGET=0)
            // ------------------------------------------------------------------
            {
              name: 'ONBOARDING_BUDGET_ENABLED'
              value: onboardingBudgetEnabled
            }
            {
              name: 'ONBOARDING_DAILY_BUDGET'
              value: onboardingDailyBudget
            }
            {
              name: 'ONBOARDING_ALLOWED_TYPES'
              value: onboardingAllowedTypes
            }
            {
              name: 'ONBOARDING_STORAGE_URL'
              value: onboardingStorageUrl
            }
            {
              name: 'ONBOARDING_STORAGE_CONTAINER'
              value: 'onboarding'                  // matches storage/main.bicep onboardingContainer
            }
            {
              name: 'ONBOARDING_BUDGET_BLOB'
              value: 'daily-budget.json'
            }

            // ------------------------------------------------------------------
            // Runtime context
            // ------------------------------------------------------------------
            {
              name: 'ENVIRONMENT'
              value: environment
            }
          ]
        }
      ]

      // MVP: Single replica for deterministic Dev behaviour.
      // FUTURE: Scale by Service Bus queue depth for Test/Prod.
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Container Apps Environment resource ID')
output containerAppsEnvironmentId string = containerAppsEnv.id

@description('Container Apps Environment name')
output containerAppsEnvironmentName string = containerAppsEnv.name

@description('Orchestrator Container App name')
output containerAppName string = orchestratorApp.name

@description('Orchestrator Container App resource ID')
output containerAppId string = orchestratorApp.id

@description('System-assigned Managed Identity principal ID — wire into servicebus-rbac.bicep as orchestratorPrincipalId')
output managedIdentityPrincipalId string = orchestratorApp.identity.principalId
