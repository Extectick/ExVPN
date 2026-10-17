# SPDX-License-Identifier: Apache-2.0
# Pure validation helpers also exercised under Windows PowerShell 5.1.
Set-StrictMode -Version Latest
function Assert-TeardownRunId([string]$RunId) {
    $parsed=[guid]::Empty
    if ($RunId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or
        ![guid]::TryParseExact($RunId,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'teardown_run_rejected' }
}
function Get-TeardownGuestInputRoot([string]$RunId) {
    Assert-TeardownRunId $RunId
    'C:\ExVPN-Teardown-Input-'+$RunId
}
function Assert-TeardownProcessIdentity($Process,[int]$ExpectedPid,[long]$ExpectedCreated,[string]$ExpectedPath) {
    if (!$Process -or $Process.Id -ne $ExpectedPid -or $Process.Path -ine $ExpectedPath -or
        $Process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $ExpectedCreated) { throw 'teardown_process_identity_changed' }
}
function Assert-TeardownGuestContext([string]$Machine,[string]$ForbiddenHost,[string]$Sid,[string]$ScriptRoot,[string]$ExpectedRoot) {
    if (!$ForbiddenHost -or $Machine -ieq $ForbiddenHost -or $Sid -cne 'S-1-5-18' -or
        [IO.Path]::GetFullPath($ScriptRoot).TrimEnd('\') -ine [IO.Path]::GetFullPath($ExpectedRoot).TrimEnd('\')) { throw 'teardown_disposable_system_required' }
}
function Get-TeardownNetworkHash {
    $routes=@(Get-NetRoute | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore | Sort-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore)
    $dns=@(Get-DnsClientServerAddress | Select-Object InterfaceIndex,AddressFamily,ServerAddresses | Sort-Object InterfaceIndex,AddressFamily)
    $json=[ordered]@{routes=$routes;dns=$dns} | ConvertTo-Json -Depth 5 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Write-TeardownCheckpoint([string]$Path,$Value) {
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12))
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllBytes($temp,$bytes)
        [IO.File]::Move($temp,$Path) # Refuse replacement on both PS5.1 and PS7.
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}
