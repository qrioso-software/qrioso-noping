Set-StrictMode -Version Latest

function Read-QriosoInfraEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw ".env.infra debe ser un archivo regular."
    }
    if ($item.Length -gt 4096) { throw ".env.infra supera el límite de 4096 bytes." }

    $allowedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in @("AccessApiBaseUri", "TlsSpkiPin", "AccessToken")) { [void]$allowedKeys.Add($key) }
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $lines = [IO.File]::ReadAllLines($item.FullName, [Text.UTF8Encoding]::new($false, $true))
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index].Trim()
        if (-not $line -or $line.StartsWith("#", [StringComparison]::Ordinal)) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { throw ".env.infra tiene una línea inválida en $($index + 1)." }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if (-not $allowedKeys.Contains($key)) { throw ".env.infra contiene la clave no admitida '$key'." }
        if ($values.ContainsKey($key)) { throw ".env.infra repite la clave '$key'." }
        $values.Add($key, $value)
        if ([string]::IsNullOrWhiteSpace($value)) { throw ".env.infra dejó vacía la clave '$key'." }
    }

    foreach ($requiredKey in $allowedKeys) {
        if (-not $values.ContainsKey($requiredKey)) { throw ".env.infra no contiene la clave obligatoria '$requiredKey'." }
    }

    try { $accessUri = [Uri]$values["AccessApiBaseUri"] }
    catch { throw "AccessApiBaseUri no es una URI absoluta válida." }
    if (-not $accessUri.IsAbsoluteUri -or $accessUri.Scheme -ne "https" -or $accessUri.Port -ne 8443 -or
        $accessUri.AbsolutePath -ne "/" -or $accessUri.Query -or $accessUri.Fragment -or $accessUri.UserInfo -or
        $accessUri.HostNameType -notin [UriHostNameType]::Dns, [UriHostNameType]::IPv4) {
        throw "AccessApiBaseUri debe ser un origen HTTPS en el puerto 8443."
    }
    if ($values["TlsSpkiPin"] -notmatch "^sha256/[A-Za-z0-9+/]{43}=$") {
        throw "TlsSpkiPin no tiene el formato SPKI SHA-256 esperado."
    }
    if ($values["AccessToken"] -notmatch "^qnp_[a-z0-9][a-z0-9-]{2,31}_[A-Za-z0-9_-]{43}$") {
        throw "AccessToken no tiene el formato Qrioso NoPing esperado."
    }

    [PSCustomObject]@{
        AccessApiBaseUri = $accessUri.AbsoluteUri.TrimEnd('/')
        TlsSpkiPin = $values["TlsSpkiPin"]
        AccessToken = $values["AccessToken"]
    }
}
