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

# $Tasks tasks split evenly into $Groups task groups ("## 1. Group 1", "## 2. Group 2", ...).
function New-Change([string]$Name, [int]$Tasks, [int]$Groups = 1) {
    & $os new change $Name 2>&1 | Out-Null
    $d = "openspec/changes/$Name"
    Set-Content "$d/proposal.md" "## Why`nThe project needs the capability described by change $Name for testing auto-mode.`n## What Changes`n- Add $Name.`n"
    Set-Content "$d/design.md" "## Decisions`n- Keep it simple.`n"
    $t = ''; $per = [math]::Ceiling($Tasks / $Groups)
    for ($g = 1; $g -le $Groups; $g++) {
        $t += "## $g. Group $g`n"
        for ($i = 1; $i -le $per -and (($g - 1) * $per + $i) -le $Tasks; $i++) { $t += "- [ ] $g.$i Task $i`n" }
    }
    Set-Content "$d/tasks.md" $t
    $cap = "cap-$($Name -replace '^\d+-', '')"
    New-Item -ItemType Directory -Force "$d/specs/$cap" | Out-Null
    Set-Content "$d/specs/$cap/spec.md" "## ADDED Requirements`n### Requirement: $Name works`nThe system SHALL support $Name.`n#### Scenario: Basic`n- **WHEN** used`n- **THEN** it works`n"
}

$DefaultConfig = '{ "testCommand": ".\\run-tests.cmd", "timeoutMinutes": 2, "maxRunsPerChange": 5 }'

# The project's tests fail while broken.txt exists; the fake agent creates or deletes it.
function New-Project([string]$Name, [string[]]$Changes, [string]$Config = $DefaultConfig) {
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
    foreach ($c in $Changes) {
        $parts = $c -split ':'; $groups = 1
        if ($parts.Count -gt 2) { $groups = [int]$parts[2] }
        New-Change $parts[0] ([int]$parts[1]) $groups
    }
    Set-Content 'openspec/auto-mode.json' $Config
    Set-Content 'run-tests.cmd' '@if exist broken.txt (echo FAIL broken.txt & exit /b 1) else (echo ok)'
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
Check ($r.Out -match 'no failing test observed') 'tests green: fix waits for the human'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/fix-01-a.run01.prompt.txt")) 'fix-01-a not processed by the loop'

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

function Read-RunPrompt([string]$P, [string]$File) {
    $f = Get-ChildItem "$P/.openspec-auto/runs/*/$File" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return [System.IO.File]::ReadAllText($f.FullName) }
    ''
}

Write-Host "T8 agent claims SUCCESS, runner's own test run fails"
$p = New-Project 't8' @('01-a:1', '02-b:1')
$r = Invoke-Runner $p '01-a=success-red;02-b=success'
Check ($r.Code -eq 1) 'runner stops (exit 1)'
Check ($r.Out -match 'tests fail after 01-a was archived') 'failing tests after archive reported'
Check ($r.Out -match '\| 01-a \| FAILED-CHECK') '01-a is FAILED-CHECK in the report'
Check (Test-Path "$p/.openspec-auto/runs/*/01-a.run01.tests.txt") 'test output saved'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/02-b.run01.prompt.txt")) '02-b not processed'

Write-Host "T9 red or dirty baseline refuses to start"
$p = New-Project 't9' @('01-a:1')
Push-Location $p; Set-Content broken.txt 'x'; git add -A 2>&1 | Out-Null; git commit -q -m red 2>&1 | Out-Null; Pop-Location
$r = Invoke-Runner $p '01-a=success'
Check ($r.Code -eq 2 -and $r.Out -match 'baseline tests fail') 'red baseline refused (exit 2)'
Check (-not (Test-Path "$p/.openspec-auto/runs")) 'no agent run started'
Check (Test-Path "$p/.openspec-auto/baseline-tests.txt") 'baseline output saved'
$p = New-Project 't9b' @('01-a:1') '{ "testCommand": "echo x> junk.out", "timeoutMinutes": 2 }'
$r = Invoke-Runner $p '01-a=success'
Check ($r.Code -eq 2 -and $r.Out -match 'leaves the working tree dirty') 'test command dirtying the tree refused'

