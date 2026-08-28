using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace QriosoNoPing.Core;

public sealed class ServiceControlClient
{
    public async Task<ServiceResponse> SendAsync(ServiceRequest request, CancellationToken cancellationToken = default)
    {
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        await using NamedPipeClientStream pipe = new(
            ".",
            ServiceCommands.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough);
        await pipe.ConnectAsync(timeout.Token);
        NamedPipeServerIdentity.AssertTrustedInstalledService(pipe);
        await using StreamWriter writer = new(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
        string encoded = JsonSerializer.Serialize(request, ServiceJsonContext.Default.ServiceRequest);
        if (Encoding.UTF8.GetByteCount(encoded) > ServiceCommands.MaximumMessageBytes)
        {
            throw new InvalidDataException("The Qrioso service request is too large.");
        }
        await writer.WriteLineAsync(encoded.AsMemory(), timeout.Token);
        string? responseLine = await BoundedUtf8LineReader.ReadAsync(pipe, ServiceCommands.MaximumMessageBytes, timeout.Token);
        if (string.IsNullOrEmpty(responseLine))
        {
            throw new InvalidDataException("The Qrioso service returned an invalid response.");
        }

        try
        {
            return JsonSerializer.Deserialize(responseLine, ServiceJsonContext.Default.ServiceResponse)
                ?? throw new InvalidDataException("The Qrioso service returned an empty response.");
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("The Qrioso service returned malformed JSON.", exception);
        }
    }
}
