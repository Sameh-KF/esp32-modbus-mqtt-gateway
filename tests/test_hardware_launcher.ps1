# Read-only local network inventory regression. Does not execute the launcher.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$launcher=Join-Path $PSScriptRoot '../tools/Start-HardwareDemo.ps1'
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Launcher parse failed'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-HardwareLanAddress'},$false)
Invoke-Expression $function.Extent.Text
$addresses=@()
foreach($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
    if($adapter.OperationalStatus -ne 'Up' -or $adapter.NetworkInterfaceType -eq 'Loopback'){continue}
    foreach($unicast in $adapter.GetIPProperties().UnicastAddresses){
        $ipv4=$unicast.Address
        if($ipv4.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
           -not [Net.IPAddress]::IsLoopback($ipv4) -and -not $ipv4.ToString().StartsWith('169.254.')){
            $addresses += $ipv4.ToString()
        }
    }
}
if(-not $addresses.Count){throw 'No active IPv4 available for this read-only regression check'}
foreach($address in $addresses){
    $resolved=Resolve-HardwareLanAddress -Requested $address
    if($resolved -cne $address){throw 'Explicit assigned IPv4 was rejected or transformed'}
}
$rejected=$false
try{[void](Resolve-HardwareLanAddress -Requested '127.0.0.1')}catch{$rejected=$true}
if(-not $rejected){throw 'Loopback address was incorrectly accepted as hardware LAN'}
"PASS: explicit assigned IPv4 resolution for $($addresses.Count) addresses; loopback rejected; no processes or connections started."
