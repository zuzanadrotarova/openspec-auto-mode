<#
.SYNOPSIS
    OpenSpec auto-mode: implements numbered OpenSpec changes (NN-name) one after another,
    each in a fresh Claude Code process with an empty context.

.DESCRIPTION
    The runner is deterministic and keeps no state of its own; everything is derived from
    OpenSpec and git, so resuming is the same command as the first start.

    For every active change matching NN-name (ascending):
      1. creates or reuses the branch auto/NN-name (chained from the previous change),
      2. runs `claude -p` with the worker agent in a new process (empty context),
      3. verifies the result from files (git status, OpenSpec validation, archive / BLOCKED.md,
         remote refs) and only then starts the next process,
      4. repeats with a new process while the change reports progress (CONTINUE), so even a
         large change never fills one context window.

.PARAMETER Project
    Project root (git repository with OpenSpec). Default: current directory.

.PARAMETER Init
    Creates openspec/auto-mode.json from the template and prepares local git exclusions.

.PARAMETER DryRun
    Runs the start checks and prints the plan without running anything.

.PARAMETER ClaudeCommand
    Command used to start Claude Code. Default: claude (overridable for tests).
#>
[CmdletBinding()]
param(
    [string]$Project = (Get-Location).Path,
    [switch]$Init,
    [switch]$DryRun,
    [string]$ClaudeCommand = 'claude'
)

$ErrorActionPreference = 'Stop'

$ToolDir = $PSScriptRoot
$StateDirName = '.openspec-auto'
$ConfigRel = 'openspec/auto-mode.json'
$AgentName = 'openspec-auto'
$HookMarker = '# openspec-auto-mode pre-push guard'
$IsWin = ($env:OS -eq 'Windows_NT')
$Utf8 = New-Object System.Text.UTF8Encoding $false

# ---------------------------------------------------------------- helpers

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  x $Text" -ForegroundColor Red }
function Write-Ok([string]$Text) { Write-Host "  + $Text" -ForegroundColor Green }

function Write-TextFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}

# Runs a native command; returns exit code and combined output. Never throws on stderr.
function Invoke-Exec([string]$File, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    [pscustomobject]@{ Code = $code; Out = (($out | Where-Object { $_ -ne $null }) -join "`n").Trim() }
}

function Invoke-Git([string[]]$Arguments) { Invoke-Exec 'git' $Arguments }

$OpenSpecExe = 'openspec'
if ($IsWin -and (Get-Command 'openspec.cmd' -ErrorAction SilentlyContinue)) { $OpenSpecExe = 'openspec.cmd' }
function Invoke-OpenSpec([string[]]$Arguments) { Invoke-Exec $OpenSpecExe $Arguments }

function Get-ChangeNumber([string]$Name) { [int]($Name -replace '^(\d+)-.*$', '$1') }

function Get-ActiveChanges {
    $r = Invoke-OpenSpec @('list', '--json')
    if ($r.Code -ne 0) { throw "openspec list --json failed:`n$($r.Out)" }
    $start = $r.Out.IndexOf('{')
    if ($start -lt 0) { throw "openspec list --json returned no JSON:`n$($r.Out)" }
    $json = $r.Out.Substring($start) | ConvertFrom-Json
    @($json.changes)
}

function Get-NumberedChanges($Active) {
    @($Active | Where-Object { $_.name -match '^\d{2,}-' } |
        Sort-Object @{ Expression = { Get-ChangeNumber $_.name } }, @{ Expression = { $_.name } })
}

# Start check: the propose phase of a change is complete and valid (all artifacts of its schema
# are done or skipped, it has tasks, and openspec validate passes).
function Get-ProposeProblems([string]$Change) {
    $problems = @()
    $s = Invoke-OpenSpec @('status', '--change', $Change, '--json')
    $start = $s.Out.IndexOf('{')
    if ($s.Code -ne 0 -or $start -lt 0) { return @("openspec status failed: $($s.Out)") }
    $status = $s.Out.Substring($start) | ConvertFrom-Json
    $missing = @($status.artifacts | Where-Object { $_.status -notin @('done', 'skipped') } | ForEach-Object { "$($_.id) ($($_.outputPath))" })
    if ($missing.Count) { $problems += "missing artifacts: $($missing -join ', ')" }
    $t = Get-TaskCounts (Join-Path $Project "openspec/changes/$Change")
    if ($t.Total -eq 0) { $problems += 'tasks.md has no tasks (- [ ] ...)' }
    $v = Invoke-OpenSpec @('validate', $Change, '--no-interactive')
    if ($v.Code -ne 0) {
        $errs = @($v.Out -split "`n" | Where-Object { $_ -match '\[ERROR\]' } | ForEach-Object { $_ -replace '^.*?\[ERROR\]', '[ERROR]' })
        if (-not $errs.Count) { $errs = @($v.Out) }
        $problems += "openspec validate failed: $($errs -join ' | ')"
    }
    $problems
}

