# Installs the /openspec-auto Claude Code skill for the current user.
# The skill points to the runner in this repository, so after `git pull`
# the new runner is used right away. Re-run this script only when
# claude-skill/openspec-auto/SKILL.md changes.

$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
$source = Join-Path $repo 'claude-skill\openspec-auto\SKILL.md'
$target = Join-Path $HOME '.claude\skills\openspec-auto'

New-Item -ItemType Directory -Force $target | Out-Null

$text = [System.IO.File]::ReadAllText($source)
$text = $text.Replace('{{OPENSPEC_AUTO_HOME}}', $repo)
[System.IO.File]::WriteAllText((Join-Path $target 'SKILL.md'), $text, (New-Object System.Text.UTF8Encoding $false))

Write-Host "Skill installed: $target"
Write-Host "Runner:          $(Join-Path $repo 'openspec-auto.ps1')"
Write-Host 'Restart Claude Code and use /openspec-auto in your project.'
