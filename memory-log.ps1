# Memory log of one auto-mode start (docs/memory-recovery-plan.md 2.6), started by openspec-auto.ps1.
# Appends one line every -Seconds to -Csv: time, available memory, commit charge, commit limit,
# commit percent and the 5 biggest processes by working set (names stay local, the file is not
# sent anywhere). Ends when the runner (-ParentPid) ends; it is also in the runner's job object.
param([Parameter(Mandatory)][string]$Csv, [int]$Seconds = 60, [Parameter(Mandatory)][int]$ParentPid)

$ErrorActionPreference = 'Stop'
$parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
if (-not $parent) { exit 0 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OsaMemLog {
    [StructLayout(LayoutKind.Sequential)] class MemStatus {
        public uint Length = (uint)Marshal.SizeOf(typeof(MemStatus)); public uint MemoryLoad;
        public ulong TotalPhys; public ulong AvailPhys; public ulong TotalPageFile; public ulong AvailPageFile;
        public ulong TotalVirtual; public ulong AvailVirtual; public ulong AvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx([In, Out] MemStatus status);
    // available MB, commit MB, commit limit MB; null on error
    public static double[] Read() {
        MemStatus m = new MemStatus();
        if (!GlobalMemoryStatusEx(m)) return null;
        return new double[] { m.AvailPhys / 1048576.0, (m.TotalPageFile - m.AvailPageFile) / 1048576.0, m.TotalPageFile / 1048576.0 };
    }
}
'@

$utf8 = New-Object System.Text.UTF8Encoding $false
$inv = [System.Globalization.CultureInfo]::InvariantCulture
if (-not (Test-Path -LiteralPath $Csv)) {
    [System.IO.File]::WriteAllText($Csv, "time,availableMB,commitMB,commitLimitMB,commitPercent,top`r`n", $utf8)
}
if ($Seconds -lt 1) { $Seconds = 1 }

while ($true) {
    try {
        $m = [OsaMemLog]::Read()
        $top = @(Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; MB = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB }
        } | Sort-Object MB -Descending | Select-Object -First 5 | ForEach-Object { '{0} {1:0}' -f $_.Name, $_.MB }) -join '; '
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv)
        if ($m) {
            $pct = 0; if ($m[2] -gt 0) { $pct = [math]::Round(100 * $m[1] / $m[2]) }
            $line += ',{0:0},{1:0},{2:0},{3}' -f $m[0], $m[1], $m[2], $pct
        } else { $line += ',,,,' }
        $line += ',"' + ($top -replace '"', "'") + '"'
        [System.IO.File]::AppendAllText($Csv, $line + "`r`n", $utf8)
    } catch { }
    # waits the interval, but ends at once when the runner ends
    if ($parent.WaitForExit($Seconds * 1000)) { break }
}
