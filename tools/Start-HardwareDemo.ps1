<#
.SYNOPSIS
Starts or reuses the local broker/dashboard for the physical ESP32 gateway.
.DESCRIPTION
Stops only manifest-owned synthetic gateway/simulator processes. Never starts
them. Existing compatible hardware runs are reused. Use -RestartDashboard once
when migrating the old dashboard; -RestartBroker only when its LAN bind changed.
No serial access, services, password changes, ACL changes or firewall changes.
#>
[CmdletBinding()]
param(
    [string] $RuntimeRoot,
    [string] $LanAddress,
    [switch] $RestartDashboard,
    [switch] $RestartBroker
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Demo-Paths.ps1')
$paths = Get-DemoPaths -RuntimeRoot $RuntimeRoot

function Resolve-HardwareLanAddress {
    param([string] $Requested)
    $candidates = @()
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne 'Up' -or $adapter.NetworkInterfaceType -eq 'Loopback') { continue }
        $properties = $adapter.GetIPProperties()
        $hasGateway = @($properties.GatewayAddresses | Where-Object {
            $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.ToString() -ne '0.0.0.0'
        }).Count -gt 0
        foreach ($address in $properties.UnicastAddresses) {
            $ip = $address.Address
            if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                -not [Net.IPAddress]::IsLoopback($ip) -and -not $ip.ToString().StartsWith('169.254.')) {
                $candidates += [pscustomobject]@{ Address=$ip.ToString(); DefaultRoute=$hasGateway }
            }
        }
    }
    if (-not $candidates.Count) { throw 'No usable active LAN IPv4 address was found.' }
    if ($Requested) {
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($Requested, [ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $Requested -notin @($candidates | ForEach-Object { $_.Address })) { throw '-LanAddress must be an IPv4 address currently assigned to this computer.' }
        return $Requested
    }
    $preferred = @($candidates | Where-Object DefaultRoute | Select-Object -ExpandProperty Address -Unique)
    if ($preferred.Count -eq 1) { return $preferred[0] }
    $all = @($candidates | Select-Object -ExpandProperty Address -Unique)
    if ($all.Count -eq 1) { return $all[0] }
    throw 'LAN selection is ambiguous. Pass -LanAddress with the computer IPv4 address reachable by the ESP32.'
}

