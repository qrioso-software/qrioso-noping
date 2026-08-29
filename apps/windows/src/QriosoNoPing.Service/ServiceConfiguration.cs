using System.Reflection;
using System.Text.RegularExpressions;
using QriosoNoPing.Core;

namespace QriosoNoPing.Service;

public sealed record ServiceConfiguration(
    string AccessApiBaseUri,
    string TlsSpkiPin,
    string PilotAccessToken,
    string[] FortniteExecutables,
    string NativeDirectory)
{
    private static readonly Regex PinPattern = new("^sha256/[A-Za-z0-9+/]{43}=$", RegexOptions.CultureInvariant);
    private static readonly Regex ExecutablePattern = new("^[A-Za-z0-9_.-]+\\.exe$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public Uri AccessApiUri => new(AccessApiBaseUri, UriKind.Absolute);

    public static ServiceConfiguration Load()
    {
        Dictionary<string, string> metadata = Assembly.GetExecutingAssembly()
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .Where(attribute => attribute.Key.StartsWith("QriosoNoPing.", StringComparison.Ordinal) && attribute.Value is not null)
            .ToDictionary(attribute => attribute.Key, attribute => attribute.Value!, StringComparer.Ordinal);
        string Required(string key) => metadata.TryGetValue($"QriosoNoPing.{key}", out string? value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new InvalidDataException($"Missing embedded pilot configuration: {key}.");

        ServiceConfiguration configuration = new(
            Required("AccessApiBaseUri"),
            Required("TlsSpkiPin"),
            Required("AccessToken"),
            [
                "FortniteClient-Win64-Shipping.exe",
                "FortniteClient-Win64-Shipping_BE.exe",
                "FortniteClient-Win64-Shipping_EAC_EOS.exe"
            ],
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "Qrioso NoPing", "service", "native"));
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

        if (!AccessToken.TryParse(PilotAccessToken, out _))
        {
            throw new InvalidDataException("PilotAccessToken must be a valid Qrioso NoPing access token.");
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
