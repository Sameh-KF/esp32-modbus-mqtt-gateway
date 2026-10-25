<#
.SYNOPSIS
Starts the four local host-simulation processes in hidden windows.
.DESCRIPTION
Requires an already prepared runtime. Uses loopback ports 1883, 1880 and 1502.
Each launch gets its own log directory. No services or firewall settings change.
Use Stop-Demo.ps1 to stop only the recorded processes belonging to this demo.
#>
[CmdletBinding()]
param([string] $RuntimeRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Demo-Paths.ps1')
$paths = Get-DemoPaths -RuntimeRoot $RuntimeRoot

foreach ($required in @($paths.Python, $paths.Broker, $paths.BrokerConfig, $paths.NodeRed,
        $paths.DashboardPackage, $paths.DashboardSettings, $paths.DashboardFlows, $paths.Simulator, $paths.Gateway)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file is missing: $required. Prepare the runtime before starting the demo." }
}
if (-not $paths.Node -or -not (Test-Path -LiteralPath $paths.Node -PathType Leaf)) { throw 'Node.js was not found on PATH.' }
if (Test-Path -LiteralPath $paths.Manifest -PathType Leaf) {
    $previous = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
    if (-not $previous.PSObject.Properties['processes']) { throw 'The existing process manifest is invalid; inspect it before starting.' }
    foreach ($entry in @($previous.processes)) {
        if (Get-OwnedDemoProcess -Entry $entry) { throw "Demo component '$($entry.name)' is already running. Use tools/Stop-Demo.ps1 first." }
    }
}
foreach ($port in @(1883, 1880, 1502)) {
    if (-not (Test-DemoPortAvailable -Port $port)) { throw "Port $port is already in use. No demo processes were started." }
}
[void] [IO.Directory]::CreateDirectory($paths.StateDir)
[void] [IO.Directory]::CreateDirectory($paths.LogsDir)
$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
$launchLogs = Join-Path $paths.LogsDir $runId
[void] [IO.Directory]::CreateDirectory($launchLogs)
$manifest = [ordered]@{
    schema_version = 1
    run_id = $runId
    source_mode = 'simulated'
    project_root = $paths.ProjectRoot
    runtime_root = $paths.RuntimeRoot
    started_at_utc = [DateTime]::UtcNow.ToString('o')
    log_directory = $launchLogs
    processes = @()
}
$owned = [Collections.Generic.List[object]]::new()

function Start-DemoComponent {
    param([string] $Name, [string] $Executable, [string[]] $Arguments, [int] $Port = 0, [int] $TimeoutSeconds = 20)
    $argumentString = ($Arguments | ForEach-Object { ConvertTo-DemoArgument -Value $_ }) -join ' '
    $stdout = Join-Path $launchLogs "$Name.stdout.log"
    $stderr = Join-Path $launchLogs "$Name.stderr.log"
    $process = Start-Process -FilePath $Executable -ArgumentList $argumentString -WorkingDirectory $paths.ProjectRoot `
        -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $entry = [ordered]@{
        name = $Name
        pid = $process.Id
        start_time_utc = $process.StartTime.ToUniversalTime().ToString('o')
        executable = $Executable
        stdout = $stdout
        stderr = $stderr
    }
    $owned.Add($entry)
    $manifest.processes = @($owned.ToArray())
    Save-DemoManifest -Path $paths.Manifest -Manifest $manifest
    if ($Port) {
        Wait-DemoPort -Port $Port -Process $process -TimeoutSeconds $TimeoutSeconds
    } else {
        Start-Sleep -Seconds 2
        $process.Refresh()
        if ($process.HasExited) { throw "Component '$Name' exited during startup. Check $stderr." }
    }
    Write-Host "Ready: $Name (PID $($process.Id))"
}

try {
    Start-DemoComponent -Name 'broker' -Executable $paths.Broker -Arguments @('-c', $paths.BrokerConfig) -Port 1883
    Start-DemoComponent -Name 'dashboard' -Executable $paths.Node -Arguments @($paths.NodeRed, '--userDir', $paths.NodeRedUserDir,
        '--settings', $paths.DashboardSettings, $paths.DashboardFlows) -Port 1880 -TimeoutSeconds 45
    Start-DemoComponent -Name 'simulator' -Executable $paths.Python -Arguments @('-u', '-m', 'host.simulator', '--host', '127.0.0.1', '--port', '1502') -Port 1502
    Start-DemoComponent -Name 'gateway' -Executable $paths.Python -Arguments @('-u', '-m', 'host.gateway', '--modbus-host', '127.0.0.1',
        '--modbus-port', '1502', '--mqtt-host', '127.0.0.1', '--mqtt-port', '1883', '--trust-system-clock', '--log', (Join-Path $launchLogs 'gateway.events.jsonl'))
    Write-Host ''
    Write-Host 'Host simulation is running. No ESP32 or physical RS485 validation has occurred.'
    Write-Host 'Dashboard: http://127.0.0.1:1880/dashboard/'
    Write-Host "Logs: $launchLogs"
    Write-Host "Stop: & `"$(Join-Path $PSScriptRoot 'Stop-Demo.ps1')`" -RuntimeRoot `"$($paths.RuntimeRoot)`""
} catch {
    $launchError = $_
    $remaining = [Collections.Generic.List[object]]::new()
    $rollbackEntries = @($owned.ToArray())
    [Array]::Reverse($rollbackEntries)
    foreach ($entry in $rollbackEntries) {
        try {
            $process = Get-OwnedDemoProcess -Entry ([pscustomobject] $entry)
            if ($process) { Stop-Process -InputObject $process -Force -ErrorAction Stop }
        } catch {
            $remaining.Add($entry)
            Write-Warning "Rollback could not stop '$($entry.name)': $($_.Exception.Message)"
        }
    }
    if ($remaining.Count) {
        $manifest.processes = @($remaining.ToArray())
        Save-DemoManifest -Path $paths.Manifest -Manifest $manifest
    } elseif (Test-Path -LiteralPath $paths.Manifest -PathType Leaf) {
        Remove-Item -LiteralPath $paths.Manifest -Force
    }
    throw "Demo startup failed; processes started by this launch were rolled back. Logs: $launchLogs. $($launchError.Exception.Message)"
}
