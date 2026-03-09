// =============================================================================
// Service Bus RBAC Module
// =============================================================================
// Purpose: Grant least-privilege Service Bus roles to compute identities.
//
// Assignments:
//   - Purview Bridge (Azure Function) → Azure Service Bus Data Sender
//     Allows the bridge to publish Purview diagnostic events to purview-events.
//
//   - Orchestrator (Container App) → Azure Service Bus Data Receiver
//     Allows the orchestrator to consume enrichment requests from
//     enrichment-requests.
//
// Both assignments are scoped to the Service Bus namespace.
// Assignments are conditional — skipped when principalId is empty, which
// allows this module to be deployed before compute resources are provisioned.
//
// Built-in role IDs (Azure global):
//   Azure Service Bus Data Sender:   69a216fc-b8fb-44d8-bc22-1f3c2cd27a39
//   Azure Service Bus Data Receiver: 4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0
// =============================================================================

@description('Service Bus namespace name')
param serviceBusNamespaceName string

@description('Principal ID of the Purview Bridge Managed Identity (Azure Function). Leave empty to skip assignment.')
param bridgePrincipalId string = ''

@description('Principal ID of the Orchestrator Managed Identity (Container App). Leave empty to skip assignment.')
param orchestratorPrincipalId string = ''

// =============================================================================
// ROLE DEFINITION IDs (built-in Azure roles)
// =============================================================================

var serviceBusDataSenderRoleId   = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var serviceBusDataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'

// =============================================================================
// EXISTING RESOURCE REFERENCE
// =============================================================================

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' existing = {
  name: serviceBusNamespaceName
}

// =============================================================================
// RBAC ASSIGNMENT 1 — Bridge → Data Sender
// =============================================================================
// The Purview Bridge reads from Event Hub (purview-diagnostics) and publishes
// to the Service Bus queue purview-events. It needs Send permission.
// =============================================================================

resource bridgeSenderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(bridgePrincipalId)) {
  name: guid(serviceBusNamespace.id, bridgePrincipalId, serviceBusDataSenderRoleId)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataSenderRoleId)
    principalId: bridgePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// RBAC ASSIGNMENT 2 — Orchestrator → Data Receiver
// =============================================================================
// The Orchestrator Container App reads enrichment requests from the
// enrichment-requests queue. It needs Receive (Listen + Read) permission.
// =============================================================================

resource orchestratorReceiverRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(orchestratorPrincipalId)) {
  name: guid(serviceBusNamespace.id, orchestratorPrincipalId, serviceBusDataReceiverRoleId)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataReceiverRoleId)
    principalId: orchestratorPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Role assignment ID for the Purview Bridge sender (empty if skipped)')
output bridgeSenderRoleAssignmentId string = !empty(bridgePrincipalId) ? bridgeSenderRoleAssignment.id : ''

@description('Role assignment ID for the Orchestrator receiver (empty if skipped)')
output orchestratorReceiverRoleAssignmentId string = !empty(orchestratorPrincipalId) ? orchestratorReceiverRoleAssignment.id : ''
