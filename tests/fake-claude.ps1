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
    Mark-Impl
}
# "Implementation" for acceptance tests: impl/<change>.txt appears when the last task is ticked
# (acceptance check scripts of the tests look for it). $script:LateImpl: only the repair run writes it.
$script:LateImpl = $false
function Mark-Impl([switch]$Force) {
    if ($script:LateImpl -and -not $Force) { return }
    if (@(Get-Content $tasks | Where-Object { $_ -match '^- \[ \]' }).Count -eq 0 -or $Force) {
        New-Item -ItemType Directory -Force 'impl' | Out-Null
        Set-Content "impl/$change.txt" 'implemented'
    }
}
# Ticks the open tasks of one "## N." group in tasks.md.
function Tick-Group([string]$Group) {
    $lines = [System.IO.File]::ReadAllLines((Resolve-Path $tasks))
    $cur = $null
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^##\s+(\d+)\.') { $cur = $Matches[1]; continue }
        if ($cur -eq $Group -and $lines[$i] -match '^- \[ \]') { $lines[$i] = $lines[$i] -replace '^- \[ \]', '- [x]' }
    }
    [System.IO.File]::WriteAllText((Resolve-Path $tasks), (($lines -join "`n") + "`n"))
    Mark-Impl
}
function Unit {
    if ($prompt -match 'Final run:') { return 'final' }
    if ($prompt -match 'Repair: task group (\d+)') { return "repair:$($Matches[1])" }
    if ($prompt -match 'Task group for this run: (\d+)\.') { return "group:$($Matches[1])" }
    'none'
}
# Group-aware worker: one group per run, archive only in the final run.
# $RedGroup: the group that breaks the tests; $Repairs: whether a repair run fixes them.
function Group-Worker([string]$RedGroup, [bool]$Repairs) {
    $u = Unit
    if ($u -eq 'final') { Archive; Result 'SUCCESS' }
    if ($u -like 'repair:*') {
        if ($Repairs) { Remove-Item 'broken.txt' -ErrorAction SilentlyContinue; if ($script:LateImpl) { Mark-Impl -Force }; Commit "$change repair" }
        Result 'CONTINUE'
    }
    if ($u -like 'group:*') {
        $g = $u.Substring(6)
        Tick-Group $g
        if ($g -eq $RedGroup) { Break-Tests }
        Commit "$change group $g"; Result 'CONTINUE'
    }
    Write-Output "no unit in prompt"; exit 5
}
function Commit([string]$Msg) { git add -A 2>&1 | Out-Null; git commit -q -m $Msg 2>&1 | Out-Null }
function Archive { & $os archive $change -y 2>&1 | Out-Null; Commit "$change archive" }
function Result([string]$Kind) {
    $o = @{ type = 'result'; subtype = 'success'; is_error = $false; num_turns = 3; total_cost_usd = 0.01; result = "AUTO-MODE-RESULT: $Kind`nfake" }
    Write-Output ($o | ConvertTo-Json -Compress)
    exit 0
}

function Break-Tests { Set-Content 'broken.txt' 'the project test script fails while this file exists' }
function New-Fix {
    & $os new change "fix-$change" 2>&1 | Out-Null
    Add-Content "openspec/changes/fix-$change/.openspec.yaml" 'skip_specs: true'
    Set-Content "openspec/changes/fix-$change/proposal.md" "## Why`nTest for greeting fails after change $change, the output has a trailing space.`n## What Changes`n- Fix greeting output.`n"
    Set-Content "openspec/changes/fix-$change/tasks.md" "- [ ] 1.1 Fix trailing space`n- [ ] 1.2 Check the caller`n- [ ] 1.3 Re-run the tests`n"
}

switch ($mode) {
    'group' { Group-Worker '' $true }
    'group-red' { Group-Worker '1' $true }
    'group-stuck' { Group-Worker '1' $false }
    'group-late' { $script:LateImpl = $true; Group-Worker '' $true }
    'tamper' {
        Get-ChildItem "acceptance/$change" -File | ForEach-Object { Set-Content $_.FullName '@echo ok' }
        Tick 999; Commit "$change impl"; Archive; Result 'SUCCESS'
    }
    'tamper-rm' { git rm -q -r "acceptance/$change" 2>&1 | Out-Null; Tick 999; Commit "$change impl"; Archive; Result 'SUCCESS' }
    'success-regress' { Remove-Item 'impl/*' -Exclude "$change.txt"; Tick 999; Commit "$change impl"; Archive; Result 'SUCCESS' }
    'success' { Tick 999; Commit "$change impl"; Archive; Result 'SUCCESS' }
    'success-red' { Tick 999; Break-Tests; Commit "$change impl"; Archive; Result 'SUCCESS' }
    'fixgreen' { Remove-Item 'broken.txt' -ErrorAction SilentlyContinue; Tick 999; Commit "$change fixed"; Archive; Result 'SUCCESS' }
    'continue' {
        Tick 1; Commit "$change one task"
        if ((Get-Content $tasks | Where-Object { $_ -match '^- \[ \]' }).Count -eq 0) { Archive; Result 'SUCCESS' }
        Result 'CONTINUE'
    }
    'continue-red' { Tick 1; Commit "$change one task, tests still red"; Result 'CONTINUE' }
    'noncritical' {
        Tick 1; Commit "$change partial"
        New-Fix; Commit "fix-$change proposal"; Archive; Result 'NONCRITICAL'
    }
    'noncritical-red' {
        Tick 1; Break-Tests; Commit "$change partial"
        New-Fix; Commit "fix-$change proposal"; Archive; Result 'NONCRITICAL'
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
