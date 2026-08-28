[CmdletBinding()]
param(
    [string]$Subject = "CN=Qrioso Software Consulting Development",
    [int]$ValidMonths = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw "Este script debe ejecutarse en Windows." }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ejecuta este script como Administrador."
}
if ($ValidMonths -lt 1 -or $ValidMonths -gt 12) { throw "ValidMonths debe estar entre 1 y 12." }

$certificate = New-SelfSignedCertificate `
    -Subject $Subject `
    -Type CodeSigningCert `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter ([DateTime]::UtcNow.AddMonths($ValidMonths))

$publicCertificate = Join-Path ([IO.Path]::GetTempPath()) ("qrioso-dev-" + [Guid]::NewGuid().ToString("N") + ".cer")
try {
    Export-Certificate -Cert $certificate -FilePath $publicCertificate -Force | Out-Null
    Import-Certificate -FilePath $publicCertificate -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
    Import-Certificate -FilePath $publicCertificate -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null
}
finally {
    if (Test-Path -LiteralPath $publicCertificate) { Remove-Item -LiteralPath $publicCertificate -Force }
}

Write-Host "Certificado local de DESARROLLO creado. Thumbprint: $($certificate.Thumbprint)" -ForegroundColor Green
Write-Host "Úsalo solamente para el piloto Test Mode en esta PC. No sustituye la firma Microsoft de producción ni debe distribuirse."
Write-Host "Al terminar, elimina ese thumbprint de CurrentUser\My, LocalMachine\Root y LocalMachine\TrustedPublisher."
