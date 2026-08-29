[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$expectedSignerThumbprint = "__SIGNER_THUMBPRINT__"

function Assert-PackageIntegrity {
    param([string]$PackageRoot)

    if ($expectedSignerThumbprint -notmatch "^[0-9A-F]{40}$") {
        throw "Este instalador no fue sellado por build-windows.ps1 y no puede distribuirse."
    }
    $selfSignature = Get-AuthenticodeSignature -LiteralPath $PSCommandPath
    if ($selfSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $selfSignature.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $expectedSignerThumbprint) {
        throw "La firma del instalador de Qrioso NoPing no es válida."
    }

    $manifestPath = Join-Path $PackageRoot "integrity.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Falta el manifiesto firmado de integridad." }
    $manifestSignature = Get-AuthenticodeSignature -LiteralPath $manifestPath
    if ($manifestSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $manifestSignature.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $expectedSignerThumbprint) {
        throw "La firma del manifiesto de integridad no es válida."
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $reparsePoints = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($reparsePoints.Count -ne 0) { throw "El paquete contiene enlaces o puntos de reanálisis no autorizados." }
    $actualFiles = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File | Where-Object { $_.FullName -ne $manifestPath })
    if ($actualFiles.Count -ne $manifest.Count) { throw "El paquete contiene archivos faltantes o no autorizados." }
    foreach ($file in $actualFiles) {
        $relative = [IO.Path]::GetRelativePath($PackageRoot, $file.FullName).Replace('/', '\')
        if (-not $manifest.ContainsKey($relative)) { throw "Archivo no autorizado en el paquete: $relative" }
        $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($actualHash -ne $manifest[$relative]) { throw "Falló la integridad SHA-256 de: $relative" }
    }
    return $manifest
}

function Assert-StagedPayloadIntegrity {
    param([string]$StagingRoot, [Collections.IDictionary]$Manifest)

    $expected = @{}
    foreach ($entry in $Manifest.GetEnumerator()) {
        if ($entry.Key.StartsWith("app\", [StringComparison]::OrdinalIgnoreCase) -or
            $entry.Key.StartsWith("service\", [StringComparison]::OrdinalIgnoreCase) -or
            $entry.Key.Equals("uninstall.ps1", [StringComparison]::OrdinalIgnoreCase)) {
            $expected[$entry.Key] = $entry.Value
        }
    }

    $reparsePoints = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($reparsePoints.Count -ne 0) { throw "La copia protegida contiene enlaces o puntos de reanálisis no autorizados." }
    $actualFiles = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Force -File)
    if ($actualFiles.Count -ne $expected.Count) { throw "La copia protegida contiene archivos faltantes o no autorizados." }
    foreach ($file in $actualFiles) {
        $relative = [IO.Path]::GetRelativePath($StagingRoot, $file.FullName).Replace('/', '\')
        if (-not $expected.ContainsKey($relative)) { throw "Archivo no autorizado en la copia protegida: $relative" }
        $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($actualHash -ne $expected[$relative]) { throw "Falló la integridad de la copia protegida: $relative" }
    }
}

function Remove-QriosoService {
    param([string]$Name)
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $Name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo eliminar el registro anterior del servicio de Qrioso NoPing." }
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
            Start-Sleep -Milliseconds 250
        }
        throw "Windows no terminó de eliminar el servicio anterior de Qrioso NoPing."
    }
}

function Stop-QriosoService {
    param([string]$Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $Name -Force
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(15))
    }
}

function Register-QriosoService {
    param([string]$Name, [string]$Executable)
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        & sc.exe config $Name binPath= "`"$Executable`"" start= delayed-auto depend= "BFE/Nsi/TcpIp" obj= LocalSystem DisplayName= "Qrioso NoPing · Servicio de red" | Out-Null
    }
    else {
        & sc.exe create $Name binPath= "`"$Executable`"" start= delayed-auto depend= "BFE/Nsi/TcpIp" obj= LocalSystem DisplayName= "Qrioso NoPing · Servicio de red" | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "No se pudo registrar o actualizar el servicio de red de Qrioso NoPing." }
    & sc.exe description $Name "Motor local y privilegiado de rutas de Qrioso NoPing" | Out-Null
    & sc.exe sidtype $Name unrestricted | Out-Null
    & sc.exe failure $Name reset= 86400 actions= restart/5000/restart/15000/none/0 | Out-Null
    & sc.exe failureflag $Name 1 | Out-Null
    Start-Service -Name $Name
    $service = Get-Service -Name $Name
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
}

