<#
.SYNOPSIS
Prepares a project-local Windows x64 runtime for the host simulation.
.DESCRIPTION
Requires an existing Python >=3.10, Node.js >=22.9 and npm on PATH.
Downloads pinned official archives and verifies the SHA256 bytes used by this
project. Extracts Mosquitto; neither its installer nor a Windows service is run.
Python packages and Node-RED stay inside RuntimeRoot. No global installs,
administrator privileges, registry changes or firewall changes are requested.
.EXAMPLE
./tools/Install-Demo.ps1
.EXAMPLE
./tools/Install-Demo.ps1 -RuntimeRoot 'C:/MyDemoRuntime' -Python 'C:/Python314/python.exe'
#>
[CmdletBinding()]
param(
    [string] $RuntimeRoot,
    [string] $Python = 'python',
    [string] $DownloadCache
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Demo-Paths.ps1')
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'This installer supports Windows x64 only.'
}
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $RuntimeRoot) { $RuntimeRoot = Join-Path $projectRoot '.runtime' }
$paths = Get-DemoPaths -RuntimeRoot $RuntimeRoot
$RuntimeRoot = $paths.RuntimeRoot
if ($RuntimeRoot.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($RuntimeRoot).TrimEnd('\', '/') -or $RuntimeRoot -eq $projectRoot) {
    throw 'RuntimeRoot must be a dedicated directory, not a drive root or the project directory itself.'
}
if (-not $DownloadCache) { $DownloadCache = Join-Path $RuntimeRoot 'downloads' }
if (-not [IO.Path]::IsPathRooted($DownloadCache)) { $DownloadCache = Join-Path $projectRoot $DownloadCache }
$DownloadCache = [IO.Path]::GetFullPath($DownloadCache)
$pythonCommand = Get-Command -Name $Python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$npmCommand = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pythonCommand) { throw 'Python was not found. Install Python >=3.10 first, or pass -Python with its executable path.' }
if (-not $paths.Node) { throw 'Node.js was not found. Install Node.js >=22.9 first.' }
if (-not $npmCommand) { throw 'npm.cmd was not found. Install Node.js with npm first.' }
$pythonExecutable = $pythonCommand.Source
$npmExecutable = $npmCommand.Source