Write-Host "T10 NONCRITICAL with failing tests: fix processed right away"
$p = New-Project 't10' @('01-a:2', '02-b:1')
$r = Invoke-Runner $p '01-a=noncritical-red;fix-01-a=fixgreen;02-b=success'
Check ($r.Code -eq 0) 'runner exit 0'
Check ((Archived $p 'fix-01-a') -and (Archived $p '02-b')) 'fix-01-a and 02-b archived'
$fp = Read-RunPrompt $p 'fix-01-a.run01.prompt.txt'
Check ($fp -match 'Kind: fix \(fixes 01-a\)') 'fix prompt names the kind and the parent'
Check ($fp -match 'FAIL broken.txt') 'fix prompt carries the runner test evidence'
Check ((GitIn $p branch --list 'auto/fix-01-a') -eq '') 'no separate branch for the fix'
Check ((GitIn $p log --format=%s auto/01-a) -match 'fix-01-a fixed') 'fix committed on auto/01-a'
Push-Location $p; git merge-base --is-ancestor auto/01-a auto/02-b; $anc = $LASTEXITCODE; Pop-Location
Check ($anc -eq 0) 'auto/02-b is based on the fixed auto/01-a'
Check ($r.Out -match 'fixed by fix-01-a') 'report links the change to its fix'

Write-Host "T10b fix claims SUCCESS, tests still red"
$p = New-Project 't10b' @('01-a:2', '02-b:1')
$r = Invoke-Runner $p '01-a=noncritical-red;fix-01-a=success;02-b=success'
Check ($r.Code -eq 1 -and $r.Out -match 'tests fail after fix-01-a was archived') 'fix gate stops the loop'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/02-b.run01.prompt.txt")) '02-b not processed'

Write-Host "T10c fix does not converge"
$p = New-Project 't10c' @('01-a:2', '02-b:1')
$r = Invoke-Runner $p '01-a=noncritical-red;fix-01-a=continue-red;02-b=success'
Check ($r.Code -eq 1 -and $r.Out -match 'tests still fail after 2 runs') 'stops after maxRunsPerFix'
Check ((Get-ChildItem "$p/.openspec-auto/runs/*/fix-01-a.run*.prompt.txt").Count -eq 2) 'exactly 2 fix runs'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/02-b.run01.prompt.txt")) '02-b not processed'

Write-Host "T10d fixMode=stop"
$p = New-Project 't10d' @('01-a:2', '02-b:1') '{ "testCommand": ".\\run-tests.cmd", "timeoutMinutes": 2, "fixMode": "stop" }'
$r = Invoke-Runner $p '01-a=noncritical-red;fix-01-a=fixgreen;02-b=success'
Check ($r.Code -eq 1 -and $r.Out -match 'fixMode=stop') 'loop stops with fixMode=stop'
Check ((Active $p 'fix-01-a') -and -not (Test-Path "$p/.openspec-auto/runs/*/fix-01-a.run01.prompt.txt")) 'fix-01-a left for the human'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/02-b.run01.prompt.txt")) '02-b not processed'

Write-Host "T10e blocked fix refuses restart"
$p = New-Project 't10e' @('01-a:2', '02-b:1')
$r = Invoke-Runner $p '01-a=noncritical-red;fix-01-a=blocked;02-b=success'
Check ($r.Code -eq 1 -and (Test-Path "$p/openspec/changes/fix-01-a/BLOCKED.md")) 'fix blocked, loop stops'
$r = Invoke-Runner $p 'fix-01-a=fixgreen;02-b=success'
Check ($r.Code -eq 2 -and $r.Out -match 'fix-01-a is blocked') 'restart refused while the fix is blocked'

Write-Host "T11 interrupted fix is resumed"
$p = New-Project 't11' @('01-a:2', '02-b:1')
$r = Invoke-Runner $p '01-a=noncritical-red;fix-01-a=crash;02-b=success'
Check ($r.Code -eq 1) 'crashed fix stops the loop'
$r = Invoke-Runner $p 'fix-01-a=fixgreen;02-b=success'
Check ($r.Code -eq 0 -and $r.Out -match 'resuming fix-01-a') 'restart resumes the fix despite red baseline'
Check ((Archived $p 'fix-01-a') -and (Archived $p '02-b')) 'fix-01-a and 02-b archived after resume'

function Count-Prompts([string]$P, [string]$C) { @(Get-ChildItem "$P/.openspec-auto/runs/*/$C.run*.prompt.txt" -ErrorAction SilentlyContinue).Count }