function Set-QriosoDataPermissions {
    param([string]$DataRoot, [string]$PrivateRoot)
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $PrivateRoot -Force | Out-Null
    & icacls.exe $DataRoot /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron proteger los datos de configuración." }
    & icacls.exe $PrivateRoot /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron proteger las llaves locales." }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Ejecuta install.ps1 desde PowerShell como Administrador." }

$sourceRoot = $PSScriptRoot
$packageManifest = Assert-PackageIntegrity -PackageRoot $sourceRoot
$sourceApp = Join-Path $sourceRoot "app"
$sourceService = Join-Path $sourceRoot "service"
$sourceAppExecutable = Join-Path $sourceApp "Qrioso NoPing.exe"
$sourceServiceExecutable = Join-Path $sourceService "Qrioso NoPing Service.exe"
$sourceDriverRoot = Join-Path $sourceService "native\driver"
$requiredPaths = @(
    $sourceApp, $sourceService, $sourceAppExecutable, $sourceServiceExecutable,
    (Join-Path $sourceService "native\tunnel.dll"), (Join-Path $sourceService "native\wireguard.dll"),
    (Join-Path $sourceService "native\QriosoNoPing.Wfp.dll"), (Join-Path $sourceDriverRoot "QriosoNoPing.Wfp.sys"),
    (Join-Path $sourceDriverRoot "QriosoNoPing.Wfp.inf"), (Join-Path $sourceDriverRoot "QriosoNoPing.Wfp.cat")
)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "El paquete está incompleto; falta: $requiredPath" }
}
foreach ($requiredDirectory in @($sourceApp, $sourceService, $sourceDriverRoot)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) { throw "El paquete esperaba un directorio válido: $requiredDirectory" }
}
foreach ($requiredFile in $requiredPaths | Where-Object { $_ -notin @($sourceApp, $sourceService) }) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "El paquete esperaba un archivo válido: $requiredFile" }
}
$catalog = Test-FileCatalog -Path $sourceDriverRoot -CatalogFilePath (Join-Path $sourceDriverRoot "QriosoNoPing.Wfp.cat") -Detailed
if ($catalog.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { throw "El catálogo firmado del driver WFP no es válido." }

$installRoot = Join-Path $env:ProgramFiles "Qrioso NoPing"
$dataRoot = Join-Path $env:ProgramData "Qrioso NoPing"
$privateRoot = Join-Path $dataRoot "private"
$installId = [Guid]::NewGuid().ToString("N")
$stagingRoot = Join-Path $env:ProgramFiles "Qrioso NoPing.installing-$installId"
$backupRoot = Join-Path $env:ProgramFiles "Qrioso NoPing.backup-$installId"
$serviceName = "QriosoNoPing"
$serviceExecutable = Join-Path $installRoot "service\Qrioso NoPing Service.exe"
$appExecutable = Join-Path $installRoot "app\Qrioso NoPing.exe"
$mutex = New-Object Threading.Mutex($false, "Global\QriosoNoPingInstaller")
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); throw "Ya hay otra instalación de Qrioso NoPing en curso." }

