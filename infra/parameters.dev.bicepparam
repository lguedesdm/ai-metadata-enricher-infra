// =============================================================================
// Development Environment Parameters
// =============================================================================
// This file contains environment-specific parameters for the Dev environment.
//
// Usage:
//   az deployment sub create \
//     --location eastus \
//     --template-file infra/main.bicep \
//     --parameters infra/parameters.dev.bicep
// =============================================================================

using './main.bicep'

// =============================================================================
// CORE PARAMETERS
// =============================================================================

param environment = 'dev'
param location = 'eastus'
param projectName = 'ai-metadata'  // Align naming to rg-ai-metadata-dev and cosmos-ai-metadata-dev

// =============================================================================
// STORAGE PARAMETERS
// =============================================================================

param storageSku = 'Standard_LRS'  // Locally redundant storage for Dev

// =============================================================================
// COSMOS DB PARAMETERS
// =============================================================================

// TTL intentionally not applied in DEV phase; handled in Task 2

// =============================================================================
// AZURE AI SEARCH PARAMETERS
// =============================================================================

param searchSku = 'basic'  // Basic tier for Azure AI Search in Dev per architecture
param deploySearchIndex = false  // Index already created manually (deployment script had auth issues in ACI)
param deployStorage = true      // Canonical storage aimetadatadevstganpqtlf2 deployed and validated
param deploySearch = true       // Enable Azure AI Search (required for RAG)

// Cosmos containers are deployed in Phase 2 (disabled for Phase 1)
param deployCosmosContainers = true

// =============================================================================
// SERVICE BUS PARAMETERS
// =============================================================================

param serviceBusSku = 'Standard'  // Standard tier for Dev (supports topics and subscriptions)

// =============================================================================
// EVENT HUB PARAMETERS
// =============================================================================

param deployEventHub = true     // Enable Event Hub (required for Purview → pipeline ingestion)
param deployFunctions = true   // Migrated from Y1 (Dynamic — quota 0) to FC1 (Flex Consumption)

// =============================================================================
// COMPUTE PARAMETERS
// =============================================================================

param deployOpenAI = true              // Enable Azure OpenAI (required for LLM enrichment)
param openAiDeploymentName = 'gpt-4o'  // GPT deployment name — matches AZURE_OPENAI_DEPLOYMENT_NAME env var
param deployCompute = true    // Enable Orchestrator Container App
param deployRegistry = true  // Enable Azure Container Registry
param containerImage = 'craimetadatadev.azurecr.io/ai-metadata-orchestrator:dev'

// =============================================================================
// OBSERVABILITY PARAMETERS
// =============================================================================

param deployObservability = true  // Enable Log Analytics workspace + Application Insights

// =============================================================================
// PURVIEW PARAMETERS
// =============================================================================

param purviewAccountName = 'purview-ai-metadata-dev'  // Canonical Purview account
