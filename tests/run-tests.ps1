# Runner tests with a fake Claude worker (no API calls).
# Usage: powershell -ExecutionPolicy Bypass -File tests/run-tests.ps1 [-WorkDir <dir>]
param([string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'openspec-auto-tests'))

$ErrorActionPreference = 'Continue'
$Tool = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $Tool 'openspec-auto.ps1'
$Fake = Join-Path $PSScriptRoot 'fake-claude.cmd'
$os = 'openspec'
if (Get-Command 'openspec.cmd' -ErrorAction SilentlyContinue) { $os = 'openspec.cmd' }
$script:Failed = 0

function Check([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "    ok   $Msg" -ForegroundColor Green }
    else { Write-Host "    FAIL $Msg" -ForegroundColor Red; $script:Failed++ }
}

function New-Change([string]$Name, [int]$Tasks) {
    & $os new change $Name 2>&1 | Out-Null
    $d = "openspec/changes/$Name"
    Set-Content "$d/proposal.md" "## Why`nThe project needs the capability described by change $Name for testing auto-mode.`n## What Changes`n- Add $Name.`n"
    Set-Content "$d/design.md" "## Decisions`n- Keep it simple.`n"
    $t = "## 1. Impl`n"; for ($i = 1; $i -le $Tasks; $i++) { $t += "- [ ] 1.$i Task $i`n" }
    Set-Content "$d/tasks.md" $t
    $cap = "cap-$($Name -replace '^\d+-', '')"
    New-Item -ItemType Directory -Force "$d/specs/$cap" | Out-Null
    Set-Content "$d/specs/$cap/spec.md" "## ADDED Requirements`n### Requirement: $Name works`nThe system SHALL support $Name.`n#### Scenario: Basic`n- **WHEN** used`n- **THEN** it works`n"
}

function New-Project([string]$Name, [string[]]$Changes) {
    $p = Join-Path $WorkDir $Name
    $remote = Join-Path $WorkDir "$Name-remote.git"
    Remove-Item -Recurse -Force $p, $remote -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $p | Out-Null
    git init -q --bare $remote 2>&1 | Out-Null
    Push-Location $p
    git init -q -b main 2>&1 | Out-Null
    git config user.name 'Test'; git config user.email 'test@example.com'; git config core.autocrlf false
    Set-Content .gitattributes '* text=auto eol=lf'
    & $os init --tools none --no-animation 2>&1 | Out-Null
    foreach ($c in $Changes) { $n, $k = $c -split ':'; New-Change $n ([int]$k) }
    Set-Content 'openspec/auto-mode.json' '{ "testCommand": "echo ok", "timeoutMinutes": 2, "maxRunsPerChange": 5 }'
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
    git remote add origin $remote; git push -q origin main 2>&1 | Out-Null
    Pop-Location
    $p
}

function Invoke-Runner([string]$P, [string]$Plan) {
    $env:FAKE_PLAN = $Plan
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Runner -Project $P -ClaudeCommand $Fake 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    Set-Content (Join-Path $WorkDir ((Split-Path -Leaf $P) + '.log')) $out
    [pscustomobject]@{ Code = $code; Out = ($out -join "`n") }
}

function Archived([string]$P, [string]$C) { [bool](Get-ChildItem "$P/openspec/changes/archive" -Directory | Where-Object { $_.Name -match "^\d{4}-\d{2}-\d{2}-$C$" }) }
function Active([string]$P, [string]$C) { Test-Path "$P/openspec/changes/$C" }
function GitIn([string]$P) { Push-Location $P; $r = (& git @args 2>&1 | ForEach-Object { "$_" }) -join "`n"; Pop-Location; $r.Trim() }
function Clean([string]$P) { (GitIn $P status --porcelain) -eq '' }

New-Item -ItemType Directory -Force $WorkDir | Out-Null

Write-Host "T1 success + multi-run change (context cleared between runs)"
$p = New-Project 't1' @('01-a:2', '02-b:3', 'fix-old:1')
$r = Invoke-Runner $p '01-a=success;02-b=continue'
Check ($r.Code -eq 0) 'runner exit 0'
Check ((Archived $p '01-a') -and (Archived $p '02-b')) 'both changes archived'
Check (Active $p 'fix-old') 'fix-old untouched (not processed)'
Push-Location $p; git merge-base --is-ancestor auto/01-a auto/02-b; $anc = $LASTEXITCODE; Pop-Location
Check ($anc -eq 0) 'auto/02-b is based on auto/01-a'
Check ((Get-ChildItem "$p/.openspec-auto/runs/*/02-b.run*.prompt.txt").Count -eq 3) '02-b processed in 3 separate processes'
Check ((GitIn $p rev-parse origin/main) -eq (GitIn $p rev-parse main)) 'nothing pushed'
Check (Clean $p) 'git status clean (report is git-excluded)'
Check (Test-Path "$p/.openspec-auto/auto-mode-report.md") 'report written'

