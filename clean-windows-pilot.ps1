[CmdletBinding()]
param(
    [switch]$KeepLocalAccess,
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "Este script debe ejecutarse en la PC Windows donde se instalo el piloto."
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Abre PowerShell como Administrador y vuelve a ejecutar el comando."
}

$cleanupErrors = [Collections.Generic.List[string]]::new()
$restartRequired = $false
$serviceName = "QriosoNoPing"
$driverServiceName = "QriosoNoPingWfp"
$installRoot = Join-Path $env:ProgramFiles "Qrioso NoPing"
$dataRoot = Join-Path $env:ProgramData "Qrioso NoPing"
$serviceExecutable = Join-Path $installRoot "service\Qrioso NoPing Service.exe"
$driverBinary = Join-Path $env:SystemRoot "System32\drivers\QriosoNoPing.Wfp.sys"
$pnputil = Join-Path $env:SystemRoot "System32\pnputil.exe"
$bcdedit = Join-Path $env:SystemRoot "System32\bcdedit.exe"
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "Qrioso NoPing.lnk"
$startMenuDirectory = Join-Path ([Environment]::GetFolderPath("CommonPrograms")) "Qrioso"
$mutex = [Threading.Mutex]::new($false, "Global\QriosoNoPingInstaller")
if (-not $mutex.WaitOne(0)) {
    $mutex.Dispose()
    throw "Hay otra instalacion o desinstalacion de Qrioso NoPing en curso."
}

function Add-QriosoCleanupError {
    param([string]$Message)
    [void]$cleanupErrors.Add($Message)
    Write-Warning $Message
}

function Stop-QriosoService {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        return
    }
    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(15))
    }
    catch {
        Write-Warning "No se pudo detener el servicio $Name; se intentara marcarlo para eliminarlo al reiniciar: $($_.Exception.Message)"
        $script:restartRequired = $true
    }
}

function Remove-QriosoService {
    param([string]$Name)

    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) {
        return
    }
    & sc.exe delete $Name | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Add-QriosoCleanupError "No se pudo eliminar el registro del servicio $Name (codigo $LASTEXITCODE)."
        return
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Warning "El servicio $Name quedo marcado para eliminarse al reiniciar."
    $script:restartRequired = $true
}

