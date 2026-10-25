<#
.SYNOPSIS
Tests PC <-> USB-RS485 <-> XY-485 <-> ESP32 using nonce-matched PING/PONG.
.DESCRIPTION
Use only with the standalone rs485-link-test firmware and sensor disconnected.
Logs raw RX; never accepts a request echo or an old nonce as a reply.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^(?i:COM)[1-9][0-9]*$')][string] $Port,
    [ValidateRange(1, 10)][int] $Samples = 3,
    [ValidateRange(250, 10000)][int] $TimeoutMs = 2000
)
function Test-Rs485Pong {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{16}$')][string] $Nonce
    )
    $lines = [Text.Encoding]::ASCII.GetString($Bytes).Split([char] 10)
    for ($index = 0; $index -lt $lines.Count - 1; $index++) {
        $line = $lines[$index]
        if ($line.Length -gt 0 -and $line[-1] -eq [char] 13) { $line = $line.Substring(0, $line.Length - 1) }
        if ([string]::Equals($line, "PONG $Nonce", [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}
function Read-Rs485Pong {
    param(
        [Parameter(Mandatory)] $Serial,
        [Parameter(Mandatory)][string] $Nonce,
        [ValidateRange(1, 10000)][int] $TimeoutMs,
        [ValidateRange(16, 65536)][int] $MaxBytes = 4096
    )
    $bytes = [Collections.Generic.List[byte]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $matched = $false
    while ($bytes.Count -lt $MaxBytes -and $clock.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = $TimeoutMs - [int] $clock.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        $Serial.ReadTimeout = [Math]::Max(1, [Math]::Min(50, $remaining))
        try {
            $value = [byte] $Serial.ReadByte()
            $bytes.Add($value)
            if ($value -eq 10 -and (Test-Rs485Pong -Bytes $bytes.ToArray() -Nonce $Nonce)) {
                $matched = $true
                break
            }
        } catch [TimeoutException] { continue }
    }
    [pscustomobject]@{
        matched_pong = $matched
        byte_count = $bytes.Count
        raw_rx_hex = [BitConverter]::ToString($bytes.ToArray()).Replace('-', ' ')
        raw_rx_ascii = [Text.Encoding]::ASCII.GetString($bytes.ToArray())
        elapsed_ms = [int] $clock.ElapsedMilliseconds
        byte_limit_reached = ($bytes.Count -ge $MaxBytes)
    }
}
function Invoke-Rs485LinkTest {
    param(
        [Parameter(Mandatory)][string] $Port,
        [int] $Samples,
        [int] $TimeoutMs,
        [Parameter(Mandatory)][string] $ProjectRoot
    )
    $ErrorActionPreference = 'Stop'
    $logDirectory = Join-Path $ProjectRoot 'logs'
    [void] [IO.Directory]::CreateDirectory($logDirectory)
    $logPath = Join-Path $logDirectory ('rs485-link-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N'))
    $log = [ordered]@{
        schema_version = 1
        started_at_utc = [DateTime]::UtcNow.ToString('o')
        completed_at_utc = $null
        port = $Port
        profile = '9600/8N1'
        test = 'PC PING / ESP32 PONG with fresh 16-hex nonce per request'
        samples = [Collections.Generic.List[object]]::new()
        matched_pongs = 0
        error = $null
        limitations = 'This validates the tested link only. No SHT20, voltage, accuracy or Modbus validation is claimed.'
    }
    $serial = $null
    try {
        $serial = [IO.Ports.SerialPort]::new($Port, 9600, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
        $serial.Handshake = [IO.Ports.Handshake]::None
        $serial.DtrEnable = $false
        $serial.RtsEnable = $false
        $serial.WriteTimeout = 1000
        $serial.Open()
        Write-Host "Standalone ESP32 peer test on $Port, 9600/8N1; sensor must be disconnected."
        for ($sample = 1; $sample -le $Samples; $sample++) {
            $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 16).ToUpperInvariant()
            $record = [ordered]@{
                sample = $sample
                started_at_utc = [DateTime]::UtcNow.ToString('o')
                nonce = $nonce
                tx_ascii = "PING $nonce"
                rx = $null
                error = $null
            }
            $log.samples.Add($record)
            try {
                $serial.DiscardInBuffer()
                [byte[]] $request = [Text.Encoding]::ASCII.GetBytes("PING $nonce" + [char] 10)
                Write-Host "TX: PING $nonce"
                $serial.Write($request, 0, $request.Length)
                $record.rx = Read-Rs485Pong -Serial $serial -Nonce $nonce -TimeoutMs $TimeoutMs
                Write-Host "RX HEX: [$($record.rx.raw_rx_hex)]"
                if ($record.rx.matched_pong) {
                    $log.matched_pongs++
                    Write-Host "MATCH: PONG $nonce"
                } else { Write-Warning "No complete matching PONG for sample $sample." }
            } catch {
                $record.error = $_.Exception.Message
                Write-Warning "Sample $sample failed: $($record.error)"
            }
            if ($sample -lt $Samples) { Start-Sleep -Milliseconds 300 }
        }
    } catch { $log.error = $_.Exception.Message; throw }
    finally {
        if ($null -ne $serial) { $serial.Dispose() }
        $log.completed_at_utc = [DateTime]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($logPath, ($log | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Write-Host "JSON log: $logPath"
    }
    if ($log.matched_pongs -ne $Samples) { throw "$($log.matched_pongs)/$Samples matching PONG replies. Compare ESP32 console RX/TX with this log." }
    Write-Host "PASS: $Samples/$Samples fresh nonce-matched PONG replies; bidirectional link observed."
}
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Port) { throw 'Specify the confirmed USB-RS485 adapter: -Port COM14' }
Invoke-Rs485LinkTest -Port $Port -Samples $Samples -TimeoutMs $TimeoutMs -ProjectRoot (Split-Path -Parent $PSScriptRoot)
