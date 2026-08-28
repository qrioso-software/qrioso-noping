[CmdletBinding()]
param(
    [ValidateSet("x64")]
    [string]$Architecture = "x64",
    [ValidateSet("Release")]
    [string]$Configuration = "Release",
    [Parameter(Mandatory = $true)]
    [string]$AccessApiBaseUri,
    [Parameter(Mandatory = $true)]
    [string]$TlsSpkiPin,
    [Parameter(Mandatory = $true)]
    [string]$SigningCertificateThumbprint,
    [ValidateSet("Microsoft", "Test")]
    [string]$DriverSigningMode = "Microsoft",
    [string]$NativeArtifactsPath,
    [string]$TimestampServer = "http://timestamp.digicert.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SignTool {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $candidate = Get-ChildItem -LiteralPath $kitsRoot -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\x64\signtool.exe" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $candidate) { throw "No se encontró signtool.exe en el Windows SDK." }
    return $candidate.FullName
}

function Get-CodeSigningCertificate {
    param([string]$Thumbprint)
    $normalized = ($Thumbprint -replace "\s", "").ToUpperInvariant()
    if ($normalized -notmatch "^[0-9A-F]{40}$") {
        throw "SigningCertificateThumbprint debe ser un thumbprint SHA-1 de 40 caracteres hexadecimales."
    }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$normalized" -ErrorAction SilentlyContinue
    if (-not $certificate) { $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$normalized" -ErrorAction SilentlyContinue }
    if (-not $certificate -or -not $certificate.HasPrivateKey) {
        throw "No se encontró el certificado de firma con clave privada: $normalized"
    }
    if ($certificate.NotAfter -le [DateTime]::UtcNow.AddDays(30)) { throw "El certificado de firma expira en menos de 30 días." }
    if (-not ($certificate.EnhancedKeyUsageList.ObjectId.Value -contains "1.3.6.1.5.5.7.3.3")) {
        throw "El certificado no permite Code Signing."
    }
    return $certificate
}

function Assert-ValidSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Firma Authenticode inválida en $Path ($($signature.Status))."
    }
}

function Assert-MicrosoftDriverCatalog {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $signature.SignerCertificate.Subject -notmatch "Microsoft Windows Hardware Compatibility Publisher") {
        throw "El catálogo WFP no está firmado por Microsoft Hardware Dev Center: $Path"
    }
}

function Invoke-QriosoSign {
    param(
        [string]$Path,
        [string]$SignTool,
        [string]$Thumbprint,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$TimestampUrl,
        [switch]$PreserveExistingValidSignature
    )
    $existingSignature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($existingSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
        ($PreserveExistingValidSignature -or
         $existingSignature.SignerCertificate.Thumbprint.ToUpperInvariant() -eq $Certificate.Thumbprint.ToUpperInvariant())) {
        return
    }
    if ([IO.Path]::GetExtension($Path) -in ".ps1", ".psd1") {
        $signature = Set-AuthenticodeSignature -LiteralPath $Path -Certificate $Certificate -TimestampServer $TimestampUrl -HashAlgorithm SHA256
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { throw "Falló la firma Authenticode de $Path ($($signature.StatusMessage))" }
        return
    }
    $arguments = @("sign", "/sha1", $Thumbprint, "/fd", "SHA256", "/tr", $TimestampUrl, "/td", "SHA256")
    $arguments += $Path
    & $SignTool @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Falló la firma Authenticode de $Path" }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw "Este script debe ejecutarse en una PC con Windows." }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "No se encontró .NET SDK 10. Instala Visual Studio con WinUI/Windows App SDK, Windows 11 SDK y .NET 10 SDK."
}
$sdkVersion = (& dotnet --version).Trim()
if (-not $sdkVersion.StartsWith("10.")) { throw "Se requiere .NET SDK 10; versión encontrada: $sdkVersion" }

try { $accessUri = [Uri]$AccessApiBaseUri } catch { throw "AccessApiBaseUri no es una URI absoluta válida." }
if (-not $accessUri.IsAbsoluteUri -or $accessUri.Scheme -ne "https" -or $accessUri.Port -ne 8443 -or
    $accessUri.AbsolutePath -ne "/" -or $accessUri.Query -or $accessUri.Fragment -or $accessUri.UserInfo -or
    $accessUri.HostNameType -notin [UriHostNameType]::Dns, [UriHostNameType]::IPv4) {
    throw "AccessApiBaseUri debe ser un origen HTTPS en el puerto 8443, sin ruta, query ni fragmento."
}
if ($TlsSpkiPin -notmatch "^sha256/[A-Za-z0-9+/]{43}=$") { throw "TlsSpkiPin debe tener el formato sha256/<base64 SHA-256>." }

