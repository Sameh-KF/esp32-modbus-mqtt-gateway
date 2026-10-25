<#
.SYNOPSIS
Lists serial ports or reads two SHT20 Modbus input registers using Windows PowerShell.
.DESCRIPTION
Manual-based candidate profile: FC04, raw address 1, count 2, 9600/8N1.
No configuration writes, installations or automatic port selection.
Without -Port, only lists ports. Confirm the USB-RS485 port before opening it.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^(?i:COM)[1-9][0-9]*$')][string] $Port,
    [switch] $ListPorts,
    [ValidateRange(1, 247)][int] $UnitId = 1,
    [ValidateSet(9600, 14400, 19200)][int] $BaudRate = 9600,
    [ValidateRange(1, 20)][int] $Samples = 3,
    [ValidateRange(250, 10000)][int] $TimeoutMs = 1500
)
$ErrorActionPreference = 'Stop'

function Get-Sht20Crc {
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

function New-Sht20Request {
    param([ValidateRange(1, 247)][int] $UnitId = 1)
    [byte[]] $body = @($UnitId, 4, 0, 1, 0, 2)
    $crc = Get-Sht20Crc -Data $body
    return ,([byte[]] ($body + @([byte] ($crc -band 255), [byte] ($crc -shr 8))))
}

function ConvertFrom-Sht20Response {
    param([Parameter(Mandatory)][byte[]] $Frame, [int] $UnitId = 1)
    if ($Frame.Length -lt 5) { throw 'Truncated RTU response.' }
    $crc = Get-Sht20Crc -Data ([byte[]] $Frame[0..($Frame.Length - 3)])
    $receivedCrc = [int] $Frame[-2] + 256 * [int] $Frame[-1]
    if ([int] $crc -ne $receivedCrc) { throw 'CRC mismatch; response rejected.' }
    if ($Frame[0] -ne $UnitId) { throw "Unexpected device address: $($Frame[0])." }
    if ($Frame[1] -eq 0x84) {
        if ($Frame.Length -ne 5) { throw 'Invalid Modbus exception length.' }
        throw ('Modbus exception 0x{0:X2}; no measurement accepted.' -f $Frame[2])
    }
    if ($Frame[1] -ne 4) { throw "Unexpected function code: $($Frame[1])." }
    if ($Frame.Length -ne 9 -or $Frame[2] -ne 4) { throw 'Expected exactly two input registers (4 data bytes).' }
    [int] $temperature = 256 * [int] $Frame[3] + [int] $Frame[4]
    [int] $humidity = 256 * [int] $Frame[5] + [int] $Frame[6]
    if ($temperature -ge 32768) { $temperature -= 65536 }
    if ($humidity -gt 1000) { throw 'Humidity outside 0..100 percent; response rejected.' }
    [pscustomobject]@{
        temperature_c = $temperature / 10.0
        humidity_pct = $humidity / 10.0
    }
}

function Read-Sht20Frame {
    param([Parameter(Mandatory)] $Serial, [int] $TimeoutMs)
    $buffer = [Collections.Generic.List[byte]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $expected = 3
    while ($buffer.Count -lt $expected) {
        $remaining = $TimeoutMs - [int] $clock.ElapsedMilliseconds
        if ($remaining -le 0) {
            $partial = [BitConverter]::ToString($buffer.ToArray()).Replace('-', ' ')
            throw "RTU timeout after $TimeoutMs ms. Partial RX: [$partial]"
        }
        $Serial.ReadTimeout = [Math]::Min(100, $remaining)
        try { $buffer.Add([byte] $Serial.ReadByte()) }
        catch [TimeoutException] { continue }
        if ($buffer.Count -eq 3) {
            if ($buffer[1] -eq 0x84) { $expected = 5 }
            elseif ($buffer[1] -eq 4 -and $buffer[2] -eq 4) { $expected = 9 }
            else {
                $header = [BitConverter]::ToString($buffer.ToArray()).Replace('-', ' ')
                throw "Unexpected response header: [$header]. Check device/profile or adapter local echo."
            }
        }
    }
    return ,($buffer.ToArray())
}

# Dot-sourcing loads the pure parser helpers for offline tests without opening a port.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($ListPorts -or -not $Port) {
    [IO.Ports.SerialPort]::GetPortNames() | Sort-Object { [int] ($_ -replace '\D', '') }
    return
}

$serial = [IO.Ports.SerialPort]::new($Port, $BaudRate, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
$serial.Handshake = [IO.Ports.Handshake]::None
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$serial.WriteTimeout = 1000
[byte[]] $request = New-Sht20Request -UnitId $UnitId
$failures = 0
try {
    $serial.Open()
    Write-Host "Port $Port, $BaudRate/8N1, device $UnitId, FC04, raw start 1, count 2."
    for ($sample = 1; $sample -le $Samples; $sample++) {
        try {
            $serial.DiscardInBuffer()
            Write-Host ('TX: ' + [BitConverter]::ToString($request).Replace('-', ' '))
            $serial.Write($request, 0, $request.Length)
            [byte[]] $response = Read-Sht20Frame -Serial $serial -TimeoutMs $TimeoutMs
            Write-Host ('RX: ' + [BitConverter]::ToString($response).Replace('-', ' '))
            $values = ConvertFrom-Sht20Response -Frame $response -UnitId $UnitId
            [pscustomobject]@{
                sample = $sample
                captured_at_utc = [DateTime]::UtcNow.ToString('o')
                temperature_c = $values.temperature_c
                humidity_pct = $values.humidity_pct
                crc_valid = $true
            } | Format-List
        } catch {
            $failures++
            Write-Warning "Sample $sample failed: $($_.Exception.Message)"
        }
        if ($sample -lt $Samples) { Start-Sleep -Seconds 2 }
    }
} finally {
    $serial.Dispose()
}
if ($failures) { throw "$failures of $Samples reads failed. Do not treat failed reads as measurements." }
Write-Host "PASS: $Samples valid RTU response(s). Sensor profile still needs assessment against the actual device."
