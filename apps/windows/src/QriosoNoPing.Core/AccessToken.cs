using System.Text.RegularExpressions;

namespace QriosoNoPing.Core;

public sealed partial record AccessToken(string Id, string Value)
{
    [GeneratedRegex("^qnp_([a-z0-9][a-z0-9-]{2,31})_([A-Za-z0-9_-]{43})$", RegexOptions.CultureInvariant)]
    private static partial Regex TokenPattern();

    public static bool TryParse(string? value, out AccessToken? token)
    {
        token = null;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        Match match = TokenPattern().Match(value.Trim());
        if (!match.Success)
        {
            return false;
        }

        token = new AccessToken(match.Groups[1].Value, value.Trim());
        return true;
    }

    public string Redacted => $"qnp_{Id}_***";
}

