# Cost and run dashboard (docs/dashboard-plan.md): collects auto-mode runs and interactive Claude Code
# sessions of all projects into a central history and builds one local HTML page from it.
#
#   dashboard.ps1                     import everything, build the page, open it
#   dashboard.ps1 -Import             import everything and build the page (no browser)
#   dashboard.ps1 -Project <path>     import the auto-mode runs of one project and build the page
#   dashboard.ps1 -SessionFile <f>    import one transcript and build the page (used by -Hook)
#   dashboard.ps1 -Hook               SessionEnd hook: reads the hook JSON from stdin, imports that
#                                     session in a detached process a little later, never fails
#   dashboard.ps1 -Open               open the page as it is
#
# Data stay on this PC. Only numbers and names are stored: no prompts, code or conversation text.
# Costs are Claude Code's list-price values; with a subscription they show the value of the usage.
param(
    [switch]$Import,
    [string]$Project,
    [string]$SessionFile,
    [switch]$Hook,
    [switch]$Open,
    [int]$Delay = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$HomeDir = Join-Path $env:USERPROFILE '.openspec-auto'
if ($env:OSA_HISTORY_DIR) { $HomeDir = $env:OSA_HISTORY_DIR }
$HistoryDir = Join-Path $HomeDir 'history'
$RunsFile = Join-Path $HistoryDir 'runs.jsonl'
$SessionsFile = Join-Path $HistoryDir 'sessions.jsonl'
$PagePath = Join-Path $HomeDir 'dashboard.html'
$ConfigPath = Join-Path $HomeDir 'dashboard-config.json'
$ClaudeProjects = Join-Path $env:USERPROFILE '.claude\projects'
if ($env:OSA_CLAUDE_PROJECTS) { $ClaudeProjects = $env:OSA_CLAUDE_PROJECTS }
$LogPath = Join-Path $HistoryDir 'dashboard-errors.log'

function Say([string]$Text) { if (-not $Quiet) { Write-Host $Text } }

# ---------------------------------------------------------------- SessionEnd hook
if ($Hook) {
    # must be quick and silent: hand the work to a detached process, so the transcript is complete
    # (the cost record is written when Claude Code ends) and the session is never held up
    try {
        $in = [Console]::In.ReadToEnd() | ConvertFrom-Json
        $t = [string]$in.transcript_path
        if ($t -and (Test-Path -LiteralPath $t)) {
            $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-SessionFile', "`"$t`"", '-Delay', '20', '-Quiet')
            Start-Process powershell -ArgumentList $args2 -WindowStyle Hidden | Out-Null
        }
    } catch {
        try {
            New-Item -ItemType Directory -Force $HistoryDir | Out-Null
            [System.IO.File]::AppendAllText($LogPath, "$(Get-Date -Format s) hook: $($_.Exception.Message)`n", $Utf8)
        } catch { }
    }
    exit 0
}

# ---------------------------------------------------------------- categories (plan section 4)
$SpecSkills = @(
    'openspec-propose', 'openspec-explore', 'openspec-update-change', 'openspec-sync-specs', 'openspec',
    'opsx:propose', 'opsx:explore', 'opsx:update', 'opsx:sync', 'opsx:new', 'opsx:ff', 'opsx:continue',
    'openspec new', 'openspec instructions'
)
if (Test-Path $ConfigPath) {
    try {
        $c = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        if ($c.specSkills) { $SpecSkills = @($c.specSkills | ForEach-Object { [string]$_ }) }
    } catch { Write-Warning "dashboard-config.json ignored: $($_.Exception.Message)" }
}

function Get-Category([string[]]$Skills) {
    $spec = @($Skills | Where-Object { $SpecSkills -contains $_ })
    $other = @($Skills | Where-Object { $SpecSkills -notcontains $_ })
    if ($spec.Count -and $other.Count) { return 'mixed' }
    if ($spec.Count) { return 'spec' }
    'other'
}

# ---------------------------------------------------------------- history files
function Read-History([string]$Path) {
    $h = [ordered]@{}
    if (Test-Path $Path) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            if (-not $line.Trim()) { continue }
            try { $r = $line | ConvertFrom-Json; $h[[string]$r.key] = $r } catch { }
        }
    }
    $h
}

function Write-History([string]$Path, $H) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $H.Keys) { [void]$sb.AppendLine(($H[$k] | ConvertTo-Json -Depth 6 -Compress)) }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $sb.ToString(), $Utf8)
    Move-Item -Force $tmp $Path
}

function ConvertFrom-JsonString([string]$Escaped) { ('"' + $Escaped + '"') | ConvertFrom-Json }

function Get-ModelTable($ModelUsage) {
    $m = [ordered]@{}
    if ($ModelUsage) {
        foreach ($p in $ModelUsage.PSObject.Properties) {
            $v = $p.Value
            $m[$p.Name] = [ordered]@{
                cost = [double]$v.costUSD; input = [long]$v.inputTokens; output = [long]$v.outputTokens
                cacheRead = [long]$v.cacheReadInputTokens; cacheCreation = [long]$v.cacheCreationInputTokens
            }
        }
    }
    $m
}

