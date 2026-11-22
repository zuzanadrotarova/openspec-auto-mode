# Creates a small project for the manual checks of docs/memory-pressure-plan.md section 13
# (fake worker, nothing is paid). Usage:
#   powershell -ExecutionPolicy Bypass -File tests/new-check-project.ps1 [-Path <dir>]
# then start a run with tests/start-check-run.ps1.
param([string]$Path = (Join-Path ([System.IO.Path]::GetTempPath()) 'osa-realcheck'))

$ErrorActionPreference = 'Continue'
$os = 'openspec'
if (Get-Command 'openspec.cmd' -ErrorAction SilentlyContinue) { $os = 'openspec.cmd' }
Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Path | Out-Null
Push-Location $Path
git init -q -b main 2>&1 | Out-Null
git config user.name 'Check'; git config user.email 'check@example.com'; git config core.autocrlf false
Set-Content .gitattributes '* text=auto eol=lf'
& $os init --tools none --no-animation 2>&1 | Out-Null
& $os new change '01-check' 2>&1 | Out-Null
$d = 'openspec/changes/01-check'
Set-Content "$d/proposal.md" "## Why`nThe project needs a change for the manual checks of auto-mode.`n## What Changes`n- Add 01-check.`n"
Set-Content "$d/design.md" "## Decisions`n- Keep it simple.`n"
Set-Content "$d/tasks.md" "## 1. Check`n- [ ] 1.1 Wait`n"
New-Item -ItemType Directory -Force "$d/specs/cap-check" | Out-Null
Set-Content "$d/specs/cap-check/spec.md" "## ADDED Requirements`n### Requirement: Check works`nThe system SHALL support the check.`n#### Scenario: Basic`n- **WHEN** used`n- **THEN** it works`n"
Set-Content 'openspec/auto-mode.json' '{ "testCommand": ".\\run-tests.cmd", "timeoutMinutes": 30, "maxRunsPerChange": 5 }'
Set-Content 'run-tests.cmd' '@echo ok'
git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
Pop-Location
Write-Host "check project ready: $Path"