function Get-HardwareOwnedProcess {
    param($Entry)
    $process = Get-OwnedDemoProcess -Entry $Entry
    if ($process -and -not [string]::Equals([IO.Path]::GetFullPath($process.Path),
            [IO.Path]::GetFullPath([string]$Entry.executable), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recorded process '$($Entry.name)' executable identity differs. No process will be selected by name."
    }
    return $process
}

foreach ($required in @($paths.Broker,$paths.BrokerConfig,$paths.NodeRed,$paths.DashboardPackage,
        $paths.DashboardSettings,$paths.DashboardFlows)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file missing: $required" }
}
if (-not $paths.Node) { throw 'Node.js is not available on PATH.' }
$LanAddress = Resolve-HardwareLanAddress -Requested $LanAddress
$brokerText = [IO.File]::ReadAllText($paths.BrokerConfig)
$loopback = [regex]::Match($brokerText, '(?ms)^\s*listener\s+1883\s+127\.0\.0\.1\s*$.*?(?=^\s*listener\s|\z)')
$lan = [regex]::Match($brokerText, '(?ms)^\s*listener\s+1884\s+\S+\s*$.*?(?=^\s*listener\s|\z)')
$password = [regex]::Match($brokerText, '(?m)^\s*password_file\s+(.+?)\s*$')
if (-not $loopback.Success -or -not $lan.Success -or -not $password.Success -or
    $brokerText -notmatch '(?m)^\s*allow_anonymous\s+false\s*$' -or
    $loopback.Value -notmatch '(?m)^\s*listener_allow_anonymous\s+true\s*$' -or
    $lan.Value -notmatch '(?m)^\s*listener_allow_anonymous\s+false\s*$') {
    throw 'Expected existing security policy: anonymous loopback 1883, authenticated LAN 1884 and password_file. Configuration was not relaxed.'
}
$passwordPath = $password.Groups[1].Value.Trim().Trim('"')
if (-not [IO.Path]::IsPathRooted($passwordPath)) { $passwordPath = Join-Path $paths.ProjectRoot $passwordPath }
if (-not (Test-Path -LiteralPath $passwordPath -PathType Leaf)) { throw 'The existing broker password file is missing. No credentials were created.' }
$entries = @{}
$previous = $null
if (Test-Path -LiteralPath $paths.Manifest -PathType Leaf) {
    $previous = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
    if (-not $previous.PSObject.Properties['processes'] -or
        -not [string]::Equals([string]$previous.project_root,$paths.ProjectRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The existing manifest is invalid or belongs to another project.'
    }
    foreach ($entry in @($previous.processes)) {
        if (Get-HardwareOwnedProcess $entry) { $entries[$entry.name] = $entry }
    }
}
foreach ($port in @(1883,1880)) {
    $component = if ($port -eq 1883) { 'broker' } else { 'dashboard' }
    if (-not $entries.ContainsKey($component) -and -not (Test-DemoPortAvailable -Port $port)) {
        throw "Port $port belongs to an unrecorded process. No broad process stop or adoption is allowed."
    }
}
if ($entries.ContainsKey('broker') -and -not $RestartBroker) {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 1884 -ErrorAction SilentlyContinue)
    if (-not @($listeners | Where-Object { $_.OwningProcess -eq $entries.broker.pid -and $_.LocalAddress -eq $LanAddress }).Count) {
        throw 'The owned broker is not listening on the requested LAN IPv4:1884. Rerun with -RestartBroker to restart only that owned broker.'
    }
}
$existingView = $null
if ($entries.ContainsKey('dashboard') -and -not $RestartDashboard) {
    try { $existingView = Invoke-RestMethod -Uri 'http://127.0.0.1:1880/api/state' -TimeoutSec 3 }
    catch { throw 'The owned dashboard does not expose the current receiver. Rerun with -RestartDashboard to reload it.' }
    if (-not $existingView.PSObject.Properties['expected_source_mode'] -or
        $existingView.expected_source_mode -ne 'hardware' -or -not $existingView.run_id) {
        throw 'The owned dashboard is not in hardware mode. Rerun with -RestartDashboard for a fresh hardware-only receiver.'
    }
}
# These are the only synthetic processes this launcher is authorized to stop.
& (Join-Path $PSScriptRoot 'Stop-Demo.ps1') -RuntimeRoot $paths.RuntimeRoot -Component @('gateway','simulator')
$entries.Remove('gateway')
$entries.Remove('simulator')
foreach ($component in @('dashboard','broker')) {
    $restart = ($component -eq 'dashboard' -and $RestartDashboard) -or ($component -eq 'broker' -and $RestartBroker)
    if ($restart -and $entries.ContainsKey($component)) {
        $ownedProcess = Get-HardwareOwnedProcess $entries[$component]
        if ($ownedProcess) { Stop-Process -InputObject $ownedProcess -Force -ErrorAction Stop }
        $entries.Remove($component)
    }
}
[void][IO.Directory]::CreateDirectory($paths.StateDir)
[void][IO.Directory]::CreateDirectory($paths.LogsDir)
$runId = if ($existingView -and -not $RestartDashboard) { [string]$existingView.run_id } else {
    [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6)
}
$launchLogs = Join-Path $paths.LogsDir ("hardware-" + $runId)
[void][IO.Directory]::CreateDirectory($launchLogs)
$runtimeBrokerConfig = Join-Path $launchLogs 'mosquitto.hardware.conf'
$brokerText = [regex]::Replace($brokerText, '(?m)^(\s*listener\s+1884\s+)\S+([^\S\r\n]*)$', {
    param($match) $match.Groups[1].Value + $LanAddress + $match.Groups[2].Value
})
[IO.File]::WriteAllText($runtimeBrokerConfig,$brokerText,[Text.UTF8Encoding]::new($false))
$manifest = [ordered]@{
    schema_version=1;run_id=$runId;source_mode='hardware';project_root=$paths.ProjectRoot
    runtime_root=$paths.RuntimeRoot;started_at_utc=[DateTime]::UtcNow.ToString('o')
    log_directory=$launchLogs;lan_address=$LanAddress;broker_config=$runtimeBrokerConfig;processes=@()
}
$active = [Collections.Generic.List[object]]::new()
$startedHere = [Collections.Generic.List[object]]::new()
foreach ($component in @('broker','dashboard')) {
    if ($entries.ContainsKey($component)) { $active.Add($entries[$component]) }
}
function Save-HardwareProcessList {
    $manifest.processes = @($active.ToArray())
    Save-DemoManifest -Path $paths.Manifest -Manifest $manifest
}
function Start-HardwareComponent {
    param([string]$Name,[string]$Executable,[string[]]$Arguments,[int]$Port,[int]$TimeoutSeconds=20)
    $argumentsText = ($Arguments | ForEach-Object { ConvertTo-DemoArgument $_ }) -join ' '
    $stdout = Join-Path $launchLogs "$Name.stdout.log"
    $stderr = Join-Path $launchLogs "$Name.stderr.log"
    $startOptions = @{
        FilePath=$Executable;ArgumentList=$argumentsText;WorkingDirectory=$paths.ProjectRoot
        WindowStyle='Hidden';RedirectStandardOutput=$stdout;RedirectStandardError=$stderr;PassThru=$true
    }
    $process = Start-Process @startOptions
    $entry = [pscustomobject]@{
        name=$Name;pid=$process.Id;start_time_utc=$process.StartTime.ToUniversalTime().ToString('o')
        executable=$Executable;stdout=$stdout;stderr=$stderr
    }
    $active.Add($entry)
    $startedHere.Add($entry)
    Save-HardwareProcessList
    Wait-DemoPort -Port $Port -Process $process -TimeoutSeconds $TimeoutSeconds
    Write-Host "Ready: $Name (PID $($process.Id))"
}
try {
    Save-HardwareProcessList
    if (-not $entries.ContainsKey('broker')) {
        Start-HardwareComponent -Name 'broker' -Executable $paths.Broker -Arguments @('-c',$runtimeBrokerConfig) -Port 1883
    }
    if (-not $entries.ContainsKey('dashboard')) {
        $oldSourceMode = [Environment]::GetEnvironmentVariable('INDUSTRIAL_SOURCE_MODE','Process')
        $oldRunId = [Environment]::GetEnvironmentVariable('INDUSTRIAL_RUN_ID','Process')
        try {
            [Environment]::SetEnvironmentVariable('INDUSTRIAL_SOURCE_MODE','hardware','Process')
            [Environment]::SetEnvironmentVariable('INDUSTRIAL_RUN_ID',$runId,'Process')
            Start-HardwareComponent -Name 'dashboard' -Executable $paths.Node -Arguments @(
                $paths.NodeRed,'--userDir',$paths.NodeRedUserDir,'--settings',$paths.DashboardSettings,$paths.DashboardFlows
            ) -Port 1880 -TimeoutSeconds 45
        } finally {
            [Environment]::SetEnvironmentVariable('INDUSTRIAL_SOURCE_MODE',$oldSourceMode,'Process')
            [Environment]::SetEnvironmentVariable('INDUSTRIAL_RUN_ID',$oldRunId,'Process')
        }
    }
    $view = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try {
            $view = Invoke-RestMethod -Uri 'http://127.0.0.1:1880/api/state' -TimeoutSec 2
            if ($view.expected_source_mode -eq 'hardware' -and $view.run_id -eq $runId) { break }
        } catch { }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $view -or $view.expected_source_mode -ne 'hardware' -or $view.run_id -ne $runId) {
        throw 'Dashboard did not confirm the hardware-only receiver and run ID.'
    }
    Write-Host 'Hardware runtime ready. Waiting for live ESP32-S3 telemetry.'
    Write-Host "ESP32 broker address: $LanAddress port 1884 (existing authentication)"
    Write-Host 'Dashboard: http://127.0.0.1:1880/dashboard/'
    Write-Host "Run ID: $runId"
    Write-Host "Logs: $launchLogs"
} catch {
    $failure = $_
    $rollback = @($startedHere.ToArray())
    [Array]::Reverse($rollback)
    foreach ($entry in $rollback) {
        try {
            $process = Get-HardwareOwnedProcess $entry
            if ($process) { Stop-Process -InputObject $process -Force -ErrorAction Stop }
            [void]$active.Remove($entry)
        } catch { Write-Warning "Could not roll back owned component '$($entry.name)'." }
    }
    Save-HardwareProcessList
    throw "Hardware startup failed. Existing reused components were preserved. Logs: $launchLogs. $($failure.Exception.Message)"
}
