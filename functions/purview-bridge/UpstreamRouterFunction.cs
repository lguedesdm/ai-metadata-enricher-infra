using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace PurviewBridge;

/// <summary>
/// Upstream router: consumes ScanStatusLogEvents from the purview-events queue
/// and fans out one enrichment-request message per Purview table entity.
///
/// Pipeline role:
///   purview-events (SB trigger)
///     → resolve DB name from DataSourceName field (primary)
///       or scanName regex (fallback for compatibility)
///     → Purview Search → DB GUID
///     → DB entity → schema GUIDs (single GET)
///     → bulk schema GET → table GUIDs + names (single bulk call)
///     → enrichment-requests (one message per table)
///
/// Auth: DefaultAzureCredential (Bridge Managed Identity).
///   Service Bus trigger/sender : ServiceBusConnection__fullyQualifiedNamespace
///   Purview REST calls          : https://purview.azure.net/.default
///
/// Throttling: Purview Atlas API baseline is 250 ops/sec (25 × 10 capacity units).
///   HTTP 429 is handled with exponential backoff (up to MaxRetries attempts).
///   Bulk entity fetch (/entity/bulk) is used to keep round trips to O(1)
///   regardless of schema count.
///
/// App settings consumed:
///   PurviewAccountName              e.g. purview-ai-metadata-dev
///   EnrichmentRequestsQueueName     frozen: enrichment-requests
///   PurviewEventsQueueName          frozen: purview-events  (trigger)
///   ServiceBusConnection__fullyQualifiedNamespace  (already present)
///
/// Event format note:
///   Azure Monitor emits diagnostic logs to Event Hub wrapped in a records[]
///   array. The HeuristicTriggerBridge forwards each hub payload verbatim.
///   This function unwraps records[] when present, then falls back to treating
///   the root object as the record directly.
///
///   Primary field:  DataSourceName / dataSourceName (documented, stable)
///   Fallback field: scanName parsed via regex (custom naming, not guaranteed)
/// </summary>
public class UpstreamRouterFunction
{
    private readonly ILogger<UpstreamRouterFunction> _logger;

    // Shared, thread-safe HTTP client for all Purview REST calls.
    private static readonly HttpClient _http = new();

    // Lazy-initialised Service Bus sender for enrichment-requests.
    private static ServiceBusClient? _sbClient;
    private static ServiceBusSender? _sender;

    private const int MaxRetries   = 4;
    private const int BaseDelayMs  = 500;

