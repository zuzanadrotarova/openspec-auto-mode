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
         large change never fills one context window,
      5. runs testCommand itself after a change is archived (the agent's word is not enough);
         a NONCRITICAL change with failing tests gets its fix-NN change processed right away,
      6. with acceptanceMode, also runs the change's frozen acceptance tests (written before the
         change started, under acceptanceDir/<change>/) and stops if the agent changed them.

    testCommand also runs once before the first change: auto-mode needs a green start.

.PARAMETER Project
    Project root (git repository with OpenSpec). Default: current directory.

.PARAMETER Init
    Creates openspec/auto-mode.json from the template and prepares local git exclusions.

.PARAMETER SetupAcceptanceSchema
    Adds an "acceptance" artifact to the project's OpenSpec workflow: copies the current built-in
    spec-driven schema to openspec/schemas/spec-driven-acceptance/, inserts the artifact before
    tasks and selects the schema in openspec/config.yaml. Safe to run again (e.g. after an
    OpenSpec update); custom edits of that schema folder are overwritten.

.PARAMETER DryRun
    Runs the start checks and prints the plan without running anything.

.PARAMETER ClaudeCommand
    Command used to start Claude Code. Default: claude (overridable for tests).
#>
[CmdletBinding()]
param(
    [string]$Project = (Get-Location).Path,
    [switch]$Init,
    [switch]$SetupAcceptanceSchema,
    [switch]$DryRun,
    [string]$ClaudeCommand = 'claude'
)

$ErrorActionPreference = 'Stop'

$ToolDir = $PSScriptRoot
$StateDirName = '.openspec-auto'
$ConfigRel = 'openspec/auto-mode.json'
$AgentName = 'openspec-auto'
$AcceptSchemaName = 'spec-driven-acceptance'
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

# fix-NN-name -> NN-name (the numbered change it fixes), otherwise $null.
function Get-FixParent([string]$Name) {
    if ($Name -match '^fix-(\d{2,}-.+)$') { return $Matches[1] }
    return $null
}

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
    if (@($status.artifacts | Where-Object { $_.id -eq 'acceptance' }).Count -eq 0) { $script:NoAcceptArtifact += $Change }
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

# Task groups of tasks.md: a "## N. Title" heading and the task lines under it. Tasks before the
# first numbered heading form group 0. Groups without tasks are left out.
function Get-TaskGroups([string]$ChangeDir) {
    $file = Join-Path $ChangeDir 'tasks.md'
    $groups = New-Object System.Collections.ArrayList
    $cur = $null
    if (Test-Path $file) {
        foreach ($line in [System.IO.File]::ReadAllLines($file)) {
            if ($line -match '^\s*##\s+(\d+)\.?\s*(.*)$') {
                $cur = [pscustomobject]@{ Id = $Matches[1]; Title = $Matches[2].Trim(); Total = 0; Done = 0; Open = @() }
                [void]$groups.Add($cur)
                continue
            }
            if ($line -match '^\s*[-*]\s+\[( |x|X)\]\s*(.*)$') {
                $mark = $Matches[1]; $text = $Matches[2].Trim()
                if (-not $cur) {
                    $cur = [pscustomobject]@{ Id = '0'; Title = '(tasks without a group)'; Total = 0; Done = 0; Open = @() }
                    [void]$groups.Add($cur)
                }
                $cur.Total++
                if ($mark -ne ' ') { $cur.Done++ }
                else {
                    $tid = ($text -split '\s+')[0]
                    if ($tid -notmatch '^\d+(\.\d+)*$') { $tid = $text.Substring(0, [math]::Min(40, $text.Length)) }
                    $cur.Open += $tid
                }
            }
        }
    }
    @($groups | Where-Object { $_.Total -gt 0 })
}

function Get-GroupDone($Groups) {
    $h = @{}
    foreach ($g in @($Groups)) { $h[$g.Id] = $g.Done }
    $h
}

# Acceptance tests (step 3): files under acceptanceDir/<change>/, written before the change
# started and frozen for the agent. Only files committed to git count.
function Test-HasAcceptance([string]$Change) {
    if ($script:cfg.acceptanceMode -eq 'off') { return $false }
    (Invoke-Git @('ls-files', '--', "$($script:cfg.acceptanceDir)/$Change/")).Out -ne ''
}

# Archived numbered changes with acceptance tests: they must stay green (regression).
function Get-DoneAcceptance {
    $archive = Join-Path $Project 'openspec/changes/archive'
    if ($script:cfg.acceptanceMode -eq 'off' -or -not (Test-Path $archive)) { return @() }
    $names = @(Get-ChildItem -Path $archive -Directory | ForEach-Object { $_.Name -replace '^\d{4}-\d{2}-\d{2}-', '' } |
        Where-Object { $_ -match '^\d{2,}-' } | Sort-Object @{ Expression = { Get-ChangeNumber $_ } }, @{ Expression = { $_ } })
    @($names | Where-Object { Test-HasAcceptance $_ })
}

