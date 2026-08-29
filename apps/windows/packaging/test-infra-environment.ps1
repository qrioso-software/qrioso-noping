[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\build\Read-InfraEnvironment.ps1")

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
foreach ($scriptPath in @(
    (Join-Path $repositoryRoot "build-windows.ps1"),
    (Join-Path $repositoryRoot "build-windows-pilot.ps1")
)) {
    $parseTokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell inválido en $scriptPath`: $($parseErrors[0].Message)"
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "qrioso-infra-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

function Write-TestFile {
    param([string]$Name, [string]$Content)
    $path = Join-Path $temporaryRoot $Name
    [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
    return $path
}

function Assert-Rejected {
    param([string]$Path, [string]$ExpectedMessage)
    $rejected = $false
    try { Read-QriosoInfraEnvironment -Path $Path | Out-Null }
    catch {
        $rejected = $true
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Mensaje inesperado para $Path`: $($_.Exception.Message)"
        }
    }
    if (-not $rejected) { throw "Se aceptó un InfraEnvironmentFile inválido: $Path" }
}

try {
    $validPath = Write-TestFile -Name "valid.env" -Content @"
# Configuración entregada por infra-up
AccessApiBaseUri=https://52.55.104.171:8443/
TlsSpkiPin=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
"@
    $configuration = Read-QriosoInfraEnvironment -Path $validPath
    if ($configuration.AccessApiBaseUri -ne "https://52.55.104.171:8443" -or
        $configuration.TlsSpkiPin -ne "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") {
        throw "El archivo válido no produjo la configuración esperada."
    }

    Assert-Rejected -Path (Write-TestFile -Name "wrong-key.env" -Content "AccessApiUri=https://52.55.104.171:8443/`nTlsSpkiPin=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`n") -ExpectedMessage "clave no admitida 'AccessApiUri'"
    Assert-Rejected -Path (Write-TestFile -Name "extra-key.env" -Content "AccessApiBaseUri=https://52.55.104.171:8443`nTlsSpkiPin=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`nAWS_PROFILE=ridenow-main`n") -ExpectedMessage "clave no admitida 'AWS_PROFILE'"
    Assert-Rejected -Path (Write-TestFile -Name "duplicate.env" -Content "AccessApiBaseUri=https://52.55.104.171:8443`nAccessApiBaseUri=https://52.55.104.171:8443`nTlsSpkiPin=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`n") -ExpectedMessage "repite la clave 'AccessApiBaseUri'"
    Assert-Rejected -Path (Write-TestFile -Name "missing.env" -Content "AccessApiBaseUri=https://52.55.104.171:8443`n") -ExpectedMessage "clave obligatoria 'TlsSpkiPin'"
    Assert-Rejected -Path (Write-TestFile -Name "bad-pin.env" -Content "AccessApiBaseUri=https://52.55.104.171:8443`nTlsSpkiPin=invalid`n") -ExpectedMessage "TlsSpkiPin debe tener"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host "Contrato .env.infra validado correctamente."
