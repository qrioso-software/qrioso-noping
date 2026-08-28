using System.Text.Json.Serialization;

namespace QriosoNoPing.Core;

public static class ServiceCommands
{
    public const string PipeName = "QriosoNoPing.Control.v1";
    public const int MaximumMessageBytes = 64 * 1024;
    public const string Register = "register";
    public const string Connect = "connect";
    public const string Disconnect = "disconnect";
    public const string Status = "status";
}

public sealed record ServiceRequest(string Command, string? Token = null, string? Mode = null);

public sealed record ServiceResponse(bool Success, string? Error, ServiceStatus Status);

public sealed record ServiceStatus(
    string State,
    bool HasAccessToken,
    string? RedactedToken,
    DateTimeOffset? LeaseExpiresAt,
    RouteMetricsSnapshot RouteA,
    RouteMetricsSnapshot RouteB,
    string WinningRoute,
    string Mode,
    string? Message);

[JsonSerializable(typeof(ServiceRequest))]
[JsonSerializable(typeof(ServiceResponse))]
public sealed partial class ServiceJsonContext : JsonSerializerContext;
