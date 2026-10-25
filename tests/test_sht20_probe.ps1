# Offline protocol checks only. No COM ports are opened.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../tools/Test-Sht20.ps1')
$script:passed = 0
function Assert-True {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
function Get-TestFrame {
    param([string] $Hex)
    return ,([byte[]] @($Hex.Split(' ') | ForEach-Object { [Convert]::ToByte($_, 16) }))
}
function Assert-Rejected {
    param([scriptblock] $Action, [string] $Pattern, [string] $Name)
    try { & $Action | Out-Null }
    catch {
        Assert-True ($_.Exception.Message -match $Pattern) $Name
        return
    }
    throw "FAIL: $Name (response was accepted)"
}
$request = [BitConverter]::ToString((New-Sht20Request)).Replace('-', ' ')
Assert-True ($request -eq '01 04 00 01 00 02 20 0B') 'request matches manual FC04/address 1/count 2'
$goodFrame = Get-TestFrame '01 04 04 01 31 02 22 2A CE'
$good = ConvertFrom-Sht20Response -Frame $goodFrame
Assert-True ($good.temperature_c -eq 30.5 -and $good.humidity_pct -eq 54.6) 'manual example decodes correctly'
$negative = ConvertFrom-Sht20Response -Frame (Get-TestFrame '01 04 04 FF 33 02 22 BA E6')
Assert-True ($negative.temperature_c -eq -20.5 -and $negative.humidity_pct -eq 54.6) 'signed negative temperature'
$zero = ConvertFrom-Sht20Response -Frame (Get-TestFrame '01 04 04 00 00 00 00 FB 84')
Assert-True ($zero.temperature_c -eq 0 -and $zero.humidity_pct -eq 0) 'zero values remain valid measurements'
$maxHumidity = ConvertFrom-Sht20Response -Frame (Get-TestFrame '01 04 04 00 00 03 E8 FB 3A')
Assert-True ($maxHumidity.humidity_pct -eq 100) '100 percent humidity accepted'
Assert-Rejected { ConvertFrom-Sht20Response -Frame (Get-TestFrame '01 04 04 01 31 02 22 2A 00') } 'CRC mismatch' 'corrupted response rejected'
Assert-Rejected { ConvertFrom-Sht20Response -Frame (Get-TestFrame '01 04 04 01') } 'Truncated' 'truncated response rejected'
Assert-Rejected { ConvertFrom-Sht20Response -Frame $goodFrame -UnitId 2 } 'device address' 'wrong device rejected'
Assert-Rejected { ConvertFrom-Sht20Response -Frame (Get-TestFrame '01 84 02 C2 C1') } 'exception 0x02' 'Modbus exception is not a measurement'
[byte[]] $invalidBody = @(1, 4, 4, 0, 0, 3, 233)
$invalidCrc = Get-Sht20Crc -Data $invalidBody
[byte[]] $invalidHumidity = $invalidBody + @([byte] ($invalidCrc -band 255), [byte] ($invalidCrc -shr 8))
Assert-Rejected { ConvertFrom-Sht20Response -Frame $invalidHumidity } 'Humidity outside' 'out-of-range humidity rejected'
if (-not ('Sht20TestSerial' -as [type])) {
    Add-Type -TypeDefinition '
using System;
using System.Collections.Generic;
using System.Threading;
public sealed class Sht20TestSerial {
    private readonly Queue<byte> bytes;
    public int ReadTimeout { get; set; }
    public Sht20TestSerial(byte[] data) {
        bytes = data == null ? new Queue<byte>() : new Queue<byte>(data);
    }
    public int ReadByte() {
        if (bytes.Count > 0) return bytes.Dequeue();
        Thread.Sleep(Math.Max(1, ReadTimeout));
        throw new TimeoutException("Offline fake timeout");
    }
}'
}
function New-TestSerial {
    param([byte[]] $Data)
    return [Sht20TestSerial]::new($Data)
}
$received = Read-Sht20Frame -Serial (New-TestSerial $goodFrame) -TimeoutMs 250
Assert-True ([BitConverter]::ToString($received) -eq [BitConverter]::ToString($goodFrame)) 'byte-stream reader collects a full reply'
$exception = Read-Sht20Frame -Serial (New-TestSerial (Get-TestFrame '01 84 02 C2 C1')) -TimeoutMs 250
Assert-True ($exception.Length -eq 5) 'byte-stream reader accepts five-byte exception frame for validation'
Assert-Rejected { Read-Sht20Frame -Serial (New-TestSerial ([byte[]] @())) -TimeoutMs 50 } 'RTU timeout' 'no-data timeout is bounded'
Assert-Rejected { Read-Sht20Frame -Serial (New-TestSerial (Get-TestFrame '01 04 04 01')) -TimeoutMs 50 } 'RTU timeout.*Partial RX' 'partial reply times out with received bytes'
Assert-Rejected { Read-Sht20Frame -Serial (New-TestSerial (Get-TestFrame '01 04 00')) -TimeoutMs 50 } 'Unexpected response header' 'malformed byte count rejected early'
Write-Output "PASS: $script:passed offline protocol checks; no hardware opened."