Write-Host "T2 non-critical error"
$p = New-Project 't2' @('01-a:2', '02-b:1')
$r = Invoke-Runner $p '01-a=noncritical;02-b=success'
Check ($r.Code -eq 0) 'runner exit 0'
Check ((Archived $p '01-a') -and (Archived $p '02-b')) 'both archived'
Check (Active $p 'fix-01-a') 'fix-01-a created and not implemented'
Check ($r.Out -match 'NONCRITICAL') 'report shows NONCRITICAL'

Write-Host "T3 critical error, refuse to start, resume after resolution"
$p = New-Project 't3' @('01-a:1', '02-b:1')
$r = Invoke-Runner $p '01-a=blocked;02-b=success'
Check ($r.Code -eq 1) 'runner stops (exit 1)'
Check ((Active $p '01-a') -and (Test-Path "$p/openspec/changes/01-a/BLOCKED.md")) '01-a not archived, BLOCKED.md exists'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/02-b.run01.prompt.txt")) '02-b not processed'
$r = Invoke-Runner $p '01-a=success;02-b=success'
Check ($r.Code -eq 2 -and $r.Out -match 'is blocked') 'restart refused while BLOCKED.md exists'
Push-Location $p; git rm -q openspec/changes/01-a/BLOCKED.md 2>&1 | Out-Null; git commit -q -m resolved 2>&1 | Out-Null; Pop-Location
$r = Invoke-Runner $p '01-a=success;02-b=success'
Check ($r.Code -eq 0) 'resumed run finishes'
Check ((Archived $p '01-a') -and (Archived $p '02-b')) 'both archived after resume'
Check ($r.Out -match 'resum') 'report marks the run as resumed'

Write-Host "T4 push attempts"
$p = New-Project 't4' @('01-a:1', '02-b:1')
$r = Invoke-Runner $p '01-a=push;02-b=success'
Check ($r.Code -eq 1) 'runner stops'
Check ($r.Out -match 'remote-tracking refs changed') 'hook-bypassing push detected'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/02-b.run01.prompt.txt")) '02-b not processed'
Push-Location $p; $env:OPENSPEC_AUTO_MODE = '1'; git push -q origin main 2>&1 | Out-Null; $hookCode = $LASTEXITCODE; Remove-Item Env:OPENSPEC_AUTO_MODE; Pop-Location
Check ($hookCode -ne 0) 'pre-push hook refuses push with OPENSPEC_AUTO_MODE=1'

Write-Host "T5 missing write (dirty tree) and no progress"
$p = New-Project 't5' @('01-a:1', '02-b:1')
$r = Invoke-Runner $p '01-a=dirty;02-b=success'
Check ($r.Code -eq 1 -and $r.Out -match 'not clean') 'dirty tree stops the loop'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/02-b.run01.prompt.txt")) '02-b not processed'
$p = New-Project 't5b' @('01-a:1')
$r = Invoke-Runner $p '01-a=noop'
Check ($r.Code -eq 1 -and $r.Out -match 'no progress') 'run without progress stops the loop'
$p = New-Project 't5c' @('01-a:1')
$r = Invoke-Runner $p '01-a=crash'
Check ($r.Code -eq 1 -and $r.Out -match 'exited with code') 'crashed run stops the loop'

Write-Host "T6 only fix changes"
$p = New-Project 't6' @('fix-login:1')
$r = Invoke-Runner $p ''
Check ($r.Code -eq 2 -and $r.Out -match 'no active numbered changes') 'fix changes are skipped'

Write-Host "T7 incomplete propose is refused at start"
$p = New-Project 't7' @('01-a:1', '02-b:1', '03-c:1', '04-d:1')
Push-Location $p
Remove-Item openspec/changes/02-b/design.md
Set-Content openspec/changes/03-c/specs/cap-c/spec.md "## ADDED Requirements`n### Requirement: No scenario`nThe system SHALL do c.`n"
Set-Content openspec/changes/04-d/tasks.md "## 1. Impl`nnothing yet`n"
git add -A 2>&1 | Out-Null; git commit -q -m broken 2>&1 | Out-Null
Pop-Location
$r = Invoke-Runner $p '01-a=success;02-b=success;03-c=success;04-d=success'
Check ($r.Code -eq 2) 'runner refuses to start (exit 2)'
Check ($r.Out -match '02-b is not ready.*missing artifacts: design') 'missing design.md reported'
Check ($r.Out -match '03-c is not ready.*validate failed') 'invalid spec delta reported'
Check ($r.Out -match '04-d is not ready.*no tasks') 'empty tasks.md reported'
Check ($r.Out -notmatch '01-a is not ready') 'complete change not reported'
Check (-not (Test-Path "$p/.openspec-auto/runs")) 'no agent run started'

Write-Host ''
if ($script:Failed) { Write-Host "$script:Failed check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
