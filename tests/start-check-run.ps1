# Starts a long fake run with -Background in the check project (see new-check-project.ps1).
# The fake worker waits -Seconds, then finishes the change. Nothing is paid.
param(
    [string]$Path = (Join-Path ([System.IO.Path]::GetTempPath()) 'osa-realcheck'),
    [int]$Seconds = 240
)
$tool = Split-Path -Parent $PSScriptRoot
$env:FAKE_PLAN = '01-check=long'
$env:FAKE_SLEEP_SECONDS = [string]$Seconds
# fake runs stay out of the user's cost dashboard
$env:OSA_HISTORY_DIR = Join-Path ([System.IO.Path]::GetTempPath()) 'osa-check-dashboard'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tool 'openspec-auto.ps1') -Project $Path -ClaudeCommand (Join-Path $PSScriptRoot 'fake-claude.cmd') -Background
exit $LASTEXITCODE
