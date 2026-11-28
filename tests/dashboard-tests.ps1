# Tests of dashboard.ps1 with a synthetic transcript and synthetic auto-mode runs (no API calls,
# nothing outside the work folder is read or written).
# Usage: powershell -ExecutionPolicy Bypass -File tests/dashboard-tests.ps1 [-WorkDir <dir>]
param([string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'openspec-auto-dashboard-tests'))

$ErrorActionPreference = 'Continue'
$Dashboard = Join-Path (Split-Path -Parent $PSScriptRoot) 'dashboard.ps1'
$script:Failed = 0
function Check([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "    ok   $Msg" -ForegroundColor Green }
    else { Write-Host "    FAIL $Msg" -ForegroundColor Red; $script:Failed++ }
}
function Write-Lines([string]$Path, [string[]]$Lines) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
}

Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
$proj = Join-Path $WorkDir 'projects\demo'
$claude = Join-Path $WorkDir 'claude-projects'
$env:OSA_HISTORY_DIR = Join-Path $WorkDir 'home'
$env:OSA_CLAUDE_PROJECTS = $claude
$cwdJson = ($proj | ConvertTo-Json)   # escaped path, with quotes

# a spec-preparation session worked on by two Claude Code processes (two cost records each)
$t1 = Join-Path $claude 'demo\11111111-1111-1111-1111-111111111111.jsonl'
Write-Lines $t1 @(
    '{"type":"user","cwd":' + $cwdJson + ',"sessionId":"11111111-1111-1111-1111-111111111111","timestamp":"2026-11-20T08:00:00.000Z","message":{"content":"<command-name>/opsx:propose</command-name>"}}'
    '{"type":"assistant","cwd":' + $cwdJson + ',"timestamp":"2026-11-20T08:05:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"openspec-propose"}}]}}'
    '{"type":"cost-state","sessionId":"11111111-1111-1111-1111-111111111111","totalCostUSD":1.0,"totalLinesAdded":5,"totalLinesRemoved":1,"totalDuration":60000,"startTime":100,"modelUsage":{"claude-haiku-5-5":{"inputTokens":10,"outputTokens":20,"cacheReadInputTokens":30,"cacheCreationInputTokens":40,"costUSD":0.25},"claude-opus-5-5":{"inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":4,"costUSD":0.75}}}'
    '{"type":"cost-state","sessionId":"11111111-1111-1111-1111-111111111111","totalCostUSD":2.0,"totalLinesAdded":7,"totalLinesRemoved":1,"totalDuration":120000,"startTime":100,"modelUsage":{"claude-opus-5-5":{"inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":4,"costUSD":2.0}}}'
    '{"type":"assistant","cwd":' + $cwdJson + ',"timestamp":"2026-11-20T10:00:00.000Z","message":{"content":"later process"}}'
    '{"type":"cost-state","sessionId":"11111111-1111-1111-1111-111111111111","totalCostUSD":3.5,"totalLinesAdded":3,"totalLinesRemoved":2,"totalDuration":180000,"startTime":200,"modelUsage":{"claude-opus-5-5":{"inputTokens":5,"outputTokens":6,"cacheReadInputTokens":7,"cacheCreationInputTokens":8,"costUSD":3.5}}}'
)
# a mixed session and a crashed one without a cost record; a subagent transcript is ignored
Write-Lines (Join-Path $claude 'demo\22222222-2222-2222-2222-222222222222.jsonl') @(
    '{"type":"user","cwd":' + $cwdJson + ',"sessionId":"22222222-2222-2222-2222-222222222222","timestamp":"2026-11-21T08:00:00.000Z"}'
    '{"type":"assistant","timestamp":"2026-11-21T08:01:00.000Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"openspec-explore"}},{"type":"tool_use","name":"Skill","input":{"skill":"openspec-auto"}}]}}'
    '{"type":"cost-state","sessionId":"22222222-2222-2222-2222-222222222222","totalCostUSD":4.0,"totalDuration":1,"startTime":5,"modelUsage":{}}'
)
Write-Lines (Join-Path $claude 'demo\33333333-3333-3333-3333-333333333333.jsonl') @(
    '{"type":"user","cwd":' + $cwdJson + ',"sessionId":"33333333-3333-3333-3333-333333333333","timestamp":"2026-11-22T08:00:00.000Z"}'
)
Write-Lines (Join-Path $claude 'demo\11111111-1111-1111-1111-111111111111\subagents\agent-x.jsonl') @(
    '{"type":"cost-state","sessionId":"sub","totalCostUSD":99,"startTime":1,"modelUsage":{}}'
)
# auto-mode runs of the project: two runs of a change (second hit the turn limit), report with the result
$rd = Join-Path $proj '.openspec-auto\runs\20261120-090000'
Write-Lines (Join-Path $rd '01-a.run01.out.json') @('{"type":"result","subtype":"success","total_cost_usd":0.5,"num_turns":10,"duration_ms":120000,"modelUsage":{"claude-opus-5-5":{"inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":4,"costUSD":0.5}}}')
Write-Lines (Join-Path $rd '01-a.run01.prompt.txt') @('Change: 01-a', 'Task group for this run: 1. Group 1 (open tasks: 1.1)')
Write-Lines (Join-Path $rd '01-a.run02.out.json') @('{"type":"result","subtype":"error_max_turns","total_cost_usd":1.25,"num_turns":200,"duration_ms":60000,"modelUsage":{}}')
Write-Lines (Join-Path $rd '01-a.run02.prompt.txt') @('Change: 01-a', 'Final run: all task groups are done')
Write-Lines (Join-Path $rd '01-a.run03.out.json') @('')
Write-Lines (Join-Path $rd 'auto-mode-report.md') @('| Change | Result | Runs |', '|---|---|---|', '| 01-a | STOPPED | 2 |')

