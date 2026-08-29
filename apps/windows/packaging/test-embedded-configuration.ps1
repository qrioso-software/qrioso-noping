[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$infraReaderPath = Join-Path $repositoryRoot "apps\windows\build\Read-InfraEnvironment.ps1"
. $infraReaderPath
. (Join-Path $repositoryRoot "apps\windows\build\Test-CodeSigningCertificate.ps1")
. (Join-Path $repositoryRoot "apps\windows\build\Get-DotNetSdkVersion.ps1")
foreach ($scriptPath in @(
    (Join-Path $repositoryRoot "build-windows.ps1"),
    (Join-Path $repositoryRoot "build-windows-pilot.ps1"),
    (Join-Path $repositoryRoot "clean-windows-pilot.ps1"),
    (Join-Path $repositoryRoot "apps\windows\build\Test-CodeSigningCertificate.ps1"),
    (Join-Path $repositoryRoot "apps\windows\build\Get-DotNetSdkVersion.ps1"),
    (Join-Path $repositoryRoot "apps\windows\build\Install-NativeBuildDependencies.ps1")
)) {
    $parseTokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell inválido en $scriptPath`: $($parseErrors[0].Message)"
    }
}

$detectedSdkVersion = ConvertTo-QriosoDotNetSdkVersion -VersionOutput @("10.0.100") -ExitCode 0
if ($detectedSdkVersion -ne "10.0.100") {
    throw "No se reconoció una salida válida de .NET SDK 10."
}
if ((ConvertTo-QriosoDotNetSdkVersion -VersionOutput @() -ExitCode 1) -or
    (ConvertTo-QriosoDotNetSdkVersion -VersionOutput @("PowerShell 7.5.4") -ExitCode 0)) {
    throw "Se aceptó una salida que no corresponde a un .NET SDK válido."
}

$infraReaderSource = [IO.File]::ReadAllText($infraReaderPath)
if ($infraReaderSource.Contains(".TryAdd(", [StringComparison]::Ordinal)) {
    throw "Read-InfraEnvironment.ps1 usa Dictionary.TryAdd, que no existe en Windows PowerShell 5.1/.NET Framework."
}

$codeSigningOids = [System.Security.Cryptography.OidCollection]::new()
[void]$codeSigningOids.Add([System.Security.Cryptography.Oid]::new("1.3.6.1.5.5.7.3.3"))
$codeSigningExtension = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
    $codeSigningOids,
    $false
)
$certificateWithCodeSigning = [PSCustomObject]@{ Extensions = @($codeSigningExtension) }
if (-not (Test-QriosoCodeSigningCertificate -Certificate $certificateWithCodeSigning)) {
    throw "No se reconoció una extensión EKU válida de Code Signing."
}
$certificateWithoutCodeSigning = [PSCustomObject]@{ Extensions = @() }
if (Test-QriosoCodeSigningCertificate -Certificate $certificateWithoutCodeSigning) {
    throw "Se aceptó un certificado sin la extensión EKU de Code Signing."
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "qrioso-embedded-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $validEnvironmentPath = Join-Path $temporaryRoot ".env.infra"
    [IO.File]::WriteAllText($validEnvironmentPath, @"
AccessApiBaseUri=https://relay.example:8443
TlsSpkiPin=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AccessToken=qnp_pilot-windows_AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@, [Text.UTF8Encoding]::new($false))
    $parsed = Read-QriosoInfraEnvironment -Path $validEnvironmentPath
    if ($parsed.AccessApiBaseUri -ne "https://relay.example:8443" -or
        $parsed.AccessToken -ne "qnp_pilot-windows_AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") {
        throw "El contrato de .env.infra no produjo la configuración incrustable esperada."
    }

    $duplicateEnvironmentPath = Join-Path $temporaryRoot "duplicate.env.infra"
    [IO.File]::WriteAllText($duplicateEnvironmentPath, @"
AccessApiBaseUri=https://relay.example:8443
TlsSpkiPin=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AccessToken=qnp_pilot-windows_AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AccessToken=qnp_pilot-windows_AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@, [Text.UTF8Encoding]::new($false))
    try {
        Read-QriosoInfraEnvironment -Path $duplicateEnvironmentPath | Out-Null
        throw "Se aceptó una clave duplicada en .env.infra."
    }
    catch {
        if ($_.Exception.Message -eq "Se aceptó una clave duplicada en .env.infra.") { throw }
    }

    $invalidEnvironmentPath = Join-Path $temporaryRoot "invalid.env.infra"
    [IO.File]::WriteAllText($invalidEnvironmentPath, @"
AccessApiBaseUri=https://relay.example:8443
TlsSpkiPin=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AccessToken=invalid
"@, [Text.UTF8Encoding]::new($false))
    try {
        Read-QriosoInfraEnvironment -Path $invalidEnvironmentPath | Out-Null
        throw "Se aceptó un AccessToken inválido."
    }
    catch {
        if ($_.Exception.Message -eq "Se aceptó un AccessToken inválido.") { throw }
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

$configurationPath = Join-Path $repositoryRoot "apps\windows\src\QriosoNoPing.Service\ServiceConfiguration.cs"
$configurationSource = [IO.File]::ReadAllText($configurationPath)
foreach ($requiredValue in @(
    'GetCustomAttributes<AssemblyMetadataAttribute>()',
    'Required("AccessApiBaseUri")',
    'Required("TlsSpkiPin")',
    'Required("AccessToken")',
    'AccessToken.TryParse(PilotAccessToken',
    'FortniteClient-Win64-Shipping.exe',
    'FortniteClient-Win64-Shipping_BE.exe',
    'FortniteClient-Win64-Shipping_EAC_EOS.exe'
)) {
    if (-not $configurationSource.Contains($requiredValue, [StringComparison]::Ordinal)) {
        throw "Falta configuración compilada en ServiceConfiguration.cs: $requiredValue"
    }
}
foreach ($forbiddenValue in @('QRIOSO_NOPING_CONFIG', 'config.json', 'File.OpenRead', 'qnp_pilot-windows_')) {
    if ($configurationSource.Contains($forbiddenValue, [StringComparison]::Ordinal)) {
        throw "ServiceConfiguration.cs todavía depende de configuración externa: $forbiddenValue"
    }
}

$controllerSource = [IO.File]::ReadAllText((Join-Path $repositoryRoot "apps\windows\src\QriosoNoPing.Service\NetworkController.cs"))
if (-not $controllerSource.Contains('RegisterAsync(configuration.PilotAccessToken', [StringComparison]::Ordinal)) {
    throw "NetworkController no registra automáticamente la llave compilada durante el primer arranque."
}

$installerSource = [IO.File]::ReadAllText((Join-Path $repositoryRoot "apps\windows\packaging\install.ps1"))
foreach ($forbiddenValue in @('__ACCESS_API_BASE_URI__', '__TLS_SPKI_PIN__', 'Write-QriosoConfiguration')) {
    if ($installerSource.Contains($forbiddenValue, [StringComparison]::Ordinal)) {
        throw "install.ps1 todavía intenta escribir configuración externa: $forbiddenValue"
    }
}

$buildSource = [IO.File]::ReadAllText((Join-Path $repositoryRoot "build-windows.ps1"))
foreach ($requiredValue in @(
    'Read-QriosoInfraEnvironment',
    'QriosoNoPing.EmbeddedConfiguration.g.cs',
    'AssemblyMetadata("QriosoNoPing.AccessApiBaseUri"',
    'AssemblyMetadata("QriosoNoPing.TlsSpkiPin"',
    'AssemblyMetadata("QriosoNoPing.AccessToken"'
)) {
    if (-not $buildSource.Contains($requiredValue, [StringComparison]::Ordinal)) {
        throw "build-windows.ps1 no incrusta la configuración esperada: $requiredValue"
    }
}

$pilotBuildSource = [IO.File]::ReadAllText((Join-Path $repositoryRoot "build-windows-pilot.ps1"))
foreach ($requiredValue in @('Install-QriosoDotNetSdk10', 'Microsoft.DotNet.SDK.10', 'Get-QriosoDotNetSdkVersion', 'Install-QriosoNativeBuildDependencies')) {
    if (-not $pilotBuildSource.Contains($requiredValue, [StringComparison]::Ordinal)) {
        throw "build-windows-pilot.ps1 no prepara automáticamente .NET SDK 10: $requiredValue"
    }
}

$pilotCleanupSource = [IO.File]::ReadAllText((Join-Path $repositoryRoot "clean-windows-pilot.ps1"))
foreach ($requiredValue in @(
    'QriosoNoPingWfp',
    'QriosoNoPing.Wfp.sys',
    '/delete-driver',
    '/uninstall',
    '/force',
    '/set testsigning off',
    'CN=Qrioso Software Consulting Development',
    'Restart-Computer -Force'
)) {
    if (-not $pilotCleanupSource.Contains($requiredValue, [StringComparison]::OrdinalIgnoreCase)) {
        throw "clean-windows-pilot.ps1 no contiene la limpieza esperada: $requiredValue"
    }
}

$nativeDependenciesSource = [IO.File]::ReadAllText((Join-Path $repositoryRoot "apps\windows\build\Install-NativeBuildDependencies.ps1"))
foreach ($requiredValue in @(
    'Microsoft.VisualStudio.2022.BuildTools',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre',
    'Component.Microsoft.Windows.DriverKit.BuildTools',
    'Microsoft.WindowsSDK.10.0.26100',
    'Microsoft.WindowsWDK.10.0.26100',
    'Inf2Cat.exe',
    'InfVerif.exe',
    'WindowsDriver.Common.targets'
)) {
    if (-not $nativeDependenciesSource.Contains($requiredValue, [StringComparison]::Ordinal)) {
        throw "El bootstrap nativo no contiene el requisito esperado: $requiredValue"
    }
}

Write-Host "Contrato del piloto, configuración compilada y autorregistro validados."
