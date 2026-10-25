param([string]$Compiler='gcc',[string]$Python='python')
$ErrorActionPreference='Stop'
$mainDirectory=Join-Path $PSScriptRoot '..\main'
$temporaryDirectory=Join-Path ([IO.Path]::GetTempPath()) ('gateway-host-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
foreach($name in @('sht20_protocol','gateway_payload')) {
    $exe=Join-Path $temporaryDirectory ($name+'.exe')
    & $Compiler -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror -O2 '-I' $mainDirectory (Join-Path $PSScriptRoot ('test_'+$name+'.c')) (Join-Path $mainDirectory ($name+'.c')) -o $exe
    if($LASTEXITCODE -ne 0){throw ('Host compilation failed: '+$name)}
    $result=& $exe
    if($LASTEXITCODE -ne 0){throw ('Host test failed: '+$name)}
    if($name -eq 'gateway_payload') {
        $path=Join-Path $temporaryDirectory 'payloads.jsonl'
        [IO.File]::WriteAllLines($path,[string[]]$result,[Text.UTF8Encoding]::new($false))
        & $Python (Join-Path $PSScriptRoot 'verify_payloads.py') $path
        if($LASTEXITCODE -ne 0){throw 'JSON field verification failed'}
    } else { $result }
}