function Add-Models($Into, $From) {
    foreach ($k in $From.Keys) {
        if (-not $Into.Contains($k)) { $Into[$k] = [ordered]@{ cost = 0.0; input = 0; output = 0; cacheRead = 0; cacheCreation = 0 } }
        foreach ($f in @('cost', 'input', 'output', 'cacheRead', 'cacheCreation')) { $Into[$k][$f] += $From[$k][$f] }
    }
}

# ---------------------------------------------------------------- interactive sessions
# A transcript can hold several cost records: one per Claude Code process that worked on the
# session (startTime), each counting only its own process. Session cost = sum of the last record
# of every process. A session without a record (crashed, still open) has an unknown cost.
function Read-Session([string]$Path) {
    $cwd = $null; $first = $null; $last = $null; $sid = $null
    $segments = @{}
    $skills = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $cwd -and $line -match '"cwd":"((?:[^"\\]|\\.)*)"') { $cwd = ConvertFrom-JsonString $Matches[1] }
        if (-not $sid -and $line -match '"sessionId":"([0-9a-f-]+)"') { $sid = $Matches[1] }
        if ($line -match '"timestamp":"([^"]+)"') {
            if (-not $first) { $first = $Matches[1] }
            $last = $Matches[1]
        }
        if ($line.StartsWith('{"type":"cost-state"') -or $line -match '^\{[^{]*"type":"cost-state"') {
            try { $j = $line | ConvertFrom-Json; $segments[[string]$j.startTime] = $j } catch { }
            continue
        }
        foreach ($m in [regex]::Matches($line, '"name":"Skill","input":\{"skill":"([^"]+)"')) { [void]$skills.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($line, '<command-name>/?([a-z][a-z0-9:-]*)</command-name>')) {
            $n = $m.Groups[1].Value
            if ($n -like 'opsx:*' -or $n -like 'openspec*') { [void]$skills.Add($n) }
        }
        foreach ($m in [regex]::Matches($line, '"command":"openspec(?:\.cmd)? (new|instructions)\b')) { [void]$skills.Add("openspec $($m.Groups[1].Value)") }
    }
    if (-not $sid) { $sid = [System.IO.Path]::GetFileNameWithoutExtension($Path) }
    $models = [ordered]@{}
    $cost = $null; $added = 0; $removed = 0; $durMs = 0
    if ($segments.Count) {
        $cost = 0.0
        foreach ($s in $segments.Values) {
            $cost += [double]$s.totalCostUSD; $added += [long]$s.totalLinesAdded; $removed += [long]$s.totalLinesRemoved
            $durMs += [long]$s.totalDuration
            Add-Models $models (Get-ModelTable $s.modelUsage)
        }
    }
    $sk = @($skills | Sort-Object)
    [ordered]@{
        key = $sid; sessionId = $sid; project = $cwd; projectName = $(if ($cwd) { Split-Path -Leaf $cwd } else { '(unknown)' })
        start = $first; end = $last; cost = $cost; costKnown = ($null -ne $cost); processes = $segments.Count
        minutes = [math]::Round($durMs / 60000, 1); models = $models; linesAdded = $added; linesRemoved = $removed
        skills = $sk; category = (Get-Category $sk)
    }
}

function Get-TopTranscripts {
    if (-not (Test-Path $ClaudeProjects)) { return @() }
    # top level only: subagent transcripts (<session>/subagents/) are part of their session's cost
    @(Get-ChildItem $ClaudeProjects -Directory | ForEach-Object { Get-ChildItem $_.FullName -Filter *.jsonl -File })
}

# ---------------------------------------------------------------- auto-mode runs
function Find-StateDir([string]$Dir) {
    $d = $Dir
    for ($i = 0; $i -lt 6 -and $d; $i++) {
        if (Test-Path -LiteralPath (Join-Path $d '.openspec-auto\runs')) { return $d }
        $d = Split-Path -Parent $d
    }
    $null
}

