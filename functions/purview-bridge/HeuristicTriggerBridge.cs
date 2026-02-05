using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace PurviewBridge;

/// <summary>
/// Minimal bridge function that forwards Event Hub events to Service Bus.
/// This is a heuristic trigger - payload is treated as opaque.
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
            var message = new ServiceBusMessage(eventData ?? "heuristic_trigger_received");
            await _sender!.SendMessageAsync(message);
            _logger.LogInformation("Heuristic trigger forwarded to Service Bus");
        }
    }
}