$swapped = $false
$previousMoved = $false
$wfpInstalled = $false
$serviceExisted = [bool](Get-Service -Name $serviceName -ErrorAction SilentlyContinue)
$completed = $false
try {
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    Copy-Item -LiteralPath $sourceApp -Destination $stagingRoot -Recurse
    Copy-Item -LiteralPath $sourceService -Destination $stagingRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceRoot "uninstall.ps1") -Destination $stagingRoot
    Assert-StagedPayloadIntegrity -StagingRoot $stagingRoot -Manifest $packageManifest
    Get-Process -Name "Qrioso NoPing" -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-QriosoService -Name $serviceName

    if (Test-Path -LiteralPath $installRoot) { Move-Item -LiteralPath $installRoot -Destination $backupRoot; $previousMoved = $true }
    Move-Item -LiteralPath $stagingRoot -Destination $installRoot
    $swapped = $true

    Set-QriosoDataPermissions -DataRoot $dataRoot -PrivateRoot $privateRoot
    & $serviceExecutable /install-wfp
    if ($LASTEXITCODE -ne 0) { throw "No se pudo instalar el componente WFP firmado (código $LASTEXITCODE)." }
    $wfpInstalled = $true
    Register-QriosoService -Name $serviceName -Executable $serviceExecutable

    $shell = New-Object -ComObject WScript.Shell
    $desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "Qrioso NoPing.lnk"
    $shortcut = $shell.CreateShortcut($desktopShortcutPath)
    $shortcut.TargetPath = $appExecutable
    $shortcut.WorkingDirectory = Join-Path $installRoot "app"
    $shortcut.IconLocation = "$appExecutable,0"
    $shortcut.Description = "Optimización y medición de rutas para juegos"
    $shortcut.Save()

    $startMenuDirectory = Join-Path ([Environment]::GetFolderPath("CommonPrograms")) "Qrioso"
    New-Item -ItemType Directory -Path $startMenuDirectory -Force | Out-Null
    foreach ($entry in @(
        @{ Name = "Qrioso NoPing.lnk"; Target = $appExecutable; Arguments = ""; Description = "Optimización y medición de rutas para juegos" },
        @{ Name = "Desinstalar Qrioso NoPing.lnk"; Target = "powershell.exe"; Arguments = "-NoProfile -ExecutionPolicy AllSigned -File `"$(Join-Path $installRoot 'uninstall.ps1')`""; Description = "Desinstalar Qrioso NoPing" }
    )) {
        $link = $shell.CreateShortcut((Join-Path $startMenuDirectory $entry.Name))
        $link.TargetPath = $entry.Target
        $link.Arguments = $entry.Arguments
        $link.WorkingDirectory = $installRoot
        $link.IconLocation = "$appExecutable,0"
        $link.Description = $entry.Description
        $link.Save()
    }

    $uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\QriosoNoPing"
    New-Item -Path $uninstallKey -Force | Out-Null
    Set-ItemProperty -Path $uninstallKey -Name DisplayName -Value "Qrioso NoPing"
    Set-ItemProperty -Path $uninstallKey -Name Publisher -Value "Qrioso Software Consulting"
    Set-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value "0.1.0"
    Set-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value $appExecutable
    Set-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installRoot
    Set-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy AllSigned -File `"$(Join-Path $installRoot 'uninstall.ps1')`""
    Set-ItemProperty -Path $uninstallKey -Name NoModify -Type DWord -Value 1
    Set-ItemProperty -Path $uninstallKey -Name NoRepair -Type DWord -Value 1

    $completed = $true
    Write-Host "Qrioso NoPing instalado y verificado en $installRoot" -ForegroundColor Green
}
catch {
    $installationError = $_
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    try { Stop-QriosoService -Name $serviceName } catch { [void]$rollbackErrors.Add("detener el servicio: $($_.Exception.Message)") }
    try {
        if ($wfpInstalled -and (Test-Path -LiteralPath $serviceExecutable)) { & $serviceExecutable /uninstall-wfp | Out-Null }
    } catch { [void]$rollbackErrors.Add("retirar WFP nuevo: $($_.Exception.Message)") }
    try {
        if (($swapped -or $previousMoved) -and (Test-Path -LiteralPath $installRoot)) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
        if ($previousMoved -and (Test-Path -LiteralPath $backupRoot)) { Move-Item -LiteralPath $backupRoot -Destination $installRoot }
    } catch { [void]$rollbackErrors.Add("restaurar archivos: $($_.Exception.Message)") }
    try {
        $previousServiceExecutable = Join-Path $installRoot "service\Qrioso NoPing Service.exe"
        if ($serviceExisted -and (Test-Path -LiteralPath $previousServiceExecutable)) {
            & $previousServiceExecutable /install-wfp | Out-Null
            Register-QriosoService -Name $serviceName -Executable $previousServiceExecutable
        }
        elseif (-not $serviceExisted -and (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) { Remove-QriosoService -Name $serviceName }
    } catch { [void]$rollbackErrors.Add("restaurar versión anterior: $($_.Exception.Message)") }
    foreach ($rollbackError in $rollbackErrors) { Write-Warning "Reversión incompleta al intentar $rollbackError" }
    if ($rollbackErrors.Count -gt 0) { Write-Warning "La copia anterior, si existe, permanece en $backupRoot." }
    throw $installationError
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
    if ($completed -and (Test-Path -LiteralPath $backupRoot)) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
