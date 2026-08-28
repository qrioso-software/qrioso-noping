using System.Diagnostics;
using System.ServiceProcess;
using System.Text;
using QriosoNoPing.Core;

namespace QriosoNoPing.Service;

public sealed class WireGuardTunnelManager(ILogger<WireGuardTunnelManager> logger)
{
    private const string ServiceA = "WireGuardTunnel$QriosoRouteA";
    private const string ServiceB = "WireGuardTunnel$QriosoRouteB";

    public async Task StartAsync(PersistedState state, AccessSession session, CancellationToken cancellationToken)
    {
        await StopAsync(cancellationToken);
        string runtimeDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Qrioso NoPing", "private", "runtime");
        Directory.CreateDirectory(runtimeDirectory);
        string configA = Path.Combine(runtimeDirectory, "QriosoRouteA.conf");
        string configB = Path.Combine(runtimeDirectory, "QriosoRouteB.conf");
        try
        {
            await File.WriteAllTextAsync(configA, BuildConfiguration(state.RouteA.PrivateKey, session.ClientAddressA, session.ServerPublicKeyA, session.DirectEndpoint, "10.78.0.1/32", session.Mtu), new UTF8Encoding(false), cancellationToken);
            await File.WriteAllTextAsync(configB, BuildConfiguration(state.RouteB.PrivateKey, session.ClientAddressB, session.ServerPublicKeyB, session.AcceleratedEndpoint, "10.79.0.1/32", session.Mtu), new UTF8Encoding(false), cancellationToken);
            await CreateAndStartAsync(ServiceA, "Qrioso NoPing · Ruta A", configA, cancellationToken);
            try
            {
                await CreateAndStartAsync(ServiceB, "Qrioso NoPing · Ruta B", configB, cancellationToken);
            }
            catch
            {
                await RemoveAsync(ServiceA, CancellationToken.None);
                throw;
            }
        }
        finally
        {
            bool deletedA = DeleteSensitive(configA);
            bool deletedB = DeleteSensitive(configB);
            if (!deletedA || !deletedB)
            {
                await StopAsync(CancellationToken.None);
                throw new IOException("No se pudieron eliminar los archivos temporales de las claves WireGuard.");
            }
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await RemoveAsync(ServiceB, cancellationToken);
        await RemoveAsync(ServiceA, cancellationToken);
    }

    private async Task CreateAndStartAsync(string serviceName, string displayName, string configurationPath, CancellationToken cancellationToken)
    {
        string executable = Environment.ProcessPath ?? throw new InvalidOperationException("Cannot determine the service executable path.");
        string binaryPath = $"\"{executable}\" /wireguard-service \"{configurationPath}\"";
        await RunScAsync(["create", serviceName, "binPath=", binaryPath, "start=", "demand", "error=", "normal", "depend=", "Nsi/TcpIp", "DisplayName=", displayName], false, cancellationToken);
        try
        {
            await RunScAsync(["sidtype", serviceName, "unrestricted"], false, cancellationToken);
            await RunScAsync(["description", serviceName, $"Túnel cifrado administrado por Qrioso NoPing ({displayName})"], false, cancellationToken);
            await RunScAsync(["start", serviceName], false, cancellationToken);
            using ServiceController controller = new(serviceName);
            await Task.Run(() => controller.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15)), cancellationToken);
        }
        catch
        {
            await RemoveAsync(serviceName, CancellationToken.None);
            throw;
        }
    }

    private async Task RemoveAsync(string serviceName, CancellationToken cancellationToken)
    {
        await RunScAsync(["stop", serviceName], true, cancellationToken);
        try
        {
            using ServiceController controller = new(serviceName);
            await Task.Run(() => controller.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(10)), cancellationToken);
        }
        catch (InvalidOperationException)
        {
            // Service is not installed.
        }
        catch (System.ServiceProcess.TimeoutException)
        {
            logger.LogWarning("WireGuard tunnel {ServiceName} did not stop inside the timeout.", serviceName);
        }
        await RunScAsync(["delete", serviceName], true, cancellationToken);
    }

    private static string BuildConfiguration(string privateKey, string address, string serverPublicKey, string endpoint, string allowedAddress, int mtu) =>
        $"[Interface]\r\nPrivateKey = {privateKey}\r\nAddress = {address}\r\nMTU = {mtu}\r\n\r\n[Peer]\r\nPublicKey = {serverPublicKey}\r\nEndpoint = {endpoint}\r\nAllowedIPs = {allowedAddress}\r\nPersistentKeepalive = 25\r\n";

    private static async Task RunScAsync(string[] arguments, bool ignoreFailure, CancellationToken cancellationToken)
    {
        ProcessStartInfo startInfo = new(Path.Combine(Environment.SystemDirectory, "sc.exe"))
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (string argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using Process process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not launch Windows Service Control.");
        string standardOutput = await process.StandardOutput.ReadToEndAsync(cancellationToken);
        string standardError = await process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        if (process.ExitCode != 0 && !ignoreFailure)
        {
            throw new InvalidOperationException($"Service Control failed with exit code {process.ExitCode}: {standardError} {standardOutput}".Trim());
        }
    }

    private static bool DeleteSensitive(string path)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (!File.Exists(path))
                {
                    return true;
                }

                File.Delete(path);
                return true;
            }
            catch (IOException) when (attempt < 4)
            {
                Thread.Sleep(50);
            }
            catch (UnauthorizedAccessException) when (attempt < 4)
            {
                Thread.Sleep(50);
            }
        }

        return !File.Exists(path);
    }
}