function Invoke-Dashboard([string[]]$More) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Dashboard @More 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Read-Jsonl([string]$Name) { @(Get-Content (Join-Path $env:OSA_HISTORY_DIR "history\$Name") | ForEach-Object { $_ | ConvertFrom-Json }) }

Write-Host 'D1 import of sessions and runs'
$r = Invoke-Dashboard @('-Import')
Check ($r.Code -eq 0) 'import exit 0'
$ses = Read-Jsonl 'sessions.jsonl'; $runs = Read-Jsonl 'runs.jsonl'
Check ($ses.Count -eq 3) 'three sessions (subagent transcript not counted)'
$s1 = $ses | Where-Object { $_.sessionId -like '1111*' }
Check ($s1.cost -eq 5.5 -and $s1.processes -eq 2) 'session cost = last record of each process, summed (2.0 + 3.5)'
Check ($s1.models.'claude-opus-5-5'.cost -eq 5.5 -and -not $s1.models.'claude-haiku-5-5') 'models of the last records only'
Check ($s1.linesAdded -eq 10 -and $s1.project -eq $proj -and $s1.projectName -eq 'demo') 'lines and project from the transcript'
Check ($s1.category -eq 'spec' -and ($s1.skills -join ',') -eq 'openspec-propose,opsx:propose') 'skills found, category spec preparation'
Check (($ses | Where-Object { $_.sessionId -like '2222*' }).category -eq 'mixed') 'spec and other skills: mixed'
$s3 = $ses | Where-Object { $_.sessionId -like '3333*' }
Check ($s3.category -eq 'other' -and -not $s3.costKnown -and $null -eq $s3.cost) 'no cost record: cost unknown, category other'
Check ($runs.Count -eq 3) 'three runs found through the project of the sessions'
$r1 = $runs | Where-Object { $_.run -eq 1 }; $r2 = $runs | Where-Object { $_.run -eq 2 }; $r3 = $runs | Where-Object { $_.run -eq 3 }
Check ($r1.cost -eq 0.5 -and $r1.unit -eq 'group 1' -and $r1.minutes -eq 2 -and $r1.outcome -eq 'STOPPED') 'run: cost, unit, minutes, result of the change'
Check ($r2.subtype -eq 'error_max_turns' -and $r2.unit -eq 'final' -and $r2.turns -eq 200) 'limit stop and final run recognised'
Check ($null -eq $r3.cost -and $r3.subtype -like 'no result*') 'run without a result: cost unknown'
$page = Join-Path $env:OSA_HISTORY_DIR 'dashboard.html'
$html = if (Test-Path $page) { [System.IO.File]::ReadAllText($page) } else { '' }
Check ($html -match '"sessionId":"11111111' -and $html -notmatch '/\*DATA\*/null') 'page built with the data embedded'

