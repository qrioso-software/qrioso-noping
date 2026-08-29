[CmdletBinding()]
param()

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
. (Join-Path $root "apps\windows\build\Test-CodeSigningCertificate.ps1")
. (Join-Path $root "apps\windows\build\Get-DotNetSdkVersion.ps1")

function Install-QriosoDotNetSdk10 {
    $sdkVersion = Get-QriosoDotNetSdkVersion
    if ($sdkVersion -and $sdkVersion.StartsWith("10.")) { return }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "Falta .NET SDK 10 y winget no está disponible para instalarlo automáticamente."
    }

    Write-Host "Instalando .NET SDK 10..." -ForegroundColor Cyan
    & $winget.Source install `
        --id Microsoft.DotNet.SDK.10 `
        --exact `
        --source winget `
        --scope machine `
        --accept-source-agreements `
        --accept-package-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "No se pudo instalar .NET SDK 10 mediante winget." }

    $dotnetDirectory = Join-Path $env:ProgramFiles "dotnet"
    $env:Path = "$dotnetDirectory;$env:Path"
    $sdkVersion = Get-QriosoDotNetSdkVersion -DotNetExecutable (Join-Path $dotnetDirectory "dotnet.exe")
    if (-not $sdkVersion -or -not $sdkVersion.StartsWith("10.")) {
        throw ".NET SDK 10 terminó de instalarse, pero no quedó disponible en esta sesión."
    }
    Write-Host ".NET SDK $sdkVersion listo." -ForegroundColor Green
}

function Find-QriosoDevelopmentCertificate {
    Get-ChildItem -Path "Cert:\CurrentUser\My" |
        Where-Object {
            $thumbprint = $_.Thumbprint
            $_.Subject -eq "CN=Qrioso Software Consulting Development" -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt [DateTime]::UtcNow.AddDays(30) -and
            (Test-QriosoCodeSigningCertificate -Certificate $_) -and
            (Test-Path -LiteralPath "Cert:\LocalMachine\Root\$thumbprint") -and
            (Test-Path -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$thumbprint")
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

Install-QriosoDotNetSdk10

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
    -SigningCertificateThumbprint $certificate.Thumbprint `
    -DriverSigningMode Test

Write-Host ""
Write-Host "Build del piloto terminado." -ForegroundColor Green
Write-Warning "Reinicia Windows antes de instalar para que Test Mode quede activo."
Write-Host 'Después de reiniciar, descomprime dist\windows\QriosoNoPing-win-x64.zip y ejecuta install.ps1 como Administrador.'