$root = $PSScriptRoot
Set-Location $root
$windowsRoot = Join-Path $root "apps\windows"
if ([string]::IsNullOrWhiteSpace($NativeArtifactsPath)) {
    $nativeFolder = if ($DriverSigningMode -eq "Test") { "test-x64" } else { "x64" }
    $NativeArtifactsPath = Join-Path $windowsRoot "native\bin\$nativeFolder"
}
$nativeRoot = [IO.Path]::GetFullPath($NativeArtifactsPath)
$driverRoot = Join-Path $nativeRoot "driver"
$wireGuardPreparation = Join-Path $windowsRoot "native\scripts\acquire-wireguard.ps1"
$nativeBuild = Join-Path $windowsRoot "native\scripts\build-native.ps1"
$testDriverPreparation = Join-Path $windowsRoot "native\scripts\prepare-test-driver.ps1"
if (-not (Test-Path -LiteralPath (Join-Path $nativeRoot "wireguard.dll")) -or
    -not (Test-Path -LiteralPath (Join-Path $nativeRoot "tunnel.dll")) -or
    -not (Test-Path -LiteralPath (Join-Path $nativeRoot "wireguard-provenance.json"))) {
    Write-Host "Preparando automáticamente WireGuardNT y tunnel.dll desde fuentes oficiales fijadas..."
    & $wireGuardPreparation -Architecture $Architecture -OutputPath $nativeRoot
}
if ($DriverSigningMode -eq "Test" -or
    -not (Test-Path -LiteralPath (Join-Path $nativeRoot "QriosoNoPing.Wfp.dll")) -or
    -not (Test-Path -LiteralPath (Join-Path $driverRoot "QriosoNoPing.Wfp.sys")) -or
    -not (Test-Path -LiteralPath (Join-Path $driverRoot "QriosoNoPing.Wfp.inf")) -or
    -not (Test-Path -LiteralPath (Join-Path $driverRoot "QriosoNoPing.Wfp.cat"))) {
    Write-Host "Compilando automáticamente el componente nativo WFP..."
    & $nativeBuild -Architecture $Architecture -Configuration $Configuration -OutputPath $nativeRoot
}
$nativeFiles = @(
    (Join-Path $nativeRoot "tunnel.dll"), (Join-Path $nativeRoot "wireguard.dll"),
    (Join-Path $nativeRoot "wireguard-provenance.json"),
    (Join-Path $nativeRoot "licenses\WireGuardNT-LICENSE.txt"),
    (Join-Path $nativeRoot "licenses\WireGuard-Windows-COPYING.txt"),
    (Join-Path $nativeRoot "QriosoNoPing.Wfp.dll"), (Join-Path $driverRoot "QriosoNoPing.Wfp.sys"),
    (Join-Path $driverRoot "QriosoNoPing.Wfp.inf"), (Join-Path $driverRoot "QriosoNoPing.Wfp.cat")
)
foreach ($requiredPath in $nativeFiles) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Falta el artefacto nativo obligatorio: $requiredPath" }
}
$certificate = Get-CodeSigningCertificate $SigningCertificateThumbprint
$thumbprint = $certificate.Thumbprint.ToUpperInvariant()
if ($DriverSigningMode -eq "Microsoft" -and
    ($certificate.Subject -match "Development" -or $certificate.Subject -eq $certificate.Issuer)) {
    throw "El build Microsoft exige un certificado Authenticode público de Qrioso; el certificado local Development solo sirve con -DriverSigningMode Test."
}
$signTool = Get-SignTool
if ($DriverSigningMode -eq "Test") {
    & $testDriverPreparation -SigningCertificateThumbprint $thumbprint -DriverPath $driverRoot -TimestampServer $TimestampServer
}
Invoke-QriosoSign -Path (Join-Path $nativeRoot "tunnel.dll") -SignTool $signTool -Thumbprint $thumbprint -Certificate $certificate -TimestampUrl $TimestampServer
Invoke-QriosoSign -Path (Join-Path $nativeRoot "QriosoNoPing.Wfp.dll") -SignTool $signTool -Thumbprint $thumbprint -Certificate $certificate -TimestampUrl $TimestampServer
Assert-ValidSignature (Join-Path $nativeRoot "tunnel.dll")
$provenancePath = Join-Path $nativeRoot "wireguard-provenance.json"
$provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
if (-not $provenance.PSObject.Properties["tunnelDllSourceBuildSha256"]) {
    $provenance | Add-Member -NotePropertyName tunnelDllSourceBuildSha256 -NotePropertyValue $provenance.tunnelDllSha256
}
$provenance.tunnelDllSha256 = (Get-FileHash -LiteralPath (Join-Path $nativeRoot "tunnel.dll") -Algorithm SHA256).Hash
$provenance | Add-Member -NotePropertyName qriosoSigningCertificateThumbprint -NotePropertyValue $thumbprint -Force
$provenance | Add-Member -NotePropertyName packagedAtUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString("O")) -Force
[IO.File]::WriteAllText($provenancePath, ($provenance | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$wireGuardSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $nativeRoot "wireguard.dll")
if ($wireGuardSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
    $wireGuardSignature.SignerCertificate.Subject -notmatch "WireGuard") {
    throw "wireguard.dll no conserva la firma oficial de WireGuard."
}
if ($DriverSigningMode -eq "Microsoft") {
    Assert-MicrosoftDriverCatalog (Join-Path $driverRoot "QriosoNoPing.Wfp.cat")
}
else {
    $testCatalogSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $driverRoot "QriosoNoPing.Wfp.cat")
    if ($testCatalogSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $testCatalogSignature.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $thumbprint) {
        throw "El catálogo de prueba no está firmado por el certificado Development seleccionado."
    }
}
$catalog = Test-FileCatalog -Path $driverRoot -CatalogFilePath (Join-Path $driverRoot "QriosoNoPing.Wfp.cat") -Detailed
if ($catalog.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "El catálogo del driver WFP no coincide con el paquete o no tiene una firma válida."
}

