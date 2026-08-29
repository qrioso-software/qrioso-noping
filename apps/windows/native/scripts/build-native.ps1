[CmdletBinding()]
param(
    [ValidateSet("x64")]
    [string]$Architecture = "x64",
    [ValidateSet("Release")]
    [string]$Configuration = "Release",
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\bin\x64")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-VisualStudioTool {
    param([string]$FileName)
    $command = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "No se encontró vswhere.exe ni $FileName." }
    $installation = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    if (-not $installation) { throw "Visual Studio no tiene las herramientas C++ x64 instaladas." }
    $match = Get-ChildItem -LiteralPath $installation -Filter $FileName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $match) { throw "No se encontró $FileName dentro de Visual Studio." }
    return $match.FullName
}

function Find-WindowsKitTool {
    param([string]$FileName)
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $match = Get-ChildItem -LiteralPath $kitsRoot -Filter $FileName -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\x64\$FileName" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $match) { throw "No se encontró $FileName. Instala Windows 11 SDK y WDK." }
    return $match.FullName
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "El componente WFP debe compilarse en una PC Windows con Visual Studio 2022, SDK y WDK."
}

$nativeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$solution = Join-Path $nativeRoot "QriosoNoPing.Wfp.sln"
$outputRoot = [IO.Path]::GetFullPath($OutputPath)
$driverOutput = Join-Path $outputRoot "driver"
$msbuild = Find-VisualStudioTool "MSBuild.exe"
$inf2Cat = Find-WindowsKitTool "Inf2Cat.exe"
$infVerif = Find-WindowsKitTool "InfVerif.exe"

Write-Host "Compilando QriosoNoPing.Wfp.dll y QriosoNoPing.Wfp.sys..."
& $msbuild $solution /restore /m /p:Configuration=$Configuration /p:Platform=$Architecture /p:SignMode=Off /p:RunCodeAnalysis=true
if ($LASTEXITCODE -ne 0) { throw "Falló la compilación del componente WFP." }

$clientDll = Join-Path $nativeRoot "build\client\QriosoNoPing.Wfp.dll"
$driverSys = Join-Path $nativeRoot "build\driver\QriosoNoPing.Wfp.sys"
$driverInf = Join-Path $nativeRoot "src\driver\QriosoNoPing.Wfp.inf"
foreach ($path in @($clientDll, $driverSys, $driverInf)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "El build WFP no produjo el archivo esperado: $path" }
}
New-Item -ItemType Directory -Path $driverOutput -Force | Out-Null
Copy-Item -LiteralPath $clientDll -Destination (Join-Path $outputRoot "QriosoNoPing.Wfp.dll") -Force
Copy-Item -LiteralPath $driverSys -Destination (Join-Path $driverOutput "QriosoNoPing.Wfp.sys") -Force
Copy-Item -LiteralPath $driverInf -Destination (Join-Path $driverOutput "QriosoNoPing.Wfp.inf") -Force

Write-Host "Validando el INF con las reglas actuales del WDK..."
& $infVerif /w (Join-Path $driverOutput "QriosoNoPing.Wfp.inf") | Out-Host
if ($LASTEXITCODE -ne 0) { throw "InfVerif rechazó QriosoNoPing.Wfp.inf." }

Write-Host "Generando el catálogo exacto del paquete WFP..."
& $inf2Cat "/driver:$driverOutput" "/os:10_X64" /uselocaltime
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat rechazó el paquete WFP." }
$catalog = Join-Path $driverOutput "QriosoNoPing.Wfp.cat"
if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) { throw "Inf2Cat no generó QriosoNoPing.Wfp.cat." }

Write-Host "Build nativo terminado en $outputRoot." -ForegroundColor Green
Write-Host "El catálogo aún debe volver firmado por Microsoft Partner Center antes del build de producción." -ForegroundColor Yellow
