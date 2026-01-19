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
param projectName = 'aime'  // Shortened for resource name compliance

// =============================================================================
// STORAGE PARAMETERS
// =============================================================================

param storageSku = 'Standard_LRS'  // Locally redundant storage for Dev

// =============================================================================
// COSMOS DB PARAMETERS
// =============================================================================

param stateTtlSeconds = 604800  // 7 days (7 * 24 * 60 * 60)
param auditTtlSeconds = 15552000  // 180 days (180 * 24 * 60 * 60)

// =============================================================================
// AZURE AI SEARCH PARAMETERS
// =============================================================================

param searchSku = 'basic'  // Basic tier for Dev

// =============================================================================
// SERVICE BUS PARAMETERS
// =============================================================================

param serviceBusSku = 'Standard'  // Standard tier for Dev (supports topics and subscriptions)
