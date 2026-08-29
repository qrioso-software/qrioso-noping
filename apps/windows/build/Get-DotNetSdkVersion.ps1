Set-StrictMode -Version Latest

function ConvertTo-QriosoDotNetSdkVersion {
    param(
        [object[]]$VersionOutput,
        [int]$ExitCode
    )

    if ($ExitCode -ne 0 -or $VersionOutput.Count -ne 1) { return $null }
    $version = ([string]$VersionOutput[0]).Trim()
    if ($version -notmatch "^\d+\.\d+\.\d+(?:[-+].+)?$") { return $null }
    return $version
}

function Get-QriosoDotNetSdkVersion {
    param(
        [string]$DotNetExecutable
    )

    if ([string]::IsNullOrWhiteSpace($DotNetExecutable)) {
        $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        if (-not $dotnetCommand) { return $null }
        $DotNetExecutable = $dotnetCommand.Source
    }

    try {
        $versionOutput = @(& $DotNetExecutable --version 2>$null)
        $exitCode = $LASTEXITCODE
    }
    catch {
        return $null
    }
    return ConvertTo-QriosoDotNetSdkVersion -VersionOutput $versionOutput -ExitCode $exitCode
}
