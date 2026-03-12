using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using System.Text.Json;

namespace PurviewBridge;

/// <summary>
/// Minimal bridge function that forwards Event Hub events to Service Bus.
/// This is a heuristic trigger - payload is treated as opaque.
/// Generates a correlationId per event and attaches it to the outgoing
/// Service Bus message as an ApplicationProperty for end-to-end tracing.
/// </summary>
public class HeuristicTriggerBridge
{
    private readonly ILogger<HeuristicTriggerBridge> _logger;
    private static ServiceBusClient? _serviceBusClient;
    private static ServiceBusSender? _sender;

    public HeuristicTriggerBridge(ILogger<HeuristicTriggerBridge> logger)
    {
        _logger = logger;
    }

    [Function(nameof(HeuristicTriggerBridge))]
    public async Task Run(
        [EventHubTrigger("%EventHubName%", Connection = "EventHubConnection", ConsumerGroup = "%ConsumerGroup%")]
        string[] events)
    {
        // Lazy initialization of Service Bus client with Managed Identity
        if (_serviceBusClient == null)
        {
            var sbNamespace = Environment.GetEnvironmentVariable("ServiceBusConnection__fullyQualifiedNamespace");
            _serviceBusClient = new ServiceBusClient(sbNamespace, new DefaultAzureCredential());
            _sender = _serviceBusClient.CreateSender(Environment.GetEnvironmentVariable("ServiceBusQueueName"));
        }

        // One incoming event → one outgoing message (heuristic trigger)
        foreach (var eventData in events)
        {
            // Generate a fresh correlationId at the pipeline entry point.
            // Propagated downstream via Service Bus ApplicationProperties.
            var correlationId = Guid.NewGuid().ToString();

            var message = new ServiceBusMessage(eventData ?? "heuristic_trigger_received");
            message.ApplicationProperties["correlationId"] = correlationId;

            await _sender!.SendMessageAsync(message);

            _logger.LogInformation("{ObsLog}", ObsLog("bridge", "message_forwarded", correlationId));
        }
    }

    internal static string ObsLog(string stage, string evt, string correlationId, string? assetId = null) =>
        JsonSerializer.Serialize(new Dictionary<string, string?>
        {
            ["assetId"]       = assetId,
            ["correlationId"] = correlationId,
            ["stage"]         = stage,
            ["event"]         = evt,
            ["timestamp"]     = DateTime.UtcNow.ToString("o")
        });
}
