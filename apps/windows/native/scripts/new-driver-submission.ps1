[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SigningCertificateThumbprint,
    [string]$DriverPath = (Join-Path $PSScriptRoot "..\bin\x64\driver"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\build\submission"),
    [string]$TimestampServer = "http://timestamp.digicert.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-SignTool {
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $match = Get-ChildItem -LiteralPath $kitsRoot -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\x64\signtool.exe" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $match) { throw "No se encontró signtool.exe." }
    return $match.FullName
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw "Este script debe ejecutarse en Windows." }
$thumbprint = ($SigningCertificateThumbprint -replace "\s", "").ToUpperInvariant()
if ($thumbprint -notmatch "^[0-9A-F]{40}$") { throw "El thumbprint debe contener 40 caracteres hexadecimales." }
$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
if (-not $certificate) { $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint" -ErrorAction SilentlyContinue }
if (-not $certificate -or -not $certificate.HasPrivateKey) { throw "No se encontró el certificado de firma con su clave privada." }

$driverRoot = [IO.Path]::GetFullPath($DriverPath)
$submissionRoot = [IO.Path]::GetFullPath($OutputPath)
$packageName = "QriosoNoPingWfp"
$required = @("QriosoNoPing.Wfp.inf", "QriosoNoPing.Wfp.sys", "QriosoNoPing.Wfp.cat")
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $driverRoot $name) -PathType Leaf)) { throw "Falta $name en $driverRoot" }
}
if (Test-Path -LiteralPath $submissionRoot) { Remove-Item -LiteralPath $submissionRoot -Recurse -Force }
New-Item -ItemType Directory -Path $submissionRoot | Out-Null
$cabName = "QriosoNoPing-Wfp-attestation.cab"
$ddf = Join-Path $submissionRoot "submission.ddf"
$lines = @(
    ".OPTION EXPLICIT",
    ".Set CabinetFileCountThreshold=0",
    ".Set FolderFileCountThreshold=0",
    ".Set FolderSizeThreshold=0",
    ".Set MaxCabinetSize=0",
    ".Set MaxDiskFileCount=0",
    ".Set MaxDiskSize=0",
    ".Set CompressionType=MSZIP",
    ".Set Cabinet=on",
    ".Set Compress=on",
    ".Set DiskDirectoryTemplate=$submissionRoot",
    ".Set CabinetNameTemplate=$cabName",
    ".Set DestinationDir=$packageName"
)
foreach ($name in $required) { $lines += '"' + (Join-Path $driverRoot $name) + '"' }
[IO.File]::WriteAllLines($ddf, $lines, [Text.Encoding]::ASCII)
& makecab.exe /f $ddf | Out-Host
if ($LASTEXITCODE -ne 0) { throw "makecab.exe no pudo crear la entrega." }
$cabPath = Join-Path $submissionRoot $cabName
if (-not (Test-Path -LiteralPath $cabPath -PathType Leaf)) { throw "No se creó $cabPath" }

$signTool = Find-SignTool
& $signTool sign /sha1 $thumbprint /fd SHA256 /tr $TimestampServer /td SHA256 $cabPath | Out-Host
if ($LASTEXITCODE -ne 0) { throw "No se pudo firmar el CAB para Partner Center." }
$signature = Get-AuthenticodeSignature -LiteralPath $cabPath
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { throw "El CAB no tiene una firma Authenticode válida." }
Write-Host "Entrega lista: $cabPath" -ForegroundColor Green
Write-Host "Súbela como attestation signing en Microsoft Partner Center y reemplaza driver\ con el paquete firmado que devuelva Microsoft."