function Get-AcceptanceCommand([string]$Change) { ([string]$script:cfg.acceptanceCommand).Replace('{change}', $Change) }

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
        testTimeoutMinutes = 20
        fixMode            = 'immediate'
        maxRunsPerFix      = 2
        groupTesting       = $true
        maxGroupRepairs    = 2
        acceptanceMode     = 'off'
        acceptanceCommand  = $null
        acceptanceDir      = 'acceptance'
    }
    if (-not (Test-Path $path)) { return $null }
    $json = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    if ($null -eq $cfg.testTimeoutMinutes) { $cfg.testTimeoutMinutes = 20 }
    if ($null -eq $cfg.fixMode) { $cfg.fixMode = 'immediate' }
    if ($null -eq $cfg.maxRunsPerFix) { $cfg.maxRunsPerFix = 2 }
    if ($null -eq $cfg.groupTesting) { $cfg.groupTesting = $true }
    if ($null -eq $cfg.maxGroupRepairs) { $cfg.maxGroupRepairs = 2 }
    if ($null -eq $cfg.acceptanceMode) { $cfg.acceptanceMode = 'off' }
    if ($null -eq $cfg.acceptanceDir) { $cfg.acceptanceDir = 'acceptance' }
    $cfg.acceptanceDir = (([string]$cfg.acceptanceDir).Replace('\', '/').Trim().TrimEnd('/')) -replace '^\./', ''
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
function New-WorkerSettings($Cfg, [string]$Path, [string[]]$AcceptChanges) {
    $shell = @(
        'openspec', 'git add', 'git commit', 'git status', 'git diff', 'git log', 'git show',
        'git rm', 'git mv', 'git restore', 'ls', 'mkdir', 'pwd'
    )
    $accept = @($AcceptChanges | Where-Object { $_ } | ForEach-Object { Get-AcceptanceCommand $_ })
    foreach ($c in @($Cfg.testCommand) + @($Cfg.allowedCommands) + $accept) {
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
    # frozen acceptance tests; the runner's git diff check after every run is the real guard
    if ($Cfg.acceptanceMode -ne 'off') { $deny += @("Edit(./$($Cfg.acceptanceDir)/**)", "Write(./$($Cfg.acceptanceDir)/**)") }
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

# Runs a command line through the shell in a NEW process and waits with a timeout
# (the whole process tree is killed on timeout). Never throws on a non-zero exit code.
function Invoke-Process([string]$CommandLine, [double]$TimeoutMinutes, [string]$StdIn) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($IsWin) {
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/d /s /c `"$CommandLine`""
    } else {
        $psi.FileName = '/bin/sh'
        $psi.Arguments = "-c '$($CommandLine.Replace("'", "'\''"))'"
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
    if ($StdIn) { $proc.StandardInput.Write($StdIn) }
    $proc.StandardInput.Close()

    $timedOut = $false
    try {
        if (-not $proc.WaitForExit([int]($TimeoutMinutes * 60 * 1000))) {
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
    [pscustomobject]@{
        ExitCode = $exitCode; TimedOut = $timedOut; Stdout = $stdout; Stderr = $stderr
        Minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    }
}

# The runner runs testCommand itself: "tests exit 0" counts only when a program observes it.
# $AcceptFor: changes whose acceptance tests run after testCommand (all must pass). The label and
# the evidence tail come from the first failing command.
function Invoke-Tests($Cfg, [string]$LogPath, [string[]]$AcceptFor) {
    $cmds = @([pscustomobject]@{ Name = ''; Line = [string]$Cfg.testCommand })
    foreach ($c in @($AcceptFor | Where-Object { $_ })) {
        $cmds += [pscustomobject]@{ Name = "acceptance $c "; Line = (Get-AcceptanceCommand $c) }
    }
    $log = ''; $passed = $true; $label = 'green'; $tail = ''; $exitCode = 0; $timedOut = $false; $minutes = 0.0
    foreach ($c in $cmds) {
        $p = Invoke-Process $c.Line ([double]$Cfg.testTimeoutMinutes) ''
        $minutes += $p.Minutes
        $text = [string]$p.Stdout
        if ($p.Stderr) { $text = $text.TrimEnd() + "`n" + $p.Stderr }
        if ($cmds.Count -gt 1) { $log += "===== $($c.Line) (exit $($p.ExitCode))`n" }
        $log += $text.TrimEnd() + "`n"
        $ok = (-not $p.TimedOut) -and ($p.ExitCode -eq 0)
        if (-not $ok -and $passed) {
            $passed = $false; $exitCode = $p.ExitCode; $timedOut = $p.TimedOut
            if ($p.TimedOut) { $label = "red ($($c.Name)timeout after $($Cfg.testTimeoutMinutes) min)" }
            else { $label = "red ($($c.Name)exit $($p.ExitCode))" }
            $lines = @(($text -replace "`r", '') -split "`n" | Where-Object { $_.Trim() -ne '' })
            $tail = (@($lines | Select-Object -Last 40 | ForEach-Object {
                if ($_.Length -gt 300) { $_.Substring(0, 300) } else { $_ }
            }) -join "`n")
            if ($c.Name) { $tail = "[$($c.Line)]`n$tail" }
        }
    }
    Write-TextFile $LogPath $log
    [pscustomobject]@{
        Passed = $passed; ExitCode = $exitCode; TimedOut = $timedOut; Label = $label
        Tail = $tail; Dirty = (Get-DirtyStatus); Log = $LogPath; Minutes = [math]::Round($minutes, 1)
    }
}

function Get-RelPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = $Project.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($root.Length).Replace('\', '/') }
    $full
}

# Starts one Claude Code run in a NEW process (= empty context) and waits with a timeout.
function Invoke-Worker($Cfg, $Item, [int]$Run, [string]$LogBase, [string]$SettingsPath, [string]$AgentsPath, [string]$UnitText) {
    $shell = @($script:AllowedShell | ForEach-Object { "- $_" }) -join "`n"
    $kind = 'change'
    $evidence = ''
    if ($Item.IsFix) {
        $kind = "fix (fixes $($Item.Parent))"
        $evidence = @"

Runner test evidence (tests $($Item.EvidenceLabel), last 40 lines of output):
$($Item.Evidence)

"@
    }
    $acceptText = ''
    $target = $Item.Name
    if ($Item.IsFix) { $target = $Item.Parent }
    if (Test-HasAcceptance $target) {
        $acceptText = @"
Acceptance tests (frozen, written before this change; never modify, move or delete anything under $($Cfg.acceptanceDir)/): $($Cfg.acceptanceDir)/$target/
Acceptance test command: $(Get-AcceptanceCommand $target)

"@
    }
    $prompt = @"
Change: $($Item.Name)
Kind: $kind
Run: $Run of max $($Item.MaxRuns) for this change
Task budget for this run: $($Cfg.tasksPerRun)
Test command: $($Cfg.testCommand)
$acceptText$UnitText$evidence
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
    $p = Invoke-Process $cmdLine ([double]$Cfg.timeoutMinutes) $prompt
    $stdout = [string]$p.Stdout
    Write-TextFile "$LogBase.out.json" $stdout
    if ($p.Stderr) { Write-TextFile "$LogBase.err.txt" $p.Stderr }

    $info = [pscustomobject]@{
        ExitCode = $p.ExitCode; TimedOut = $p.TimedOut; Minutes = $p.Minutes
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

if ($SetupAcceptanceSchema) {
    Write-Step 'Setup acceptance schema'
    if (-not (Test-Path (Join-Path $Project 'openspec'))) { throw 'openspec/ not found; run openspec init first.' }
    # always start from the current built-in schema, so an OpenSpec update is picked up by re-running
    $r = Invoke-OpenSpec @('schema', 'fork', 'spec-driven', $AcceptSchemaName, '--force')
    if ($r.Code -ne 0) { throw "openspec schema fork failed:`n$($r.Out)" }
    $schemaDir = Join-Path $Project "openspec/schemas/$AcceptSchemaName"
    $schemaFile = Join-Path $schemaDir 'schema.yaml'
    if (-not (Test-Path $schemaFile)) { throw "schema not found after fork: $schemaFile" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]][System.IO.File]::ReadAllLines($schemaFile))
    if ($lines -match '^\s*-\s+id:\s*acceptance\s*$') { throw "the built-in spec-driven schema already has an 'acceptance' artifact; check it before adding ours" }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^description:') { $lines[$i] = 'description: OpenSpec workflow with acceptance tests (OpenSpec auto-mode) - proposal, specs, design, acceptance, tasks'; break }
    }
    $tasksAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^  - id: tasks\s*$') { $tasksAt = $i; break } }
    if ($tasksAt -lt 0) { throw "artifact 'tasks' not found in $schemaFile; add the acceptance artifact by hand (templates/schema/)" }
    # tasks requires acceptance: insert after the last entry of its block-style requires list
    $reqAt = -1
    for ($i = $tasksAt + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^\S|^  - '; $i++) {
        if ($lines[$i] -match '^    requires:\s*$') { $reqAt = $i; break }
    }
    if ($reqAt -lt 0) { throw "'requires:' list of artifact 'tasks' not found in $schemaFile; add the acceptance artifact by hand (templates/schema/)" }
    $last = $reqAt
    while ($last + 1 -lt $lines.Count -and $lines[$last + 1] -match '^      - ') { $last++ }
    $lines.Insert($last + 1, '      - acceptance')
    $artifact = [System.IO.File]::ReadAllLines((Join-Path $ToolDir 'templates/schema/acceptance-artifact.yaml'))
    $lines.InsertRange($tasksAt, [string[]]$artifact)
    Write-TextFile $schemaFile (($lines -join "`n") + "`n")
    Copy-Item (Join-Path $ToolDir 'templates/schema/acceptance.md') (Join-Path $schemaDir 'templates/acceptance.md') -Force
    $osConfig = Join-Path $Project 'openspec/config.yaml'
    $text = ''
    if (Test-Path $osConfig) { $text = [System.IO.File]::ReadAllText($osConfig) }
    if ($text -match '(?m)^schema:.*$') { $text = $text -replace '(?m)^schema:.*$', "schema: $AcceptSchemaName" }
    else { $text = "schema: $AcceptSchemaName`n" + $text }
    Write-TextFile $osConfig $text
    $v = Invoke-OpenSpec @('schema', 'validate', $AcceptSchemaName)
    if ($v.Code -ne 0) { throw "openspec schema validate $AcceptSchemaName failed:`n$($v.Out)" }
    Write-Ok "openspec/schemas/$AcceptSchemaName/ created (proposal, specs, design, acceptance, tasks), schema valid"
    Write-Ok "openspec/config.yaml uses schema $AcceptSchemaName for new changes"
    $c = Read-Config
    if (-not $c -or $c.acceptanceMode -ne 'reviewed' -or -not $c.acceptanceCommand) {
        Write-Warn "set acceptanceMode to 'reviewed' and acceptanceCommand in $ConfigRel, otherwise the runner does not run these tests"
    }
    Write-Warn 'changes created before keep their schema (.openspec.yaml); fix changes use spec-driven'
    Write-Host '    Commit openspec/schemas/ and openspec/config.yaml.'
    return
}

# ---------------------------------------------------------------- start checks (kap. 5.2)

Write-Step "OpenSpec auto-mode in $Project"
$errors = @()
if (-not (Get-Command $OpenSpecExe -ErrorAction SilentlyContinue)) { $errors += 'openspec CLI not found' }
$cfg = Read-Config
if (-not $cfg) { $errors += "$ConfigRel missing (run with -Init)" }
elseif (-not $cfg.testCommand) { $errors += "testCommand is not set in $ConfigRel" }
elseif ($cfg.fixMode -notin @('immediate', 'stop')) { $errors += "fixMode in $ConfigRel must be 'immediate' or 'stop' (is '$($cfg.fixMode)')" }
elseif ($cfg.acceptanceMode -notin @('off', 'reviewed')) { $errors += "acceptanceMode in $ConfigRel must be 'off' or 'reviewed' (is '$($cfg.acceptanceMode)')" }
elseif ($cfg.acceptanceMode -ne 'off') {
    if (-not ([string]$cfg.acceptanceCommand).Contains('{change}')) { $errors += "acceptanceCommand in $ConfigRel must contain {change} (e.g. node --test `"$($cfg.acceptanceDir)/{change}/*.accept.js`")" }
    if (-not $cfg.acceptanceDir -or [System.IO.Path]::IsPathRooted($cfg.acceptanceDir) -or $cfg.acceptanceDir -match '(^|/)\.\.?(/|$)' -or $cfg.acceptanceDir -match '[*?]') {
        $errors += "acceptanceDir in $ConfigRel must be a plain relative folder inside the project (is '$($cfg.acceptanceDir)')"
    }
}
$baseBranch = Get-CurrentBranch
if (-not $baseBranch) { $errors += 'HEAD is detached; check out a branch first' }
if ((Invoke-Git @('config', 'user.email')).Out -eq '') { $errors += 'git user.email is not set' }
Add-GitExclude
$dirty = Get-DirtyStatus
if ($dirty) { $errors += "working tree is not clean:`n$dirty" }

$numbered = @()
$fixCandidate = $null
$NoAcceptArtifact = @()
if ($errors.Count -eq 0) {
    $active = Get-ActiveChanges
    $numbered = Get-NumberedChanges $active
    # fix-NN changes whose numbered change is already archived (created by an earlier run)
    $pendingFixes = @($active | Where-Object { $fp = Get-FixParent $_.name; $fp -and (Get-ArchivedDir $fp) })
    $blocked = @(@($numbered) + @($pendingFixes) | Where-Object { Test-Path (Join-Path $Project "openspec/changes/$($_.name)/BLOCKED.md") })
    foreach ($b in $blocked) {
        $errors += "change $($b.name) is blocked (openspec/changes/$($b.name)/BLOCKED.md); resolve it, delete BLOCKED.md and commit"
    }
    # an interrupted fix can be resumed only on the branch of the change it fixes
    $fixCandidate = $pendingFixes | Where-Object { "auto/$(Get-FixParent $_.name)" -eq $baseBranch } |
        ForEach-Object { $_.name } | Select-Object -First 1
    if ($numbered.Count -eq 0 -and -not $fixCandidate) { $errors += 'no active numbered changes (NN-name) to process' }
    foreach ($c in $numbered) {
        foreach ($p in (Get-ProposeProblems $c.name)) {
            $errors += "change $($c.name) is not ready (propose incomplete): $p"
        }
        if ($cfg.acceptanceMode -eq 'reviewed' -and -not (Test-HasAcceptance $c.name)) {
            $errors += "change $($c.name) has no acceptance tests ($($cfg.acceptanceDir)/$($c.name)/ with committed files); write them before the start (acceptanceMode=reviewed)"
        }
        if ($cfg.groupTesting) {
            # one run per open group plus the final run must fit into maxRunsPerChange
            $open = @(Get-TaskGroups (Join-Path $Project "openspec/changes/$($c.name)") | Where-Object { $_.Done -lt $_.Total })
            if ($open.Count + 1 -gt [int]$cfg.maxRunsPerChange) {
                $errors += "change $($c.name) has $($open.Count) open task groups; with groupTesting it needs at least $($open.Count + 1) runs, but maxRunsPerChange is $($cfg.maxRunsPerChange)"
            }
        }
    }
}
if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Bad $e }
    exit 2
}

$resumed = ($baseBranch -like 'auto/*') -or ((Invoke-Git @('branch', '--list', 'auto/*')).Out -ne '')
Write-Ok "base branch: $baseBranch$(if ($resumed) { ' (resuming)' })"

# Baseline: a failure must not be blamed on the first change, so the start has to be green.
Write-Host '    baseline tests ...' -NoNewline
$baselineLog = Join-Path $Project "$StateDirName/baseline-tests.txt"
$baselineAccept = @(Get-DoneAcceptance)
$baseline = Invoke-Tests $cfg $baselineLog $baselineAccept
Write-Host (" {0}, {1} min" -f $baseline.Label, $baseline.Minutes)
if ($baselineAccept.Count) { Write-Ok "acceptance tests of archived changes included: $($baselineAccept -join ', ')" }
$resumeFix = $null
if ($cfg.acceptanceMode -eq 'reviewed' -and $NoAcceptArtifact.Count) {
    Write-Warn "without the acceptance artifact in their OpenSpec workflow: $($NoAcceptArtifact -join ', ') (optional, see -SetupAcceptanceSchema)"
}
if ($baseline.Dirty) {
    Write-Bad "testCommand leaves the working tree dirty:`n$($baseline.Dirty)`n    add these files to .gitignore (or clean them up) and run again"
    exit 2
}
if (-not $baseline.Passed) {
    if ($fixCandidate -and $cfg.fixMode -eq 'immediate') {
        $resumeFix = $fixCandidate
        Write-Warn "baseline tests fail; resuming $resumeFix first"
    } else {
        Write-Bad "baseline tests fail: $($baseline.Label); auto-mode needs a green start. Output: $StateDirName/baseline-tests.txt"
        exit 2
    }
} else {
    Write-Ok 'baseline tests green'
}
if ($numbered.Count -eq 0 -and -not $resumeFix) { Write-Bad 'no active numbered changes (NN-name) to process'; exit 2 }

$planNames = @(@($resumeFix) + @($numbered | ForEach-Object { $_.name }) | Where-Object { $_ })
Write-Ok ("plan: " + ($planNames -join ' -> '))
if ($DryRun) { Write-Step 'Dry run, no agent started.'; exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $Project "$StateDirName/runs/$stamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$settingsPath = Join-Path $runDir 'worker-settings.json'
$agentsPath = Join-Path $runDir 'worker-agents.json'
$acceptChanges = @(@($baselineAccept) + @($numbered | ForEach-Object { $_.name } | Where-Object { Test-HasAcceptance $_ }))
New-WorkerSettings $cfg $settingsPath $acceptChanges
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

function New-QueueItem([string]$Name, [bool]$IsFix, [string]$Parent, [string]$Branch, [int]$MaxRuns, [string]$Evidence, [string]$EvidenceLabel) {
    [pscustomobject]@{
        Name = $Name; IsFix = $IsFix; Parent = $Parent; Branch = $Branch; MaxRuns = $MaxRuns
        Evidence = $Evidence; EvidenceLabel = $EvidenceLabel
    }
}

# Queue instead of a fixed list: a fix-NN change is inserted right after its change.
$queue = New-Object System.Collections.ArrayList
if ($resumeFix) {
    $rp = Get-FixParent $resumeFix
    [void]$queue.Add((New-QueueItem $resumeFix $true $rp "auto/$rp" ([int]$cfg.maxRunsPerFix) $baseline.Tail $baseline.Label))
}
foreach ($c in $numbered) {
    [void]$queue.Add((New-QueueItem $c.name $false $null "auto/$($c.name)" ([int]$cfg.maxRunsPerChange) $null $null))
}

for ($qi = 0; $qi -lt $queue.Count; $qi++) {
    $item = $queue[$qi]
    $change = $item.Name
    $branch = $item.Branch
    Write-Step "$(if ($item.IsFix) { 'Fix' } else { 'Change' }) $change"

    # 1. branch (kap. 5 bod 1, kap. 5.2); a fix runs on the branch of the change it fixes
    if ($item.IsFix) {
        $current = Get-CurrentBranch
        if ($current -ne $branch) {
            $stopReason = "fix $change must run on $branch, but the current branch is $current; nothing was changed"
            $results += [pscustomobject]@{ Change = $change; Outcome = 'STOPPED'; Runs = 0; Branch = $branch; Cost = 0; Tests = '-'; Notes = $stopReason }
            break
        }
        Write-Ok "fixing on branch $branch"
    } elseif (Test-BranchExists $branch) {
        $current = Get-CurrentBranch
        if ($current -ne $branch) {
            if ((Invoke-Git @('merge-base', '--is-ancestor', 'HEAD', $branch)).Code -ne 0) {
                $stopReason = "branch $branch exists and diverges from the current branch $current; nothing was changed"
                $results += [pscustomobject]@{ Change = $change; Outcome = 'STOPPED'; Runs = 0; Branch = $branch; Cost = 0; Tests = '-'; Notes = $stopReason }
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
    if ($branches -notcontains $branch) { $branches += $branch }

    $outcome = $null; $notes = @(); $cost = 0.0; $run = 0; $testsLabel = '-'
    if ($item.IsFix) { $notes += "fixes $($item.Parent)" }

    # task groups as units (step 2): one group per run, runner tests after every group
    $useGroups = [bool]$cfg.groupTesting -and -not $item.IsFix
    $groupHistory = [ordered]@{}            # group id -> list of 'green' / 'red'
    $repairGroup = $null; $repairCount = 0; $repairEvidence = ''; $repairLabel = ''; $repairScope = @()
    $groupStartHead = Get-Head

    while (-not $outcome) {
        $run++
        if ($run -gt $item.MaxRuns) {
            $outcome = 'STOPPED'
            if ($item.IsFix) { $notes += "tests still fail after $($item.MaxRuns) runs (maxRunsPerFix); the fix plan is probably wrong" }
            else { $notes += "no result after $($item.MaxRuns) runs (maxRunsPerChange)" }
            break
        }
        $before = Get-TaskCounts (Join-Path $Project "openspec/changes/$change")
        $groupsBefore = @(Get-TaskGroups (Join-Path $Project "openspec/changes/$change"))
        $doneBefore = Get-GroupDone $groupsBefore
        $refsBefore = Get-RemoteRefs
        $headBefore = Get-Head

        # the unit of this run: one task group, a repair of a red group, or the final (archive) run
        $mode = $null; $unitGroup = $null; $unitText = ''
        if ($useGroups) {
            $openGroup = $groupsBefore | Where-Object { $_.Done -lt $_.Total } | Select-Object -First 1
            if ($repairGroup) {
                $mode = 'repair'; $unitGroup = $repairGroup
                $scopeText = 'not known after a restart; change as little as possible'
                if ($repairScope.Count) { $scopeText = $repairScope -join ', ' }
                $unitText = @"
Repair: task group $repairGroup is complete, but the runner's tests fail ($repairLabel).
Fix only the cause of the failure. Files changed by the group (scope): $scopeText
Do not tick or start other tasks and do not archive. End with CONTINUE.

Runner test evidence (last 40 lines of output):
$repairEvidence

"@
            } elseif ($openGroup) {
                $mode = 'group'; $unitGroup = $openGroup.Id
                $unitText = @"
Task group for this run: $($openGroup.Id). $($openGroup.Title) (open tasks: $($openGroup.Open -join ', '))
Finish this group only and end with CONTINUE; do not archive in this run. The runner runs the tests when the group is complete.

"@
            } else {
                $mode = 'final'
                $unitText = @"
Final run: all task groups are done and the runner's tests are green.
Do the completion check and archive (SUCCESS).

"@
            }
        }

        # 2. new process = empty context (kap. 5.1)
        $unitLabel = ''
        if ($mode -eq 'group') { $unitLabel = ", group $unitGroup" } elseif ($mode -eq 'repair') { $unitLabel = ", repair of group $unitGroup" } elseif ($mode -eq 'final') { $unitLabel = ', final' }
        Write-Host "    run $run ($($before.Done)/$($before.Total) tasks done$unitLabel) ..." -NoNewline
        $logBase = Join-Path $runDir ("{0}.run{1:D2}" -f $change, $run)
        $w = Invoke-Worker $cfg $item $run $logBase $settingsPath $agentsPath $unitText
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
        if ($item.IsFix -and (Test-Path (Join-Path $Project "openspec/changes/fix-$change"))) {
            $problems += "fix-$change was created; a fix change must not create another change"
        }
        if ($cfg.acceptanceMode -ne 'off') {
            # frozen acceptance tests: any commit touching acceptanceDir (edit, git rm, git mv) stops the loop
            $touched = @(((Invoke-Git @('diff', '--name-only', $headBefore, 'HEAD', '--', "$($cfg.acceptanceDir)/")).Out -split "`n") | Where-Object { $_ })
            if ($touched.Count) { $problems += "agent changed frozen acceptance tests: $($touched -join ', ')" }
        }

        # 4. evaluate result from files (kap. 7)
        $activeDir = Join-Path $Project "openspec/changes/$change"
        $archivedDir = Get-ArchivedDir $change
        $isActive = Test-Path $activeDir
        $isBlocked = $isActive -and (Test-Path (Join-Path $activeDir 'BLOCKED.md'))

        if ($archivedDir -and -not $isActive) {
            $t = Get-TaskCounts $archivedDir
            if (Test-Path (Join-Path $archivedDir 'BLOCKED.md')) { $problems += 'archived change contains BLOCKED.md' }
            if ($t.Done -eq $t.Total) { $kind = 'SUCCESS' }
            elseif ($item.IsFix) {
                $problems += "fix change archived with $($t.Done)/$($t.Total) tasks; a fix change has no NONCRITICAL result"
                $kind = 'UNEXPECTED'
            } else {
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
            elseif ($mode -eq 'repair') { $kind = 'CONTINUE' }   # progress of a repair = tests turn green (below)
            else {
                $problems += "no progress: change not archived, no BLOCKED.md, tasks $($after.Done)/$($after.Total) unchanged (kap. 7.4)"
                $kind = 'UNEXPECTED'
            }
        } else {
            $problems += 'change is neither active nor archived'
            $kind = 'UNEXPECTED'
        }

        # 5. test gate: once the change is archived, the runner runs testCommand itself
        $tests = $null
        if ($problems.Count -eq 0 -and $kind -in @('SUCCESS', 'NONCRITICAL')) {
            Write-Host '    tests ...' -NoNewline
            # the change is archived now, so its acceptance tests are part of the regression set
            $tests = Invoke-Tests $cfg "$logBase.tests.txt" @(Get-DoneAcceptance)
            $testsLabel = $tests.Label
            Write-Host (" {0}, {1} min" -f $tests.Label, $tests.Minutes)
            $claimText = '-'
            if ($w.Claimed) { $claimText = $w.Claimed }
            if ($tests.Dirty) { $problems += "testCommand left the working tree dirty:`n$($tests.Dirty)" }
            elseif ($kind -eq 'SUCCESS' -and -not $tests.Passed) {
                $problems += "tests fail after $change was archived ($($tests.Label), agent claimed $claimText); output: $(Get-RelPath $tests.Log)"
            }
        }
        if ($w.Claimed -and $w.Claimed -ne $kind -and $problems.Count -eq 0) {
            $notes += "run ${run}: agent claimed $($w.Claimed), files say $kind"
        }

        # 6. group gate (step 2): tests after every completed group, repair of a red group
        $groupStop = $null
        if ($useGroups -and $problems.Count -eq 0) {
            $groupsDir = $activeDir
            if ($archivedDir -and -not $isActive) { $groupsDir = $archivedDir }
            $groupsAfter = @(Get-TaskGroups $groupsDir)
            if ($mode -eq 'group') {
                $outside = @($groupsAfter | Where-Object { $_.Id -ne $unitGroup -and $_.Done -gt [int]$doneBefore[$_.Id] } | ForEach-Object { $_.Id })
                if ($outside.Count) { $notes += "run ${run}: ticked tasks outside group $unitGroup (groups $($outside -join ', '))" }
            }
            if ($kind -eq 'SUCCESS' -and $mode -ne 'final') { $notes += "run ${run}: archived without a final run" }
            if ($kind -eq 'CONTINUE') {
                $completed = @($groupsAfter | Where-Object { $_.Done -eq $_.Total -and [int]$doneBefore[$_.Id] -lt $_.Total } | ForEach-Object { $_.Id })
                $gid = $null
                if ($mode -eq 'repair') { $gid = $repairGroup } elseif ($completed.Count) { $gid = $completed[-1] }
                if ($gid) {
                    # acceptance tests must pass once all groups are done (before the final run)
                    $gAccept = @()
                    $allDone = -not ($groupsAfter | Where-Object { $_.Done -lt $_.Total })
                    if ($allDone -and (Test-HasAcceptance $change)) { $gAccept = @($change) }
                    Write-Host "    tests after group $gid$(if ($gAccept.Count) { ' (+ acceptance)' }) ..." -NoNewline
                    $gt = Invoke-Tests $cfg ("{0}.group{1}.tests.txt" -f $logBase, $gid) $gAccept
                    Write-Host (" {0}, {1} min" -f $gt.Label, $gt.Minutes)
                    if ($gt.Dirty) { $problems += "testCommand left the working tree dirty:`n$($gt.Dirty)" }
                    else {
                        if (-not $groupHistory.Contains($gid)) { $groupHistory[$gid] = @() }
                        if ($gt.Passed) {
                            $groupHistory[$gid] += 'green'
                            $repairGroup = $null; $repairCount = 0; $groupStartHead = Get-Head
                            Write-Ok "group $gid green"
                        } else {
                            $groupHistory[$gid] += 'red'
                            if ($mode -eq 'repair') { $repairCount++ }
                            else {
                                $repairGroup = $gid; $repairCount = 0
                                $repairScope = @(((Invoke-Git @('diff', '--name-only', $groupStartHead, 'HEAD')).Out -split "`n") | Where-Object { $_ })
                            }
                            $repairEvidence = $gt.Tail; $repairLabel = $gt.Label
                            if ($repairCount -ge [int]$cfg.maxGroupRepairs) {
                                $groupStop = "group $gid still red after $repairCount repair runs (maxGroupRepairs); output: $(Get-RelPath $gt.Log)"
                            } else {
                                Write-Warn "group $gid red ($($gt.Label)); the next run repairs it"
                            }
                        }
                    }
                }
            }
        }

        if ($problems.Count -gt 0) {
            foreach ($p in $problems) { Write-Bad $p }
            $outcome = 'FAILED-CHECK'; $notes += $problems
            $stopReason = "write-check failed after run $run of $change (see notes); log: $logBase.out.json"
        } elseif ($groupStop) {
            Write-Bad $groupStop
            $outcome = 'STOPPED'; $notes += $groupStop
            $stopReason = "change ${change}: $groupStop"
        } elseif ($kind -eq 'CONTINUE') {
            $after = Get-TaskCounts $activeDir
            Write-Ok "progress $($before.Done) -> $($after.Done)/$($after.Total); starting a fresh process"
        } else {
            $outcome = $kind
            if ($kind -eq 'BLOCKED') { $stopReason = "change $change is blocked: openspec/changes/$change/BLOCKED.md" }
            if ($kind -eq 'NONCRITICAL') {
                $fix = "fix-$change"
                if ($tests.Passed) {
                    $notes += "${fix}: no failing test observed, waits for you"
                } elseif ($cfg.fixMode -eq 'immediate') {
                    $notes += "tests $($tests.Label); $fix processed next"
                    $queue.Insert($qi + 1, (New-QueueItem $fix $true $change $branch ([int]$cfg.maxRunsPerFix) $tests.Tail $tests.Label))
                } else {
                    $notes += "tests $($tests.Label); $fix waits for you (fixMode=stop)"
                    $stopReason = "tests fail after NONCRITICAL $change; $fix waits for you (fixMode=stop); output: $(Get-RelPath $tests.Log)"
                }
            }
            Write-Ok "result: $kind"
        }
    }
    if ($outcome -eq 'STOPPED' -and -not $stopReason) { $stopReason = "change ${change}: $($notes -join '; ')" }
    if ($groupHistory.Count) {
        # e.g. "groups: 1 green, 2 red->green (1 repair)"
        $parts = foreach ($k in $groupHistory.Keys) {
            $h = @($groupHistory[$k])
            $s = "$k $($h -join '->')"
            if ($h.Count -gt 1) { $s += " ($($h.Count - 1) repair$(if ($h.Count -gt 2) { 's' }))" }
            $s
        }
        $notes = @("groups: $($parts -join ', ')") + @($notes)
    }

    if ($item.IsFix) {
        $parentRow = $results | Where-Object { $_.Change -eq $item.Parent } | Select-Object -First 1
        if ($parentRow) {
            $fixNote = "$change failed ($outcome)"
            if ($outcome -eq 'SUCCESS') { $fixNote = "fixed by $change" }
            $parentRow.Notes = (@($parentRow.Notes, $fixNote) | Where-Object { $_ }) -join '; '
        }
    }
    $results += [pscustomobject]@{ Change = $change; Outcome = $outcome; Runs = [math]::Min($run, $item.MaxRuns); Branch = $branch; Cost = $cost; Tests = $testsLabel; Notes = ($notes -join '; ') }
    if ($stopReason -or ($outcome -notin @('SUCCESS', 'NONCRITICAL'))) { break }
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
$baselineText = $baseline.Label
if ($resumeFix) { $baselineText += " (resuming $resumeFix)" }
if ($baselineAccept.Count) { $baselineText += " (incl. acceptance tests of $($baselineAccept -join ', '))" }
[void]$sb.AppendLine("- Baseline tests: $baselineText")
if ($cfg.acceptanceMode -ne 'off') {
    [void]$sb.AppendLine("- Acceptance tests: $($cfg.acceptanceMode), frozen under ``$($cfg.acceptanceDir)/``")
    if ($cfg.acceptanceMode -eq 'reviewed' -and $NoAcceptArtifact.Count) {
        [void]$sb.AppendLine("- Note: without the acceptance artifact in their OpenSpec workflow: $($NoAcceptArtifact -join ', ') (optional, see -SetupAcceptanceSchema)")
    }
}
if ($stopReason) { [void]$sb.AppendLine("- **Stopped:** $stopReason") } else { [void]$sb.AppendLine('- **Finished:** all numbered changes processed') }
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Changes')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Change | Result | Runs | Tests | Branch | Cost USD | Notes |')
[void]$sb.AppendLine('|---|---|---|---|---|---|---|')
foreach ($r in $results) {
    $n = ($r.Notes -replace "`r?`n", ' ' -replace '\|', '/')
    [void]$sb.AppendLine("| $($r.Change) | $($r.Outcome) | $($r.Runs) | $($r.Tests) | ``$($r.Branch)`` | $([math]::Round($r.Cost, 2)) | $n |")
}
foreach ($n in $notReached) { [void]$sb.AppendLine("| $n | not processed | 0 | | | | |") }
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
