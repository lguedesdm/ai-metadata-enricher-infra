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
param deploySearchIndex = true  // Enable unified index creation from the frozen schema JSON
param deployStorage = false     // Do not deploy Storage in Phase 2
param deploySearch = false      // Do not deploy Search in Phase 2

// Cosmos containers are deployed in Phase 2 (disabled for Phase 1)
param deployCosmosContainers = true

// =============================================================================
// SERVICE BUS PARAMETERS
// =============================================================================

param serviceBusSku = 'Standard'  // Standard tier for Dev (supports topics and subscriptions)
