[CmdletBinding()]
param(
    [switch]$KeepLocalAccess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$expectedSignerThumbprint = "__SIGNER_THUMBPRINT__"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Ejecuta uninstall.ps1 desde PowerShell como Administrador." }
$signature = Get-AuthenticodeSignature -LiteralPath $PSCommandPath
if ($expectedSignerThumbprint -notmatch "^[0-9A-F]{40}$" -or
    $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
    $signature.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $expectedSignerThumbprint) {
    throw "La firma del desinstalador de Qrioso NoPing no es válida."
}

$serviceName = "QriosoNoPing"
$installRoot = Join-Path $env:ProgramFiles "Qrioso NoPing"
$dataRoot = Join-Path $env:ProgramData "Qrioso NoPing"
$serviceExecutable = Join-Path $installRoot "service\Qrioso NoPing Service.exe"
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "Qrioso NoPing.lnk"
$startMenuDirectory = Join-Path ([Environment]::GetFolderPath("CommonPrograms")) "Qrioso"
$mutex = New-Object Threading.Mutex($false, "Global\QriosoNoPingInstaller")
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); throw "Ya hay otra instalación o desinstalación de Qrioso NoPing en curso." }

try {
    Get-Process -Name "Qrioso NoPing" -ErrorAction SilentlyContinue | Stop-Process -Force
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(15))
    }

    if (Test-Path -LiteralPath $serviceExecutable) {
        & $serviceExecutable /uninstall-wfp
        if ($LASTEXITCODE -ne 0) { throw "No se pudo retirar el componente WFP firmado (código $LASTEXITCODE). No se eliminaron sus archivos." }
    }

    foreach ($tunnelService in @("WireGuardTunnel`$QriosoRouteB", "WireGuardTunnel`$QriosoRouteA")) {
        & sc.exe stop $tunnelService | Out-Null
        & sc.exe delete $tunnelService | Out-Null
    }
    if ($service) {
        & sc.exe delete $serviceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo eliminar Qrioso NoPing Service." }
    }

    if (Test-Path -LiteralPath $desktopShortcutPath) { Remove-Item -LiteralPath $desktopShortcutPath -Force }
    if (Test-Path -LiteralPath $startMenuDirectory) { Remove-Item -LiteralPath $startMenuDirectory -Recurse -Force }
    Remove-Item -LiteralPath "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\QriosoNoPing" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
    if (-not $KeepLocalAccess -and (Test-Path -LiteralPath $dataRoot)) { Remove-Item -LiteralPath $dataRoot -Recurse -Force }

    $dataMessage = if ($KeepLocalAccess) { " Se conservó el acceso local protegido para una reinstalación." } else { " También se eliminaron la configuración y el acceso local cifrado." }
    Write-Host "Qrioso NoPing fue desinstalado.$dataMessage" -ForegroundColor Green
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
