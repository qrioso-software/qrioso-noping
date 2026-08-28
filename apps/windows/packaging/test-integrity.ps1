[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$installerPath = Join-Path $PSScriptRoot "install.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "install.ps1 no se pudo analizar." }
$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Assert-StagedPayloadIntegrity"
}, $true)
if ($null -eq $functionAst) { throw "No se encontró Assert-StagedPayloadIntegrity." }
. ([ScriptBlock]::Create($functionAst.Extent.Text))

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "qrioso-installer-test-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot "app"), (Join-Path $testRoot "service") | Out-Null
    [IO.File]::WriteAllText((Join-Path $testRoot "app\app.exe"), "app")
    [IO.File]::WriteAllText((Join-Path $testRoot "service\service.exe"), "service")
    [IO.File]::WriteAllText((Join-Path $testRoot "uninstall.ps1"), "uninstall")
    $manifest = @{
        "app\app.exe" = (Get-FileHash -LiteralPath (Join-Path $testRoot "app\app.exe") -Algorithm SHA256).Hash
        "service\service.exe" = (Get-FileHash -LiteralPath (Join-Path $testRoot "service\service.exe") -Algorithm SHA256).Hash
        "uninstall.ps1" = (Get-FileHash -LiteralPath (Join-Path $testRoot "uninstall.ps1") -Algorithm SHA256).Hash
    }

    Assert-StagedPayloadIntegrity -StagingRoot $testRoot -Manifest $manifest

    [IO.File]::WriteAllText((Join-Path $testRoot "service\service.exe"), "tampered")
    try {
        Assert-StagedPayloadIntegrity -StagingRoot $testRoot -Manifest $manifest
        throw "La prueba esperaba que un archivo alterado fuera rechazado."
    }
    catch {
        if ($_.Exception.Message -like "La prueba esperaba*") { throw }
    }

    [IO.File]::WriteAllText((Join-Path $testRoot "service\service.exe"), "service")
    [IO.File]::WriteAllText((Join-Path $testRoot "service\.hidden"), "unexpected")
    try {
        Assert-StagedPayloadIntegrity -StagingRoot $testRoot -Manifest $manifest
        throw "La prueba esperaba que un archivo oculto no autorizado fuera rechazado."
    }
    catch {
        if ($_.Exception.Message -like "La prueba esperaba*") { throw }
    }

    Write-Host "Installer staged-integrity checks passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
