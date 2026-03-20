// =============================================================================
// Production Environment Parameters
// =============================================================================
// This file contains environment-specific parameters for the Prod environment.
//
// Usage:
//   az deployment sub create \
//     --location eastus \
//     --template-file infra/main.bicep \
//     --parameters infra/parameters.prod.bicepparam
// =============================================================================

using './main.bicep'

// =============================================================================
// CORE PARAMETERS
// =============================================================================

param environment = 'prod'
param location = 'eastus'
param projectName = 'ai-metadata'

// =============================================================================
// STORAGE PARAMETERS
// =============================================================================

param storageSku = 'Standard_GRS'  // Geo-redundant storage for Prod

// =============================================================================
// COSMOS DB PARAMETERS
// =============================================================================

// Cosmos containers deployed (state + audit)
param deployCosmosContainers = true
param enableFreeTier = false  // Free tier already used by dev account in this subscription

// =============================================================================
// AZURE AI SEARCH PARAMETERS
// =============================================================================

param searchSku = 'basic'  // Basic tier for initial Prod validation
param deploySearchIndex = true  // Create the frozen index schema via deployment script
param deployStorage = true
param deploySearch = true
param deploySearchIndexers = true

// =============================================================================
// SERVICE BUS PARAMETERS
// =============================================================================

param serviceBusSku = 'Standard'  // Standard tier (supports topics and subscriptions)

// =============================================================================
// EVENT HUB PARAMETERS
// =============================================================================

param deployEventHub = true
param deployFunctions = true

// =============================================================================
// COMPUTE PARAMETERS
// =============================================================================

param deployOpenAI = true
param openAiDeploymentName = 'gpt-4o'
param deployCompute = true
param deployRegistry = true
param containerImage = 'craimetadataprod.azurecr.io/ai-metadata-orchestrator:prod'

// =============================================================================
// OBSERVABILITY PARAMETERS
// =============================================================================

param deployObservability = true
param alertEmail = 'leonardo.guedes@datameaning.com'

// =============================================================================
// PURVIEW PARAMETERS
// =============================================================================

param purviewAccountName = 'purview-ai-metadata-prod'
param deployPurview = true