$outputRoot = Join-Path $root "dist\windows"
$packageRoot = Join-Path $outputRoot "QriosoNoPing-win-$Architecture"
$appOutput = Join-Path $packageRoot "app"
$serviceOutput = Join-Path $packageRoot "service"
$serviceNativeOutput = Join-Path $serviceOutput "native"
$archive = Join-Path $outputRoot "QriosoNoPing-win-$Architecture.zip"
if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
New-Item -ItemType Directory -Path $appOutput -Force | Out-Null
New-Item -ItemType Directory -Path $serviceOutput -Force | Out-Null

Write-Host "1/6 Restaurando y ejecutando pruebas..."
& dotnet test (Join-Path $windowsRoot "tests\QriosoNoPing.Core.Tests\QriosoNoPing.Core.Tests.csproj") --configuration $Configuration
if ($LASTEXITCODE -ne 0) { throw "Fallaron las pruebas .NET." }
Write-Host "2/6 Compilando la aplicación WinUI autocontenida..."
& dotnet publish (Join-Path $windowsRoot "src\QriosoNoPing.App\QriosoNoPing.App.csproj") --configuration $Configuration --runtime "win-$Architecture" --self-contained true -p:Platform=$Architecture --output $appOutput
if ($LASTEXITCODE -ne 0) { throw "Falló la compilación de la aplicación WinUI." }
Write-Host "3/6 Compilando el Windows Service autocontenido..."
& dotnet publish (Join-Path $windowsRoot "src\QriosoNoPing.Service\QriosoNoPing.Service.csproj") --configuration $Configuration --runtime "win-$Architecture" --self-contained true -p:PublishSingleFile=true --output $serviceOutput
if ($LASTEXITCODE -ne 0) { throw "Falló la compilación del Windows Service." }

New-Item -ItemType Directory -Path (Join-Path $serviceNativeOutput "driver") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $serviceNativeOutput "licenses") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $nativeRoot "tunnel.dll") -Destination $serviceNativeOutput
Copy-Item -LiteralPath (Join-Path $nativeRoot "wireguard.dll") -Destination $serviceNativeOutput
Copy-Item -LiteralPath (Join-Path $nativeRoot "wireguard-provenance.json") -Destination $serviceNativeOutput
Copy-Item -LiteralPath (Join-Path $nativeRoot "licenses\WireGuardNT-LICENSE.txt") -Destination (Join-Path $serviceNativeOutput "licenses")
Copy-Item -LiteralPath (Join-Path $nativeRoot "licenses\WireGuard-Windows-COPYING.txt") -Destination (Join-Path $serviceNativeOutput "licenses")
Copy-Item -LiteralPath (Join-Path $nativeRoot "QriosoNoPing.Wfp.dll") -Destination $serviceNativeOutput
Copy-Item -LiteralPath (Join-Path $driverRoot "QriosoNoPing.Wfp.sys") -Destination (Join-Path $serviceNativeOutput "driver")
Copy-Item -LiteralPath (Join-Path $driverRoot "QriosoNoPing.Wfp.inf") -Destination (Join-Path $serviceNativeOutput "driver")
Copy-Item -LiteralPath (Join-Path $driverRoot "QriosoNoPing.Wfp.cat") -Destination (Join-Path $serviceNativeOutput "driver")
Copy-Item (Join-Path $windowsRoot "packaging\install.ps1") $packageRoot
Copy-Item (Join-Path $windowsRoot "packaging\uninstall.ps1") $packageRoot
Copy-Item (Join-Path $windowsRoot "packaging\LEEME.txt") $packageRoot
[IO.File]::WriteAllText((Join-Path $packageRoot "driver-signing-mode.txt"), $DriverSigningMode, [Text.UTF8Encoding]::new($false))
$installerPath = Join-Path $packageRoot "install.ps1"
$installer = [IO.File]::ReadAllText($installerPath)
$installer = $installer.Replace("__ACCESS_API_BASE_URI__", $accessUri.AbsoluteUri.TrimEnd('/'))
$installer = $installer.Replace("__TLS_SPKI_PIN__", $TlsSpkiPin)
$installer = $installer.Replace("__SIGNER_THUMBPRINT__", $thumbprint)
if ($installer.Contains("__ACCESS_API_BASE_URI__") -or $installer.Contains("__TLS_SPKI_PIN__") -or $installer.Contains("__SIGNER_THUMBPRINT__")) { throw "No se pudieron sellar los parámetros del instalador." }
[IO.File]::WriteAllText($installerPath, $installer, [Text.UTF8Encoding]::new($false))
$uninstallerPath = Join-Path $packageRoot "uninstall.ps1"
$uninstaller = [IO.File]::ReadAllText($uninstallerPath).Replace("__SIGNER_THUMBPRINT__", $thumbprint)
if ($uninstaller.Contains("__SIGNER_THUMBPRINT__")) { throw "No se pudo sellar el desinstalador." }
[IO.File]::WriteAllText($uninstallerPath, $uninstaller, [Text.UTF8Encoding]::new($false))

