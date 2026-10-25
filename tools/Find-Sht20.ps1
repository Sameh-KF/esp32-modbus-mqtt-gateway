<#
.SYNOPSIS
Bounded, read-only SHT20 RTU discovery; requires an explicitly confirmed COM port.
.DESCRIPTION
Only FC03/FC04 reads. No broadcast, sensor configuration, ASCII commands, or
RTS/DE control. Adapter settings change locally. A silent default run takes
about 35 seconds plus host overhead. Raw traffic is printed and logged under
project/logs. No payload is interpreted as a validated measurement.
Dot-source to load helpers without opening a port.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^(?i:COM)[1-9][0-9]*$')][string] $Port,
    [ValidateRange(250, 5000)][int] $TimeoutMs = 1200
)

function Get-Sht20DiscoveryCrc {
    param([Parameter(Mandatory)][byte[]] $Data)
    [int] $crc = 0xFFFF
    foreach ($value in $Data) {
        $crc = $crc -bxor [int] $value
        for ($bit = 0; $bit -lt 8; $bit++) {
            if ($crc -band 1) { $crc = ($crc -shr 1) -bxor 0xA001 }
            else { $crc = $crc -shr 1 }
        }
    }
    return [uint16] $crc
}
function ConvertTo-Sht20DiscoveryHex {
    param([AllowEmptyCollection()][byte[]] $Bytes = @())
    return [BitConverter]::ToString($Bytes).Replace('-', ' ')
}
function New-Sht20DiscoveryRequest {
    param(
        [ValidateRange(1, 10)][int] $UnitId = 1,
        [ValidateSet(3, 4)][int] $FunctionCode = 4,
        [ValidateSet(0, 1, 257)][int] $StartAddress = 1,
        [ValidateSet(1, 2)][int] $Count = 2
    )
    [byte[]] $body = @($UnitId, $FunctionCode, ($StartAddress -shr 8), ($StartAddress -band 255), 0, $Count)
    $crc = Get-Sht20DiscoveryCrc -Data $body
    return ,([byte[]] ($body + @([byte] ($crc -band 255), [byte] ($crc -shr 8))))
}
function Get-Sht20DiscoveryPlan {
    $profiles = @(
        [pscustomobject]@{ Name = '9600/8N1'; Baud = 9600; Parity = 'None'; StopBits = 'One' },
        [pscustomobject]@{ Name = '14400/8N1'; Baud = 14400; Parity = 'None'; StopBits = 'One' },
        [pscustomobject]@{ Name = '19200/8N1'; Baud = 19200; Parity = 'None'; StopBits = 'One' },
        [pscustomobject]@{ Name = '4800/8N1'; Baud = 4800; Parity = 'None'; StopBits = 'One' },
        [pscustomobject]@{ Name = '9600/8E1'; Baud = 9600; Parity = 'Even'; StopBits = 'One' },
        [pscustomobject]@{ Name = '9600/8N2'; Baud = 9600; Parity = 'None'; StopBits = 'Two' }
    )
    foreach ($start in @(0, 1, 257)) {
        [pscustomobject]@{ Profile = $profiles[0]; UnitId = 1; FunctionCode = 3; StartAddress = $start; Count = 1 }
    }
    foreach ($unit in 2..10) {
        [pscustomobject]@{ Profile = $profiles[0]; UnitId = $unit; FunctionCode = 4; StartAddress = 1; Count = 2 }
    }
    foreach ($profile in $profiles[1..5]) {
        [pscustomobject]@{ Profile = $profile; UnitId = 1; FunctionCode = 4; StartAddress = 1; Count = 2 }
        [pscustomobject]@{ Profile = $profile; UnitId = 1; FunctionCode = 3; StartAddress = 0; Count = 1 }
    }
}
function Test-Sht20DiscoveryReply {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory)][byte[]] $Request
    )
    if ($Request.Length -ne 8 -or $Request[0] -lt 1 -or $Request[0] -gt 10 -or $Request[1] -notin @(3, 4)) {
        throw 'An eight-byte addressed FC03/FC04 discovery request is required.'
    }
    $requestCrc = Get-Sht20DiscoveryCrc -Data ([byte[]] $Request[0..5])
    if ([int] $requestCrc -ne ([int] $Request[6] + 256 * [int] $Request[7])) { throw 'Invalid request CRC.' }
    $expectedBytes = 2 * (256 * [int] $Request[4] + [int] $Request[5])
    $diagnostics = [Collections.Generic.List[string]]::new()
    $reply = $null
    $echoCount = 0
    for ($offset = 0; $offset -lt $Bytes.Length; $offset++) {
        # Never parse inside a complete, exact request echo.
        if (($Bytes.Length - $offset) -ge $Request.Length) {
            $echo = $true
            for ($i = 0; $i -lt $Request.Length; $i++) {
                if ($Bytes[$offset + $i] -ne $Request[$i]) { $echo = $false; break }
            }
            if ($echo) {
                $echoCount++; $diagnostics.Add("local_echo@$offset")
                $offset += $Request.Length - 1
                continue
            }
        }
        if (($Bytes.Length - $offset) -lt 2) { continue }
        $unit = [int] $Bytes[$offset]; $fc = [int] $Bytes[$offset + 1]
        if ($unit -lt 1 -or $unit -gt 247 -or $fc -notin @(3, 4, 0x83, 0x84)) { continue }
        if (($Bytes.Length - $offset) -lt 3) { $diagnostics.Add("truncated_header@$offset"); continue }
        $exception = (($fc -band 0x80) -ne 0)
        $byteCount = [int] $Bytes[$offset + 2]; $length = 5
        if (-not $exception) {
            if ($byteCount -lt 2 -or $byteCount -gt 250 -or ($byteCount % 2) -ne 0) {
                $diagnostics.Add("invalid_byte_count@$offset"); continue
            }
            $length = $byteCount + 5
        }
        if (($Bytes.Length - $offset) -lt $length) { $diagnostics.Add("truncated_frame@$offset"); continue }
        [byte[]] $frame = $Bytes[$offset..($offset + $length - 1)]
        $crc = Get-Sht20DiscoveryCrc -Data ([byte[]] $frame[0..($length - 3)])
        if ([int] $crc -ne ([int] $frame[-2] + 256 * [int] $frame[-1])) { $diagnostics.Add("crc_mismatch@$offset"); continue }
        if ($unit -ne $Request[0]) { $diagnostics.Add("unit_mismatch@$offset"); continue }
        $expectedFc = [int] $Request[1]
        if ($exception) { $expectedFc = $expectedFc -bor 0x80 }
        if ($fc -ne $expectedFc) { $diagnostics.Add("function_mismatch@$offset"); continue }
        if (-not $exception -and $byteCount -ne $expectedBytes) { $diagnostics.Add("count_mismatch@$offset"); continue }
        $reply = [pscustomobject]@{
            kind = $(if ($exception) { 'exception' } else { 'normal' })
            offset = $offset; frame_hex = ConvertTo-Sht20DiscoveryHex -Bytes $frame
            unit_id = $unit; function_code = $fc; crc_valid = $true
            exception_code = $(if ($exception) { $byteCount } else { $null })
        }
        break
    }
    [pscustomobject]@{
        matching_reply = ($null -ne $reply); reply = $reply; local_echo_count = $echoCount
        diagnostics = @($diagnostics | Select-Object -First 64)
    }
}
function Read-Sht20DiscoveryCapture {
    param(
        [Parameter(Mandatory)] $Serial,
        [Parameter(Mandatory)][ValidateRange(1, 10000)][int] $WindowMs,
        [ValidateSet('Passive', 'Active', 'Pending')][string] $Mode = 'Passive',
        [byte[]] $Request,
        [ValidateRange(16, 65536)][int] $MaxBytes = 4096,
        [ValidateRange(10, 500)][int] $QuietMs = 80
    )
    if ($Mode -eq 'Active' -and ($null -eq $Request -or $Request.Length -ne 8)) { throw 'Active capture requires its request.' }
    $buffer = [Collections.Generic.List[byte]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastByteMs = 0; $reason = 'deadline'; $readError = $null
    while ($clock.ElapsedMilliseconds -lt $WindowMs) {
        if ($buffer.Count -ge $MaxBytes) { $reason = 'byte_limit'; break }
        if ($buffer.Count -gt 0 -and ($clock.ElapsedMilliseconds - $lastByteMs) -ge $QuietMs) {
            if ($Mode -eq 'Pending') { $reason = 'quiet'; break }
            if ($Mode -eq 'Active' -and (Test-Sht20DiscoveryReply -Bytes $buffer.ToArray() -Request $Request).matching_reply) {
                $reason = 'matching_reply_then_quiet'; break
            }
        }
        if ($Mode -eq 'Pending' -and $buffer.Count -eq 0 -and $Serial.BytesToRead -eq 0) { $reason = 'empty'; break }
        $remaining = $WindowMs - [int] $clock.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        $Serial.ReadTimeout = [Math]::Max(1, [Math]::Min(40, $remaining))
        try { $buffer.Add([byte] $Serial.ReadByte()); $lastByteMs = $clock.ElapsedMilliseconds }
        catch [TimeoutException] { continue }
        catch { $readError = $_.Exception.Message; $reason = 'read_error'; break }
    }
    [pscustomobject]@{
        bytes = $buffer.ToArray(); raw_hex = ConvertTo-Sht20DiscoveryHex -Bytes $buffer.ToArray()
        byte_count = $buffer.Count; elapsed_ms = [int] $clock.ElapsedMilliseconds
        end_reason = $reason; byte_limit_reached = ($buffer.Count -ge $MaxBytes); error = $readError
    }
}
function Save-Sht20DiscoveryLog {
    param([Parameter(Mandatory)] $Log, [Parameter(Mandatory)][string] $Path)
    [IO.File]::WriteAllText($Path, ($Log | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
function Invoke-Sht20Discovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^(?i:COM)[1-9][0-9]*$')][string] $Port,
        [ValidateRange(250, 5000)][int] $TimeoutMs = 1200,
        [Parameter(Mandatory)][string] $ProjectRoot
    )
    $ErrorActionPreference = 'Stop'
    $plan = @(Get-Sht20DiscoveryPlan)
    $logDirectory = Join-Path $ProjectRoot 'logs'
    [void] [IO.Directory]::CreateDirectory($logDirectory)
    $logPath = Join-Path $logDirectory ('sht20-discovery-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N'))
    $log = [ordered]@{
        schema_version = 1; started_at_utc = [DateTime]::UtcNow.ToString('o'); completed_at_utc = $null; elapsed_ms = $null
        port = $Port; timeout_ms = $TimeoutMs; read_only = $true
        adapter_control = @{ data_bits = 8; handshake = 'None'; dtr_enable = $false; rts_enable = $false }
        scope = '22 planned reads; unit IDs 1..10; six adapter profiles; no sensor configuration writes'
        passive = $null; pending = [Collections.Generic.List[object]]::new(); probes = [Collections.Generic.List[object]]::new()
        outcome = 'running'; match = $null; error = $null
        limitations = @('Silence does not establish sensor failure.',
            'Only unit IDs 1..10 considered; not every unit tested at every profile.',
            'Matching reply/exception: candidate profile only; retest alone to confirm register map.',
            'Payloads are not validated measurements; RTU cannot identify late/unsolicited identical replies.')
    }
    Save-Sht20DiscoveryLog -Log $log -Path $logPath
    $serial = $null; $runClock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $serial = [IO.Ports.SerialPort]::new($Port, 9600, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
        $serial.Handshake = [IO.Ports.Handshake]::None; $serial.DtrEnable = $false; $serial.RtsEnable = $false
        $serial.WriteTimeout = 1000; $serial.Open()
        Start-Sleep -Milliseconds 300
        $silentSeconds = (2000 + $plan.Count * $TimeoutMs + 21 * 200 + 6 * 300) / 1000.0
        Write-Host "Read-only $Port; $($plan.Count) reads; silent run about $silentSeconds seconds plus host overhead."
        Write-Host "Handshake=None; DTR=False; RTS=False. Log: $logPath"
        $passive = Read-Sht20DiscoveryCapture -Serial $serial -WindowMs 2000 -Mode Passive
        $log.passive = [ordered]@{
            profile = '9600/8N1'; captured_at_utc = [DateTime]::UtcNow.ToString('o'); raw_hex = $passive.raw_hex
            byte_count = $passive.byte_count; end_reason = $passive.end_reason; error = $passive.error; accepted_as_reply = $false
        }
        Write-Host "Passive 9600/8N1 RX: [$($passive.raw_hex)] (not a solicited reply)"
        Save-Sht20DiscoveryLog -Log $log -Path $logPath
        if ($passive.error) { throw $passive.error }
        if ($passive.byte_limit_reached) { throw 'Passive byte limit reached; raw data preserved; discovery stopped.' }
        $currentProfile = '9600/8N1'; $index = 0
        foreach ($probe in $plan) {
            $index++
            if ($probe.Profile.Name -ne $currentProfile) {
                $serial.BaudRate = $probe.Profile.Baud
                $serial.Parity = [IO.Ports.Parity] ([Enum]::Parse([IO.Ports.Parity], $probe.Profile.Parity))
                $serial.StopBits = [IO.Ports.StopBits] ([Enum]::Parse([IO.Ports.StopBits], $probe.Profile.StopBits))
                $currentProfile = $probe.Profile.Name
                Start-Sleep -Milliseconds 300
            }
            # Preserve pending traffic separately; never flush/discard a bad header.
            $pending = Read-Sht20DiscoveryCapture -Serial $serial -WindowMs 200 -Mode Pending
            if ($pending.byte_count -gt 0 -or $pending.error) {
                $log.pending.Add([ordered]@{
                    before_probe = $index; profile = $currentProfile; captured_at_utc = [DateTime]::UtcNow.ToString('o')
                    raw_hex = $pending.raw_hex; byte_count = $pending.byte_count; end_reason = $pending.end_reason
                    error = $pending.error; accepted_as_reply = $false
                })
                Write-Host "Pending $currentProfile RX: [$($pending.raw_hex)] (not assigned to next probe)"
                Save-Sht20DiscoveryLog -Log $log -Path $logPath
            }
            if ($pending.error) { throw $pending.error }
            if ($pending.byte_limit_reached) { throw 'Pending byte limit reached; raw data preserved; discovery stopped.' }
            [byte[]] $request = New-Sht20DiscoveryRequest -UnitId $probe.UnitId -FunctionCode $probe.FunctionCode -StartAddress $probe.StartAddress -Count $probe.Count
            $record = [ordered]@{
                index = $index; started_at_utc = [DateTime]::UtcNow.ToString('o'); profile = $currentProfile
                unit_id = $probe.UnitId; function_code = $probe.FunctionCode; raw_start_address = $probe.StartAddress; register_count = $probe.Count
                tx_hex = ConvertTo-Sht20DiscoveryHex -Bytes $request; raw_rx_hex = ''; byte_count = 0
                end_reason = $null; byte_limit_reached = $false; analysis = $null; error = $null
            }
            $log.probes.Add($record)
            Write-Host "[$index/$($plan.Count)] $currentProfile unit=$($probe.UnitId) FC0$($probe.FunctionCode) start=$($probe.StartAddress) count=$($probe.Count) TX: [$($record.tx_hex)]"
            try {
                $serial.Write($request, 0, $request.Length)
                $capture = Read-Sht20DiscoveryCapture -Serial $serial -WindowMs $TimeoutMs -Mode Active -Request $request
                $record.raw_rx_hex = $capture.raw_hex; $record.byte_count = $capture.byte_count
                $record.end_reason = $capture.end_reason; $record.byte_limit_reached = $capture.byte_limit_reached; $record.error = $capture.error
                $record.analysis = Test-Sht20DiscoveryReply -Bytes $capture.bytes -Request $request
                Write-Host "RX: [$($capture.raw_hex)]"
                Save-Sht20DiscoveryLog -Log $log -Path $logPath
                if ($capture.error) { throw $capture.error }
                if ($record.analysis.matching_reply) {
                    $log.outcome = 'matching_reply'; $log.match = $record
                    Write-Host "STOP: matching $($record.analysis.reply.kind) reply at $currentProfile, unit $($probe.UnitId)."
                    Write-Host "Matched frame: [$($record.analysis.reply.frame_hex)]"
                    Write-Host 'Candidate only: retest this profile alone to confirm the register map. No validated measurements reported.'
                    break
                }
                if ($capture.byte_limit_reached) { throw 'RX byte limit reached; raw data preserved; discovery stopped.' }
            } catch { $record.error = $_.Exception.Message; throw }
            if ($index -lt $plan.Count) { Start-Sleep -Milliseconds 200 }
        }
        if ($log.outcome -eq 'running') {
            $log.outcome = 'no_matching_reply'
            Write-Host 'No matching reply. Silence does not establish sensor failure; unit IDs examined were only 1..10.'
        }
    } catch { $log.outcome = 'error'; $log.error = $_.Exception.Message; throw }
    finally {
        if ($null -ne $serial) { $serial.Dispose() }
        $log.completed_at_utc = [DateTime]::UtcNow.ToString('o'); $log.elapsed_ms = [int] $runClock.ElapsedMilliseconds
        Save-Sht20DiscoveryLog -Log $log -Path $logPath
        Write-Host "JSON log: $logPath"
    }
}
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Port) { throw 'Specify the confirmed adapter explicitly: .\Find-Sht20.ps1 -Port COM14 [-TimeoutMs 1200]' }
Invoke-Sht20Discovery -Port $Port -TimeoutMs $TimeoutMs -ProjectRoot (Split-Path -Parent $PSScriptRoot)