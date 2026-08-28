using System.Text.Json;
using System.Text.RegularExpressions;

namespace QriosoNoPing.Service;

public sealed record ServiceConfiguration(
    string AccessApiBaseUri,
    string TlsSpkiPin,
    string[] FortniteExecutables,
    string NativeDirectory)
{
    private static readonly Regex PinPattern = new("^sha256/[A-Za-z0-9+/]{43}=$", RegexOptions.CultureInvariant);
    private static readonly Regex ExecutablePattern = new("^[A-Za-z0-9_.-]+\\.exe$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public Uri AccessApiUri => new(AccessApiBaseUri, UriKind.Absolute);

    public static ServiceConfiguration Load()
    {
        string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        string path = Environment.GetEnvironmentVariable("QRIOSO_NOPING_CONFIG")
            ?? Path.Combine(programData, "Qrioso NoPing", "config.json");
        using FileStream stream = File.OpenRead(path);
        ServiceConfiguration configuration = JsonSerializer.Deserialize<ServiceConfiguration>(stream, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow
        }) ?? throw new InvalidDataException("Qrioso NoPing configuration is empty.");
        configuration.Validate();
        return configuration;
    }

    public void Validate()
    {
        if (!Uri.TryCreate(AccessApiBaseUri, UriKind.Absolute, out Uri? uri) ||
            uri.Scheme != Uri.UriSchemeHttps || uri.Port != 8443 || uri.AbsolutePath != "/" ||
            !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) || !string.IsNullOrEmpty(uri.UserInfo) ||
            uri.HostNameType is not (UriHostNameType.Dns or UriHostNameType.IPv4))
        {
            throw new InvalidDataException("AccessApiBaseUri must be an HTTPS origin on port 8443.");
        }

        if (!PinPattern.IsMatch(TlsSpkiPin))
        {
            throw new InvalidDataException("TlsSpkiPin must be a SHA-256 SPKI pin.");
        }

        if (FortniteExecutables is null || FortniteExecutables.Length == 0 || FortniteExecutables.Length > 8 || FortniteExecutables.Any(value => !ExecutablePattern.IsMatch(value)))
        {
            throw new InvalidDataException("FortniteExecutables must contain 1-8 executable file names.");
        }

        string expectedNativeDirectory = Path.GetFullPath(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "Qrioso NoPing", "service", "native"));
        if (!Path.IsPathFullyQualified(NativeDirectory) ||
            !string.Equals(Path.GetFullPath(NativeDirectory), expectedNativeDirectory, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("NativeDirectory must be the protected Qrioso installation directory.");
        }
    }
}