function Invoke-CheckedDemoCommand {
    param([string] $Executable, [string[]] $Arguments, [string] $Description)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

$pythonVersionText = & $pythonExecutable -c 'import sys; print(*sys.version_info[:3], sep=chr(46))'
if ($LASTEXITCODE -ne 0 -or -not $pythonVersionText) { throw 'Python could not report its version; check the selected executable.' }
if ([version] ([string] $pythonVersionText).Trim() -lt [version] '3.10.0') { throw 'Python >=3.10 is required.' }
$nodeVersionText = & $paths.Node --version
if ($LASTEXITCODE -ne 0 -or -not $nodeVersionText) { throw 'Node.js could not report its version.' }
if ([version] (([string] $nodeVersionText).Trim().TrimStart('v')) -lt [version] '22.9.0') { throw 'Node.js >=22.9 is required by Node-RED 5.0.8.' }
$npmVersionText = & $npmExecutable --version
if ($LASTEXITCODE -ne 0) { throw 'npm could not report its version.' }
Write-Host "Using Python $(([string] $pythonVersionText).Trim()), Node.js $(([string] $nodeVersionText).Trim()), npm $(([string] $npmVersionText).Trim())."

$requirementsPath = Join-Path $projectRoot 'requirements.txt'
$packagePath = Join-Path $projectRoot 'package.json'
$lockPath = Join-Path $projectRoot 'package-lock.json'
foreach ($required in @($requirementsPath, $packagePath, $lockPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required project file is missing: $required" }
}
$package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
if ($package.dependencies.'node-red' -ne '5.0.8' -or $package.dependencies.'@flowfuse/node-red-dashboard' -ne '1.33.0') {
    throw 'package.json must pin Node-RED 5.0.8 and FlowFuse Dashboard 1.33.0 for this installer.'
}
$lockSummaryCode = 'const lock = require(process.argv[1]); console.log(JSON.stringify({lockfileVersion:lock.lockfileVersion, packages:Object.entries(lock.packages || {}).filter(([path]) => path.length).map(([path, entry]) => ({path, version:entry.version}))}));'
$lockSummaryText = & $paths.Node -e $lockSummaryCode $lockPath
if ($LASTEXITCODE -ne 0) { throw 'Node.js could not read package-lock.json.' }
# npm uses an empty root-package key; Node emits a simple list that Windows
# PowerShell ConvertFrom-Json can read without requiring -AsHashtable.
$lock = $lockSummaryText | ConvertFrom-Json
if ($lock.lockfileVersion -ne 3 -or -not $lock.PSObject.Properties['packages']) { throw 'Expected an npm v3 package lock.' }
$lockedNodeRed = @($lock.packages | Where-Object { $_.path -eq 'node_modules/node-red' })
$lockedDashboard = @($lock.packages | Where-Object { $_.path -eq 'node_modules/@flowfuse/node-red-dashboard' })
if ($lockedNodeRed.Count -ne 1 -or $lockedDashboard.Count -ne 1 -or $lockedNodeRed[0].version -ne '5.0.8' -or $lockedDashboard[0].version -ne '1.33.0') {
    throw 'package-lock.json does not match the pinned dashboard package versions.'
}
$expectedLockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
if (Test-Path -LiteralPath $paths.Manifest -PathType Leaf) {
    $existingManifest = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
    if (-not $existingManifest.PSObject.Properties['processes']) { throw 'Inspect the invalid runtime process manifest before installing.' }
    foreach ($entry in @($existingManifest.processes)) {
        if (Get-OwnedDemoProcess -Entry $entry) { throw 'Stop the running demo with tools/Stop-Demo.ps1 before changing its runtime.' }
    }
}

$downloads = @(
    @{ Name = '7zr.exe'; Uri = 'https://github.com/ip7z/7zip/releases/download/26.04/7zr.exe'; Sha256 = '256FECA8E274E5DA655E2A284FABAFD9F554365EB164862089DACD4E8276D282' },
    @{ Name = '7z2604-x64.exe'; Uri = 'https://github.com/ip7z/7zip/releases/download/26.04/7z2604-x64.exe'; Sha256 = 'D54BF805F9F3704D1E8DB2FA3498AE7EF2DF0312B40B558E7C71C734430A665D' },
    @{ Name = 'mosquitto-2.1.2-install-windows-x64.exe'; Uri = 'https://mosquitto.org/files/binary/win64/mosquitto-2.1.2-install-windows-x64.exe'; Sha256 = '58008AD7A22ADA0B4073AFA415801746E027C5F583E4FA52D0F4E9193B98D6AA' }
)
$temporaryRoot = Join-Path $RuntimeRoot 'temp'
$extractorRoot = Join-Path $RuntimeRoot 'extractor'
$pythonRoot = Join-Path $RuntimeRoot 'python-env'
$pipCache = Join-Path $RuntimeRoot 'pip-cache'
$npmCache = Join-Path $RuntimeRoot 'npm-cache'
foreach ($directory in @($RuntimeRoot, $DownloadCache, $temporaryRoot, $extractorRoot, $paths.NodeRedUserDir, $pipCache, $npmCache)) {
    [void] [IO.Directory]::CreateDirectory($directory)
}
$savedEnvironment = @{}
foreach ($name in @('TEMP', 'TMP', 'PIP_CACHE_DIR', 'PIP_DISABLE_PIP_VERSION_CHECK', 'npm_config_cache', 'npm_config_update_notifier')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$originalLocation = Get-Location
try {
    $env:TEMP = $temporaryRoot
    $env:TMP = $temporaryRoot
    $env:PIP_CACHE_DIR = $pipCache
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:npm_config_cache = $npmCache
    $env:npm_config_update_notifier = 'false'
    foreach ($download in $downloads) {
        $destination = Join-Path $DownloadCache $download.Name
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Write-Host "Downloading $($download.Name) from its official source..."
            $partialPath = "$destination.partial-$([Guid]::NewGuid().ToString('N'))"
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $download.Uri -OutFile $partialPath -TimeoutSec 180
                if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash -ne $download.Sha256) {
                    throw "SHA256 mismatch for $($download.Name); the downloaded file will not be used."
                }
                Move-Item -LiteralPath $partialPath -Destination $destination
            } finally {
                if (Test-Path -LiteralPath $partialPath -PathType Leaf) { Remove-Item -LiteralPath $partialPath -Force }
            }
        }
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $download.Sha256) {
            throw "Cached file SHA256 mismatch: $destination. Obtain the pinned official file before retrying."
        }
    }
    Write-Host 'Extracting local tools; no installer or service is executed...'
    Invoke-CheckedDemoCommand -Executable (Join-Path $DownloadCache '7zr.exe') `
        -Arguments @('x', (Join-Path $DownloadCache '7z2604-x64.exe'), "-o$extractorRoot", '-y') -Description '7-Zip extraction'
    Invoke-CheckedDemoCommand -Executable (Join-Path $extractorRoot '7z.exe') `
        -Arguments @('x', (Join-Path $DownloadCache 'mosquitto-2.1.2-install-windows-x64.exe'), "-o$(Join-Path $RuntimeRoot 'mosquitto')", '-y') -Description 'Mosquitto extraction'
    if (-not (Test-Path -LiteralPath $paths.Broker -PathType Leaf)) { throw 'Mosquitto extraction did not produce mosquitto.exe.' }
    $brokerHelp = & $paths.Broker -h
    if ($LASTEXITCODE -ne 0 -or ($brokerHelp -join "`n") -notmatch 'mosquitto version 2\.1\.2') {
        throw 'Mosquitto 2.1.2 could not run. Check the local broker files and Windows runtime dependencies.'
    }

    if (-not (Test-Path -LiteralPath $paths.Python -PathType Leaf)) {
        Write-Host 'Creating the local Python environment...'
        Invoke-CheckedDemoCommand -Executable $pythonExecutable -Arguments @('-m', 'venv', '--copies', $pythonRoot) -Description 'Python environment creation'
    }
    Write-Host 'Installing the pinned Python dependencies into the local environment...'
    Invoke-CheckedDemoCommand -Executable $paths.Python -Arguments @('-m', 'pip', 'install', '--disable-pip-version-check', '--requirement', $requirementsPath) -Description 'Python dependency installation'
    Invoke-CheckedDemoCommand -Executable $paths.Python -Arguments @('-m', 'pip', 'check') -Description 'Python dependency verification'
    Invoke-CheckedDemoCommand -Executable $paths.Python -Arguments @('-c', "import sys, importlib.metadata as m; assert sys.version_info >= (3, 10); assert m.version('pymodbus') == '3.16.1'; assert m.version('paho-mqtt') == '2.1.0'; print('Pinned Python dependencies verified.')") -Description 'Pinned Python version verification'

    Copy-Item -LiteralPath $packagePath -Destination (Join-Path $paths.NodeRedUserDir 'package.json') -Force
    $runtimeLockPath = Join-Path $paths.NodeRedUserDir 'package-lock.json'
    Copy-Item -LiteralPath $lockPath -Destination $runtimeLockPath -Force
    # Precreate locked package folders and each package's nested node_modules
    # sequentially. npm's bundled dependencies create additional intermediate
    # directories (not distinct package-lock entries). This avoids a parallel
    # mkdir failure seen in the restricted workspace. npm ci deletes these folders.
    $nodeRedPrefix = $paths.NodeRedUserDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($lockedPackage in $lock.packages) {
        if (-not $lockedPackage.path.StartsWith('node_modules/', [StringComparison]::Ordinal)) { throw "Unexpected package-lock path: $($lockedPackage.path)" }
        $packageDirectory = [IO.Path]::GetFullPath((Join-Path $paths.NodeRedUserDir $lockedPackage.path))
        if (-not $packageDirectory.StartsWith($nodeRedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'A package-lock directory escapes the local Node-RED folder.' }
        [void] [IO.Directory]::CreateDirectory($packageDirectory)
        [void] [IO.Directory]::CreateDirectory((Join-Path $packageDirectory 'node_modules'))
    }
    Write-Host 'Installing the locked Node-RED dashboard dependencies locally (package scripts disabled)...'
    Set-Location -LiteralPath $paths.NodeRedUserDir
    Invoke-CheckedDemoCommand -Executable $npmExecutable -Arguments @('install', '--ignore-scripts', '--no-fund', '--no-audit', '--prefer-offline') -Description 'Locked Node-RED installation'
    if ((Get-FileHash -LiteralPath $runtimeLockPath -Algorithm SHA256).Hash -ne $expectedLockHash) {
        throw 'npm changed the dependency lock. The runtime is not accepted; inspect the lock before running the demo.'
    }
    $installedNodeRed = Get-Content -LiteralPath (Join-Path $paths.NodeRedUserDir 'node_modules/node-red/package.json') -Raw | ConvertFrom-Json
    $installedDashboard = Get-Content -LiteralPath $paths.DashboardPackage -Raw | ConvertFrom-Json
    if ($installedNodeRed.version -ne '5.0.8' -or $installedDashboard.version -ne '1.33.0') { throw 'Installed dashboard versions differ from the project pins.' }
    if (-not (Test-Path -LiteralPath $paths.NodeRed -PathType Leaf)) { throw 'Node-RED did not produce the expected red.js entry point.' }

    $localConfigPath = Join-Path $projectRoot 'config/local-runtime.json'
    $localConfig = [ordered]@{
        runtime_root = $RuntimeRoot
        prepared_at_utc = [DateTime]::UtcNow.ToString('o')
        source_mode = 'simulated'
        versions = [ordered]@{ python = ([string] $pythonVersionText).Trim(); node = ([string] $nodeVersionText).Trim(); mosquitto = '2.1.2'; node_red = '5.0.8'; flowfuse_dashboard = '1.33.0' }
    }
    Save-DemoManifest -Path $localConfigPath -Manifest $localConfig
    Write-Host ''
    Write-Host "Local runtime prepared: $RuntimeRoot"
    Write-Host 'No broker, gateway or dashboard processes have been started.'
    Write-Host "Start with: & `"$(Join-Path $PSScriptRoot 'Start-Demo.ps1')`""
} catch {
    throw "Local runtime preparation failed: $($_.Exception.Message) The partial runtime and download cache remain for inspection and retry."
} finally {
    Set-Location -LiteralPath $originalLocation.Path
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
