[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias("EnvFile")]
    [string]$InfraEnvironmentFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "Este script debe ejecutarse en una PC Windows."
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Abre PowerShell como Administrador y vuelve a ejecutar el comando."
}

$root = $PSScriptRoot
Set-Location $root
$infraPath = (Get-Item -LiteralPath $InfraEnvironmentFile -Force -ErrorAction Stop).FullName

function Find-QriosoDevelopmentCertificate {
    Get-ChildItem -Path "Cert:\CurrentUser\My" |
        Where-Object {
            $thumbprint = $_.Thumbprint
            $_.Subject -eq "CN=Qrioso Software Consulting Development" -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt [DateTime]::UtcNow.AddDays(30) -and
            ($_.EnhancedKeyUsageList.ObjectId.Value -contains "1.3.6.1.5.5.7.3.3") -and
            (Test-Path -LiteralPath "Cert:\LocalMachine\Root\$thumbprint") -and
            (Test-Path -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$thumbprint")
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

$certificate = Find-QriosoDevelopmentCertificate
if (-not $certificate) {
    Write-Host "Creando el certificado local de piloto..." -ForegroundColor Cyan
    & (Join-Path $root "apps\windows\native\scripts\new-development-certificate.ps1")
    $certificate = Find-QriosoDevelopmentCertificate
}
if (-not $certificate) {
    throw "No se pudo crear o localizar el certificado local de piloto."
}

Write-Host "Habilitando Windows Test Mode para el driver del piloto..." -ForegroundColor Cyan
& bcdedit.exe /set testsigning on | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "No se pudo habilitar Test Mode. Secure Boot puede impedirlo; desactívalo temporalmente y repite el comando."
}

& (Join-Path $root "build-windows.ps1") `
    -InfraEnvironmentFile $infraPath `
    -SigningCertificateThumbprint $certificate.Thumbprint `
    -DriverSigningMode Test

Write-Host ""
Write-Host "Build del piloto terminado." -ForegroundColor Green
Write-Warning "Reinicia Windows antes de instalar para que Test Mode quede activo."
Write-Host 'Después de reiniciar, descomprime dist\windows\QriosoNoPing-win-x64.zip y ejecuta install.ps1 como Administrador.'
