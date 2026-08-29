[CmdletBinding()]
param(
    [ValidateSet("x64")]
    [string]$Architecture = "x64",
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\bin\x64")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$wireGuardNtVersion = "1.1"
$wireGuardNtSha256 = "DCEB30A9BC4BE48CCE0F74160FC88A585A2C2627366E8F846FC6658F9038DACE"
$wireGuardWindowsCommit = "4e6726c23ae9c5cb58e0c9910f3b7515621d133d"
$wireGuardNtUri = "https://download.wireguard.com/wireguard-nt/wireguard-nt-$wireGuardNtVersion.zip"
$wireGuardWindowsRepository = "https://git.zx2c4.com/wireguard-windows"

function Assert-WireGuardSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $signature.SignerCertificate.Subject -notmatch "WireGuard") {
        throw "wireguard.dll no conserva una firma Authenticode oficial de WireGuard: $Path"
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "La adquisición y compilación de WireGuard embebible debe ejecutarse en Windows."
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw "Se requiere Git for Windows para obtener el source oficial y fijado de tunnel.dll."
}

$outputRoot = [IO.Path]::GetFullPath($OutputPath)
$manifestPath = Join-Path $outputRoot "wireguard-provenance.json"
$wireGuardDll = Join-Path $outputRoot "wireguard.dll"
$tunnelDll = Join-Path $outputRoot "tunnel.dll"
$licensesRoot = Join-Path $outputRoot "licenses"
$cached = $false
if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $wireGuardDll -PathType Leaf) -and
    (Test-Path -LiteralPath $tunnelDll -PathType Leaf)) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $cached = $manifest.wireGuardNtVersion -eq $wireGuardNtVersion -and
            $manifest.wireGuardNtArchiveSha256 -eq $wireGuardNtSha256 -and
            $manifest.wireGuardWindowsCommit -eq $wireGuardWindowsCommit -and
            (Get-FileHash -LiteralPath $wireGuardDll -Algorithm SHA256).Hash -eq $manifest.wireGuardDllSha256 -and
            (Get-FileHash -LiteralPath $tunnelDll -Algorithm SHA256).Hash -eq $manifest.tunnelDllSha256
        if ($cached) { Assert-WireGuardSignature $wireGuardDll }
    }
    catch { $cached = $false }
}
if ($cached) {
    Write-Host "WireGuard embebible ya está preparado y coincide con su procedencia fijada."
    return
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("qrioso-wireguard-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $archivePath = Join-Path $temporaryRoot "wireguard-nt.zip"
    Write-Host "Descargando WireGuardNT $wireGuardNtVersion desde download.wireguard.com..."
    Invoke-WebRequest -Uri $wireGuardNtUri -OutFile $archivePath -UseBasicParsing
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($archiveHash -ne $wireGuardNtSha256) {
        throw "El SHA-256 de WireGuardNT no coincide. Esperado $wireGuardNtSha256; recibido $archiveHash."
    }
    $expandedRoot = Join-Path $temporaryRoot "wireguard-nt-expanded"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedRoot
    $officialDll = Join-Path $expandedRoot "wireguard-nt\bin\amd64\wireguard.dll"
    Assert-WireGuardSignature $officialDll

    $sourceRoot = Join-Path $temporaryRoot "wireguard-windows"
    Write-Host "Obteniendo wireguard-windows en el commit fijado $wireGuardWindowsCommit..."
    & git.exe clone --filter=blob:none $wireGuardWindowsRepository $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw "No se pudo clonar el source oficial de wireguard-windows." }
    & git.exe -C $sourceRoot checkout --detach $wireGuardWindowsCommit
    if ($LASTEXITCODE -ne 0) { throw "No se pudo fijar wireguard-windows en $wireGuardWindowsCommit." }
    $actualCommit = (& git.exe -C $sourceRoot rev-parse HEAD).Trim()
    if ($actualCommit -ne $wireGuardWindowsCommit) { throw "El checkout de wireguard-windows no coincide con el commit fijado." }

    Write-Host "Compilando tunnel.dll desde el proyecto embeddable-dll-service oficial..."
    & (Join-Path $sourceRoot "embeddable-dll-service\build.bat")
    if ($LASTEXITCODE -ne 0) { throw "Falló la compilación oficial de tunnel.dll." }
    $builtTunnel = Join-Path $sourceRoot "embeddable-dll-service\amd64\tunnel.dll"
    if (-not (Test-Path -LiteralPath $builtTunnel -PathType Leaf)) { throw "El build oficial no produjo amd64\tunnel.dll." }

    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $licensesRoot -Force | Out-Null
    Copy-Item -LiteralPath $officialDll -Destination $wireGuardDll -Force
    Copy-Item -LiteralPath $builtTunnel -Destination $tunnelDll -Force
    Copy-Item -LiteralPath (Join-Path $expandedRoot "wireguard-nt\LICENSE.txt") -Destination (Join-Path $licensesRoot "WireGuardNT-LICENSE.txt") -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot "COPYING") -Destination (Join-Path $licensesRoot "WireGuard-Windows-COPYING.txt") -Force
    Assert-WireGuardSignature $wireGuardDll

    $provenance = [ordered]@{
        acquiredAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        wireGuardNtVersion = $wireGuardNtVersion
        wireGuardNtUri = $wireGuardNtUri
        wireGuardNtArchiveSha256 = $wireGuardNtSha256
        wireGuardDllSha256 = (Get-FileHash -LiteralPath $wireGuardDll -Algorithm SHA256).Hash
        wireGuardWindowsRepository = $wireGuardWindowsRepository
        wireGuardWindowsCommit = $wireGuardWindowsCommit
        tunnelDllSourceBuildSha256 = (Get-FileHash -LiteralPath $tunnelDll -Algorithm SHA256).Hash
        tunnelDllSha256 = (Get-FileHash -LiteralPath $tunnelDll -Algorithm SHA256).Hash
        architecture = $Architecture
    }
    [IO.File]::WriteAllText($manifestPath, ($provenance | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Host "WireGuard embebible quedó preparado en $outputRoot" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