Write-Host "T12 task groups: one group per run, runner tests after every group, final archive run"
$p = New-Project 't12' @('01-a:4:2', '02-b:1')
$r = Invoke-Runner $p '01-a=group;02-b=group'
Check ($r.Code -eq 0) 'runner exit 0'
Check ((Archived $p '01-a') -and (Archived $p '02-b')) 'both archived'
Check ((Count-Prompts $p '01-a') -eq 3) '01-a: 3 runs (group 1, group 2, final)'
Check ((Read-RunPrompt $p '01-a.run01.prompt.txt') -match 'Task group for this run: 1\. Group 1 \(open tasks: 1\.1, 1\.2\)') 'run 1 names group 1 and its open tasks'
Check ((Read-RunPrompt $p '01-a.run02.prompt.txt') -match 'Task group for this run: 2\.') 'run 2 names group 2'
Check ((Read-RunPrompt $p '01-a.run03.prompt.txt') -match 'Final run:') 'run 3 is the final run'
Check ((Test-Path "$p/.openspec-auto/runs/*/01-a.run01.group1.tests.txt") -and (Test-Path "$p/.openspec-auto/runs/*/01-a.run02.group2.tests.txt")) 'runner tested after each group'
Check ((Count-Prompts $p '02-b') -eq 2) '02-b (one group): 2 runs'
Check ($r.Out -match 'groups: 1 green, 2 green') 'report shows group results'

Write-Host "T13 red group is repaired"
$p = New-Project 't13' @('01-a:4:2')
$r = Invoke-Runner $p '01-a=group-red'
Check ($r.Code -eq 0 -and (Archived $p '01-a')) 'change finishes after the repair'
$rp = Read-RunPrompt $p '01-a.run02.prompt.txt'
Check ($rp -match 'Repair: task group 1 is complete') 'run 2 is a repair of group 1'
Check ($rp -match 'FAIL broken\.txt') 'repair prompt carries the runner test evidence'
Check ($rp -match 'scope\): .*broken\.txt') 'repair scope lists the files changed by the group'
Check ((Count-Prompts $p '01-a') -eq 4) '4 runs (group 1, repair, group 2, final)'
Check ($r.Out -match '1 red->green \(1 repair\)') 'report shows the repair'

Write-Host "T14 red group is not repaired"
$p = New-Project 't14' @('01-a:4:2', '02-b:1')
$r = Invoke-Runner $p '01-a=group-stuck;02-b=group'
Check ($r.Code -eq 1 -and $r.Out -match 'group 1 still red after 2 repair runs') 'stops after maxGroupRepairs'
Check ((Count-Prompts $p '01-a') -eq 3) '3 runs (group 1, 2 repairs)'
Check ((Count-Prompts $p '02-b') -eq 0) '02-b not processed'

Write-Host "T15 agent ignores the groups"
$p = New-Project 't15' @('01-a:4:2')
$r = Invoke-Runner $p '01-a=success'
Check ($r.Code -eq 0 -and (Archived $p '01-a')) 'still SUCCESS (step 1 gate was green)'
Check ($r.Out -match 'ticked tasks outside group 1') 'note: ticked tasks outside the group'
Check ($r.Out -match 'archived without a final run') 'note: archived without a final run'

Write-Host "T16 groupTesting off"
$p = New-Project 't16' @('01-a:4:2') '{ "testCommand": ".\\run-tests.cmd", "timeoutMinutes": 2, "groupTesting": false }'
$r = Invoke-Runner $p '01-a=success'
Check ($r.Code -eq 0 -and (Count-Prompts $p '01-a') -eq 1) 'one run as before'
Check ((Read-RunPrompt $p '01-a.run01.prompt.txt') -notmatch 'Task group') 'prompt has no task group'
Check (-not (Test-Path "$p/.openspec-auto/runs/*/01-a.run01.group*.tests.txt")) 'no group test runs'

Write-Host "T17 too many groups for maxRunsPerChange"
$p = New-Project 't17' @('01-a:6:6')
$r = Invoke-Runner $p '01-a=group'
Check ($r.Code -eq 2 -and $r.Out -match 'needs at least 7 runs') 'refused at start'

Write-Host ''
if ($script:Failed) { Write-Host "$script:Failed check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