    // scanName fallback pattern: lineage_for_<dbName>_<8+ uppercase hex chars>
    // NOT a guaranteed Purview format — kept only for backwards compatibility.
    private static readonly Regex ScanNameRegex =
        new(@"lineage_for_(.+?)_[A-F0-9]{8,}", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public UpstreamRouterFunction(ILogger<UpstreamRouterFunction> logger)
    {
        _logger = logger;
    }

    [Function(nameof(UpstreamRouterFunction))]
    public async Task Run(
        [ServiceBusTrigger("%PurviewEventsQueueName%", Connection = "ServiceBusConnection")]
        ServiceBusReceivedMessage message)
    {
        // Read correlationId propagated by the Bridge. Fall back to a new UUID
        // if the message pre-dates correlationId support or arrived via another path.
        var correlationId = message.ApplicationProperties.TryGetValue("correlationId", out var cid)
            ? cid?.ToString() ?? Guid.NewGuid().ToString()
            : Guid.NewGuid().ToString();

        var body = message.Body.ToString();

        _logger.LogInformation("{ObsLog}", ObsLog("router", "message_received", correlationId));

        // ------------------------------------------------------------------ //
        // 1. Resolve DB name
        //    Primary  : DataSourceName field (stable, documented by Microsoft)
        //    Fallback : regex on scanName (custom format, not guaranteed)
        // ------------------------------------------------------------------ //
        string dbName;
        try
        {
            dbName = ResolveDbName(body);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "{ObsLog}", ObsLog("router", "db_name_resolution_failed", correlationId));
            return;
        }

        if (string.IsNullOrEmpty(dbName))
        {
            _logger.LogWarning("{ObsLog}", ObsLog("router", "db_name_unresolved_skipped", correlationId));
            return;
        }

        _logger.LogInformation("Resolved DB name: {DbName}", dbName);

        // ------------------------------------------------------------------ //
        // 2. Acquire a Purview bearer token via Bridge Managed Identity
        // ------------------------------------------------------------------ //
        var credential = new DefaultAzureCredential();
        var tokenResult = await credential.GetTokenAsync(
            new TokenRequestContext(new[] { "https://purview.azure.net/.default" }),
            CancellationToken.None);

        var purviewAccount = Environment.GetEnvironmentVariable("PurviewAccountName")
            ?? throw new InvalidOperationException("PurviewAccountName app setting is missing");
        var baseUrl = $"https://{purviewAccount}.purview.azure.com/datamap/api";

        // ------------------------------------------------------------------ //
        // 3. Search Purview for the azure_sql_db entity matching dbName
        // ------------------------------------------------------------------ //
        var dbGuid = await SearchEntityGuid(baseUrl, tokenResult.Token, dbName);
        if (dbGuid is null)
        {
            _logger.LogWarning("{ObsLog}", ObsLog("router", "db_entity_not_found", correlationId));
            return;
        }
        _logger.LogInformation("Found DB entity GUID: {DbGuid}", dbGuid);

        // ------------------------------------------------------------------ //
        // 4. Get DB entity → extract schema GUIDs (1 API call)
        // ------------------------------------------------------------------ //
        var schemaRefs = await GetRelationshipRefs(baseUrl, tokenResult.Token, dbGuid, "schemas");
        if (schemaRefs.Count == 0)
        {
            _logger.LogWarning("{ObsLog}", ObsLog("router", "no_schemas_found_skipped", correlationId));
            return;
        }

        // ------------------------------------------------------------------ //
        // 5. Bulk-fetch all schema entities in a single call → extract tables
        //    Uses /entity/bulk?guid=...&guid=... to avoid N sequential GETs.
        //    Purview Atlas API baseline: 250 ops/sec (25 × 10 capacity units).
        //    HTTP 429 is retried with exponential backoff.
        // ------------------------------------------------------------------ //
        var schemaGuids = schemaRefs.Select(r => r.Guid).ToList();
        var schemaEntities = await BulkGetEntities(baseUrl, tokenResult.Token, schemaGuids);

        EnsureSender();
        var tableMessages = new List<ServiceBusMessage>();

        foreach (var schemaEntity in schemaEntities)
        {
            var tableRefs = ExtractRelationshipRefs(schemaEntity, "tables");
            foreach (var (tableGuid, tableName) in tableRefs)
            {
                var payload = JsonSerializer.Serialize(new
                {
                    id           = tableGuid,
                    entityType   = "azure_sql_table",
                    entityName   = tableName,
                    sourceSystem = "purview"
                });

                var outgoing = new ServiceBusMessage(Encoding.UTF8.GetBytes(payload));
                outgoing.ApplicationProperties["correlationId"] = correlationId;
                tableMessages.Add(outgoing);

                _logger.LogInformation("{ObsLog}", ObsLog("router", "enrichment_request_queued", correlationId, tableGuid));
            }
        }

        if (tableMessages.Count > 0)
        {
            await _sender!.SendMessagesAsync(tableMessages);
            _logger.LogInformation("{ObsLog}", ObsLog("router", "enrichment_requests_sent", correlationId));
        }
        else
        {
            _logger.LogWarning("{ObsLog}", ObsLog("router", "no_tables_found_skipped", correlationId));
        }
    }

