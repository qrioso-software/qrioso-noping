using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace QriosoNoPing.Service;

public sealed class WireGuardNative(ServiceConfiguration configuration)
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void GenerateKeypairDelegate([Out] byte[] publicKey, [Out] byte[] privateKey);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private delegate bool TunnelServiceDelegate([MarshalAs(UnmanagedType.LPWStr)] string configFile);

    public WireGuardKeyPair GenerateKeyPair()
    {
        byte[] publicKey = new byte[32];
        byte[] privateKey = new byte[32];
        nint library = LoadTunnelLibrary();
        try
        {
            GenerateKeypairDelegate generate = Marshal.GetDelegateForFunctionPointer<GenerateKeypairDelegate>(
                NativeLibrary.GetExport(library, "WireGuardGenerateKeypair"));
            generate(publicKey, privateKey);
            return new WireGuardKeyPair(Convert.ToBase64String(publicKey), Convert.ToBase64String(privateKey));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(publicKey);
            CryptographicOperations.ZeroMemory(privateKey);
            NativeLibrary.Free(library);
        }
    }

    public bool RunTunnelService(string configFile)
    {
        nint library = LoadTunnelLibrary();
        try
        {
            TunnelServiceDelegate run = Marshal.GetDelegateForFunctionPointer<TunnelServiceDelegate>(
                NativeLibrary.GetExport(library, "WireGuardTunnelService"));
            return run(configFile);
        }
        finally
        {
            NativeLibrary.Free(library);
        }
    }

    private nint LoadTunnelLibrary()
    {
        string tunnelPath = Path.GetFullPath(Path.Combine(configuration.NativeDirectory, "tunnel.dll"));
        string nativeRoot = Path.GetFullPath(configuration.NativeDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!tunnelPath.StartsWith(nativeRoot, StringComparison.OrdinalIgnoreCase) || !File.Exists(tunnelPath) || !File.Exists(Path.Combine(configuration.NativeDirectory, "wireguard.dll")))
        {
            throw new FileNotFoundException("The signed embedded WireGuard runtime is incomplete.", tunnelPath);
        }

        return NativeLibrary.Load(tunnelPath);
    }
}
