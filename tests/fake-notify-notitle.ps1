# Fake notify script without -Title (like the original send-notify.ps1): appends "-|priority|message".
param([Parameter(Mandatory = $true)][string]$Message, [int]$Priority = 1)
[System.IO.File]::AppendAllText($env:FAKE_NOTIFY_LOG, "-|$Priority|$Message`n", (New-Object System.Text.UTF8Encoding $false))