    private static string ObsLog(string stage, string evt, string correlationId, string? assetId = null) =>
        System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, string?>
        {
            ["assetId"]       = assetId,
            ["correlationId"] = correlationId,
            ["stage"]         = stage,
            ["event"]         = evt,
            ["timestamp"]     = DateTime.UtcNow.ToString("o")
        });

    // ---------------------------------------------------------------------- //
    // DB NAME RESOLUTION
    // ---------------------------------------------------------------------- //

    // Regex to detect hashed/opaque DataSourceName values produced by lineage scans.
    // These are SHA-256 hex strings (64 chars), optionally prefixed with "lineage_".
    // They do NOT map to searchable Purview entity names and must be skipped.
    private static readonly Regex HashedDsnRegex =
        new(@"^(lineage_)?[A-F0-9]{32,}$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>
    /// Resolves the database name from the incoming Service Bus message.
    ///
    /// Azure Monitor wraps diagnostic log records in a "records" array when
    /// forwarding to Event Hub. Each record may nest its fields inside a
    /// "properties" sub-object (the standard Azure Monitor diagnostic format).
    /// This method unwraps both layers.
    ///
    /// Lookup order (applied to both record-level and properties-level):
    ///   1. DataSourceName (PascalCase) — documented Azure Monitor column name
    ///      (skipped if value looks like a hash, e.g. lineage extract events)
    ///   2. dataSourceName (camelCase)  — alternate serialisation observed in transit
    ///      (skipped if value looks like a hash)
    ///   3. scanName / ScanName regex   — fallback for custom-named scans
    ///      (extracts DB name from "lineage_for_{dbName}_{hex}" pattern)
    /// </summary>
    private string ResolveDbName(string message)
    {
        using var doc = JsonDocument.Parse(message);
        var root = doc.RootElement;

        // Unwrap records[] array if present (Azure Monitor → Event Hub format)
        JsonElement record = root;
        if (root.TryGetProperty("records", out var recordsArr) && recordsArr.GetArrayLength() > 0)
            record = recordsArr[0];

        // Build the list of elements to search: record itself + properties sub-object.
        // Azure Monitor diagnostic logs nest actual fields inside "properties".
        var searchTargets = new List<JsonElement> { record };
        if (record.TryGetProperty("properties", out var propsElement)
            && propsElement.ValueKind == JsonValueKind.Object)
        {
            searchTargets.Add(propsElement);
        }

        // Primary: DataSourceName / dataSourceName (on each search target)
        foreach (var target in searchTargets)
        {
            foreach (var fieldName in new[] { "DataSourceName", "dataSourceName" })
            {
                if (target.TryGetProperty(fieldName, out var dsnProp))
                {
                    var dsn = dsnProp.GetString();
                    if (!string.IsNullOrWhiteSpace(dsn))
                    {
                        // Skip hashed/opaque values from lineage extract events —
                        // they don't resolve to Purview entity names.
                        if (HashedDsnRegex.IsMatch(dsn))
                        {
                            _logger.LogInformation(
                                "Skipping hashed DataSourceName (lineage extract): {Dsn}", dsn);
                            continue;
                        }

                        _logger.LogInformation("DB name resolved via {Field}: {DbName}", fieldName, dsn);
                        return dsn;
                    }
                }
            }
        }

        // Fallback: regex on scanName / ScanName (on each search target)
        // Extracts DB name from "lineage_for_{dbName}_{hexchars}" pattern.
        // WARNING: this format is NOT guaranteed by Microsoft — it reflects a
        // custom scan naming convention in this environment.
        foreach (var target in searchTargets)
        {
            foreach (var fieldName in new[] { "scanName", "ScanName" })
            {
                if (target.TryGetProperty(fieldName, out var snProp))
                {
                    var scanName = snProp.GetString() ?? string.Empty;
                    var match = ScanNameRegex.Match(scanName);
                    if (match.Success)
                    {
                        var dbName = match.Groups[1].Value;
                        _logger.LogInformation(
                            "DB name resolved via scanName regex (lineage extract): {DbName}", dbName);
                        return dbName;
                    }
                }
            }
        }

        // Log the event type for diagnostics when resolution fails
        foreach (var target in searchTargets)
        {
            if (target.TryGetProperty("dataSourceType", out var dstProp))
            {
                _logger.LogWarning(
                    "DB name unresolved for event type {EventType} — skipping",
                    dstProp.GetString());
                break;
            }
        }

        return string.Empty;
    }

    // ---------------------------------------------------------------------- //
    // PURVIEW API HELPERS
    // ---------------------------------------------------------------------- //

    /// <summary>
    /// POST to Purview Search for a single azure_sql_db entity and return its GUID.
    /// </summary>
    private async Task<string?> SearchEntityGuid(string baseUrl, string token, string dbName)
    {
        var body = JsonSerializer.Serialize(new
        {
            keywords = dbName,
            filter   = new { entityType = "azure_sql_db" }
        });

        using var resp = await SendWithRetry(() =>
        {
            var req = new HttpRequestMessage(
                HttpMethod.Post,
                $"{baseUrl}/search/query?api-version=2023-09-01")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return req;
        });

        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
        if (doc.RootElement.TryGetProperty("value", out var arr) && arr.GetArrayLength() > 0)
            return arr[0].TryGetProperty("id", out var id) ? id.GetString() : null;

        return null;
    }

    /// <summary>
    /// GET /atlas/v2/entity/guid/{guid} and return (guid, displayText) pairs
    /// from the named relationship attribute (e.g. "schemas").
    /// </summary>
    private async Task<List<(string Guid, string Name)>> GetRelationshipRefs(
        string baseUrl, string token, string guid, string relationship)
    {
        using var resp = await SendWithRetry(() =>
        {
            var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl}/atlas/v2/entity/guid/{guid}");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return req;
        });

        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
        if (!doc.RootElement.TryGetProperty("entity", out var entity)) return [];

        return ExtractRelationshipRefs(entity, relationship);
    }

    /// <summary>
    /// Bulk-fetch multiple entities in a single API call.
    /// GET /atlas/v2/entity/bulk?guid={g1}&guid={g2}&...
    /// Returns the "entities" array from the response.
    ///
    /// Reduces N sequential GETs to 1 call — critical for catalogs with many schemas.
    /// </summary>
    private async Task<List<JsonElement>> BulkGetEntities(
        string baseUrl, string token, IReadOnlyList<string> guids)
    {
        var qs = string.Join("&", guids.Select(g => $"guid={Uri.EscapeDataString(g)}"));

        using var resp = await SendWithRetry(() =>
        {
            var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl}/atlas/v2/entity/bulk?{qs}");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return req;
        });

        var results = new List<JsonElement>();

        // Parse into a persistent document (caller owns lifetime via the list)
        var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
        if (doc.RootElement.TryGetProperty("entities", out var entities))
        {
            foreach (var entity in entities.EnumerateArray())
                results.Add(entity.Clone()); // Clone detaches from the document lifetime
        }

        return results;
    }

    /// <summary>
    /// Extracts (guid, displayText) pairs from an entity element's
    /// relationshipAttributes[relationship] array.
    /// </summary>
    private static List<(string Guid, string Name)> ExtractRelationshipRefs(
        JsonElement entity, string relationship)
    {
        var results = new List<(string, string)>();

        if (!entity.TryGetProperty("relationshipAttributes", out var relAttrs)) return results;
        if (!relAttrs.TryGetProperty(relationship, out var items)) return results;

        foreach (var item in items.EnumerateArray())
        {
            var itemGuid = item.TryGetProperty("guid", out var g) ? g.GetString() ?? "" : "";
            var itemName = item.TryGetProperty("displayText", out var n) ? n.GetString() ?? itemGuid : itemGuid;
            if (!string.IsNullOrEmpty(itemGuid))
                results.Add((itemGuid, itemName));
        }

        return results;
    }

    // ---------------------------------------------------------------------- //
    // HTTP + RETRY
    // ---------------------------------------------------------------------- //

    /// <summary>
    /// Sends an HTTP request with exponential backoff retry on HTTP 429.
    /// Purview Atlas API baseline is 250 ops/sec; throttling returns 429 with
    /// a Retry-After header. We honour it when present, else use backoff.
    /// </summary>
    private async Task<HttpResponseMessage> SendWithRetry(Func<HttpRequestMessage> buildRequest)
    {
        for (int attempt = 0; attempt <= MaxRetries; attempt++)
        {
            using var req = buildRequest();
            var resp = await _http.SendAsync(req);

            if (resp.StatusCode != System.Net.HttpStatusCode.TooManyRequests)
            {
                resp.EnsureSuccessStatusCode();
                return resp;
            }

            if (attempt == MaxRetries)
            {
                _logger.LogError("Purview API: still throttled after {MaxRetries} retries — giving up", MaxRetries);
                resp.EnsureSuccessStatusCode(); // throws HttpRequestException
            }

            int delayMs = resp.Headers.RetryAfter?.Delta is TimeSpan retryAfter
                ? (int)retryAfter.TotalMilliseconds
                : BaseDelayMs * (int)Math.Pow(2, attempt);

            _logger.LogWarning("Purview API: HTTP 429 on attempt {Attempt}/{Max} — retrying in {DelayMs}ms",
                attempt + 1, MaxRetries, delayMs);

            await Task.Delay(delayMs);
        }

        // Unreachable, but satisfies compiler
        throw new InvalidOperationException("SendWithRetry exhausted without returning");
    }

    // ---------------------------------------------------------------------- //
    // SERVICE BUS
    // ---------------------------------------------------------------------- //

    private static void EnsureSender()
    {
        if (_sbClient is not null) return;

        var ns = Environment.GetEnvironmentVariable("ServiceBusConnection__fullyQualifiedNamespace")
            ?? throw new InvalidOperationException("ServiceBusConnection__fullyQualifiedNamespace app setting is missing");
        var queue = Environment.GetEnvironmentVariable("EnrichmentRequestsQueueName")
            ?? throw new InvalidOperationException("EnrichmentRequestsQueueName app setting is missing");

        _sbClient = new ServiceBusClient(ns, new DefaultAzureCredential());
        _sender   = _sbClient.CreateSender(queue);
    }
}
