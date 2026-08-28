using System.Diagnostics;
using System.Runtime.InteropServices;

namespace QriosoNoPing.Service;

public interface IPacketInterceptor : IDisposable
{
    byte[]? ReadOutbound(int timeoutMilliseconds);
    void InjectInbound(ReadOnlySpan<byte> packet);
}

public sealed class WfpPacketInterceptor : IPacketInterceptor
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private delegate bool InstallDelegate(
        [MarshalAs(UnmanagedType.LPWStr)] string driverDirectory,
        out int errorCode);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private delegate bool UninstallDelegate(out int errorCode);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    private delegate nint OpenDelegate(
        [MarshalAs(UnmanagedType.LPWStr)] string executableNames,
        uint proxyProcessId,
        out int errorCode);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int ReadDelegate(nint handle, [Out] byte[] buffer, int capacity, out int packetLength, int timeoutMilliseconds);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int InjectDelegate(nint handle, byte[] packet, int packetLength);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void CloseDelegate(nint handle);

    private readonly nint library;
    private readonly nint handle;
    private readonly ReadDelegate read;
    private readonly InjectDelegate inject;
    private readonly CloseDelegate close;
    private bool disposed;

    public static int Install(ServiceConfiguration configuration) => ExecuteInstaller(configuration, install: true);

    public static int Uninstall(string nativeDirectory) => ExecuteInstaller(nativeDirectory, install: false);

    public WfpPacketInterceptor(ServiceConfiguration configuration)
    {
        string nativeRoot = Path.GetFullPath(configuration.NativeDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string libraryPath = Path.GetFullPath(Path.Combine(configuration.NativeDirectory, "QriosoNoPing.Wfp.dll"));
        string driverPath = Path.GetFullPath(Path.Combine(configuration.NativeDirectory, "driver", "QriosoNoPing.Wfp.sys"));
        if (!libraryPath.StartsWith(nativeRoot, StringComparison.OrdinalIgnoreCase) ||
            !driverPath.StartsWith(nativeRoot, StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(libraryPath) ||
            !File.Exists(driverPath))
        {
            throw new FileNotFoundException("The signed Qrioso WFP component is incomplete.", libraryPath);
        }

        library = NativeLibrary.Load(libraryPath);
        OpenDelegate open = Load<OpenDelegate>("QnpWfpOpen");
        read = Load<ReadDelegate>("QnpWfpRead");
        inject = Load<InjectDelegate>("QnpWfpInjectInbound");
        close = Load<CloseDelegate>("QnpWfpClose");
        handle = open(string.Join(';', configuration.FortniteExecutables), checked((uint)Environment.ProcessId), out int errorCode);
        if (handle == 0)
        {
            NativeLibrary.Free(library);
            throw new InvalidOperationException($"Could not activate the signed WFP filter (error {errorCode}).");
        }
    }

    public byte[]? ReadOutbound(int timeoutMilliseconds)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        byte[] buffer = new byte[QriosoNoPing.Core.MultipathProtocol.MaxPayloadLength];
        int result = read(handle, buffer, buffer.Length, out int packetLength, timeoutMilliseconds);
        if (result == 0)
        {
            return null;
        }

        if (result < 0 || packetLength is < 1 or > QriosoNoPing.Core.MultipathProtocol.MaxPayloadLength)
        {
            throw new InvalidOperationException("The WFP component returned an invalid packet.");
        }

        return buffer.AsSpan(0, packetLength).ToArray();
    }

    public void InjectInbound(ReadOnlySpan<byte> packet)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        byte[] copy = packet.ToArray();
        if (inject(handle, copy, copy.Length) == 0)
        {
            throw new InvalidOperationException("The WFP component could not inject the response packet.");
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        close(handle);
        NativeLibrary.Free(library);
    }

    private T Load<T>(string exportName) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, exportName));

    private static int ExecuteInstaller(ServiceConfiguration configuration, bool install) =>
        ExecuteInstaller(configuration.NativeDirectory, install);

    private static int ExecuteInstaller(string nativeDirectory, bool install)
    {
        string nativeRoot = Path.GetFullPath(nativeDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string libraryPath = Path.GetFullPath(Path.Combine(nativeDirectory, "QriosoNoPing.Wfp.dll"));
        string driverDirectory = Path.GetFullPath(Path.Combine(nativeDirectory, "driver"));
        if (!libraryPath.StartsWith(nativeRoot, StringComparison.OrdinalIgnoreCase) ||
            !driverDirectory.StartsWith(nativeRoot, StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(libraryPath) ||
            !Directory.Exists(driverDirectory))
        {
            return 2;
        }

        nint installerLibrary = NativeLibrary.Load(libraryPath);
        try
        {
            bool success;
            int errorCode;
            if (install)
            {
                InstallDelegate installer = Marshal.GetDelegateForFunctionPointer<InstallDelegate>(
                    NativeLibrary.GetExport(installerLibrary, "QnpWfpInstall"));
                success = installer(driverDirectory, out errorCode);
            }
            else
            {
                UninstallDelegate uninstaller = Marshal.GetDelegateForFunctionPointer<UninstallDelegate>(
                    NativeLibrary.GetExport(installerLibrary, "QnpWfpUninstall"));
                success = uninstaller(out errorCode);
            }

            return success ? 0 : errorCode == 0 ? 1 : errorCode;
        }
        finally
        {
            NativeLibrary.Free(installerLibrary);
        }
    }
}
