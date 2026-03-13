using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using System.Text.Json;

namespace PurviewBridge;

/// <summary>
/// Emits host_alive heartbeat logs every 60 minutes for the bridge and router
/// services. Both services run in this function app process — one timer covers both.
///
/// Azure Monitor scheduled-query alerts detect absence of these logs over a
/// 120-minute window to identify service failure. One missed heartbeat is
/// tolerated before alerting.
/// </summary>
public class HeartbeatFunction
{
    private readonly ILogger<HeartbeatFunction> _logger;

    public HeartbeatFunction(ILogger<HeartbeatFunction> logger)
    {
        _logger = logger;
    }

    [Function(nameof(HeartbeatFunction))]
    public void Run([TimerTrigger("0 0 * * * *")] TimerInfo timer)
    {
        var timestamp = DateTime.UtcNow.ToString("o");

        foreach (var service in new[] { "bridge", "router" })
        {
            _logger.LogInformation("{Heartbeat}", JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["event"]     = "host_alive",
                ["service"]   = service,
                ["timestamp"] = timestamp
            }));
        }
    }
}
