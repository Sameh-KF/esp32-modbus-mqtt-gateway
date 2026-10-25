<#
.SYNOPSIS
Captures real localhost MQTT traffic for evidence; never publishes or controls IO.
#>
[CmdletBinding()]
param(
    [string] $RuntimeRoot,
    [ValidateRange(1,600)][int] $Seconds = 60,
    [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Demo-Paths.ps1')
$paths = Get-DemoPaths -RuntimeRoot $RuntimeRoot
if (-not $OutputRoot) { $OutputRoot = Join-Path $paths.LogsDir 'hardware-evidence' }
if (-not [IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot = Join-Path $paths.ProjectRoot $OutputRoot }
if (-not (Test-Path -LiteralPath $paths.Python -PathType Leaf)) { throw 'Prepared Python runtime is missing.' }
Push-Location -LiteralPath $paths.ProjectRoot
try {
    & $paths.Python -m host.capture_hardware_evidence --seconds $Seconds --output-root $OutputRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Capture saved its evidence, but no fresh valid hardware measurements were accepted or MQTT failed. Inspect summary.json.'
    }
} finally { Pop-Location }
