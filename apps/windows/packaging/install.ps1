[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ejecuta install.ps1 desde PowerShell como Administrador."
}

$sourceRoot = $PSScriptRoot
$installRoot = Join-Path $env:ProgramFiles "Qrioso NoPing"
$serviceName = "QriosoNoPing"
$serviceExecutable = Join-Path $installRoot "service\Qrioso NoPing Service.exe"
$appExecutable = Join-Path $installRoot "app\Qrioso NoPing.exe"

if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName | Out-Null
    Start-Sleep -Seconds 2
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Copy-Item (Join-Path $sourceRoot "app") $installRoot -Recurse -Force
Copy-Item (Join-Path $sourceRoot "service") $installRoot -Recurse -Force

& sc.exe create $serviceName binPath= "`"$serviceExecutable`"" start= auto DisplayName= "Qrioso NoPing · Servicio de red" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "No se pudo registrar el servicio de red de Qrioso NoPing."
}
& sc.exe description $serviceName "Motor local y privilegiado de rutas de Qrioso NoPing" | Out-Null
Start-Service -Name $serviceName

$shell = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Qrioso NoPing.lnk"
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $appExecutable
$shortcut.WorkingDirectory = Join-Path $installRoot "app"
$shortcut.IconLocation = "$appExecutable,0"
$shortcut.Description = "Optimización y medición de rutas para juegos"
$shortcut.Save()

$startMenuDirectory = Join-Path ([Environment]::GetFolderPath("CommonPrograms")) "Qrioso"
New-Item -ItemType Directory -Path $startMenuDirectory -Force | Out-Null
$startMenuShortcutPath = Join-Path $startMenuDirectory "Qrioso NoPing.lnk"
$startMenuShortcut = $shell.CreateShortcut($startMenuShortcutPath)
$startMenuShortcut.TargetPath = $appExecutable
$startMenuShortcut.WorkingDirectory = Join-Path $installRoot "app"
$startMenuShortcut.IconLocation = "$appExecutable,0"
$startMenuShortcut.Description = "Optimización y medición de rutas para juegos"
$startMenuShortcut.Save()

Write-Host "Qrioso NoPing instalado en $installRoot" -ForegroundColor Green
