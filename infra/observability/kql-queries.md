# KQL Queries -- AI Metadata Enricher Pipeline Dashboard (Phase 8)
#
# All queries target the `pipeline_completion` trace event emitted by the
# enrichment pipeline and orchestrator.  Fields are in customDimensions
# and are string-serialised by the OpenTelemetry SDK.
#
# Business label mappings (data-agnostic):
#   SUCCESS     -> "Successfully Enriched"
#   SKIP        -> "Already Processed"
#   NO_CONTEXT  -> "Insufficient Context"
#   BLOCK       -> "Validation Protected"
#   ERROR       -> "Processing Error"
#
# Application Insights resource: appi-ai-metadata-dev
# Log Analytics workspace:       log-ai-metadata-dev

## Query 1: Overview KPIs (Section 1 -- tiles visualization)

```kql
// Unpivoted into Metric/Value rows for Azure Workbook tiles rendering.
// Original single-row format caused "Could not create tiles" errors.
let data = traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| summarize
    TotalExecutions = count(),
    Successes = countif(tostring(customDimensions["status"]) == "SUCCESS"),
    AvgLatencyMs = coalesce(round(avg(toint(customDimensions["durationMs"])), 0), 0.0)
| extend SuccessRatePct = iff(TotalExecutions > 0, round(100.0 * Successes / TotalExecutions, 1), 0.0);
print x=1 | project Metric = 'Total Executions', Value = toreal(toscalar(data | project TotalExecutions))
| union (print x=1 | project Metric = 'Success Rate (%)', Value = toreal(toscalar(data | project SuccessRatePct)))
| union (print x=1 | project Metric = 'Avg Latency (ms)', Value = toreal(toscalar(data | project AvgLatencyMs)))
```

## Query 2: Status Distribution with Business Labels (Sections 1 & 2)

```kql
traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| extend rawStatus = tostring(customDimensions["status"])
| extend DisplayStatus = case(
    rawStatus == "SUCCESS", "Successfully Enriched",
    rawStatus == "SKIP", "Already Processed",
    rawStatus == "NO_CONTEXT", "Insufficient Context",
    rawStatus == "BLOCK", "Validation Protected",
    rawStatus == "ERROR", "Processing Error",
    "Unknown"
  )
| summarize Count = count() by DisplayStatus
| order by Count desc
```

## Query 3: Decision Distribution with Percentages (Section 2)

```kql
traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| extend rawStatus = tostring(customDimensions["status"])
| extend DisplayStatus = case(
    rawStatus == "SUCCESS", "Successfully Enriched",
    rawStatus == "SKIP", "Already Processed",
    rawStatus == "NO_CONTEXT", "Insufficient Context",
    rawStatus == "BLOCK", "Validation Protected",
    rawStatus == "ERROR", "Processing Error",
    "Unknown"
  )
| summarize Count = count() by DisplayStatus
| extend Total = toscalar(
    traces
    | where timestamp {TimeRange}
    | where customDimensions["event"] == "pipeline_completion"
    | count
  )
| extend Percentage = round(100.0 * Count / Total, 1)
| project DisplayStatus, Count, Percentage
| order by Count desc
```

## Query 4: Latency by Pipeline Stage (Section 3)

```kql
traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| where isnotempty(customDimensions["durationMs"])
| extend DurationMs = toint(customDimensions["durationMs"])
| summarize
    AvgMs = round(avg(DurationMs), 0),
    P50Ms = round(percentile(DurationMs, 50), 0),
    P95Ms = round(percentile(DurationMs, 95), 0),
    MaxMs = max(DurationMs),
    Executions = count()
  by Stage = tostring(customDimensions["stage"])
| where isnotempty(Stage)
| order by AvgMs desc
```

## Query 5: LLM Token Usage & Estimated Cost (Section 3 -- tiles visualization)

