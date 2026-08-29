#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'git pull --ff-only origin main; if ($LASTEXITCODE -eq 0) { Set-ExecutionPolicy -Scope Process Bypass -Force; & ".\build-windows-pilot.ps1" }'