function Get-TaskCounts([string]$ChangeDir) {
    $file = Join-Path $ChangeDir 'tasks.md'
    $total = 0; $done = 0
    if (Test-Path $file) {
        foreach ($line in [System.IO.File]::ReadAllLines($file)) {
            if ($line -match '^\s*[-*]\s+\[( |x|X)\]') {
                $total++
                if ($Matches[1] -ne ' ') { $done++ }
            }
        }
    }
    [pscustomobject]@{ Total = $total; Done = $done }
}

function Get-ArchivedDir([string]$Change) {
    $archive = Join-Path $Project 'openspec/changes/archive'
    if (-not (Test-Path $archive)) { return $null }
    $pattern = '^\d{4}-\d{2}-\d{2}-' + [regex]::Escape($Change) + '$'
    $dir = Get-ChildItem -Path $archive -Directory | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
    if ($dir) { return $dir.FullName }
    return $null
}

function Get-CurrentBranch {
    $r = Invoke-Git @('symbolic-ref', '--short', '-q', 'HEAD')
    if ($r.Code -ne 0) { return $null }
    $r.Out
}

function Get-Head { (Invoke-Git @('rev-parse', 'HEAD')).Out }

function Get-DirtyStatus {
    $r = Invoke-Git @('status', '--porcelain')
    if ($r.Code -ne 0) { return "git status failed: $($r.Out)" }
    $r.Out
}

function Get-RemoteRefs { (Invoke-Git @('for-each-ref', '--format=%(refname) %(objectname)', 'refs/remotes')).Out }

