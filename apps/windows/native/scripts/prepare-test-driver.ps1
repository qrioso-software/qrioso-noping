[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SigningCertificateThumbprint,
    [string]$DriverPath = (Join-Path $PSScriptRoot "..\bin\test-x64\driver"),
    [string]$TimestampServer = "http://timestamp.digicert.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-WindowsKitTool {
    param([string]$FileName)
    $command = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $match = Get-ChildItem -LiteralPath $kitsRoot -Filter $FileName -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\x64\$FileName" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $match) { throw "No se encontró $FileName. Instala Windows 11 SDK y WDK." }
    return $match.FullName
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "La firma de prueba del driver debe prepararse en Windows."
}
$thumbprint = ($SigningCertificateThumbprint -replace "\s", "").ToUpperInvariant()
if ($thumbprint -notmatch "^[0-9A-F]{40}$") { throw "El thumbprint debe contener 40 caracteres hexadecimales." }
$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
if (-not $certificate) { $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint" -ErrorAction SilentlyContinue }
if (-not $certificate -or -not $certificate.HasPrivateKey) { throw "No se encontró el certificado de desarrollo con clave privada." }
if ($certificate.Subject -notmatch "Development") {
    throw "La modalidad Test exige el certificado local marcado como Development; no reutilices aquí una identidad de producción."
}

$driverRoot = [IO.Path]::GetFullPath($DriverPath)
$sysPath = Join-Path $driverRoot "QriosoNoPing.Wfp.sys"
$infPath = Join-Path $driverRoot "QriosoNoPing.Wfp.inf"
foreach ($path in @($sysPath, $infPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Falta el artefacto del driver: $path" }
}
$signTool = Find-WindowsKitTool "signtool.exe"
$inf2Cat = Find-WindowsKitTool "Inf2Cat.exe"

Write-Host "Firmando el SYS para una prueba local en Windows Test Mode..."
& $signTool sign /sha1 $thumbprint /fd SHA256 /tr $TimestampServer /td SHA256 $sysPath | Out-Host
if ($LASTEXITCODE -ne 0) { throw "No se pudo firmar QriosoNoPing.Wfp.sys para la prueba local." }

Write-Host "Regenerando el catálogo después de firmar el SYS..."
& $inf2Cat "/driver:$driverRoot" "/os:10_X64" /uselocaltime | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat rechazó el paquete de prueba WFP." }
$catPath = Join-Path $driverRoot "QriosoNoPing.Wfp.cat"
if (-not (Test-Path -LiteralPath $catPath -PathType Leaf)) { throw "Inf2Cat no produjo QriosoNoPing.Wfp.cat." }

& $signTool sign /sha1 $thumbprint /fd SHA256 /tr $TimestampServer /td SHA256 $catPath | Out-Host
if ($LASTEXITCODE -ne 0) { throw "No se pudo firmar el catálogo WFP de prueba." }
foreach ($path in @($sysPath, $catPath)) {
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $signature.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $thumbprint) {
        throw "La firma de prueba no valida con el certificado esperado: $path"
    }
}
$catalog = Test-FileCatalog -Path $driverRoot -CatalogFilePath $catPath -Detailed
if ($catalog.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "El catálogo de prueba no coincide exactamente con INF/SYS."
}

Write-Host "Driver preparado para una prueba local en Windows Test Mode." -ForegroundColor Green
Write-Warning "No distribuyas este paquete. Para cargarlo debes habilitar Test Mode y reiniciar; Secure Boot puede impedirlo."
Write-Host "Comando elevado: bcdedit /set testsigning on"
Write-Host "Para volver al modo normal: bcdedit /set testsigning off"
