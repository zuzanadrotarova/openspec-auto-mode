# Fake Claude Code worker for runner tests. Behaviour per change comes from env FAKE_PLAN,
# e.g. "01-a=success;02-b=continue". It acts on files like the real worker would.
$ErrorActionPreference = 'Continue'
$prompt = [Console]::In.ReadToEnd()
$change = ([regex]::Match($prompt, 'Change:\s*(\S+)')).Groups[1].Value
$plan = @{}
foreach ($pair in ($env:FAKE_PLAN -split ';')) {
    if ($pair -match '^(.+?)=(.+)$') { $plan[$Matches[1]] = $Matches[2] }
}
$mode = $plan[$change]
$dir = "openspec/changes/$change"
$tasks = "$dir/tasks.md"
$os = 'openspec'
if (Get-Command 'openspec.cmd' -ErrorAction SilentlyContinue) { $os = 'openspec.cmd' }

function Tick([int]$Count) {
    $lines = [System.IO.File]::ReadAllLines((Resolve-Path $tasks))
    $n = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($n -lt $Count -and $lines[$i] -match '^- \[ \]') { $lines[$i] = $lines[$i] -replace '^- \[ \]', '- [x]'; $n++ }
    }
    [System.IO.File]::WriteAllText((Resolve-Path $tasks), (($lines -join "`n") + "`n"))
}
function Commit([string]$Msg) { git add -A 2>&1 | Out-Null; git commit -q -m $Msg 2>&1 | Out-Null }
function Archive { & $os archive $change -y 2>&1 | Out-Null; Commit "$change archive" }
function Result([string]$Kind) {
    $o = @{ type = 'result'; subtype = 'success'; is_error = $false; num_turns = 3; total_cost_usd = 0.01; result = "AUTO-MODE-RESULT: $Kind`nfake" }
    Write-Output ($o | ConvertTo-Json -Compress)
    exit 0
}

switch ($mode) {
    'success' { Tick 999; Commit "$change impl"; Archive; Result 'SUCCESS' }
    'continue' {
        Tick 1; Commit "$change one task"
        if ((Get-Content $tasks | Where-Object { $_ -match '^- \[ \]' }).Count -eq 0) { Archive; Result 'SUCCESS' }
        Result 'CONTINUE'
    }
    'noncritical' {
        Tick 1; Commit "$change partial"
        & $os new change "fix-$change" 2>&1 | Out-Null
        Add-Content "openspec/changes/fix-$change/.openspec.yaml" 'skip_specs: true'
        Set-Content "openspec/changes/fix-$change/proposal.md" "## Why`nTest for greeting fails after change $change, the output has a trailing space.`n## What Changes`n- Fix greeting output.`n"
        Set-Content "openspec/changes/fix-$change/tasks.md" "- [ ] 1.1 Fix trailing space`n"
        Commit "fix-$change proposal"; Archive; Result 'NONCRITICAL'
    }
    'blocked' {
        Set-Content "$dir/BLOCKED.md" "## What blocks`nNeeds a new package.`n"
        Commit "$change blocked"; Result 'BLOCKED'
    }
    'push' {
        git push -q origin HEAD 2>&1 | Out-Null                       # must be refused by the hook
        git -c core.hooksPath=no-hooks-here push -q origin HEAD 2>&1 | Out-Null  # bypasses the hook -> runner must detect
        Tick 999; Commit "$change impl"; Archive; Result 'SUCCESS'
    }
    'dirty' { Tick 999; Result 'SUCCESS' }
    'noop' { Result 'CONTINUE' }
    'crash' { exit 3 }
    default { Write-Output "unknown mode for $change"; exit 4 }
}
