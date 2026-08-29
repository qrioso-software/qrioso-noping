Set-StrictMode -Version Latest

function Get-QriosoVisualStudioBuildToolsPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $null }

    $installations = @(& $vswhere `
        -latest `
        -products Microsoft.VisualStudio.Product.BuildTools `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Component.Microsoft.Windows.DriverKit.BuildTools `
        -property installationPath)
    if ($LASTEXITCODE -ne 0 -or $installations.Count -eq 0) { return $null }

    $installationPath = ([string]$installations[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($installationPath)) { return $null }
    return $installationPath
}

function Get-QriosoAnyVisualStudioBuildToolsPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $null }

    $installations = @(& $vswhere `
        -latest `
        -products Microsoft.VisualStudio.Product.BuildTools `
        -property installationPath)
    if ($LASTEXITCODE -ne 0 -or $installations.Count -eq 0) { return $null }

    $installationPath = ([string]$installations[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($installationPath)) { return $null }
    return $installationPath
}

function Test-QriosoNativeBuildDependencies {
    $installationPath = Get-QriosoVisualStudioBuildToolsPath
    if (-not $installationPath) { return $false }

    $msbuild = Join-Path $installationPath "MSBuild\Current\Bin\MSBuild.exe"
    if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) { return $false }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"
    foreach ($toolName in @("Inf2Cat.exe", "InfVerif.exe")) {
        $tool = Get-ChildItem -LiteralPath (Join-Path $kitsRoot "bin") -Filter $toolName -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*\x64\$toolName" } |
            Select-Object -First 1
        if (-not $tool) { return $false }
    }

    $driverTargets = Get-ChildItem -LiteralPath (Join-Path $kitsRoot "build") -Filter "WindowsDriver.Common.targets" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return $null -ne $driverTargets
}

function Invoke-QriosoWingetInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [string]$Override
    )

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw "winget no está disponible para instalar $PackageId." }

    $arguments = @(
        "install", "--id", $PackageId, "--exact", "--source", "winget",
        "--scope", "machine", "--accept-source-agreements", "--accept-package-agreements"
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) { $arguments += @("--override", $Override) }
    & $winget.Source @arguments | Out-Host
    if ($LASTEXITCODE -notin @(0, 1641, 3010)) {
        throw "winget no pudo instalar $PackageId (código $LASTEXITCODE)."
    }
}

function Install-QriosoNativeBuildDependencies {
    if (Test-QriosoNativeBuildDependencies) { return }

    Write-Host "Instalando Visual Studio 2022 Build Tools, Windows SDK y WDK..." -ForegroundColor Cyan
    $components = @(
        "Microsoft.Component.MSBuild",
        "Microsoft.VisualStudio.Workload.VCTools",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre",
        "Microsoft.VisualStudio.Component.Windows11SDK.26100",
        "Component.Microsoft.Windows.DriverKit.BuildTools"
    )

    $installationPath = Get-QriosoAnyVisualStudioBuildToolsPath
    if (-not $installationPath) {
        $visualStudioArguments = @("--passive", "--wait", "--norestart")
        foreach ($component in $components) { $visualStudioArguments += @("--add", $component) }
        Invoke-QriosoWingetInstall `
            -PackageId "Microsoft.VisualStudio.2022.BuildTools" `
            -Override ($visualStudioArguments -join " ")
    }
    else {
        $visualStudioInstaller = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\setup.exe"
        if (-not (Test-Path -LiteralPath $visualStudioInstaller -PathType Leaf)) {
            throw "No se encontró el instalador de Visual Studio para agregar C++, Spectre y WDK."
        }
        $modifyArguments = @("modify", "--installPath", $installationPath, "--passive", "--wait", "--norestart")
        foreach ($component in $components) { $modifyArguments += @("--add", $component) }
        & $visualStudioInstaller @modifyArguments | Out-Host
        if ($LASTEXITCODE -notin @(0, 1641, 3010)) {
            throw "Visual Studio Installer no pudo agregar el toolchain nativo (código $LASTEXITCODE)."
        }
    }

    Invoke-QriosoWingetInstall -PackageId "Microsoft.WindowsSDK.10.0.26100"
    Invoke-QriosoWingetInstall -PackageId "Microsoft.WindowsWDK.10.0.26100"

    if (-not (Test-QriosoNativeBuildDependencies)) {
        throw "El toolchain nativo terminó de instalarse, pero aún no está disponible. Reinicia Windows y ejecuta otra vez el mismo comando."
    }
    Write-Host "Visual Studio Build Tools, Windows SDK y WDK listos." -ForegroundColor Green
}
