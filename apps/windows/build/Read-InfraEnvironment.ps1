Set-StrictMode -Version Latest

function Read-QriosoInfraEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "InfraEnvironmentFile debe apuntar a un archivo."
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "InfraEnvironmentFile no puede ser un enlace o punto de reanálisis."
    }
    if ($item.Length -gt 4096) {
        throw "InfraEnvironmentFile supera el límite de 4096 bytes."
    }

    $allowedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$allowedKeys.Add("AccessApiBaseUri")
    [void]$allowedKeys.Add("TlsSpkiPin")
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $lines = [IO.File]::ReadAllLines($item.FullName, $encoding)

    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index].Trim()
        if (-not $line -or $line.StartsWith("#", [StringComparison]::Ordinal)) { continue }

        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            throw "InfraEnvironmentFile tiene una línea inválida en $($index + 1); usa Nombre=Valor."
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if (-not $allowedKeys.Contains($key)) {
            throw "InfraEnvironmentFile contiene la clave no admitida '$key'. Solo usa AccessApiBaseUri y TlsSpkiPin."
        }
        if (-not $values.TryAdd($key, $value)) {
            throw "InfraEnvironmentFile repite la clave '$key'."
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "InfraEnvironmentFile dejó vacía la clave '$key'."
        }
    }

    foreach ($requiredKey in @("AccessApiBaseUri", "TlsSpkiPin")) {
        if (-not $values.ContainsKey($requiredKey)) {
            throw "InfraEnvironmentFile no contiene la clave obligatoria '$requiredKey'."
        }
    }

    try { $accessUri = [Uri]$values["AccessApiBaseUri"] }
    catch { throw "AccessApiBaseUri no es una URI absoluta válida." }
    if (-not $accessUri.IsAbsoluteUri -or $accessUri.Scheme -ne "https" -or $accessUri.Port -ne 8443 -or
        $accessUri.AbsolutePath -ne "/" -or $accessUri.Query -or $accessUri.Fragment -or $accessUri.UserInfo -or
        $accessUri.HostNameType -notin [UriHostNameType]::Dns, [UriHostNameType]::IPv4) {
        throw "AccessApiBaseUri debe ser un origen HTTPS en el puerto 8443, sin ruta, query ni fragmento."
    }

    $tlsSpkiPin = $values["TlsSpkiPin"]
    if ($tlsSpkiPin -notmatch "^sha256/[A-Za-z0-9+/]{43}=$") {
        throw "TlsSpkiPin debe tener el formato sha256/<base64 SHA-256>."
    }

    [PSCustomObject]@{
        AccessApiBaseUri = $accessUri.AbsoluteUri.TrimEnd('/')
        TlsSpkiPin = $tlsSpkiPin
    }
}
