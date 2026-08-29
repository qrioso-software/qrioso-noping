#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'Set-ExecutionPolicy -Scope Process Bypass -Force; & ".\build-windows-pilot.ps1"'