Write-Host 'D2 re-import updates records instead of duplicating them; deleted projects stay'
$r = Invoke-Dashboard @('-Import')
Check ((Read-Jsonl 'sessions.jsonl').Count -eq 3 -and (Read-Jsonl 'runs.jsonl').Count -eq 3) 'same number of records'
Remove-Item -Recurse -Force $proj
Remove-Item -Recurse -Force (Join-Path $claude 'demo\22222222-2222-2222-2222-222222222222.jsonl')
$r = Invoke-Dashboard @('-Import')
Check ($r.Code -eq 0 -and (Read-Jsonl 'sessions.jsonl').Count -eq 3 -and (Read-Jsonl 'runs.jsonl').Count -eq 3) 'history keeps records of deleted transcripts and projects'

Write-Host 'D3 SessionEnd hook: returns at once, imports the session a little later'
$t4 = Join-Path $WorkDir 'hook\44444444-4444-4444-4444-444444444444.jsonl'
Write-Lines $t4 @(
    '{"type":"user","cwd":"C:\\nowhere","sessionId":"44444444-4444-4444-4444-444444444444","timestamp":"2026-11-23T08:00:00.000Z"}'
    '{"type":"cost-state","sessionId":"44444444-4444-4444-4444-444444444444","totalCostUSD":0.5,"startTime":1,"modelUsage":{}}'
)
$hookIn = (@{ session_id = '4444'; transcript_path = $t4; hook_event_name = 'SessionEnd' } | ConvertTo-Json -Compress)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$hookIn | & powershell -NoProfile -ExecutionPolicy Bypass -File $Dashboard -Hook
$code = $LASTEXITCODE; $sw.Stop()
Check ($code -eq 0 -and $sw.Elapsed.TotalSeconds -lt 8) "hook exits 0 at once ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)"
$found = $false
for ($i = 0; $i -lt 40 -and -not $found; $i++) {
    Start-Sleep -Seconds 1
    $found = [bool](Read-Jsonl 'sessions.jsonl' | Where-Object { $_.sessionId -like '4444*' })
}
Check $found 'the session is in the history after the delay'
'not json' | & powershell -NoProfile -ExecutionPolicy Bypass -File $Dashboard -Hook
Check ($LASTEXITCODE -eq 0 -and (Get-Content -Raw (Join-Path $env:OSA_HISTORY_DIR 'history\dashboard-errors.log')) -match 'hook:') 'broken hook input: exit 0, error only in the log'

Write-Host 'D4 projects without transcripts (only memory left) are listed too'
$old = Join-Path $WorkDir 'projects\old_project.v2'
New-Item -ItemType Directory -Force $old | Out-Null
$enc = $old -replace '[^A-Za-z0-9]', '-'
New-Item -ItemType Directory -Force (Join-Path $claude "$enc\memory") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $claude 'C--Users-nobody-gone-project\memory') | Out-Null
$r = Invoke-Dashboard @('-Import')
$known = Read-Jsonl 'projects.jsonl'
$k1 = $known | Where-Object { $_.key -eq $enc }
$k2 = $known | Where-Object { $_.key -eq 'C--Users-nobody-gone-project' }
Check ($r.Code -eq 0 -and $k1.project -eq $old -and $k1.projectName -eq 'old_project.v2' -and $k1.exists -and $k1.transcripts -eq 0) 'folder found again on disk, real name with _ and .'
Check ($k2 -and -not $k2.exists -and $k2.projectName -eq 'nobody-gone-project') 'missing folder: name = the part after the last existing parent folder'
Check ([System.IO.File]::ReadAllText((Join-Path $env:OSA_HISTORY_DIR 'dashboard.html')) -match 'old_project\.v2') 'known projects are on the page'

Remove-Item Env:OSA_HISTORY_DIR, Env:OSA_CLAUDE_PROJECTS
Write-Host ''
if ($script:Failed) { Write-Host "$script:Failed check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
exit 0
