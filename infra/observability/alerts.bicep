// =============================================================================
// Azure Monitor Alerts Module
// =============================================================================
// Purpose: Provisions proactive alert rules for the AI Metadata Enricher
// pipeline, ensuring operational issues are detected and notified automatically.
//
// Alert categories:
//   1. Pipeline health  — error rate, block rate, inactivity
//   2. Service heartbeat — bridge, router, orchestrator liveness
//   3. Dead-letter queue — DLQ growth on Service Bus queues
//
// All scheduled query rules target Application Insights (traces) and use
// the same KQL patterns documented in kql-queries.md.
//
// DLQ alerts use Service Bus metric alerts (deadLetteredMessages).
//
// Contract reference (runtime_architecture_contract.yaml):
//   observability.metrics: llm_token_usage, enrichment_latency,
//                          validation_failures, purview_write_errors,
//                          ai_search_errors
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

@description('Application Insights resource ID (used as query scope for log alerts)')
param appInsightsId string

@description('Service Bus namespace resource ID (used as scope for metric alerts)')
param serviceBusNamespaceId string

@description('Email address for alert notifications')
param alertEmail string

// =============================================================================
// ACTION GROUP
// =============================================================================
// Defines notification channels for all alert rules.
// MVP: email only. Future: Teams/Slack webhook, PagerDuty, Azure Function.

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${resourcePrefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'aime-alerts'
    enabled: true
    emailReceivers: [
      {
        name: 'PipelineOps'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// =============================================================================
// SCHEDULED QUERY RULES — Pipeline Health
// =============================================================================

// --- Alert 1: High Error Rate (>10% in 1h) ---
resource alertHighErrorRate 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-error-rate-${resourcePrefix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AIME — High Error Rate (>10%)'
    description: 'Pipeline error rate exceeded 10% in the last hour. Investigate failed enrichments.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where timestamp > ago(1h)
| where customDimensions['event'] == 'pipeline_completion'
| summarize Total = count(), Errors = countif(tostring(customDimensions['status']) == 'ERROR')
| where Total > 0 and Errors * 100 / Total > 10
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// --- Alert 2: Pipeline Inactivity (no executions in 2h) ---
resource alertPipelineInactive 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-inactivity-${resourcePrefix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AIME — Pipeline Inactive (0 executions in 2h)'
    description: 'No pipeline_completion events detected in 2 hours. Orchestrator may be down or queue empty.'
    severity: 1
    enabled: false
    evaluationFrequency: 'PT15M'
    windowSize: 'PT2H'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where timestamp > ago(2h)
| where customDimensions['event'] == 'pipeline_completion'
| summarize Total = count()
| where Total == 0
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// --- Alert 3: High Block Rate (>25% in 1h) ---
resource alertHighBlockRate 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-block-rate-${resourcePrefix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AIME — High Block Rate (>25%)'
    description: 'Validation block rate exceeded 25% in the last hour. Review LLM output quality or prompt.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where timestamp > ago(1h)
| where customDimensions['event'] == 'pipeline_completion'
| summarize Total = count(), Blocked = countif(tostring(customDimensions['status']) == 'BLOCK')
| where Total > 0 and Blocked * 100 / Total > 25
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// =============================================================================
// SCHEDULED QUERY RULES — Service Heartbeat
// =============================================================================

// --- Alert 4: Heartbeat Loss — Bridge ---
resource alertHeartbeatBridge 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-heartbeat-bridge-${resourcePrefix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AIME — Heartbeat Loss: Bridge'
    description: 'No host_alive heartbeat from HeuristicTriggerBridge for >10 minutes.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where timestamp > ago(10m)
| where message == 'host_alive' and customDimensions['service'] == 'bridge'
| summarize HeartbeatCount = count()
| where HeartbeatCount == 0
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// --- Alert 5: Heartbeat Loss — Router ---
resource alertHeartbeatRouter 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-heartbeat-router-${resourcePrefix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AIME — Heartbeat Loss: Router'
    description: 'No host_alive heartbeat from UpstreamRouterFunction for >10 minutes.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where timestamp > ago(10m)
| where message == 'host_alive' and customDimensions['service'] == 'router'
| summarize HeartbeatCount = count()
| where HeartbeatCount == 0
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// --- Alert 6: Heartbeat Loss — Orchestrator ---
resource alertHeartbeatOrchestrator 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-heartbeat-orch-${resourcePrefix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AIME — Heartbeat Loss: Orchestrator'
    description: 'No host_alive heartbeat from Orchestrator for >10 minutes.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where timestamp > ago(10m)
| where message == 'host_alive' and customDimensions['service'] == 'orchestrator'
| summarize HeartbeatCount = count()
| where HeartbeatCount == 0
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// =============================================================================
// METRIC ALERTS — Dead-Letter Queue (Service Bus)
// =============================================================================

// --- Alert 7: DLQ Growth — enrichment-requests ---
resource alertDlqEnrichment 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-dlq-enrichment-${resourcePrefix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Dead-letter messages detected on enrichment-requests queue. Messages exhausted maxDeliveryCount (10).'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      serviceBusNamespaceId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'DLQ_enrichment_requests'
          metricName: 'DeadletteredMessages'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          dimensions: [
            {
              name: 'EntityName'
              operator: 'Include'
              values: [
                'enrichment-requests'
              ]
            }
          ]
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// --- Alert 8: DLQ Growth — purview-events ---
resource alertDlqPurviewEvents 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-dlq-purview-${resourcePrefix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Dead-letter messages detected on purview-events queue. Messages exhausted maxDeliveryCount (10).'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      serviceBusNamespaceId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'DLQ_purview_events'
          metricName: 'DeadletteredMessages'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          dimensions: [
            {
              name: 'EntityName'
              operator: 'Include'
              values: [
                'purview-events'
              ]
            }
          ]
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Action group resource ID')
output actionGroupId string = actionGroup.id

@description('Action group name')
output actionGroupName string = actionGroup.name
