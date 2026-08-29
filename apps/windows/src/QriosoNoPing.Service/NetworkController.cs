using QriosoNoPing.Core;
using System.Security.Cryptography;
using System.Text.Json;

namespace QriosoNoPing.Service;

public sealed class NetworkController(
    ILogger<NetworkController> logger,
    ILoggerFactory loggerFactory,
    ServiceConfiguration configuration,
    ProtectedStateStore stateStore,
    WireGuardNative wireGuard,
    WireGuardTunnelManager tunnels,
    AccessApiClient accessApi)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private MultipathClientEngine? engine;
    private PersistedState? persistedState;
    private AccessSession? accessSession;
    private DateTimeOffset? leaseExpiresAt;
    private string state = "disconnected";
    private string? message;
    private Task? monitor;
    private TrafficMode trafficMode = TrafficMode.Duplicate;

    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        await tunnels.StopAsync(cancellationToken);
        persistedState = await LoadProtectedStateAsync(cancellationToken);
        if (persistedState is null)
        {
            ServiceResponse registration = await RegisterAsync(configuration.PilotAccessToken, cancellationToken);
            if (!registration.Success)
            {
                state = "unconfigured";
                message = registration.Error ?? "No se pudo registrar automáticamente el acceso del piloto.";
                return;
            }
        }
        state = persistedState is null ? "unconfigured" : "disconnected";
        message ??= persistedState is null ? "Registra una llave de acceso." : "Listo para conectar.";
    }

    public async Task<ServiceResponse> RegisterAsync(string? tokenValue, CancellationToken cancellationToken)
    {
        if (!AccessToken.TryParse(tokenValue, out AccessToken? token))
        {
            return Failure("La llave no tiene el formato esperado.");
        }

        await gate.WaitAsync(cancellationToken);
        try
        {
            await DisconnectLockedAsync(cancellationToken);
            PersistedState? current = await LoadProtectedStateAsync(cancellationToken);
            state = "registering";
            message = "Validando la llave con Qrioso…";
            try
            {
                PersistedState candidate = new(
                    token!.Value,
                    token.Redacted,
                    current?.DeviceId ?? $"pc-{Guid.NewGuid():N}",
                    current?.RouteA ?? wireGuard.GenerateKeyPair(),
                    current?.RouteB ?? wireGuard.GenerateKeyPair());
                _ = await accessApi.CreateOrRenewSessionAsync(candidate, cancellationToken);
                await stateStore.SaveAsync(candidate, cancellationToken);
                persistedState = candidate;
                state = "disconnected";
                message = "Llave registrada y protegida con DPAPI.";
                return Success();
            }
            catch (Exception exception) when (IsOperationalFailure(exception))
            {
                state = current is null ? "unconfigured" : "disconnected";
                message = exception.Message;
                return Failure(exception.Message);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<ServiceResponse> ConnectAsync(string? requestedMode, CancellationToken cancellationToken)
    {
        if (!TryParseMode(requestedMode, out TrafficMode selectedMode))
        {
            return Failure("Selecciona un modo de ruta válido.");
        }
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (engine is not null)
            {
                if (trafficMode == selectedMode)
                {
                    return Success();
                }
                await DisconnectLockedAsync(cancellationToken);
            }

            persistedState ??= await LoadProtectedStateAsync(cancellationToken);
            if (persistedState is null)
            {
                return Failure("Primero registra una llave de acceso.");
            }

            trafficMode = selectedMode;
            state = "connecting";
            message = selectedMode switch
            {
                TrafficMode.RouteA => "Preparando la ruta directa cifrada…",
                TrafficMode.RouteB => "Preparando la ruta acelerada cifrada…",
                _ => "Creando las dos rutas cifradas…"
            };
            try
            {
                AccessSession session = await accessApi.CreateOrRenewSessionAsync(persistedState, cancellationToken);
                await StartDataPlaneLockedAsync(session, cancellationToken);
                state = "connected";
                message = selectedMode switch
                {
                    TrafficMode.RouteA => "Ruta A activa para la sesión de juego.",
                    TrafficMode.RouteB => "Ruta B activa para la sesión de juego.",
                    _ => "Multipath activo; la primera copia recibida gana."
                };
                monitor ??= MonitorAsync(lifetime.Token);
                return Success();
            }
            catch (Exception exception) when (IsOperationalFailure(exception))
            {
                await DisconnectLockedAsync(CancellationToken.None);
                message = exception.Message;
                return Failure(exception.Message);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<ServiceResponse> DisconnectAsync(CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            await DisconnectLockedAsync(cancellationToken);
            message = "Ruta directa restaurada.";
            return Success();
        }
        finally
        {
            gate.Release();
        }
    }

    public ServiceResponse GetStatus() => Success();

    public async Task ShutdownAsync()
    {
        lifetime.Cancel();
        if (monitor is not null)
        {
            try
            {
                await monitor;
            }
            catch (OperationCanceledException)
            {
            }
        }

        await gate.WaitAsync(CancellationToken.None);
        try
        {
            await DisconnectLockedAsync(CancellationToken.None);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task StartDataPlaneLockedAsync(AccessSession session, CancellationToken cancellationToken)
    {
        if (persistedState is null)
        {
            throw new InvalidOperationException("No protected access state is available.");
        }

        await tunnels.StartAsync(persistedState, session, cancellationToken);
        try
        {
            WfpPacketInterceptor interceptor = new(configuration);
            try
            {
                engine = new MultipathClientEngine(loggerFactory.CreateLogger<MultipathClientEngine>(), session, interceptor, trafficMode);
            }
            catch
            {
                interceptor.Dispose();
                throw;
            }
        }
        catch
        {
            await tunnels.StopAsync(CancellationToken.None);
            throw;
        }

        accessSession = session;
        leaseExpiresAt = DateTimeOffset.UtcNow.AddSeconds(session.LeaseSeconds);
    }

    private async Task DisconnectLockedAsync(CancellationToken cancellationToken)
    {
        MultipathClientEngine? currentEngine = engine;
        engine = null;
        accessSession = null;
        leaseExpiresAt = null;
        try
        {
            if (currentEngine is not null)
            {
                await currentEngine.DisposeAsync();
            }
        }
        finally
        {
            await tunnels.StopAsync(cancellationToken);
        }
        state = persistedState is null && !stateStore.Exists ? "unconfigured" : "disconnected";
    }

    private async Task MonitorAsync(CancellationToken cancellationToken)
    {
        using PeriodicTimer timer = new(TimeSpan.FromSeconds(1));
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            await gate.WaitAsync(cancellationToken);
            try
            {
                if (engine is null || persistedState is null || accessSession is null)
                {
                    continue;
                }

                if (engine.Completion.IsCompleted)
                {
                    Exception? failure = engine.Completion.Exception?.GetBaseException();
                    logger.LogError(failure, "Multipath engine stopped; restoring the direct route.");
                    await DisconnectLockedAsync(CancellationToken.None);
                    message = "El motor de red se detuvo; se restauró la ruta directa.";
                    continue;
                }

                DateTimeOffset now = DateTimeOffset.UtcNow;
                if (leaseExpiresAt is not null && now >= leaseExpiresAt.Value.AddSeconds(-Math.Max(2, accessSession.LeaseSeconds / 2)))
                {
                    try
                    {
                        AccessSession renewed = await accessApi.CreateOrRenewSessionAsync(persistedState, cancellationToken);
                        if (DataPlaneChanged(accessSession, renewed))
                        {
                            await DisconnectLockedAsync(CancellationToken.None);
                            await StartDataPlaneLockedAsync(renewed, cancellationToken);
                            state = "connected";
                        }
                        else
                        {
                            accessSession = renewed;
                            leaseExpiresAt = now.AddSeconds(renewed.LeaseSeconds);
                        }
                    }
                    catch (Exception exception) when (IsOperationalFailure(exception))
                    {
                        logger.LogWarning("Lease renewal failed: {Reason}", exception.Message);
                        if (leaseExpiresAt is not null && now >= leaseExpiresAt.Value)
                        {
                            await DisconnectLockedAsync(CancellationToken.None);
                            message = "La autorización expiró; se restauró la ruta directa.";
                        }
                    }
                }
            }
            finally
            {
                gate.Release();
            }
        }
    }

    private ServiceResponse Success() => new(true, null, Snapshot());

    private ServiceResponse Failure(string error) => new(false, error, Snapshot());

    private static bool IsOperationalFailure(Exception exception) => exception is
        HttpRequestException or
        UnauthorizedAccessException or
        InvalidDataException or
        InvalidOperationException or
        IOException or
        CryptographicException or
        FormatException or
        DllNotFoundException or
        EntryPointNotFoundException or
        BadImageFormatException or
        TaskCanceledException;

    private static bool DataPlaneChanged(AccessSession current, AccessSession renewed) =>
        current.SessionId != renewed.SessionId ||
        current.DirectEndpoint != renewed.DirectEndpoint ||
        current.AcceleratedEndpoint != renewed.AcceleratedEndpoint ||
        current.ServerPublicKeyA != renewed.ServerPublicKeyA ||
        current.ServerPublicKeyB != renewed.ServerPublicKeyB ||
        current.ClientAddressA != renewed.ClientAddressA ||
        current.ClientAddressB != renewed.ClientAddressB ||
        current.VirtualAddress != renewed.VirtualAddress ||
        current.RelayDataAddressA != renewed.RelayDataAddressA ||
        current.RelayDataAddressB != renewed.RelayDataAddressB ||
        current.Mtu != renewed.Mtu;

    private static bool TryParseMode(string? value, out TrafficMode mode)
    {
        mode = value switch
        {
            "route-a" => TrafficMode.RouteA,
            "route-b" => TrafficMode.RouteB,
            "duplicate" or null or "" => TrafficMode.Duplicate,
            _ => 0
        };
        return mode != 0;
    }

    private async Task<PersistedState?> LoadProtectedStateAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await stateStore.LoadAsync(cancellationToken);
        }
        catch (Exception exception) when (exception is CryptographicException or JsonException or InvalidDataException)
        {
            string quarantined = stateStore.QuarantineCorrupt();
            logger.LogError(exception, "Protected local state was invalid and moved to {QuarantinePath}.", quarantined);
            message = "El estado protegido local estaba dañado; registra nuevamente la llave.";
            return null;
        }
    }

    private ServiceStatus Snapshot()
    {
        (RouteMetricsSnapshot routeA, RouteMetricsSnapshot routeB, string winner) = engine?.Snapshot()
            ?? (new(null, null, null, 0, 0, 0), new(null, null, null, 0, 0, 0), "—");
        return new ServiceStatus(
            state,
            persistedState is not null || stateStore.Exists,
            persistedState?.RedactedToken,
            leaseExpiresAt,
            routeA,
            routeB,
            winner,
            trafficMode switch
            {
                TrafficMode.RouteA => "route-a",
                TrafficMode.RouteB => "route-b",
                _ => "duplicate"
            },
            message);
    }
}
