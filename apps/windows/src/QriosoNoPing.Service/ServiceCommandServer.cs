using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using QriosoNoPing.Core;

namespace QriosoNoPing.Service;

public sealed class ServiceCommandServer(ILogger<ServiceCommandServer> logger, NetworkController controller)
{
    private const int ListenerCount = 4;
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);

    public Task RunAsync(CancellationToken cancellationToken)
    {
        Task[] listeners = Enumerable.Range(0, ListenerCount)
            .Select(_ => RunListenerAsync(cancellationToken))
            .ToArray();
        return Task.WhenAll(listeners);
    }

    private async Task RunListenerAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            await using NamedPipeServerStream pipe = CreatePipe();
            try
            {
                await pipe.WaitForConnectionAsync(cancellationToken);
                using CancellationTokenSource request = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                request.CancelAfter(RequestTimeout);
                await HandleAsync(pipe, request.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                logger.LogWarning("Rejected local control request after its deadline.");
            }
            catch (Exception exception) when (exception is IOException or JsonException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException or DecoderFallbackException)
            {
                logger.LogWarning("Rejected malformed local control request: {Reason}", exception.Message);
            }
        }
    }

    private async Task HandleAsync(Stream pipe, CancellationToken cancellationToken)
    {
        await using StreamWriter writer = new(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
        string? line = await BoundedUtf8LineReader.ReadAsync(pipe, ServiceCommands.MaximumMessageBytes, cancellationToken);
        if (string.IsNullOrEmpty(line))
        {
            throw new InvalidDataException("Control request is empty or too large.");
        }

        ServiceRequest request = JsonSerializer.Deserialize(line, ServiceJsonContext.Default.ServiceRequest)
            ?? throw new InvalidDataException("Control request is empty.");
        ServiceResponse response;
        try
        {
            response = request.Command switch
            {
                ServiceCommands.Register => await controller.RegisterAsync(request.Token, cancellationToken),
                ServiceCommands.Connect => await controller.ConnectAsync(request.Mode, cancellationToken),
                ServiceCommands.Disconnect => await controller.DisconnectAsync(cancellationToken),
                ServiceCommands.Status => controller.GetStatus(),
                _ => new ServiceResponse(false, "Comando local no reconocido.", controller.GetStatus().Status)
            };
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException or InvalidOperationException or TaskCanceledException)
        {
            logger.LogError(exception, "Local control operation failed safely.");
            response = new ServiceResponse(false, "El servicio no pudo completar la operación de red de forma segura.", controller.GetStatus().Status);
        }
        string encoded = JsonSerializer.Serialize(response, ServiceJsonContext.Default.ServiceResponse);
        await writer.WriteLineAsync(encoded.AsMemory(), cancellationToken);
    }

    private static NamedPipeServerStream CreatePipe()
    {
        PipeSecurity security = new();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.InteractiveSid, null),
            PipeAccessRights.ReadWrite,
            AccessControlType.Allow));
        return NamedPipeServerStreamAcl.Create(
            ServiceCommands.PipeName,
            PipeDirection.InOut,
            ListenerCount,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough,
            4096,
            4096,
            security,
            HandleInheritability.None,
            PipeAccessRights.ReadWrite);
    }
}
