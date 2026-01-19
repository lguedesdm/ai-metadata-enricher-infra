// =============================================================================
// Messaging Module
// =============================================================================
// Purpose: Azure Service Bus for event-driven messaging.
//
// Components:
//   - Service Bus Namespace
//   - Main Queue: Primary event queue for enrichment requests
//   - Dead-Letter Queue (DLQ): Automatically configured for failed messages
//
// MVP: Public endpoints, secured via Managed Identity and RBAC.
// FUTURE: Consider Private Endpoints and advanced features (sessions, duplicate
// detection, partitioning) for Test/Prod environments.
// =============================================================================

@description('The resource name prefix')
param resourcePrefix string

@description('The Azure region for resources')
param location string

@description('Tags to apply to resources')
param tags object

@description('Service Bus SKU')
@allowed(['Basic', 'Standard', 'Premium'])
param serviceBusSku string = 'Standard'

@description('Main queue name')
param mainQueueName string = 'enrichment-requests'

@description('Max delivery count before moving to DLQ')
param maxDeliveryCount int = 10

@description('Message time-to-live (ISO 8601 duration)')
param messageTtl string = 'P7D'  // 7 days

// =============================================================================
// SERVICE BUS NAMESPACE
// =============================================================================

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: '${resourcePrefix}-sb'
  location: location
  tags: tags
  sku: {
    name: serviceBusSku
    tier: serviceBusSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'  // MVP: Public endpoints for Dev
    disableLocalAuth: false  // MVP: Allow connection strings for Dev (disable in Prod)
    zoneRedundant: false  // MVP: No zone redundancy for Dev
  }
}

// =============================================================================
// MAIN QUEUE
// =============================================================================
// The main queue for enrichment requests.
// Dead-letter queue (DLQ) is automatically created by Azure Service Bus
// when a message exceeds maxDeliveryCount or expires.
//
// DLQ Path: {queueName}/$DeadLetterQueue
// =============================================================================

resource mainQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: mainQueueName
  properties: {
    maxDeliveryCount: maxDeliveryCount
    defaultMessageTimeToLive: messageTtl
    deadLetteringOnMessageExpiration: true  // Enable DLQ for expired messages
    enableBatchedOperations: true
    requiresDuplicateDetection: false  // MVP: Disabled for simplicity
    requiresSession: false  // MVP: Disabled for simplicity
    enablePartitioning: false  // MVP: Disabled for Dev
    lockDuration: 'PT5M'  // 5 minutes lock duration
    maxSizeInMegabytes: 1024  // 1 GB max queue size
  }
}

// =============================================================================
// AUTHORIZATION RULES (Optional)
// =============================================================================
// For MVP, we rely on Managed Identity and RBAC.
// Shared Access Signatures (SAS) are available for backward compatibility
// but should be avoided in production.
//
// FUTURE: Remove SAS policies in Test/Prod and use RBAC exclusively.
// =============================================================================

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Service Bus namespace resource ID')
output serviceBusNamespaceId string = serviceBusNamespace.id

@description('Service Bus namespace name')
output serviceBusNamespaceName string = serviceBusNamespace.name

@description('Service Bus namespace endpoint')
output serviceBusEndpoint string = serviceBusNamespace.properties.serviceBusEndpoint

@description('Main queue name')
output mainQueueName string = mainQueue.name

@description('Dead-letter queue path (auto-created by Azure)')
output deadLetterQueuePath string = '${mainQueue.name}/$DeadLetterQueue'

@description('System-assigned Managed Identity principal ID')
output managedIdentityPrincipalId string = serviceBusNamespace.identity.principalId