function Get-QriosoPublishedDriverPackages {
    $infRoot = Join-Path $env:SystemRoot "INF"
    $packages = [Collections.Generic.List[string]]::new()
    foreach ($inf in Get-ChildItem -LiteralPath $infRoot -Filter "oem*.inf" -File -ErrorAction SilentlyContinue) {
        try {
            $source = [IO.File]::ReadAllText($inf.FullName)
            if ($source.IndexOf("QriosoNoPingWfp", [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $source.IndexOf("QriosoNoPing.Wfp.sys", [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$packages.Add($inf.Name)
            }
        }
        catch {
            Write-Verbose "No se pudo inspeccionar $($inf.FullName): $($_.Exception.Message)"
        }
    }
    return @($packages | Sort-Object -Unique)
}

try {
    Write-Host "Cerrando Qrioso NoPing y sus rutas..." -ForegroundColor Cyan
    Get-Process -Name "Qrioso NoPing" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-QriosoService -Name $serviceName
    foreach ($tunnelService in @('WireGuardTunnel$QriosoRouteB', 'WireGuardTunnel$QriosoRouteA')) {
        Stop-QriosoService -Name $tunnelService
    }
    Get-Process -Name "Qrioso NoPing Service" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    # Este es el camino normal: cierra la sesion WFP dinamica, detiene el
    # driver y retira el INF mediante la misma DLL usada al instalarlo.
    if (Test-Path -LiteralPath $serviceExecutable -PathType Leaf) {
        Write-Host "Retirando el componente WFP con el desinstalador nativo..." -ForegroundColor Cyan
        & $serviceExecutable /uninstall-wfp | Out-Host
        $nativeUninstallExitCode = $LASTEXITCODE
        if ($nativeUninstallExitCode -eq 3010) {
            $restartRequired = $true
        }
        elseif ($nativeUninstallExitCode -ne 0) {
            Write-Warning "El desinstalador nativo devolvio $nativeUninstallExitCode; se usara la limpieza de rescate."
        }
    }

    # Rescate independiente del ejecutable instalado. Solo selecciona un INF
    # que contenga simultaneamente el servicio y binario exclusivos de Qrioso.
    Stop-QriosoService -Name $driverServiceName
    foreach ($publishedInf in @(Get-QriosoPublishedDriverPackages)) {
        Write-Host "Eliminando $publishedInf del Driver Store..." -ForegroundColor Cyan
        & $pnputil /delete-driver $publishedInf /uninstall /force | Out-Host
        if ($LASTEXITCODE -eq 3010) {
            $restartRequired = $true
        }
        elseif ($LASTEXITCODE -ne 0) {
            Add-QriosoCleanupError "PnPUtil no pudo eliminar $publishedInf (codigo $LASTEXITCODE)."
        }
    }

    Stop-QriosoService -Name $driverServiceName
    Remove-QriosoService -Name $driverServiceName
    foreach ($tunnelService in @('WireGuardTunnel$QriosoRouteB', 'WireGuardTunnel$QriosoRouteA')) {
        Remove-QriosoService -Name $tunnelService
    }
    Remove-QriosoService -Name $serviceName

    Write-Host "Eliminando la instalacion local del piloto..." -ForegroundColor Cyan
    foreach ($path in @($desktopShortcutPath, $startMenuDirectory, $installRoot)) {
        if (Test-Path -LiteralPath $path) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
            catch {
                Add-QriosoCleanupError "No se pudo eliminar $path`: $($_.Exception.Message)"
                $restartRequired = $true
            }
        }
    }
    Remove-Item -LiteralPath "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\QriosoNoPing" -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $KeepLocalAccess -and (Test-Path -LiteralPath $dataRoot)) {
        try {
            Remove-Item -LiteralPath $dataRoot -Recurse -Force
        }
        catch {
            Add-QriosoCleanupError "No se pudieron eliminar los datos locales protegidos: $($_.Exception.Message)"
        }
    }

    Write-Host "Eliminando la confianza del certificado local de desarrollo..." -ForegroundColor Cyan
    $developmentSubject = "CN=Qrioso Software Consulting Development"
    foreach ($storePath in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\Root", "Cert:\LocalMachine\TrustedPublisher")) {
        foreach ($certificate in @(Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue | Where-Object {
            $_.Subject -eq $developmentSubject -and $_.Issuer -eq $developmentSubject
        })) {
            try {
                Remove-Item -LiteralPath $certificate.PSPath -Force
            }
            catch {
                Add-QriosoCleanupError "No se pudo eliminar el certificado $($certificate.Thumbprint) de $storePath`: $($_.Exception.Message)"
            }
        }
    }

    Write-Host "Deshabilitando Windows Test Mode..." -ForegroundColor Cyan
    & $bcdedit /set testsigning off | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Add-QriosoCleanupError "BCDEdit no pudo deshabilitar TESTSIGNING (codigo $LASTEXITCODE)."
    }
    else {
        $restartRequired = $true
    }

    $remainingPackages = @(Get-QriosoPublishedDriverPackages)
    if ($remainingPackages.Count -gt 0) {
        Add-QriosoCleanupError "El Driver Store todavia contiene: $($remainingPackages -join ', ')."
    }
    if (Test-Path -LiteralPath $driverBinary -PathType Leaf) {
        Write-Warning "El binario del driver sigue presente y Windows puede retirarlo durante el reinicio: $driverBinary"
        $restartRequired = $true
    }

    if ($cleanupErrors.Count -gt 0) {
        throw "La limpieza termino con $($cleanupErrors.Count) problema(s). Revisa las advertencias antes de reiniciar."
    }

    $dataMessage = if ($KeepLocalAccess) {
        " Se conservaron el acceso y la configuracion local cifrados."
    }
    else {
        " Tambien se eliminaron el acceso y la configuracion local cifrados."
    }
    Write-Host "Qrioso NoPing, su driver WFP de prueba y el certificado Development fueron retirados.$dataMessage" -ForegroundColor Green
    if ($restartRequired) {
        if ($Restart) {
            Write-Host "Reiniciando Windows para aplicar TESTSIGNING OFF y descargar cualquier driver pendiente..." -ForegroundColor Cyan
            Restart-Computer -Force
        }
        else {
            Write-Warning "Debes reiniciar Windows antes de volver a abrir Fortnite. Ejecuta: Restart-Computer -Force"
            Write-Warning "Si deshabilitaste Secure Boot en el BIOS para el piloto, vuelve a habilitarlo manualmente."
        }
    }
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
