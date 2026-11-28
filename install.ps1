# Installs the /openspec-auto Claude Code skill for the current user, and the cost dashboard
# (a SessionEnd hook that keeps the dashboard current, and an "OpenSpec dashboard" shortcut on the
# desktop and in the Start menu). The skill points to the runner in this repository, so after
# `git pull` the new runner is used right away. Re-run this script only when
# claude-skill/openspec-auto/SKILL.md changes, or when the repository moved.
#
#   install.ps1                 skill + dashboard
#   install.ps1 -NoDashboard    skill only (an existing dashboard hook is removed)
param([switch]$NoDashboard)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false

$repo = $PSScriptRoot
$source = Join-Path $repo 'claude-skill\openspec-auto\SKILL.md'
$target = Join-Path $HOME '.claude\skills\openspec-auto'

New-Item -ItemType Directory -Force $target | Out-Null

$text = [System.IO.File]::ReadAllText($source)
$text = $text.Replace('{{OPENSPEC_AUTO_HOME}}', $repo)
[System.IO.File]::WriteAllText((Join-Path $target 'SKILL.md'), $text, $Utf8)

Write-Host "Skill installed: $target"
Write-Host "Runner:          $(Join-Path $repo 'openspec-auto.ps1')"

# ---------------------------------------------------------------- dashboard
# SessionEnd hook in the user settings: an earlier entry of this hook is replaced, everything else in
# the file is kept. node edits the JSON (it is installed with OpenSpec) so the formatting stays.
$settings = Join-Path $HOME '.claude\settings.json'
$dashboard = Join-Path $repo 'dashboard.ps1'
$hookCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$dashboard`" -Hook"
$js = @'
const fs = require('fs');
const [file, cmd, remove] = process.argv.slice(2);
let s = {};
if (fs.existsSync(file)) {
  const raw = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
  if (raw.trim()) s = JSON.parse(raw);
}
s.hooks = s.hooks || {};
const mine = h => typeof h.command === 'string' && /dashboard\.ps1"? -Hook/.test(h.command);
let list = (s.hooks.SessionEnd || [])
  .map(g => ({ ...g, hooks: (g.hooks || []).filter(h => !mine(h)) }))
  .filter(g => g.hooks.length);
if (remove !== 'remove') list.push({ hooks: [{ type: 'command', command: cmd, timeout: 10 }] });
if (list.length) s.hooks.SessionEnd = list; else delete s.hooks.SessionEnd;
if (!Object.keys(s.hooks).length) delete s.hooks;
fs.writeFileSync(file, JSON.stringify(s, null, 2) + '\n');
'@
$jsPath = Join-Path ([System.IO.Path]::GetTempPath()) "osa-install-$PID.js"
[System.IO.File]::WriteAllText($jsPath, $js, $Utf8)
try {
    if (Test-Path $settings) { Copy-Item $settings "$settings.bak-openspec-auto" -Force }
    $mode = if ($NoDashboard) { 'remove' } else { 'add' }
    & node $jsPath $settings $hookCmd $mode
    if ($LASTEXITCODE -ne 0) { throw "could not update $settings (node exit $LASTEXITCODE); the backup is $settings.bak-openspec-auto" }
} finally { Remove-Item $jsPath -ErrorAction SilentlyContinue }

$links = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'OpenSpec dashboard.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'OpenSpec dashboard.lnk')
)
if ($NoDashboard) {
    foreach ($l in $links) { Remove-Item $l -ErrorAction SilentlyContinue }
    Write-Host 'Dashboard:       not installed (hook and shortcuts removed)'
} else {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($l in $links) {
        $lnk = $shell.CreateShortcut($l)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dashboard`""
        $lnk.WorkingDirectory = $repo
        $lnk.WindowStyle = 7
        $lnk.Description = 'Costs and runs of OpenSpec auto-mode and Claude Code sessions'
        $lnk.Save()
    }
    Write-Host "Dashboard:       hook in $settings (SessionEnd), shortcut 'OpenSpec dashboard' on the desktop and in the Start menu"
    Write-Host "                 page: $(Join-Path $HOME '.openspec-auto\dashboard.html')"
}
Write-Host 'Restart Claude Code and use /openspec-auto in your project.'
