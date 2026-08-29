#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue; $gitPath = if ($gitCommand) { $gitCommand.Source } else { Join-Path $env:ProgramFiles "Git\cmd\git.exe" }; if (-not (Test-Path -LiteralPath $gitPath)) { throw "Git for Windows no esta disponible; actualiza el repositorio manualmente antes de limpiar el piloto." }; & $gitPath pull --ff-only origin main; if ($LASTEXITCODE -ne 0) { throw "git pull fallo; no se ejecuto una copia posiblemente desactualizada de la limpieza." }; Set-ExecutionPolicy -Scope Process Bypass -Force; & ".\clean-windows-pilot.ps1"'
