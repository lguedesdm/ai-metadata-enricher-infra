// =============================================================================
// Environment Parameters Template
// =============================================================================
// Copy this file and rename for your target environment:
//   cp parameters.template.bicepparam parameters.<env>.bicepparam
//
// Replace all <PLACEHOLDER> values with environment-specific values.
// Refer to parameters.dev.bicepparam for a working example.
//
// Usage:
//   az deployment sub create \
//     --location <LOCATION> \
//     --template-file infra/main.bicep \
//     --parameters infra/parameters.<env>.bicepparam
// =============================================================================

using './main.bicep'

// =============================================================================
// CORE PARAMETERS
// =============================================================================

// Environment identifier — used in all resource names
// Allowed: dev, test, staging, prod
param environment = '<ENV>'

// Azure region for all resources
// Dev reference: 'eastus'
param location = '<LOCATION>'

// Project name — fixed across all environments, used in resource naming
// DO NOT change unless renaming the entire project
param projectName = 'ai-metadata'

// =============================================================================
// STORAGE PARAMETERS
// =============================================================================

// Storage account SKU
// Allowed: Standard_LRS (dev/test), Standard_GRS (staging), Standard_RAGRS (prod)
// Dev reference: 'Standard_LRS'
param storageSku = '<STORAGE_SKU>'

// =============================================================================
// COSMOS DB PARAMETERS
// =============================================================================

// No additional Cosmos parameters needed — account uses serverless capacity mode.
// TTL configuration is handled at the container level post-deployment.

// =============================================================================
// AZURE AI SEARCH PARAMETERS
// =============================================================================

// Search service pricing tier
// Allowed: free, basic, standard, standard2, standard3
// Dev reference: 'basic'
param searchSku = '<SEARCH_SKU>'

// Deploy the search index via deployment script
// Set to true only after the index schema JSON is in place
// Dev reference: false (index was created manually)
param deploySearchIndex = false

// Deploy blob storage account
// Dev reference: true
param deployStorage = true

// Deploy Azure AI Search service
// Dev reference: true
param deploySearch = true

// Deploy blob indexers (synergy, zipline, documentation)
// Requires deploySearch = true
// Dev reference: true
param deploySearchIndexers = true

// Deploy Cosmos DB containers (state, audit)
// Set to true in Phase 2+
// Dev reference: true
param deployCosmosContainers = true

// =============================================================================
// SERVICE BUS PARAMETERS
// =============================================================================

// Service Bus pricing tier
// Allowed: Basic, Standard, Premium
// Standard required for topics and subscriptions
// Dev reference: 'Standard'
param serviceBusSku = '<SERVICE_BUS_SKU>'

// =============================================================================
// EVENT HUB PARAMETERS
// =============================================================================

// Deploy Event Hub namespace (required for Purview → pipeline ingestion)
// Dev reference: true
param deployEventHub = true

// Deploy Azure Functions (Purview Bridge)
// Requires deployEventHub = true
// Dev reference: true
param deployFunctions = true

// =============================================================================
// COMPUTE PARAMETERS
// =============================================================================

// Deploy Azure OpenAI (required for LLM enrichment)
// Dev reference: true
param deployOpenAI = true

// GPT model deployment name — must match AZURE_OPENAI_DEPLOYMENT_NAME env var
// Dev reference: 'gpt-4o'
param openAiDeploymentName = '<OPENAI_DEPLOYMENT_NAME>'

// Deploy Orchestrator Container App
// Dev reference: true
param deployCompute = true

// Deploy Azure Container Registry
// Dev reference: true
param deployRegistry = true

// Container image for the orchestrator
// Format: <acr-name>.azurecr.io/<image-name>:<tag>
// Dev reference: 'craimetadatadev.azurecr.io/ai-metadata-orchestrator:dev'
param containerImage = '<ACR_NAME>.azurecr.io/ai-metadata-orchestrator:<ENV>'

// =============================================================================
// OBSERVABILITY PARAMETERS
// =============================================================================

// Deploy Log Analytics workspace + Application Insights
// Dev reference: true
param deployObservability = true

// Email for Azure Monitor alert notifications
// Dev reference: 'leonardo.guedes@datameaning.com'
param alertEmail = '<ALERT_EMAIL>'

// =============================================================================
// PURVIEW PARAMETERS
// =============================================================================

// Purview account name — follows pattern: purview-{projectName}-{environment}
// Dev reference: 'purview-ai-metadata-dev'
param purviewAccountName = 'purview-ai-metadata-<ENV>'