Write-Host "4/6 Firmando ejecutables, bibliotecas y scripts..."
$signTargets = @(
    Get-ChildItem -LiteralPath $appOutput -Recurse -File | Where-Object { $_.Extension -in ".exe", ".dll" }
    Get-ChildItem -LiteralPath $serviceOutput -Recurse -File | Where-Object { $_.Extension -in ".exe", ".dll" }
    Get-Item -LiteralPath (Join-Path $packageRoot "install.ps1")
    Get-Item -LiteralPath (Join-Path $packageRoot "uninstall.ps1")
)
foreach ($target in $signTargets) {
    Invoke-QriosoSign -Path $target.FullName -SignTool $signTool -Thumbprint $thumbprint -Certificate $certificate -TimestampUrl $TimestampServer -PreserveExistingValidSignature
    Assert-ValidSignature $target.FullName
}
$qriosoSignedTargets = @(
    (Join-Path $appOutput "Qrioso NoPing.exe"),
    (Join-Path $serviceOutput "Qrioso NoPing Service.exe"),
    (Join-Path $serviceNativeOutput "tunnel.dll"),
    (Join-Path $serviceNativeOutput "QriosoNoPing.Wfp.dll"),
    (Join-Path $packageRoot "install.ps1"),
    (Join-Path $packageRoot "uninstall.ps1")
)
foreach ($target in $qriosoSignedTargets) {
    $actualThumbprint = (Get-AuthenticodeSignature -LiteralPath $target).SignerCertificate.Thumbprint.ToUpperInvariant()
    if ($actualThumbprint -ne $thumbprint) { throw "El artefacto principal no quedó firmado por Qrioso: $target" }
}

Write-Host "5/6 Generando manifiesto firmado de integridad..."
$manifestPath = Join-Path $packageRoot "integrity.psd1"
$manifestLines = [Collections.Generic.List[string]]::new()
[void]$manifestLines.Add("@{")
Get-ChildItem -LiteralPath $packageRoot -Recurse -Force -File | Where-Object { $_.FullName -ne $manifestPath } | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($packageRoot, $_.FullName).Replace('/', '\')
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    $escapedRelative = $relative.Replace("'", "''")
    [void]$manifestLines.Add("    '$escapedRelative' = '$hash'")
}
[void]$manifestLines.Add("}")
[IO.File]::WriteAllLines($manifestPath, $manifestLines, [Text.UTF8Encoding]::new($false))
Invoke-QriosoSign -Path $manifestPath -SignTool $signTool -Thumbprint $thumbprint -Certificate $certificate -TimestampUrl $TimestampServer
Assert-ValidSignature $manifestPath

Write-Host "6/6 Creando ZIP de distribución..."
Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $archive -CompressionLevel Optimal
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
Write-Host ""
if ($DriverSigningMode -eq "Microsoft") {
    Write-Host "Build de producción firmado por Microsoft terminado correctamente." -ForegroundColor Green
}
else {
    Write-Host "Build piloto TEST-SIGNED terminado correctamente; úsalo solo en esta PC." -ForegroundColor Yellow
    Write-Warning "Antes de instalar: habilita Test Mode con bcdedit /set testsigning on y reinicia. Secure Boot puede impedir Test Mode."
}
Write-Host "Aplicación: $(Join-Path $appOutput 'Qrioso NoPing.exe')"
Write-Host "Paquete: $archive"
Write-Host "SHA-256: $archiveHash"
Write-Host "Para instalar, descomprime el ZIP y ejecuta install.ps1 como Administrador."
