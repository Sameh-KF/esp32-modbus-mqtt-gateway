# Shared path and process helpers for the local Windows host demonstration.
# Dot-source this file; it does not install tools or start processes.
Set-StrictMode -Version Latest

function Get-DemoPaths {
    param([string] $RuntimeRoot)
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $localConfig = Join-Path $projectRoot 'config/local-runtime.json'
    if (-not $RuntimeRoot -and (Test-Path -LiteralPath $localConfig -PathType Leaf)) {
        $config = Get-Content -LiteralPath $localConfig -Raw | ConvertFrom-Json
        if (-not $config.PSObject.Properties['runtime_root'] -or -not $config.runtime_root) {
            throw 'config/local-runtime.json must contain a non-empty runtime_root string.'
        }
        $RuntimeRoot = [string] $config.runtime_root
    }
    if (-not $RuntimeRoot) {
        $outputsRoot = Split-Path -Parent $projectRoot
        $workspaceRuntime = Join-Path (Split-Path -Parent $outputsRoot) 'work/runtime'
        if ((Split-Path -Leaf $outputsRoot) -eq 'outputs' -and (Test-Path -LiteralPath $workspaceRuntime -PathType Container)) {
            $RuntimeRoot = $workspaceRuntime
        } else {
            $RuntimeRoot = Join-Path $projectRoot '.runtime'
        }
    }
    if (-not [IO.Path]::IsPathRooted($RuntimeRoot)) {
        $RuntimeRoot = Join-Path $projectRoot $RuntimeRoot
    }
    $RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    [pscustomobject]@{
        ProjectRoot = $projectRoot
        RuntimeRoot = $RuntimeRoot
        Python = Join-Path $RuntimeRoot 'python-env/Scripts/python.exe'
        Broker = Join-Path $RuntimeRoot 'mosquitto/mosquitto.exe'
        BrokerConfig = Join-Path $projectRoot 'config/mosquitto.local.conf'
        Node = if ($nodeCommand) { $nodeCommand.Source } else { $null }
        NodeRed = Join-Path $RuntimeRoot 'node-red/node_modules/node-red/red.js'
        DashboardPackage = Join-Path $RuntimeRoot 'node-red/node_modules/@flowfuse/node-red-dashboard/package.json'
        NodeRedUserDir = Join-Path $RuntimeRoot 'node-red'
        DashboardSettings = Join-Path $projectRoot 'dashboard/settings.cjs'
        DashboardFlows = Join-Path $projectRoot 'dashboard/flows.json'
        Simulator = Join-Path $projectRoot 'host/simulator.py'
        Gateway = Join-Path $projectRoot 'host/gateway.py'
        StateDir = Join-Path $RuntimeRoot 'state'
        Manifest = Join-Path $RuntimeRoot 'state/demo-processes.json'
        LogsDir = Join-Path $RuntimeRoot 'logs'
    }
}

function ConvertTo-DemoArgument {
    param([AllowEmptyString()][string] $Value)
    # Start-Process joins ArgumentList values. Quote each Windows argument explicitly.
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $quoted = [Text.StringBuilder]::new('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void] $quoted.Append(('\' * (2 * $slashes + 1)))
            [void] $quoted.Append('"')
        } else {
            [void] $quoted.Append(('\' * $slashes))
            [void] $quoted.Append($character)
        }
        $slashes = 0
    }
    [void] $quoted.Append(('\' * (2 * $slashes)))
    [void] $quoted.Append('"')
    $quoted.ToString()
}

function Get-OwnedDemoProcess {
    param([Parameter(Mandatory)] $Entry)
    try {
        $process = Get-Process -Id ([int] $Entry.pid) -ErrorAction Stop
        $expected = [DateTimeOffset]::Parse([string] $Entry.start_time_utc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        if ($process.StartTime.ToUniversalTime().Ticks -eq $expected.Ticks) { return $process }
    } catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
        return $null
    }
    return $null
}

function Save-DemoManifest {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Manifest)
    $json = $Manifest | ConvertTo-Json -Depth 6
    $temporaryPath = "$Path.tmp"
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Test-DemoPortAvailable {
    param([int] $Port)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); return $true }
    catch [Net.Sockets.SocketException] { return $false }
    finally { $listener.Stop() }
}

function Wait-DemoPort {
    param([int] $Port, [Parameter(Mandatory)] $Process, [int] $TimeoutSeconds = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw "Process $($Process.Id) exited before port $Port became ready. Check this launch's logs." }
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connection = $client.ConnectAsync('127.0.0.1', $Port)
            if ($connection.Wait(200) -and $client.Connected) { return }
        } catch [AggregateException] { }
        catch [Net.Sockets.SocketException] { }
        finally { $client.Dispose() }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for 127.0.0.1:$Port. Check this launch's logs."
}
