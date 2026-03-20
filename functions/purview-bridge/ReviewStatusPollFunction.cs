using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using Microsoft.Azure.Cosmos;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace PurviewBridge;

/// <summary>
/// Timer-triggered function that polls Purview for review_status changes on
/// assets currently in PENDING state in Cosmos DB.
///
/// Flow (every 5 minutes):
///   1. Query Cosmos state container for all lifecycle records with status "pending"
///   2. For each PENDING asset, GET the Purview entity and read
///      businessAttributes.AI_Enrichment.review_status
///   3. If the steward changed it to APPROVED or REJECTED:
///      - Upsert the lifecycle record in Cosmos (status → approved/rejected)
///      - Write an audit record documenting the sync
///   4. If still PENDING or absent — no action (steward hasn't reviewed yet)
///
/// Auth: DefaultAzureCredential (Function App System-Assigned MI).
///   Cosmos DB  : CosmosEndpoint + Cosmos DB Built-in Data Contributor (data plane RBAC)
///   Purview    : https://purview.azure.net/.default (existing MI permission)
///
/// Idempotent: upsert with the same status is a no-op. Safe to run on overlapping
/// timer invocations.
///
/// App settings consumed:
///   CosmosEndpoint          e.g. https://cosmos-ai-metadata-dev.documents.azure.com:443/
///   CosmosDatabaseName      frozen: metadata_enricher
///   CosmosStateContainer    frozen: state
///   CosmosAuditContainer    frozen: audit
///   PurviewAccountName      (already present)
/// </summary>
public class ReviewStatusPollFunction
{
    private readonly ILogger<ReviewStatusPollFunction> _logger;

    private static readonly HttpClient _http = new();

    private const int MaxRetries  = 4;
    private const int BaseDelayMs = 500;

    public ReviewStatusPollFunction(ILogger<ReviewStatusPollFunction> logger)
    {
        _logger = logger;
    }

    [Function(nameof(ReviewStatusPollFunction))]
    public async Task Run([TimerTrigger("0 */5 * * * *")] TimerInfo timer)
    {
        var timestamp = DateTime.UtcNow;
        _logger.LogInformation("{ObsLog}", ObsLog("review_poll", "poll_started", null));

        // ------------------------------------------------------------------ //
        // 1. Connect to Cosmos DB (Managed Identity)
        // ------------------------------------------------------------------ //
        var cosmosEndpoint     = GetRequiredSetting("CosmosEndpoint");
        var cosmosDatabaseName = GetRequiredSetting("CosmosDatabaseName");
        var stateContainerName = GetRequiredSetting("CosmosStateContainer");
        var auditContainerName = GetRequiredSetting("CosmosAuditContainer");

        var credential = new DefaultAzureCredential();
        using var cosmosClient = new CosmosClient(cosmosEndpoint, credential);

        var stateContainer = cosmosClient.GetContainer(cosmosDatabaseName, stateContainerName);
        var auditContainer = cosmosClient.GetContainer(cosmosDatabaseName, auditContainerName);

        // ------------------------------------------------------------------ //
        // 2. Query all PENDING lifecycle records
        // ------------------------------------------------------------------ //
        var query = new QueryDefinition(
            "SELECT * FROM c WHERE c.lifecycleStatus = @status AND c.recordType = 'lifecycle'")
            .WithParameter("@status", "pending");

        var pendingRecords = new List<JsonElement>();
        using var feed = stateContainer.GetItemQueryStreamIterator(query);
        while (feed.HasMoreResults)
        {
            using var response = await feed.ReadNextAsync();
            using var doc = JsonDocument.Parse(response.Content);
            if (doc.RootElement.TryGetProperty("Documents", out var documents))
            {
                foreach (var item in documents.EnumerateArray())
                    pendingRecords.Add(item.Clone());
            }
        }

        if (pendingRecords.Count == 0)
        {
            _logger.LogInformation("{ObsLog}", ObsLog("review_poll", "no_pending_records", null));
            return;
        }

        _logger.LogInformation("Found {Count} pending lifecycle records to check", pendingRecords.Count);

        // ------------------------------------------------------------------ //
        // 3. Acquire Purview bearer token
        // ------------------------------------------------------------------ //
        var tokenResult = await credential.GetTokenAsync(
            new TokenRequestContext(new[] { "https://purview.azure.net/.default" }),
            CancellationToken.None);

        var purviewAccount = GetRequiredSetting("PurviewAccountName");
        var baseUrl = $"https://{purviewAccount}.purview.azure.com/datamap/api";

        // ------------------------------------------------------------------ //
        // 4. For each PENDING record, check Purview review_status
        // ------------------------------------------------------------------ //
        int totalSynced = 0;

        foreach (var record in pendingRecords)
        {
            var assetId    = record.GetProperty("id").GetString()!;
            var entityType = record.GetProperty("entityType").GetString()!;

            try
            {
                var purviewStatus = await GetPurviewReviewStatus(baseUrl, tokenResult.Token, assetId);

                if (purviewStatus is null or "PENDING" or "")
                    continue; // steward hasn't reviewed yet

                string newStatus;
                string operation;

                if (string.Equals(purviewStatus, "APPROVED", StringComparison.OrdinalIgnoreCase))
                {
                    newStatus = "approved";
                    operation = "purview_sync_approved";
                }
                else if (string.Equals(purviewStatus, "REJECTED", StringComparison.OrdinalIgnoreCase))
                {
                    newStatus = "rejected";
                    operation = "purview_sync_rejected";
                }
                else
                {
                    // Unknown value (e.g. "FOO") — ignore
                    _logger.LogWarning("Ignoring unknown review_status '{Status}' for asset {AssetId}",
                        purviewStatus, assetId);
                    continue;
                }

                // -------------------------------------------------------------- //
                // 4a. Upsert lifecycle record with new status
                // -------------------------------------------------------------- //
                var updatedRecord = BuildUpdatedLifecycleRecord(record, newStatus, timestamp);
                await stateContainer.UpsertItemAsync(
                    updatedRecord,
                    new PartitionKey(entityType));

                // -------------------------------------------------------------- //
                // 4b. Write audit record
                // -------------------------------------------------------------- //
                var correlationId = $"purview-sync-{Guid.NewGuid()}";
                var auditRecord = new Dictionary<string, object>
                {
                    ["id"]             = $"sync:{assetId}:{timestamp:o}",
                    ["entityType"]     = entityType,
                    ["assetId"]        = assetId,
                    ["correlationId"]  = correlationId,
                    ["operation"]      = operation,
                    ["outcome"]        = "SUCCESS",
                    ["reason"]         = $"Steward changed review_status to {purviewStatus} in Purview",
                    ["previousStatus"] = "pending",
                    ["newStatus"]      = newStatus,
                    ["recordType"]     = "writeback_audit",
                    ["timestamp"]      = timestamp.ToString("o")
                };

                await auditContainer.UpsertItemAsync(
                    auditRecord,
                    new PartitionKey(entityType));

                totalSynced++;

                _logger.LogInformation("{ObsLog}", ObsLog("review_poll", operation, correlationId, assetId));
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to sync review status for asset {AssetId}", assetId);
            }
        }

        _logger.LogInformation("{ObsLog}", ObsLog("review_poll", "poll_completed", null));
        _logger.LogInformation("Poll complete: {Total} pending checked, {Synced} synced",
            pendingRecords.Count, totalSynced);
    }

