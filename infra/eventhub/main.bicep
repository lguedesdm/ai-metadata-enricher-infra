// =============================================================================
// Event Hub Module
// =============================================================================
// Purpose: Azure Event Hubs for receiving Purview diagnostic signals.
//
// This Event Hub serves as the bridge receiver for Purview Diagnostic Settings.
// Purview does not support Event Grid System Topics, so Event Hubs is the
// supported emission channel for scan-related activity signals.
//
// Components:
//   - Event Hubs Namespace (Standard SKU)
//   - Event Hub: purview-diagnostics (receives Purview signals)
//
// MVP: Public endpoints, secured via Managed Identity and RBAC.
// =============================================================================

@description('The resource name prefix')
param resourcePrefix string

@description('The Azure region for resources')
param location string

@description('Tags to apply to resources')
param tags object

@description('Event Hubs Namespace SKU')
@allowed(['Basic', 'Standard', 'Premium'])
param eventHubSku string = 'Standard'

@description('Event Hub name for Purview diagnostics')
param eventHubName string = 'purview-diagnostics'

@description('Message retention in days')
@minValue(1)
@maxValue(7)
param messageRetentionDays int = 1

@description('Number of partitions')
@minValue(1)
@maxValue(32)
param partitionCount int = 2

// =============================================================================
// EVENT HUBS NAMESPACE
// =============================================================================

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: '${resourcePrefix}-eh'
  location: location
  tags: tags
  sku: {
    name: eventHubSku
    tier: eventHubSku
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'  // MVP: Public endpoints for Dev
    disableLocalAuth: false  // MVP: Allow connection strings for Dev (disable in Prod)
    isAutoInflateEnabled: false  // MVP: No auto-inflate for Dev
    zoneRedundant: false  // MVP: No zone redundancy for Dev
  }
}

// =============================================================================
// EVENT HUB FOR PURVIEW DIAGNOSTICS
// =============================================================================
// This Event Hub receives diagnostic signals from Microsoft Purview.
// Purview Diagnostic Settings will route logs/metrics here.
// =============================================================================

resource purviewDiagnosticsHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace
  name: eventHubName
  properties: {
    messageRetentionInDays: messageRetentionDays
    partitionCount: partitionCount
  }
}

// =============================================================================
// CONSUMER GROUP FOR BRIDGE FUNCTION
// =============================================================================
// The bridge function uses this consumer group to read events.
// =============================================================================

resource bridgeConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: purviewDiagnosticsHub
  name: 'bridge-function'
}

// =============================================================================
// AUTHORIZATION RULE FOR DIAGNOSTIC SETTINGS
// =============================================================================
// Purview Diagnostic Settings requires a SAS policy to send events.
// This is a platform limitation - Diagnostic Settings cannot use Managed Identity.
// =============================================================================

resource diagnosticsSendRule 'Microsoft.EventHub/namespaces/authorizationRules@2024-01-01' = {
  parent: eventHubNamespace
  name: 'DiagnosticsSendRule'
  properties: {
    rights: [
      'Send'
    ]
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Event Hub namespace resource ID')
output eventHubNamespaceId string = eventHubNamespace.id

@description('Event Hub namespace name')
output eventHubNamespaceName string = eventHubNamespace.name

@description('Event Hub name')
output eventHubName string = purviewDiagnosticsHub.name

@description('Event Hub resource ID')
output eventHubId string = purviewDiagnosticsHub.id

@description('Consumer group for bridge function')
output bridgeConsumerGroupName string = bridgeConsumerGroup.name

@description('System-assigned Managed Identity principal ID')
output managedIdentityPrincipalId string = eventHubNamespace.identity.principalId

@description('Authorization rule ID for Diagnostic Settings')
output diagnosticsSendRuleId string = diagnosticsSendRule.id
