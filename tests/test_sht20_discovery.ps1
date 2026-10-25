# Offline checks only. Dot-sourcing must not open a COM port.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../tools/Find-Sht20.ps1')
$script:discoveryPassed = 0
function Assert-Discovery {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:discoveryPassed++
    Write-Output "PASS: $Name"
}
function New-DiscoveryTestFrame {
    param([byte[]] $Body)
    $crc = Get-Sht20DiscoveryCrc -Data $Body
    return ,([byte[]] ($Body + @([byte] ($crc -band 255), [byte] ($crc -shr 8))))
}
function Assert-DiscoveryRejected {
    param([scriptblock] $Action, [string] $Name)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Discovery $rejected $Name
}
$request4 = New-Sht20DiscoveryRequest
Assert-Discovery ((ConvertTo-Sht20DiscoveryHex $request4) -eq '01 04 00 01 00 02 20 0B') 'known FC04 request and CRC'
$request3 = New-Sht20DiscoveryRequest -FunctionCode 3 -StartAddress 0 -Count 1
Assert-Discovery ((ConvertTo-Sht20DiscoveryHex $request3) -eq '01 03 00 00 00 01 84 0A') 'known FC03 request and CRC'
Assert-Discovery ((ConvertTo-Sht20DiscoveryHex (New-Sht20DiscoveryRequest -FunctionCode 3 -StartAddress 1 -Count 1)) -eq '01 03 00 01 00 01 D5 CA') 'known FC03 raw address 1 request'
Assert-Discovery ((ConvertTo-Sht20DiscoveryHex (New-Sht20DiscoveryRequest -FunctionCode 3 -StartAddress 257 -Count 1)) -eq '01 03 01 01 00 01 D4 36') 'known raw address 0x0101 request'
Assert-Discovery ((ConvertTo-Sht20DiscoveryHex (New-Sht20DiscoveryRequest -UnitId 2)) -eq '02 04 00 01 00 02 20 38') 'known unit 2 request'
Assert-DiscoveryRejected { New-Sht20DiscoveryRequest -UnitId 0 } 'broadcast forbidden'
Assert-DiscoveryRejected { New-Sht20DiscoveryRequest -UnitId 11 } 'request helper bounded to IDs 1..10'
Assert-DiscoveryRejected { New-Sht20DiscoveryRequest -FunctionCode 6 } 'write function forbidden'
[byte[]] $normal4 = @(1, 4, 4, 1, 49, 2, 34, 0x2A, 0xCE)
$result = Test-Sht20DiscoveryReply -Bytes $normal4 -Request $request4
Assert-Discovery ($result.matching_reply -and $result.reply.kind -eq 'normal') 'normal FC04 matches'
Assert-Discovery ($result.reply.frame_hex -eq '01 04 04 01 31 02 22 2A CE') 'raw reply retained without measurement decoding'
[byte[]] $normal3 = @(1, 3, 2, 1, 44, 0xB8, 9)
Assert-Discovery ((Test-Sht20DiscoveryReply -Bytes $normal3 -Request $request3).matching_reply) 'known FC03 normal response matches'
[byte[]] $exception4 = @(1, 0x84, 2, 0xC2, 0xC1)
$result = Test-Sht20DiscoveryReply -Bytes $exception4 -Request $request4
Assert-Discovery ($result.matching_reply -and $result.reply.kind -eq 'exception' -and $result.reply.exception_code -eq 2) 'matching exception identifies a candidate without a measurement'
[byte[]] $exception3 = @(1, 0x83, 2, 0xC0, 0xF1)
Assert-Discovery ((Test-Sht20DiscoveryReply -Bytes $exception3 -Request $request3).matching_reply) 'known FC03 exception matches'
$wrongUnit = New-DiscoveryTestFrame -Body ([byte[]] @(2, 4, 4, 1, 49, 2, 34))
$result = Test-Sht20DiscoveryReply -Bytes $wrongUnit -Request $request4
Assert-Discovery (-not $result.matching_reply -and ($result.diagnostics -match 'unit_mismatch')) 'wrong unit rejected despite valid CRC'
$wrongFc = New-DiscoveryTestFrame -Body ([byte[]] @(1, 3, 4, 1, 49, 2, 34))
$result = Test-Sht20DiscoveryReply -Bytes $wrongFc -Request $request4
Assert-Discovery (-not $result.matching_reply -and ($result.diagnostics -match 'function_mismatch')) 'wrong function rejected despite valid CRC'
Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes $exception3 -Request $request4).matching_reply) 'wrong exception function rejected'
$wrongCount = New-DiscoveryTestFrame -Body ([byte[]] @(1, 4, 2, 1, 49))
$result = Test-Sht20DiscoveryReply -Bytes $wrongCount -Request $request4
Assert-Discovery (-not $result.matching_reply -and ($result.diagnostics -match 'count_mismatch')) 'wrong byte count rejected despite valid CRC'
$oddCount = New-DiscoveryTestFrame -Body ([byte[]] @(1, 4, 3, 0, 0, 0))
Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes $oddCount -Request $request4).matching_reply) 'odd byte count rejected'
$corrupt = [byte[]] $normal4.Clone(); $corrupt[-1] = 0
Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes $corrupt -Request $request4).matching_reply) 'CRC corruption cannot count as a reply'
$result = Test-Sht20DiscoveryReply -Bytes $request4 -Request $request4
Assert-Discovery (-not $result.matching_reply -and $result.local_echo_count -eq 1) 'CRC-valid FC04 local echo is not a reply'
Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes $request3 -Request $request3).matching_reply) 'FC03 local echo is not a reply'
$result = Test-Sht20DiscoveryReply -Bytes ([byte[]] ($request4 + $normal4)) -Request $request4
Assert-Discovery ($result.matching_reply -and $result.local_echo_count -eq 1 -and $result.reply.offset -eq 8) 'echo plus real reply recovered'
$result = Test-Sht20DiscoveryReply -Bytes ([byte[]] (@(0xFF, 0, 1, 4, 0) + $normal4)) -Request $request4
Assert-Discovery ($result.matching_reply -and $result.reply.offset -eq 5) 'bad header does not discard a later reply'
Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes ([byte[]] @()) -Request $request4).matching_reply) 'silence cannot count as a reply'
Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes ([byte[]] @(0xFF, 0, 0xAA)) -Request $request4).matching_reply) 'noise cannot count as a reply'
for ($length = 1; $length -lt $normal4.Length; $length++) {
    $partial = [byte[]] $normal4[0..($length - 1)]
    Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes $partial -Request $request4).matching_reply) "truncation at $length bytes rejected"
}
Assert-Discovery (-not (Test-Sht20DiscoveryReply -Bytes ([byte[]] $exception4[0..3]) -Request $request4).matching_reply) 'truncated exception rejected'
$plan = @(Get-Sht20DiscoveryPlan)
Assert-Discovery ($plan.Count -eq 22) 'exactly 22 probes'
Assert-Discovery (($plan | Where-Object { $_.UnitId -lt 1 -or $_.UnitId -gt 10 -or $_.FunctionCode -notin @(3, 4) }).Count -eq 0) 'all probes addressed reads within 1..10'
Assert-Discovery (($plan[0..2].StartAddress -join ',') -eq '0,1,257') 'first three new unit-1 addresses in order'
Assert-Discovery (($plan[3..11].UnitId -join ',') -eq '2,3,4,5,6,7,8,9,10') 'next probes unit 2..10 only'
Assert-Discovery (($plan[12..21].Profile.Name -join ',') -eq '14400/8N1,14400/8N1,19200/8N1,19200/8N1,4800/8N1,4800/8N1,9600/8E1,9600/8E1,9600/8N2,9600/8N2') 'remaining profiles in specified order'
if (-not ('Sht20DiscoveryFakeSerial' -as [type])) {
    Add-Type -TypeDefinition '
using System;
using System.Collections.Generic;
using System.Threading;
public sealed class Sht20DiscoveryFakeSerial {
    private readonly Queue<byte> bytes;
    public int ReadTimeout { get; set; }
    public int BytesToRead { get { return bytes.Count; } }
    public Sht20DiscoveryFakeSerial(byte[] data) { bytes = new Queue<byte>(data); }
    public int ReadByte() {
        if (bytes.Count > 0) return bytes.Dequeue();
        Thread.Sleep(Math.Max(1, ReadTimeout));
        throw new TimeoutException("Offline fake timeout");
    }
}'
}
$captured = Read-Sht20DiscoveryCapture -Serial ([Sht20DiscoveryFakeSerial]::new($normal4)) -WindowMs 300 -Mode Active -Request $request4 -QuietMs 20
Assert-Discovery ($captured.raw_hex -eq '01 04 04 01 31 02 22 2A CE' -and $captured.end_reason -eq 'matching_reply_then_quiet') 'reader preserves normal frame through quiet window'
$captured = Read-Sht20DiscoveryCapture -Serial ([Sht20DiscoveryFakeSerial]::new($request4)) -WindowMs 80 -Mode Active -Request $request4 -QuietMs 10
Assert-Discovery ($captured.byte_count -eq 8 -and $captured.end_reason -eq 'deadline') 'echo alone waits through bounded deadline'
$captured = Read-Sht20DiscoveryCapture -Serial ([Sht20DiscoveryFakeSerial]::new([byte[]] @())) -WindowMs 50 -Mode Active -Request $request4
Assert-Discovery ($captured.byte_count -eq 0 -and $captured.elapsed_ms -lt 500) 'silent reader deadline bounded'
$passive = Read-Sht20DiscoveryCapture -Serial ([Sht20DiscoveryFakeSerial]::new($normal4)) -WindowMs 50 -Mode Passive
Assert-Discovery ($passive.raw_hex -eq '01 04 04 01 31 02 22 2A CE' -and $null -eq $passive.PSObject.Properties['matching_reply']) 'passive bytes preserved without solicited-success claim'
$captured = Read-Sht20DiscoveryCapture -Serial ([Sht20DiscoveryFakeSerial]::new([byte[]] (1..30))) -WindowMs 50 -MaxBytes 16
Assert-Discovery ($captured.byte_count -eq 16 -and $captured.byte_limit_reached -and $captured.end_reason -eq 'byte_limit') 'raw byte cap enforced'
Write-Output "PASS: $script:discoveryPassed offline checks; no COM port opened, no physical success claimed."