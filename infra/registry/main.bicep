// =============================================================================
// Azure Container Registry Module
// =============================================================================
// Purpose: Provisions the Azure Container Registry that stores the Orchestrator
// container image pulled by the Container App.
//
// Resources created:
//   - Azure Container Registry  (cr{sanitized-prefix}, SKU: Basic)
//
// Security model:
//   The Container App pulls images using its System-Assigned Managed Identity
//   (AcrPull role). Admin credentials are disabled (adminUserEnabled: false).
//   The AcrPull RBAC assignment is in the sibling registry/acr-rbac.bicep module
//   to avoid a circular dependency with the compute module:
//     - This module outputs acrLoginServer (consumed by compute)
//     - compute outputs managedIdentityPrincipalId (consumed by acr-rbac)
//
// Naming:
//   ACR names are alphanumeric only (no hyphens), max 50 chars.
//   Pattern: cr + first 20 chars of resourcePrefix (hyphens stripped).
//   e.g. resourcePrefix=ai-metadata-dev → craimetadatadev
//
// SKU: Basic — cost-optimised for Dev (1 webhook, no geo-replication).
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

// =============================================================================
// LOCAL VARIABLES
// =============================================================================

// ACR name: alphanumeric only, deterministic, ≤ 50 chars.
var acrName = 'cr${take(replace(resourcePrefix, '-', ''), 20)}'

// =============================================================================
// AZURE CONTAINER REGISTRY
// =============================================================================

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Basic'    // Dev: single replica, no geo-replication, no private endpoints
  }
  properties: {
    adminUserEnabled: false    // MI-only auth — admin credentials disabled
    publicNetworkAccess: 'Enabled'    // MVP: Public access for Dev
    zoneRedundancy: 'Disabled'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('ACR resource name')
output acrName string = containerRegistry.name

@description('ACR resource ID — used by acr-rbac.bicep')
output acrId string = containerRegistry.id

@description('ACR login server (e.g. craimetadatadev.azurecr.io) — set in compute registries block')
output acrLoginServer string = containerRegistry.properties.loginServer
