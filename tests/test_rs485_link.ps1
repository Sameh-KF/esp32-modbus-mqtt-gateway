# Offline PC-side nonce and byte-stream tests; no COM port opened.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../tools/Test-Rs485Link.ps1')
$script:linkPassed = 0
function Assert-Link {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:linkPassed++
    Write-Output "PASS: $Name"
}
function Get-LinkBytes {
    param([string] $Text)
    return ,([Text.Encoding]::ASCII.GetBytes($Text))
}
$nonce = '0123456789ABCDEF'
Assert-Link (Test-Rs485Pong -Bytes (Get-LinkBytes ("PONG $nonce" + [char] 10)) -Nonce $nonce) 'complete matching PONG accepted'
Assert-Link (Test-Rs485Pong -Bytes (Get-LinkBytes ("PONG $nonce" + [char] 13 + [char] 10)) -Nonce $nonce) 'CRLF matching PONG accepted'
Assert-Link (-not (Test-Rs485Pong -Bytes (Get-LinkBytes ("PING $nonce" + [char] 10)) -Nonce $nonce)) 'request echo rejected'
Assert-Link (-not (Test-Rs485Pong -Bytes (Get-LinkBytes ("PONG FEDCBA9876543210" + [char] 10)) -Nonce $nonce)) 'old nonce rejected'
Assert-Link (-not (Test-Rs485Pong -Bytes (Get-LinkBytes ("PONG $nonce")) -Nonce $nonce)) 'unterminated line rejected'
Assert-Link (-not (Test-Rs485Pong -Bytes (Get-LinkBytes ("xPONG $nonce" + [char] 10)) -Nonce $nonce)) 'prefixed line rejected'
Assert-Link (-not (Test-Rs485Pong -Bytes (Get-LinkBytes ("PONG $nonce extra" + [char] 10)) -Nonce $nonce)) 'suffixed line rejected'
Assert-Link (-not (Test-Rs485Pong -Bytes (Get-LinkBytes ("pong $nonce" + [char] 10)) -Nonce $nonce)) 'wrong command case rejected'
[byte[]] $echoThenReply = Get-LinkBytes ("PING $nonce" + [char] 10 + "PONG $nonce" + [char] 10)
Assert-Link (Test-Rs485Pong -Bytes $echoThenReply -Nonce $nonce) 'real reply after echo accepted'
[byte[]] $oldThenNew = Get-LinkBytes ("PONG FEDCBA9876543210" + [char] 10 + "PONG $nonce" + [char] 10)
Assert-Link (Test-Rs485Pong -Bytes $oldThenNew -Nonce $nonce) 'fresh reply after stale nonce accepted'
Assert-Link (-not (Test-Rs485Pong -Bytes (Get-LinkBytes ("PONG $nonce" + [char] 13 + [char] 13 + [char] 10)) -Nonce $nonce)) 'extra CR rejected'
Assert-Link (-not (Test-Rs485Pong -Bytes ([byte[]] @()) -Nonce $nonce)) 'silence rejected'
if (-not ('Rs485LinkFakeSerial' -as [type])) {
    Add-Type -TypeDefinition '
using System;
using System.Collections.Generic;
using System.Threading;
public sealed class Rs485LinkFakeSerial {
    private readonly Queue<byte> bytes;
    public int ReadTimeout { get; set; }
    public bool FailRead { get; set; }
    public Rs485LinkFakeSerial(byte[] data) { bytes = new Queue<byte>(data); }
    public int ReadByte() {
        if (FailRead) throw new System.IO.IOException("Fake device disconnected");
        if (bytes.Count > 0) return bytes.Dequeue();
        Thread.Sleep(Math.Max(1, ReadTimeout));
        throw new TimeoutException("Offline fake timeout");
    }
}'
}
$reply = Read-Rs485Pong -Serial ([Rs485LinkFakeSerial]::new($echoThenReply)) -Nonce $nonce -TimeoutMs 100
Assert-Link ($reply.matched_pong -and $reply.byte_count -eq $echoThenReply.Length) 'stream reader verifies reply after echo'
$empty = Read-Rs485Pong -Serial ([Rs485LinkFakeSerial]::new([byte[]] @())) -Nonce $nonce -TimeoutMs 50
Assert-Link (-not $empty.matched_pong -and $empty.byte_count -eq 0 -and $empty.elapsed_ms -lt 500) 'silent timeout is bounded'
$capped = Read-Rs485Pong -Serial ([Rs485LinkFakeSerial]::new($echoThenReply)) -Nonce $nonce -TimeoutMs 100 -MaxBytes 16
Assert-Link (-not $capped.matched_pong -and $capped.byte_limit_reached) 'byte limit cannot accept partial response'
$broken = [Rs485LinkFakeSerial]::new([byte[]] @())
$broken.FailRead = $true
$rejected = $false
try { Read-Rs485Pong -Serial $broken -Nonce $nonce -TimeoutMs 100 | Out-Null }
catch { $rejected = $_.Exception.GetBaseException().Message -eq 'Fake device disconnected' }
Assert-Link $rejected 'device errors are surfaced'
Write-Output "PASS: $script:linkPassed offline checks; no physical link result claimed."