function Test-BranchExists([string]$Branch) {
    (Invoke-Git @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")).Code -eq 0
}

function Read-Config {
    $path = Join-Path $Project $ConfigRel
    $cfg = [ordered]@{
        testCommand        = $null
        allowedCommands    = @()
        timeoutMinutes     = 60
        maxTurns           = 200
        maxRunsPerChange   = 10
        tasksPerRun        = 8
        model              = $null
        effort             = $null
        maxBudgetUsdPerRun = $null
    }
    if (-not (Test-Path $path)) { return $null }
    $json = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    $cfg.allowedCommands = @($cfg.allowedCommands | Where-Object { $_ })
    [pscustomobject]$cfg
}

function Add-GitExclude {
    $gitDir = (Invoke-Git @('rev-parse', '--absolute-git-dir')).Out
    $exclude = Join-Path $gitDir 'info/exclude'
    $line = "/$StateDirName/"
    $content = ''
    if (Test-Path $exclude) { $content = [System.IO.File]::ReadAllText($exclude) }
    if ($content -notmatch [regex]::Escape($line)) {
        if ($content -and -not $content.EndsWith("`n")) { $content += "`n" }
        Write-TextFile $exclude ($content + $line + "`n")
    }
}

# Layer 2 of push protection: pre-push hook that refuses pushes while OPENSPEC_AUTO_MODE=1.
function Install-PrePushHook {
    $gitDir = (Invoke-Git @('rev-parse', '--absolute-git-dir')).Out
    $hooksRel = (Invoke-Git @('rev-parse', '--git-path', 'hooks')).Out
    $hooksDir = $hooksRel
    if (-not [System.IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $Project $hooksRel }
    $hooksDir = [System.IO.Path]::GetFullPath($hooksDir)
    if (-not $hooksDir.StartsWith([System.IO.Path]::GetFullPath($gitDir), [System.StringComparison]::OrdinalIgnoreCase)) {
        return "core.hooksPath points outside .git ($hooksDir); pre-push guard not installed (permission rules and remote-ref check still apply)"
    }
    if (-not (Test-Path $hooksDir)) { New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null }
    $hook = Join-Path $hooksDir 'pre-push'
    $orig = Join-Path $hooksDir 'pre-push.openspec-auto-orig'
    if ((Test-Path $hook) -and -not ([System.IO.File]::ReadAllText($hook).Contains($HookMarker))) {
        if (Test-Path $orig) { return "pre-push hook exists and $orig too; guard not installed" }
        Move-Item $hook $orig
    }
    $body = @"
#!/bin/sh
$HookMarker
if [ "`$OPENSPEC_AUTO_MODE" = "1" ]; then
  echo "git push is blocked while OpenSpec auto-mode is running." >&2
  exit 1
fi
if [ -f "`$(dirname "`$0")/pre-push.openspec-auto-orig" ]; then
  exec sh "`$(dirname "`$0")/pre-push.openspec-auto-orig" "`$@"
fi
exit 0
"@
    Write-TextFile $hook ($body.Replace("`r`n", "`n"))
    return $null
}

function ConvertTo-CmdArg([string]$Value) {
    if ($Value -match '[\s"&|<>^]') { return '"' + $Value.Replace('"', '\"') + '"' }
    $Value
}

# Layer 1 of push protection + general sandbox: only allowlisted tools run (dontAsk mode).
function New-WorkerSettings($Cfg, [string]$Path) {
    $shell = @(
        'openspec', 'git add', 'git commit', 'git status', 'git diff', 'git log', 'git show',
        'git rm', 'git mv', 'git restore', 'ls', 'mkdir', 'pwd'
    )
    foreach ($c in @($Cfg.testCommand) + @($Cfg.allowedCommands)) {
        if ($c -and ($shell -notcontains $c.Trim())) { $shell += $c.Trim() }
    }
    $script:AllowedShell = $shell
    $allow = @('Read', 'Edit', 'Write', 'Glob', 'Grep', 'TodoWrite') + @($shell | ForEach-Object { "Bash(${_}:*)" })
    $deny = @(
        'Bash(git push:*)', 'Bash(git remote:*)', 'Bash(git fetch:*)', 'Bash(git pull:*)',
        'Bash(git checkout:*)', 'Bash(git switch:*)', 'Bash(git branch:*)', 'Bash(git reset:*)',
        'Bash(git rebase:*)', 'Bash(git merge:*)', 'Bash(git config:*)', 'Bash(git -c:*)', 'Bash(git -C:*)',
        'Bash(npm install:*)', 'Bash(npm i:*)', 'Bash(npm ci:*)', 'Bash(npm add:*)', 'Bash(pnpm add:*)',
        'Bash(pnpm install:*)', 'Bash(yarn add:*)', 'Bash(yarn install:*)', 'Bash(pip install:*)',
        'Bash(pip3 install:*)', 'Bash(uv add:*)', 'Bash(poetry add:*)', 'Bash(dotnet add:*)',
        'Bash(cargo add:*)', 'Bash(go get:*)', 'Bash(curl:*)', 'Bash(wget:*)',
        'Edit(./.git/**)', 'Write(./.git/**)', 'Edit(./.claude/**)', 'Write(./.claude/**)',
        "Edit(./$StateDirName/**)", "Write(./$StateDirName/**)",
        "Edit(./$ConfigRel)", "Write(./$ConfigRel)",
        'WebFetch', 'WebSearch', 'PowerShell'
    )
    $settings = @{ permissions = @{ defaultMode = 'dontAsk'; allow = $allow; deny = $deny } }
    Write-TextFile $Path ($settings | ConvertTo-Json -Depth 5)
}

function New-WorkerAgents([string]$Path) {
    $prompt = [System.IO.File]::ReadAllText((Join-Path $ToolDir 'worker-prompt.md'))
    $agents = @{}
    $agents[$AgentName] = @{
        description = 'Implements one OpenSpec change unattended (OpenSpec auto-mode worker).'
        prompt      = $prompt
    }
    Write-TextFile $Path ($agents | ConvertTo-Json -Depth 5)
}

# Starts one Claude Code run in a NEW process (= empty context) and waits with a timeout.
function Invoke-Worker($Cfg, [string]$Change, [int]$Run, [string]$LogBase, [string]$SettingsPath, [string]$AgentsPath) {
    $shell = @($script:AllowedShell | ForEach-Object { "- $_" }) -join "`n"
    $prompt = @"
Change: $Change
Run: $Run of max $($Cfg.maxRunsPerChange) for this change
Task budget for this run: $($Cfg.tasksPerRun)
Test command: $($Cfg.testCommand)

Allowed shell commands (one per Bash call, from the project root; any arguments):
$shell

Process this change according to your OpenSpec auto-mode instructions.
"@
    Write-TextFile "$LogBase.prompt.txt" $prompt

    $claudeArgs = @(
        '-p',
        '--agents', $AgentsPath,
        '--agent', $AgentName,
        '--settings', $SettingsPath,
        '--permission-mode', 'dontAsk',
        '--permission-prompts', 'none',
        '--no-session-persistence',
        '--output-format', 'json'
    )
    if ($Cfg.maxTurns) { $claudeArgs += @('--max-turns', [string]$Cfg.maxTurns) }
    if ($Cfg.model) { $claudeArgs += @('--model', [string]$Cfg.model) }
    if ($Cfg.effort) { $claudeArgs += @('--effort', [string]$Cfg.effort) }
    if ($Cfg.maxBudgetUsdPerRun) { $claudeArgs += @('--max-budget-usd', [string]$Cfg.maxBudgetUsdPerRun) }

    $cmdLine = ((@($ClaudeCommand) + $claudeArgs) | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($IsWin) {
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/d /s /c `"$cmdLine`""
    } else {
        $psi.FileName = '/bin/sh'
        $psi.Arguments = "-c '$($cmdLine.Replace("'", "'\''"))'"
    }
    $psi.WorkingDirectory = $Project
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.EnvironmentVariables['OPENSPEC_AUTO_MODE'] = '1'

    $started = Get-Date
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Write($prompt)
    $proc.StandardInput.Close()

    $timedOut = $false
    try {
        if (-not $proc.WaitForExit([int]$Cfg.timeoutMinutes * 60 * 1000)) {
            $timedOut = $true
            if ($IsWin) { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } else { $proc.Kill() }
            $proc.WaitForExit(15000) | Out-Null
        }
    } finally {
        if (-not $proc.HasExited) {
            if ($IsWin) { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } else { $proc.Kill() }
        }
    }
    $null = $outTask.Wait(15000); $null = $errTask.Wait(15000)
    $stdout = ''; $stderr = ''
    if ($outTask.IsCompleted) { $stdout = $outTask.Result }
    if ($errTask.IsCompleted) { $stderr = $errTask.Result }
    $exitCode = -1
    if ($proc.HasExited) { $exitCode = $proc.ExitCode }
    Write-TextFile "$LogBase.out.json" $stdout
    if ($stderr) { Write-TextFile "$LogBase.err.txt" $stderr }

    $info = [pscustomobject]@{
        ExitCode = $exitCode; TimedOut = $timedOut; Minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
        Claimed = $null; Subtype = $null; IsError = $false; Turns = $null; Cost = $null; Result = ''
    }
    try {
        $start = $stdout.IndexOf('{')
        if ($start -ge 0) {
            $j = $stdout.Substring($start) | ConvertFrom-Json
            $info.Subtype = $j.subtype; $info.IsError = [bool]$j.is_error
            $info.Turns = $j.num_turns; $info.Cost = $j.total_cost_usd; $info.Result = [string]$j.result
        }
    } catch { $info.Result = $stdout }
    if ($info.Result -match 'AUTO-MODE-RESULT:\s*([A-Z]+)') { $info.Claimed = $Matches[1] }
    $info
}

# ---------------------------------------------------------------- start

if (-not (Test-Path $Project)) { throw "Project path not found: $Project" }
$Project = (Resolve-Path $Project).Path
Push-Location $Project
try {

if ((Invoke-Git @('rev-parse', '--is-inside-work-tree')).Out -ne 'true') {
    throw "$Project is not a git repository (run git init and make the first commit)."
}
$top = [System.IO.Path]::GetFullPath((Invoke-Git @('rev-parse', '--show-toplevel')).Out)
if ($top.TrimEnd('\', '/') -ne $Project.TrimEnd('\', '/')) { throw "Run from the repository root ($top)." }

if ($Init) {
    Write-Step 'Init'
    if (-not (Test-Path (Join-Path $Project 'openspec'))) { throw 'openspec/ not found; run openspec init first.' }
    $cfgPath = Join-Path $Project $ConfigRel
    if (Test-Path $cfgPath) { Write-Ok "$ConfigRel already exists" }
    else {
        Copy-Item (Join-Path $ToolDir 'templates/auto-mode.json') $cfgPath
        Write-Ok "created $ConfigRel (set testCommand and allowedCommands, then commit it)"
    }
    Add-GitExclude
    Write-Ok "$StateDirName/ added to .git/info/exclude"
    return
}

# ---------------------------------------------------------------- start checks (kap. 5.2)

Write-Step "OpenSpec auto-mode in $Project"
$errors = @()
if (-not (Get-Command $OpenSpecExe -ErrorAction SilentlyContinue)) { $errors += 'openspec CLI not found' }
$cfg = Read-Config
if (-not $cfg) { $errors += "$ConfigRel missing (run with -Init)" }
elseif (-not $cfg.testCommand) { $errors += "testCommand is not set in $ConfigRel" }
$baseBranch = Get-CurrentBranch
if (-not $baseBranch) { $errors += 'HEAD is detached; check out a branch first' }
if ((Invoke-Git @('config', 'user.email')).Out -eq '') { $errors += 'git user.email is not set' }
Add-GitExclude
$dirty = Get-DirtyStatus
if ($dirty) { $errors += "working tree is not clean:`n$dirty" }

$numbered = @()
if ($errors.Count -eq 0) {
    $numbered = Get-NumberedChanges (Get-ActiveChanges)
    $blocked = @($numbered | Where-Object { Test-Path (Join-Path $Project "openspec/changes/$($_.name)/BLOCKED.md") })
    foreach ($b in $blocked) {
        $errors += "change $($b.name) is blocked (openspec/changes/$($b.name)/BLOCKED.md); resolve it, delete BLOCKED.md and commit"
    }
    if ($numbered.Count -eq 0) { $errors += 'no active numbered changes (NN-name) to process' }
    foreach ($c in $numbered) {
        foreach ($p in (Get-ProposeProblems $c.name)) {
            $errors += "change $($c.name) is not ready (propose incomplete): $p"
        }
    }
}
if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Bad $e }
    exit 2
}

$resumed = ($baseBranch -like 'auto/*') -or ((Invoke-Git @('branch', '--list', 'auto/*')).Out -ne '')
Write-Ok "base branch: $baseBranch$(if ($resumed) { ' (resuming)' })"
Write-Ok ("plan: " + (($numbered | ForEach-Object { $_.name }) -join ' -> '))
if ($DryRun) { Write-Step 'Dry run, nothing executed.'; exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $Project "$StateDirName/runs/$stamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$settingsPath = Join-Path $runDir 'worker-settings.json'
$agentsPath = Join-Path $runDir 'worker-agents.json'
New-WorkerSettings $cfg $settingsPath
New-WorkerAgents $agentsPath

$warnings = @()
$hookWarning = Install-PrePushHook
if ($hookWarning) { $warnings += $hookWarning; Write-Warn $hookWarning } else { Write-Ok 'pre-push guard installed' }
$env:OPENSPEC_AUTO_MODE = '1'

# ---------------------------------------------------------------- main loop (kap. 5)

$startTime = Get-Date
$results = @()
$branches = @()
$stopReason = $null

foreach ($c in $numbered) {
    $change = $c.name
    $branch = "auto/$change"
    Write-Step "Change $change"

    # 1. branch (kap. 5 bod 1, kap. 5.2)
    if (Test-BranchExists $branch) {
        $current = Get-CurrentBranch
        if ($current -ne $branch) {
            if ((Invoke-Git @('merge-base', '--is-ancestor', 'HEAD', $branch)).Code -ne 0) {
                $stopReason = "branch $branch exists and diverges from the current branch $current; nothing was changed"
                $results += [pscustomobject]@{ Change = $change; Outcome = 'STOPPED'; Runs = 0; Branch = $branch; Cost = 0; Notes = $stopReason }
                break
            }
            $r = Invoke-Git @('checkout', '-q', $branch)
            if ($r.Code -ne 0) { $stopReason = "git checkout $branch failed: $($r.Out)"; break }
        }
        Write-Ok "reusing existing branch $branch"
    } else {
        $r = Invoke-Git @('checkout', '-q', '-b', $branch)
        if ($r.Code -ne 0) { $stopReason = "git checkout -b $branch failed: $($r.Out)"; break }
        Write-Ok "created branch $branch"
    }
    $branches += $branch

    $outcome = $null; $notes = @(); $cost = 0.0; $run = 0
    while (-not $outcome) {
        $run++
        if ($run -gt [int]$cfg.maxRunsPerChange) {
            $outcome = 'STOPPED'; $notes += "no result after $($cfg.maxRunsPerChange) runs (maxRunsPerChange)"; break
        }
        $before = Get-TaskCounts (Join-Path $Project "openspec/changes/$change")
        $headBefore = Get-Head
        $refsBefore = Get-RemoteRefs

        # 2. new process = empty context (kap. 5.1)
        Write-Host "    run $run ($($before.Done)/$($before.Total) tasks done) ..." -NoNewline
        $logBase = Join-Path $runDir ("{0}.run{1:D2}" -f $change, $run)
        $w = Invoke-Worker $cfg $change $run $logBase $settingsPath $agentsPath
        if ($w.Cost) { $cost += [double]$w.Cost }
        Write-Host (" exit {0}, {1} min, claims {2}" -f $w.ExitCode, $w.Minutes, $(if ($w.Claimed) { $w.Claimed } else { '-' }))

        # 3. write-check by the runner (kap. 6.1 C) - must pass before the next process starts
        $problems = @()
        if ($w.TimedOut) { $problems += "run timed out after $($cfg.timeoutMinutes) min" }
        elseif ($w.ExitCode -ne 0) { $problems += "claude exited with code $($w.ExitCode) $($w.Subtype)" }
        elseif ($w.IsError) { $problems += "claude reported an error ($($w.Subtype))" }
        $cur = Get-CurrentBranch
        if ($cur -ne $branch) { $problems += "agent left branch $branch (now on $cur)" }
        $dirty = Get-DirtyStatus
        if ($dirty) { $problems += "git status is not clean:`n$dirty" }
        if ((Get-RemoteRefs) -ne $refsBefore) { $problems += 'remote-tracking refs changed during the run (possible push)' }
        $v = Invoke-OpenSpec @('validate', '--specs', '--no-interactive')
        if ($v.Code -ne 0) { $problems += "openspec validate --specs failed:`n$($v.Out)" }

        # 4. evaluate result from files (kap. 7)
        $activeDir = Join-Path $Project "openspec/changes/$change"
        $archivedDir = Get-ArchivedDir $change
        $isActive = Test-Path $activeDir
        $isBlocked = $isActive -and (Test-Path (Join-Path $activeDir 'BLOCKED.md'))

        if ($archivedDir -and -not $isActive) {
            $t = Get-TaskCounts $archivedDir
            if (Test-Path (Join-Path $archivedDir 'BLOCKED.md')) { $problems += 'archived change contains BLOCKED.md' }
            if ($t.Done -eq $t.Total) { $kind = 'SUCCESS' }
            else {
                $fix = "fix-$change"
                if (-not (Test-Path (Join-Path $Project "openspec/changes/$fix"))) {
                    $problems += "change archived with $($t.Done)/$($t.Total) tasks and no $fix change"
                } else {
                    $fv = Invoke-OpenSpec @('validate', $fix, '--no-interactive')
                    if ($fv.Code -ne 0) { $problems += "openspec validate $fix failed:`n$($fv.Out)" }
                }
                $kind = 'NONCRITICAL'
            }
        } elseif ($isBlocked) {
            $kind = 'BLOCKED'
        } elseif ($isActive) {
            $after = Get-TaskCounts $activeDir
            $cv = Invoke-OpenSpec @('validate', $change, '--no-interactive')
            if ($cv.Code -ne 0) { $problems += "openspec validate $change failed:`n$($cv.Out)" }
            if ($after.Done -gt $before.Done) { $kind = 'CONTINUE' }
            else {
                $problems += "no progress: change not archived, no BLOCKED.md, tasks $($after.Done)/$($after.Total) unchanged (kap. 7.4)"
                $kind = 'UNEXPECTED'
            }
        } else {
            $problems += 'change is neither active nor archived'
            $kind = 'UNEXPECTED'
        }
        if ($w.Claimed -and $w.Claimed -ne $kind -and $problems.Count -eq 0) {
            $notes += "run ${run}: agent claimed $($w.Claimed), files say $kind"
        }

        if ($problems.Count -gt 0) {
            foreach ($p in $problems) { Write-Bad $p }
            $outcome = 'FAILED-CHECK'; $notes += $problems
            $stopReason = "write-check failed after run $run of $change (see notes); log: $logBase.out.json"
        } elseif ($kind -eq 'CONTINUE') {
            $after = Get-TaskCounts $activeDir
            Write-Ok "progress $($before.Done) -> $($after.Done)/$($after.Total); starting a fresh process"
        } else {
            $outcome = $kind
            if ($kind -eq 'BLOCKED') { $stopReason = "change $change is blocked: openspec/changes/$change/BLOCKED.md" }
            Write-Ok "result: $kind"
        }
    }
    if ($outcome -eq 'STOPPED' -and -not $stopReason) { $stopReason = "change ${change}: $($notes -join '; ')" }

    $results += [pscustomobject]@{ Change = $change; Outcome = $outcome; Runs = [math]::Min($run, [int]$cfg.maxRunsPerChange); Branch = $branch; Cost = $cost; Notes = ($notes -join '; ') }
    if ($outcome -notin @('SUCCESS', 'NONCRITICAL')) { break }
}

# ---------------------------------------------------------------- report (kap. 10)

$endTime = Get-Date
$processed = @($results | ForEach-Object { $_.Change })
$notReached = @($numbered | Where-Object { $processed -notcontains $_.name } | ForEach-Object { $_.name })
$fixes = @(Get-ActiveChanges | Where-Object { $_.name -like 'fix-*' } | ForEach-Object { $_.name })

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# OpenSpec auto-mode report')
[void]$sb.AppendLine()
[void]$sb.AppendLine("- Project: ``$Project``")
[void]$sb.AppendLine("- Start: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))")
[void]$sb.AppendLine("- End: $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))")
[void]$sb.AppendLine("- Base branch: ``$baseBranch``$(if ($resumed) { ' (resumed run)' })")
[void]$sb.AppendLine("- Final branch: ``$(Get-CurrentBranch)``")
if ($stopReason) { [void]$sb.AppendLine("- **Stopped:** $stopReason") } else { [void]$sb.AppendLine('- **Finished:** all numbered changes processed') }
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Changes')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Change | Result | Runs | Branch | Cost USD | Notes |')
[void]$sb.AppendLine('|---|---|---|---|---|---|')
foreach ($r in $results) {
    $n = ($r.Notes -replace "`r?`n", ' ' -replace '\|', '/')
    [void]$sb.AppendLine("| $($r.Change) | $($r.Outcome) | $($r.Runs) | ``$($r.Branch)`` | $([math]::Round($r.Cost, 2)) | $n |")
}
foreach ($n in $notReached) { [void]$sb.AppendLine("| $n | not processed | 0 | | | |") }
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Fix changes waiting for you')
[void]$sb.AppendLine()
if ($fixes.Count) { foreach ($f in $fixes) { [void]$sb.AppendLine("- ``$f``") } } else { [void]$sb.AppendLine('- none') }
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Branches')
[void]$sb.AppendLine()
if ($branches.Count) { foreach ($b in $branches) { [void]$sb.AppendLine("- ``$b``") } } else { [void]$sb.AppendLine('- none') }
$blockedResult = $results | Where-Object { $_.Outcome -eq 'BLOCKED' } | Select-Object -First 1
if ($blockedResult) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("## Blocked: $($blockedResult.Change)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine([System.IO.File]::ReadAllText((Join-Path $Project "openspec/changes/$($blockedResult.Change)/BLOCKED.md")))
}
if ($warnings.Count) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Warnings')
    [void]$sb.AppendLine()
    foreach ($w in $warnings) { [void]$sb.AppendLine("- $w") }
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("Logs: ``$StateDirName/runs/$stamp/``")

$report = $sb.ToString()
Write-TextFile (Join-Path $Project "$StateDirName/auto-mode-report.md") $report
Write-TextFile (Join-Path $runDir 'auto-mode-report.md') $report
Write-Host ''
Write-Host $report
if ($stopReason) { exit 1 }
exit 0

} finally {
    Remove-Item Env:OPENSPEC_AUTO_MODE -ErrorAction SilentlyContinue
    Pop-Location
}
