using System.Net;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using QriosoNoPing.Core;

namespace QriosoNoPing.Service;

public sealed record AccessSessionRequest(string Token, string DeviceId, string PublicKeyA, string PublicKeyB);

public sealed class AccessApiClient : IDisposable
{
    private readonly HttpClient client;

    public AccessApiClient(ServiceConfiguration configuration)
    {
        byte[] expectedPin = Convert.FromBase64String(configuration.TlsSpkiPin[7..]);
        SocketsHttpHandler handler = new()
        {
            ConnectTimeout = TimeSpan.FromSeconds(5),
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
            AutomaticDecompression = DecompressionMethods.None,
            UseCookies = false
        };
        handler.SslOptions.RemoteCertificateValidationCallback = (_, certificate, _, _) =>
        {
            if (certificate is null)
            {
                return false;
            }

            using X509Certificate2 certificate2 = certificate as X509Certificate2 ?? new X509Certificate2(certificate);
            DateTime utcNow = DateTime.UtcNow;
            if (utcNow < certificate2.NotBefore.ToUniversalTime().AddMinutes(-5) || utcNow >= certificate2.NotAfter.ToUniversalTime())
            {
                return false;
            }
            byte[] actualPin = SHA256.HashData(certificate2.PublicKey.ExportSubjectPublicKeyInfo());
            return actualPin.Length == expectedPin.Length && CryptographicOperations.FixedTimeEquals(actualPin, expectedPin);
        };
        client = new HttpClient(handler)
        {
            BaseAddress = configuration.AccessApiUri,
            Timeout = TimeSpan.FromSeconds(8)
        };
    }

    public async Task<AccessSession> CreateOrRenewSessionAsync(PersistedState state, CancellationToken cancellationToken)
    {
        using HttpResponseMessage response = await client.PostAsJsonAsync(
            "/v1/session",
            new AccessSessionRequest(state.Token, state.DeviceId, state.RouteA.PublicKey, state.RouteB.PublicKey),
            cancellationToken);
        if (response.StatusCode == HttpStatusCode.Unauthorized)
        {
            throw new UnauthorizedAccessException("La llave fue rechazada o revocada.");
        }

        if (response.StatusCode == HttpStatusCode.Forbidden)
        {
            throw new UnauthorizedAccessException("La llave alcanzó su límite de dispositivos.");
        }

        response.EnsureSuccessStatusCode();
        AccessSession session = await response.Content.ReadFromJsonAsync<AccessSession>(cancellationToken: cancellationToken)
            ?? throw new InvalidDataException("El relay devolvió una sesión vacía.");
        Validate(session);
        return session;
    }

    public void Dispose() => client.Dispose();

    private static void Validate(AccessSession session)
    {
        if (session.Status != "authorized" || session.LeaseSeconds is < 5 or > 60 || session.Mtu != MultipathProtocol.CarrierMtu)
        {
            throw new InvalidDataException("El relay devolvió parámetros de sesión inseguros.");
        }

        _ = session.ParsedSessionId;
        foreach (string key in new[] { session.ServerPublicKeyA, session.ServerPublicKeyB })
        {
            byte[] decoded = Convert.FromBase64String(key);
            if (decoded.Length != 32 || decoded.All(value => value == 0) || Convert.ToBase64String(decoded) != key)
            {
                throw new InvalidDataException("El relay devolvió una clave pública WireGuard inválida.");
            }
        }

        if (session.ServerPublicKeyA == session.ServerPublicKeyB)
        {
            throw new InvalidDataException("Las dos rutas no pueden compartir la misma clave WireGuard.");
        }


        IPAddress clientA = ParseAssignedAddress(session.ClientAddressA, "10.78.0.");
        IPAddress clientB = ParseAssignedAddress(session.ClientAddressB, "10.79.0.");
        IPAddress virtualAddress = ParseAssignedAddress(session.VirtualAddress, "10.80.0.");
        if (clientA.GetAddressBytes()[3] != clientB.GetAddressBytes()[3] || clientA.GetAddressBytes()[3] != virtualAddress.GetAddressBytes()[3])
        {
            throw new InvalidDataException("El relay devolvió direcciones de sesión inconsistentes.");
        }

        ValidateDirectEndpoint(session.DirectEndpoint);
        ValidateAcceleratedEndpoint(session.AcceleratedEndpoint);
        if (session.RelayDataAddressA != "10.78.0.1:51900" || session.RelayDataAddressB != "10.79.0.1:51900")
        {
            throw new InvalidDataException("El relay devolvió endpoints internos no autorizados.");
        }
    }

    private static IPAddress ParseAssignedAddress(string value, string prefix)
    {
        string[] parts = value.Split('/', StringSplitOptions.TrimEntries);
        if (parts.Length != 2 || parts[1] != "32" || !IPAddress.TryParse(parts[0], out IPAddress? address) || address.AddressFamily != AddressFamily.InterNetwork)
        {
            throw new InvalidDataException("El relay devolvió una dirección de sesión inválida.");
        }

        byte slot = address.GetAddressBytes()[3];
        if (!parts[0].StartsWith(prefix, StringComparison.Ordinal) || slot is < 2 or > 11)
        {
            throw new InvalidDataException("El relay devolvió una dirección fuera del rango autorizado.");
        }

        return address;
    }

    private static void ValidateDirectEndpoint(string value)
    {
        if (!IPEndPoint.TryParse(value, out IPEndPoint? endpoint) || endpoint.Port != 51820 || endpoint.Address.AddressFamily != AddressFamily.InterNetwork)
        {
            throw new InvalidDataException("El relay devolvió un endpoint directo inválido.");
        }

        byte[] bytes = endpoint.Address.GetAddressBytes();
        bool blocked = bytes[0] is 0 or 10 or 127 || bytes[0] >= 224 ||
            (bytes[0] == 100 && bytes[1] is >= 64 and <= 127) ||
            (bytes[0] == 169 && bytes[1] == 254) ||
            (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 198 && bytes[1] is 18 or 19);
        if (IPAddress.IsLoopback(endpoint.Address) || blocked)
        {
            throw new InvalidDataException("El relay devolvió un endpoint directo no público.");
        }
    }

    private static void ValidateAcceleratedEndpoint(string value)
    {
        int separator = value.LastIndexOf(':');
        if (separator <= 0 || !int.TryParse(value[(separator + 1)..], out int port) || port != 51821)
        {
            throw new InvalidDataException("El relay devolvió un endpoint acelerado inválido.");
        }

        string host = value[..separator];
        if (!host.EndsWith(".awsglobalaccelerator.com", StringComparison.OrdinalIgnoreCase) ||
            host.Length > 253 || host.Split('.').Any(label => label.Length is < 1 or > 63 || label[0] == '-' || label[^1] == '-' || label.Any(character => !(char.IsAsciiLetterOrDigit(character) || character == '-'))))
        {
            throw new InvalidDataException("El relay devolvió un DNS de Global Accelerator inválido.");
        }
    }
}
