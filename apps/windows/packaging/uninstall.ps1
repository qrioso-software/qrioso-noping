[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ejecuta uninstall.ps1 desde PowerShell como Administrador."
}

$serviceName = "QriosoNoPing"
$installRoot = Join-Path $env:ProgramFiles "Qrioso NoPing"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Qrioso NoPing.lnk"
$startMenuDirectory = Join-Path ([Environment]::GetFolderPath("CommonPrograms")) "Qrioso"
$startMenuShortcutPath = Join-Path $startMenuDirectory "Qrioso NoPing.lnk"

if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName | Out-Null
    Start-Sleep -Seconds 2
}

if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath -Force
}
if (Test-Path $startMenuShortcutPath) {
    Remove-Item $startMenuShortcutPath -Force
}
if ((Test-Path $startMenuDirectory) -and -not (Get-ChildItem $startMenuDirectory -Force)) {
    Remove-Item $startMenuDirectory -Force
}
if (Test-Path $installRoot) {
    Remove-Item $installRoot -Recurse -Force
}

Write-Host "Qrioso NoPing desinstalado." -ForegroundColor Green