```kql
// Unpivoted into Metric/Value rows for Azure Workbook tiles rendering.
let data = traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| where toint(customDimensions["tokenCount"]) > 0
| summarize
    TotalTokens = sum(toint(customDimensions["tokenCount"])),
    AvgTokens = round(avg(toint(customDimensions["tokenCount"])), 0),
    LLMInvocations = count()
| extend EstimatedCostUSD = round(toreal(TotalTokens) * 0.000005, 4);
print x=1 | project Metric = 'Total Tokens', Value = toreal(toscalar(data | project TotalTokens))
| union (print x=1 | project Metric = 'Avg Tokens/Call', Value = toreal(toscalar(data | project AvgTokens)))
| union (print x=1 | project Metric = 'LLM Invocations', Value = toreal(toscalar(data | project LLMInvocations)))
| union (print x=1 | project Metric = 'Est. Cost (USD)', Value = toreal(toscalar(data | project EstimatedCostUSD)))
```

## Query 6: Error & Block Rates (Section 4 -- tiles visualization)

```kql
// Unpivoted into Metric/Value rows for Azure Workbook tiles rendering.
let data = traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| summarize
    Total = count(),
    Errors = countif(tostring(customDimensions["status"]) == "ERROR"),
    Blocked = countif(tostring(customDimensions["status"]) == "BLOCK")
| extend ErrorRatePct = iff(Total > 0, round(100.0 * Errors / Total, 1), 0.0)
| extend BlockRatePct = iff(Total > 0, round(100.0 * Blocked / Total, 1), 0.0);
print x=1 | project Metric = 'Error Rate (%)', Value = toreal(toscalar(data | project ErrorRatePct))
| union (print x=1 | project Metric = 'Block Rate (%)', Value = toreal(toscalar(data | project BlockRatePct)))
| union (print x=1 | project Metric = 'Total Errors', Value = toreal(toscalar(data | project Errors)))
| union (print x=1 | project Metric = 'Total Blocked', Value = toreal(toscalar(data | project Blocked)))
```

## Query 7: Error Rate Trend (Section 4)

```kql
traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| summarize
    Total = count(),
    Errors = countif(tostring(customDimensions["status"]) == "ERROR")
  by bin(timestamp, 1h)
| extend ErrorRatePct = iff(Total > 0, round(100.0 * Errors / Total, 1), 0.0)
| project timestamp, ErrorRatePct
```

## Query 8: Execution Trace Explorer (Section 5)

```kql
// Parameter: {CorrelationId}
// Uses strlen() guard so empty parameter shows noDataMessage instead of scanning all traces
traces
| where timestamp > ago(7d)
| where strlen("{CorrelationId}") > 0
| where tostring(customDimensions["correlationId"]) == "{CorrelationId}"
| project
    Timestamp = timestamp,
    Event = message,
    Stage = tostring(customDimensions["stage"]),
    Status = tostring(customDimensions["status"]),
    DurationMs = toint(customDimensions["durationMs"]),
    Element = tostring(customDimensions["elementName"]),
    EventType = tostring(customDimensions["event"])
| order by Timestamp asc
```

## Query 9: Recent Executions Reference (Section 5)

```kql
traces
| where timestamp {TimeRange}
| where customDimensions["event"] == "pipeline_completion"
| extend rawStatus = tostring(customDimensions["status"])
| extend DisplayStatus = case(
    rawStatus == "SUCCESS", "Successfully Enriched",
    rawStatus == "SKIP", "Already Processed",
    rawStatus == "NO_CONTEXT", "Insufficient Context",
    rawStatus == "BLOCK", "Validation Protected",
    rawStatus == "ERROR", "Processing Error",
    "Unknown"
  )
| project
    Timestamp = timestamp,
    CorrelationId = tostring(customDimensions["correlationId"]),
    Outcome = DisplayStatus,
    Stage = tostring(customDimensions["stage"]),
    DurationMs = toint(customDimensions["durationMs"])
| order by Timestamp desc
| take 20
```

## Alert Query: High Error Rate (>10% in 1h)

```kql
AppTraces
| where TimeGenerated > ago(1h)
| where Message == 'pipeline_completion'
| summarize Total = count(), Errors = countif(Properties['status'] == 'ERROR')
| where Errors * 100 / Total > 10
```

## Alert Query: Pipeline Inactive (no executions in 2h)

```kql
AppTraces
| where TimeGenerated > ago(2h)
| where Message == 'pipeline_completion'
| count
```

## Alert Query: High BLOCK Rate (>25% in 1h)

```kql
AppTraces
| where TimeGenerated > ago(1h)
| where Message == 'pipeline_completion'
| summarize Total = count(), Blocked = countif(Properties['status'] == 'BLOCK')
| where Blocked * 100 / Total > 25
```
