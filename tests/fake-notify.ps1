# Fake notify script for the runner tests: appends "title|priority|message" to $env:FAKE_NOTIFY_LOG.
# FAKE_NOTIFY_MODE: ok (default), fail (exit 1), sleep (hangs past the runner's timeout).
param([Parameter(Mandatory = $true)][string]$Message, [int]$Priority = 1, [string]$Title = 'Claude caka')
[System.IO.File]::AppendAllText($env:FAKE_NOTIFY_LOG, "$Title|$Priority|$Message`n", (New-Object System.Text.UTF8Encoding $false))
if ($env:FAKE_NOTIFY_MODE -eq 'fail') { Write-Host 'CHYBA: fake failure'; exit 1 }
if ($env:FAKE_NOTIFY_MODE -eq 'sleep') { Start-Sleep -Seconds 30 }