function Get-ReportOutcomes([string]$ReportPath) {
    $o = @{}
    if (Test-Path -LiteralPath $ReportPath) {
        foreach ($line in [System.IO.File]::ReadAllLines($ReportPath)) {
            if ($line -match '^\|\s*([^|`]+?)\s*\|\s*(SUCCESS|NONCRITICAL|BLOCKED|FAILED-CHECK|STOPPED|not processed[^|]*)\s*\|') { $o[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    $o
}

function Read-ProjectRuns([string]$ProjectDir, $Runs) {
    $runsDir = Join-Path $ProjectDir '.openspec-auto\runs'
    if (-not (Test-Path -LiteralPath $runsDir)) { return 0 }
    $name = Split-Path -Leaf $ProjectDir
    $n = 0
    foreach ($stampDir in Get-ChildItem -LiteralPath $runsDir -Directory) {
        $outcomes = Get-ReportOutcomes (Join-Path $stampDir.FullName 'auto-mode-report.md')
        foreach ($f in Get-ChildItem -LiteralPath $stampDir.FullName -Filter '*.out.json' -File) {
            if ($f.Name -notmatch '^(.+)\.run(\d+)\.out\.json$') { continue }
            $change = $Matches[1]; $run = [int]$Matches[2]
            $j = $null
            try {
                $text = [System.IO.File]::ReadAllText($f.FullName)
                $i = $text.IndexOf('{')
                if ($i -ge 0) { $j = $text.Substring($i) | ConvertFrom-Json }
            } catch { }
            $unit = ''
            $promptPath = $f.FullName -replace '\.out\.json$', '.prompt.txt'
            if (Test-Path -LiteralPath $promptPath) {
                $pt = [System.IO.File]::ReadAllText($promptPath)
                if ($pt -match 'Task group for this run: (\d+)\.') { $unit = "group $($Matches[1])" }
                elseif ($pt -match 'Repair: task group (\d+)') { $unit = "repair $($Matches[1])" }
                elseif ($pt -match 'Final run:') { $unit = 'final' }
            }
            $durMs = 0; if ($j) { $durMs = [long]$j.duration_ms }
            $end = $f.LastWriteTime
            $rec = [ordered]@{
                key = "$ProjectDir|$($stampDir.Name)|$change|$run"; project = $ProjectDir; projectName = $name
                stamp = $stampDir.Name; change = $change; run = $run; unit = $unit
                start = $end.AddMilliseconds(-$durMs).ToString('s'); end = $end.ToString('s'); minutes = [math]::Round($durMs / 60000, 1)
                cost = $(if ($j) { [double]$j.total_cost_usd } else { $null }); turns = $(if ($j) { $j.num_turns } else { $null })
                subtype = $(if ($j) { [string]$j.subtype } else { 'no result (killed or crashed)' })
                models = $(if ($j) { Get-ModelTable $j.modelUsage } else { [ordered]@{} })
                outcome = $(if ($outcomes.ContainsKey($change)) { $outcomes[$change] } else { '' })
            }
            $Runs[$rec.key] = $rec
            $n++
        }
    }
    $n
}

# ---------------------------------------------------------------- page
function Build-Page($Runs, $Sessions) {
    $template = Join-Path $PSScriptRoot 'dashboard-template.html'
    $html = [System.IO.File]::ReadAllText($template)
    $data = [ordered]@{
        built = (Get-Date).ToString('s')
        runs = @($Runs.Values)
        sessions = @($Sessions.Values)
    }
    # PowerShell 5.1 escapes < > & ' in strings, so the JSON is safe inside a <script> element
    $json = ConvertTo-Json -InputObject $data -Depth 8 -Compress
    $html = $html.Replace('/*DATA*/null', $json)
    New-Item -ItemType Directory -Force $HomeDir | Out-Null
    [System.IO.File]::WriteAllText($PagePath, $html, $Utf8)
}

# ---------------------------------------------------------------- main
try {
    if ($Delay -gt 0) { Start-Sleep -Seconds $Delay }
    if ($Open -and -not $Import -and -not $Project -and -not $SessionFile) {
        if (-not (Test-Path $PagePath)) { $Import = $true } else { Start-Process $PagePath; exit 0 }
    }
    $all = -not ($Project -or $SessionFile)
    $runs = Read-History $RunsFile
    $sessions = Read-History $SessionsFile
    $projects = New-Object System.Collections.Generic.HashSet[string]

    if ($SessionFile) {
        $s = Read-Session $SessionFile
        $sessions[$s.key] = $s
        if ($s.project) { $d = Find-StateDir $s.project; if ($d) { [void]$projects.Add($d) } }
    }
    if ($all) {
        $files = Get-TopTranscripts
        Say "sessions: reading $($files.Count) transcripts ..."
        foreach ($f in $files) {
            try {
                $s = Read-Session $f.FullName
                $sessions[$s.key] = $s
                if ($s.project) { $d = Find-StateDir $s.project; if ($d) { [void]$projects.Add($d) } }
            } catch { Say "  skipped $($f.Name): $($_.Exception.Message)" }
        }
        foreach ($r in $runs.Values) { if ($r.project -and (Test-Path -LiteralPath $r.project)) { [void]$projects.Add([string]$r.project) } }
    }
    if ($Project) { [void]$projects.Add((Resolve-Path -LiteralPath $Project).Path) }
    foreach ($p in $projects) {
        $n = Read-ProjectRuns $p $runs
        Say "runs: $n in $p"
    }

    Write-History $RunsFile $runs
    Write-History $SessionsFile $sessions
    Build-Page $runs $sessions
    Say "history: $($runs.Count) runs, $($sessions.Count) sessions in $HistoryDir"
    Say "page:    $PagePath"
    if ($all -and -not $Import) { Start-Process $PagePath }
    if ($Open -and -not $all) { Start-Process $PagePath }
} catch {
    try {
        New-Item -ItemType Directory -Force $HistoryDir | Out-Null
        [System.IO.File]::AppendAllText($LogPath, "$(Get-Date -Format s) $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)`n", $Utf8)
    } catch { }
    if (-not $Quiet) { Write-Host "dashboard failed: $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}
exit 0