    // ---------------------------------------------------------------------- //
    // PURVIEW API: read review_status from Business Metadata
    // ---------------------------------------------------------------------- //

    /// <summary>
    /// GET the Purview entity by GUID and extract
    /// businessAttributes.AI_Enrichment.review_status.
    /// Returns null if the attribute is absent or the entity is not found.
    /// </summary>
    private async Task<string?> GetPurviewReviewStatus(string baseUrl, string token, string guid)
    {
        using var resp = await SendWithRetry(() =>
        {
            var req = new HttpRequestMessage(HttpMethod.Get,
                $"{baseUrl}/atlas/v2/entity/guid/{guid}");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return req;
        });

        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());

        if (!doc.RootElement.TryGetProperty("entity", out var entity))
            return null;

        if (!entity.TryGetProperty("businessAttributes", out var bizAttrs))
            return null;

        if (!bizAttrs.TryGetProperty("AI_Enrichment", out var aiEnrichment))
            return null;

        if (!aiEnrichment.TryGetProperty("review_status", out var reviewStatus))
            return null;

        return reviewStatus.GetString();
    }

    // ---------------------------------------------------------------------- //
    // COSMOS: build updated lifecycle document
    // ---------------------------------------------------------------------- //

    /// <summary>
    /// Clones the existing lifecycle record with the updated status and timestamp.
    /// Preserves all other fields (entityType, contentHash, sourceSystem, etc.).
    /// </summary>
    private static Dictionary<string, object> BuildUpdatedLifecycleRecord(
        JsonElement original, string newStatus, DateTime updatedAt)
    {
        var result = new Dictionary<string, object>();

        foreach (var prop in original.EnumerateObject())
        {
            if (prop.Name == "lifecycleStatus")
                result["lifecycleStatus"] = newStatus;
            else if (prop.Name == "updatedAt")
                result["updatedAt"] = updatedAt.ToString("o");
            else
                result[prop.Name] = JsonSerializer.Deserialize<object>(prop.Value.GetRawText())!;
        }

        // Ensure fields exist even if missing from original
        result["lifecycleStatus"] = newStatus;
        result["updatedAt"] = updatedAt.ToString("o");

        return result;
    }

    // ---------------------------------------------------------------------- //
    // HTTP + RETRY (same pattern as UpstreamRouterFunction)
    // ---------------------------------------------------------------------- //

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
                resp.EnsureSuccessStatusCode(); // throws
            }

            int delayMs = resp.Headers.RetryAfter?.Delta is TimeSpan retryAfter
                ? (int)retryAfter.TotalMilliseconds
                : BaseDelayMs * (int)Math.Pow(2, attempt);

            _logger.LogWarning("Purview API: HTTP 429 on attempt {Attempt}/{Max} — retrying in {DelayMs}ms",
                attempt + 1, MaxRetries, delayMs);

            await Task.Delay(delayMs);
        }

        throw new InvalidOperationException("SendWithRetry exhausted without returning");
    }

    // ---------------------------------------------------------------------- //
    // HELPERS
    // ---------------------------------------------------------------------- //

    private static string GetRequiredSetting(string name) =>
        Environment.GetEnvironmentVariable(name)
            ?? throw new InvalidOperationException($"{name} app setting is missing");

    private static string ObsLog(string stage, string evt, string? correlationId, string? assetId = null) =>
        JsonSerializer.Serialize(new Dictionary<string, string?>
        {
            ["assetId"]       = assetId,
            ["correlationId"] = correlationId,
            ["stage"]         = stage,
            ["event"]         = evt,
            ["timestamp"]     = DateTime.UtcNow.ToString("o")
        });
}
