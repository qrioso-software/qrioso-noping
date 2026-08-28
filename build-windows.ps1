[CmdletBinding()]
param(
    [ValidateSet("x64")]
    [string]$Architecture = "x64",
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "Este script debe ejecutarse en una PC con Windows."
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "No se encontró .NET SDK 10. Instala Visual Studio con WinUI/Windows App SDK, Windows 11 SDK y .NET 10 SDK."
}

$sdkVersion = (& dotnet --version).Trim()
if (-not $sdkVersion.StartsWith("10.")) {
    throw "Se requiere .NET SDK 10; versión encontrada: $sdkVersion"
}

$root = $PSScriptRoot
Set-Location $root
$windowsRoot = Join-Path $root "apps\windows"
$outputRoot = Join-Path $root "dist\windows"
$packageRoot = Join-Path $outputRoot "QriosoNoPing-win-$Architecture"
$appOutput = Join-Path $packageRoot "app"
$serviceOutput = Join-Path $packageRoot "service"
$archive = Join-Path $outputRoot "QriosoNoPing-win-$Architecture.zip"

if (Test-Path $packageRoot) {
    Remove-Item $packageRoot -Recurse -Force
}
if (Test-Path $archive) {
    Remove-Item $archive -Force
}
New-Item -ItemType Directory -Path $appOutput -Force | Out-Null
New-Item -ItemType Directory -Path $serviceOutput -Force | Out-Null

Write-Host "1/4 Restaurando y ejecutando pruebas..."
& dotnet test `
    (Join-Path $windowsRoot "tests\QriosoNoPing.Core.Tests\QriosoNoPing.Core.Tests.csproj") `
    --configuration $Configuration
if ($LASTEXITCODE -ne 0) { throw "Fallaron las pruebas .NET." }

Write-Host "2/4 Compilando la aplicación WinUI autocontenida..."
& dotnet publish `
    (Join-Path $windowsRoot "src\QriosoNoPing.App\QriosoNoPing.App.csproj") `
    --configuration $Configuration `
    --runtime "win-$Architecture" `
    --self-contained true `
    -p:Platform=$Architecture `
    --output $appOutput
if ($LASTEXITCODE -ne 0) { throw "Falló la compilación de la aplicación WinUI." }

Write-Host "3/4 Compilando el Windows Service autocontenido..."
& dotnet publish `
    (Join-Path $windowsRoot "src\QriosoNoPing.Service\QriosoNoPing.Service.csproj") `
    --configuration $Configuration `
    --runtime "win-$Architecture" `
    --self-contained true `
    -p:PublishSingleFile=true `
    --output $serviceOutput
if ($LASTEXITCODE -ne 0) { throw "Falló la compilación del Windows Service." }

Copy-Item (Join-Path $windowsRoot "packaging\install.ps1") $packageRoot
Copy-Item (Join-Path $windowsRoot "packaging\uninstall.ps1") $packageRoot
Copy-Item (Join-Path $windowsRoot "packaging\LEEME.txt") $packageRoot

Write-Host "4/4 Creando ZIP de distribución..."
Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $archive -CompressionLevel Optimal

Write-Host ""
Write-Host "Build terminado correctamente." -ForegroundColor Green
Write-Host "Aplicación: $(Join-Path $appOutput 'Qrioso NoPing.exe')"
Write-Host "Paquete: $archive"
Write-Host "Para instalar el servicio, descomprime el ZIP y ejecuta install.ps1 como Administrador."
