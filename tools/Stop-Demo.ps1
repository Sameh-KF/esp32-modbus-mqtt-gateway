<#
.SYNOPSIS
Stops only demo processes whose PID and exact start time match the saved manifest.
.DESCRIPTION
Optional -Component stops selected components for local outage tests. Logs remain.
No process is selected by name, and no services or firewall settings change.
#>
[CmdletBinding()]
param(
    [string] $RuntimeRoot,
    [ValidateSet('broker', 'dashboard', 'simulator', 'gateway')]
    [string[]] $Component = @('gateway', 'simulator', 'dashboard', 'broker')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Demo-Paths.ps1')
$paths = Get-DemoPaths -RuntimeRoot $RuntimeRoot
if (-not (Test-Path -LiteralPath $paths.Manifest -PathType Leaf)) {
    Write-Host 'No recorded demo processes to stop.'
    return
}
$manifest = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
if (-not $manifest.PSObject.Properties['processes']) { throw 'The process manifest is invalid; no processes were stopped.' }
$remaining = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$stopEntries = @($manifest.processes)
[Array]::Reverse($stopEntries)
foreach ($entry in $stopEntries) {
    if ($entry.name -notin $Component) { $remaining.Add($entry); continue }
    try {
        $process = Get-OwnedDemoProcess -Entry $entry
        if ($process) {
            Stop-Process -InputObject $process -Force -ErrorAction Stop
            Write-Host "Stopped: $($entry.name) (PID $($entry.pid))"
        } else {
            Write-Warning "Skipped '$($entry.name)': the recorded PID is absent or its start time differs."
        }
    } catch {
        $remaining.Add($entry)
        $failures.Add("$($entry.name): $($_.Exception.Message)")
    }
}
if ($remaining.Count) {
    $manifest.processes = @($remaining.ToArray())
    Save-DemoManifest -Path $paths.Manifest -Manifest $manifest
} else {
    Remove-Item -LiteralPath $paths.Manifest -Force
}
if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
