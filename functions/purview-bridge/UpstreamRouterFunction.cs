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
/// and fans out one enrichment-request message per enrichable Purview asset.
///
/// Pipeline role:
///   purview-events (SB trigger)
///     → resolve data source name from DataSourceName field (primary)
///       or scanName regex (fallback for compatibility)
///     → Purview Search API → all assets matching data source
///     → filter out container/parent entity types
///     → enrichment-requests (one message per leaf asset)
///
/// Auth: DefaultAzureCredential (Bridge Managed Identity).
///   Service Bus trigger/sender : ServiceBusConnection__fullyQualifiedNamespace
///   Purview REST calls          : https://purview.azure.net/.default
///
/// Throttling: Purview Atlas API baseline is 250 ops/sec (25 × 10 capacity units).
///   HTTP 429 is handled with exponential backoff (up to MaxRetries attempts).
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

    /// <summary>
    /// Container/parent entity types that should NOT be sent for enrichment.
    /// These are structural groupings, not leaf assets with meaningful metadata.
    /// </summary>
    private static readonly HashSet<string> ExcludedEntityTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "azure_sql_db",
        "azure_sql_schema",
        "azure_storage_account",
        "azure_blob_service",
        "azure_resource_group",
        "azure_subscription"
    };

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
        // 0. Filter: only process Succeeded scan events
        // ------------------------------------------------------------------ //
        // Purview emits multiple events per scan (Throttled, Queued, Running,
        // Succeeded). Only the final Succeeded event carries meaningful data.
        // Processing intermediate events wastes Purview API calls and creates
        // duplicate enrichment-requests messages.
        try
        {
            using var filterDoc = JsonDocument.Parse(body);
            var filterRoot = filterDoc.RootElement;
            JsonElement filterRecord = filterRoot;
            if (filterRoot.TryGetProperty("records", out var filterArr) && filterArr.GetArrayLength() > 0)
                filterRecord = filterArr[0];

            var resultType = filterRecord.TryGetProperty("resultType", out var rtProp)
                ? rtProp.GetString() ?? ""
                : "";

            if (!string.Equals(resultType, "Succeeded", StringComparison.OrdinalIgnoreCase))
            {
                _logger.LogInformation(
                    "Skipping non-Succeeded event (resultType={ResultType})", resultType);
                return; // Message completed — not retried
            }
        }
        catch (Exception filterEx)
        {
            // Fail-open: if we can't parse, proceed with processing
            _logger.LogWarning(filterEx, "Could not parse resultType — proceeding with processing");
        }

        // ------------------------------------------------------------------ //
        // 1. Resolve data source name
        //    Primary  : DataSourceName field (stable, documented by Microsoft)
        //    Fallback : regex on scanName (custom format, not guaranteed)
        // ------------------------------------------------------------------ //
        string dataSourceName;
        try
        {
            dataSourceName = ResolveDataSourceName(body);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "{ObsLog}", ObsLog("router", "datasource_name_resolution_failed", correlationId));
            return;
        }

        if (string.IsNullOrEmpty(dataSourceName))
        {
            _logger.LogWarning("{ObsLog}", ObsLog("router", "datasource_name_unresolved_skipped", correlationId));
            return;
        }

        _logger.LogInformation("Resolved data source name: {DataSourceName}", dataSourceName);

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
        // 3. Search Purview for ALL assets matching dataSourceName
        // ------------------------------------------------------------------ //
        var allAssets = await SearchAssetsByDataSource(baseUrl, tokenResult.Token, dataSourceName);

        // ------------------------------------------------------------------ //
        // 4. Filter out container/parent types — keep only leaf assets
        // ------------------------------------------------------------------ //
        var enrichableAssets = allAssets
            .Where(a => !ExcludedEntityTypes.Contains(a.EntityType))
            .ToList();

        _logger.LogInformation(
            "Search returned {Total} assets, {Enrichable} enrichable after filtering for data source {DataSource}",
            allAssets.Count, enrichableAssets.Count, dataSourceName);

        if (enrichableAssets.Count == 0)
        {
            _logger.LogWarning("{ObsLog}", ObsLog("router", "no_enrichable_assets_found_skipped", correlationId));
            return;
        }

        // ------------------------------------------------------------------ //
        // 5. Send each enrichable asset to enrichment-requests queue
        // ------------------------------------------------------------------ //
        EnsureSender();
        var outMessages = new List<ServiceBusMessage>();

        foreach (var asset in enrichableAssets)
        {
            var payload = JsonSerializer.Serialize(new
            {
                id           = asset.Guid,
                entityType   = asset.EntityType,
                entityName   = asset.Name,
                sourceSystem = "purview"
            });

            var outgoing = new ServiceBusMessage(Encoding.UTF8.GetBytes(payload));
            outgoing.ApplicationProperties["correlationId"] = correlationId;
            outMessages.Add(outgoing);

            _logger.LogInformation("{ObsLog}", ObsLog("router", "enrichment_request_queued", correlationId, asset.Guid));
        }

        await _sender!.SendMessagesAsync(outMessages);
        _logger.LogInformation("{ObsLog}", ObsLog("router", "enrichment_requests_sent", correlationId));
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
    // DATA SOURCE NAME RESOLUTION
    // ---------------------------------------------------------------------- //

    // Regex to detect hashed/opaque DataSourceName values produced by lineage scans.
    // These are SHA-256 hex strings (64 chars), optionally prefixed with "lineage_".
    // They do NOT map to searchable Purview entity names and must be skipped.
    private static readonly Regex HashedDsnRegex =
        new(@"^(lineage_)?[A-F0-9]{32,}$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>
    /// Resolves the data source name from the incoming Service Bus message.
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
    private string ResolveDataSourceName(string message)
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

                        _logger.LogInformation("Data source name resolved via {Field}: {Name}", fieldName, dsn);
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
                        var name = match.Groups[1].Value;
                        _logger.LogInformation(
                            "Data source name resolved via scanName regex (lineage extract): {Name}", name);
                        return name;
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
                    "Data source name unresolved for event type {EventType} — skipping",
                    dstProp.GetString());
                break;
            }
        }

        return string.Empty;
    }

    // ---------------------------------------------------------------------- //
    // PURVIEW SEARCH API
    // ---------------------------------------------------------------------- //

    /// <summary>
    /// Lightweight DTO for assets returned by the Purview Search API.
    /// </summary>
    private sealed record AssetRef(string Guid, string EntityType, string Name);

    /// <summary>
    /// Searches Purview for ALL assets whose qualifiedName or name matches the
    /// given data source name. Uses paginated Search API calls.
    ///
    /// This replaces the old SQL-specific hierarchy walk (DB → Schemas → Tables)
    /// with a single generic search that works for any asset type.
    /// </summary>
    private async Task<List<AssetRef>> SearchAssetsByDataSource(
        string baseUrl, string token, string dataSourceName)
    {
        var results = new List<AssetRef>();
        string? continuationToken = null;
        const int pageSize = 100;
        const int maxPages = 50; // Safety: prevent infinite pagination
        int page = 0;

        while (true)
        {
            page++;
            if (page > maxPages)
            {
                _logger.LogWarning(
                    "Pagination safety limit reached ({MaxPages} pages, {Count} assets) — returning partial results",
                    maxPages, results.Count);
                break;
            }

            // Build request body: first page has no token, subsequent pages use continuationToken
            var requestObj = new Dictionary<string, object>
            {
                ["keywords"] = dataSourceName,
                ["limit"]    = pageSize
            };
            if (continuationToken != null)
                requestObj["continuationToken"] = continuationToken;

            var requestBody = JsonSerializer.Serialize(requestObj);

            HttpResponseMessage resp;
            try
            {
                resp = await SendWithRetry(() =>
                {
                    var req = new HttpRequestMessage(
                        HttpMethod.Post,
                        $"{baseUrl}/search/query?api-version=2023-09-01")
                    {
                        Content = new StringContent(requestBody, Encoding.UTF8, "application/json")
                    };
                    req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                    return req;
                });
            }
            catch (Exception ex)
            {
                // GUARDRAIL: if pagination fails, return what we have from previous pages.
                // This ensures the pipeline processes at least the first page of results
                // rather than failing entirely.
                if (results.Count > 0)
                {
                    _logger.LogWarning(ex,
                        "Pagination failed on page {Page} — returning {Count} assets from previous pages (guardrail)",
                        page, results.Count);
                    break;
                }
                throw; // First page failure — no guardrail, propagate error
            }

            var responseBody = await resp.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(responseBody);

            if (!doc.RootElement.TryGetProperty("value", out var valueArr))
                break;

            int count = 0;
            foreach (var item in valueArr.EnumerateArray())
            {
                var guid       = item.TryGetProperty("id", out var idProp)         ? idProp.GetString() ?? ""       : "";
                var entityType = item.TryGetProperty("entityType", out var etProp)  ? etProp.GetString() ?? ""       : "";
                var name       = item.TryGetProperty("name", out var nProp)         ? nProp.GetString() ?? guid      : guid;

                if (!string.IsNullOrEmpty(guid) && !string.IsNullOrEmpty(entityType))
                    results.Add(new AssetRef(guid, entityType, name));

                count++;
            }

            _logger.LogInformation(
                "Search page {Page}: {Count} results, total so far: {Total}",
                page, count, results.Count);

            // Check for continuationToken — this is how Purview Search API paginates
            continuationToken = doc.RootElement.TryGetProperty("continuationToken", out var ctProp)
                ? ctProp.GetString()
                : null;

            // No more pages if: no continuation token, or fewer results than page size
            if (string.IsNullOrEmpty(continuationToken) || count < pageSize)
                break;
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
                if (!resp.IsSuccessStatusCode)
                {
                    var errorBody = await resp.Content.ReadAsStringAsync();
                    _logger.LogError(
                        "Purview API: HTTP {StatusCode} — URL: {Url} — Body: {ErrorBody}",
                        (int)resp.StatusCode, req.RequestUri, errorBody);
                }
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
