using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace QriosoNoPing.Service;

public sealed record WireGuardKeyPair(string PublicKey, string PrivateKey);

public sealed record PersistedState(
    string Token,
    string RedactedToken,
    string DeviceId,
    WireGuardKeyPair RouteA,
    WireGuardKeyPair RouteB);

public sealed class ProtectedStateStore
{
    private static readonly byte[] Entropy = SHA256.HashData("Qrioso.NoPing.State.v1"u8);
    private readonly string statePath;

    public ProtectedStateStore()
    {
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Qrioso NoPing", "private");
        EnsurePrivateDirectory(directory);
        statePath = Path.Combine(directory, "state.dpapi");
    }

    public bool Exists => File.Exists(statePath);

    public async Task SaveAsync(PersistedState state, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(state);
        byte[] plaintext = JsonSerializer.SerializeToUtf8Bytes(state);
        try
        {
            byte[] protectedBytes = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.LocalMachine);
            try
            {
                string directory = Path.GetDirectoryName(statePath)!;
                string temporary = Path.Combine(directory, $".state-{Guid.NewGuid():N}.tmp");
                try
                {
                    await using (FileStream stream = new(
                        temporary,
                        FileMode.CreateNew,
                        FileAccess.Write,
                        FileShare.None,
                        4096,
                        FileOptions.Asynchronous | FileOptions.WriteThrough))
                    {
                        await stream.WriteAsync(protectedBytes, cancellationToken);
                        await stream.FlushAsync(cancellationToken);
                    }
                    File.Move(temporary, statePath, true);
                }
                finally
                {
                    if (File.Exists(temporary))
                    {
                        File.Delete(temporary);
                    }
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(protectedBytes);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    public async Task<PersistedState?> LoadAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(statePath))
        {
            return null;
        }

        byte[] protectedBytes = await File.ReadAllBytesAsync(statePath, cancellationToken);
        byte[] plaintext = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.LocalMachine);
        try
        {
            return JsonSerializer.Deserialize<PersistedState>(plaintext)
                ?? throw new InvalidDataException("Protected Qrioso state is empty.");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            CryptographicOperations.ZeroMemory(protectedBytes);
        }
    }

    public void Delete()
    {
        if (File.Exists(statePath))
        {
            File.Delete(statePath);
        }
    }

    public string QuarantineCorrupt()
    {
        if (!File.Exists(statePath))
        {
            return string.Empty;
        }

        string quarantined = Path.Combine(Path.GetDirectoryName(statePath)!, $"state.invalid-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}.dpapi");
        File.Move(statePath, quarantined, false);
        return quarantined;
    }

    private static void EnsurePrivateDirectory(string path)
    {
        DirectoryInfo directory = Directory.CreateDirectory(path);
        DirectorySecurity security = new();
        security.SetAccessRuleProtection(true, false);
        FileSystemRights rights = FileSystemRights.FullControl;
        InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            rights,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            rights,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        directory.SetAccessControl(security);
    }
}
