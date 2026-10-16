# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$SandboxId)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/release/artifact-audit-lib.ps1')
$root=Join-Path $repository '.private/windows-lifecycle-results'
[IO.Directory]::CreateDirectory($root) | Out-Null
Assert-AuditNoLinks $root
$identityPath=Join-Path $root '.mapping-identity.json'
if (!(Test-Path -LiteralPath $identityPath)) {
    $identity=[ordered]@{format=1;nonce=[guid]::NewGuid().ToString();host=$env:COMPUTERNAME}
    $file=[IO.File]::Open($identityPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    try { $bytes=[Text.Encoding]::UTF8.GetBytes(($identity | ConvertTo-Json -Compress)); $file.Write($bytes,0,$bytes.Length) } finally { $file.Dispose() }
}
Assert-AuditNoLinks $identityPath
$identity=Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json -AsHashtable
$nonce=[guid]::Empty
if ($identity.Count -ne 3 -or $identity.format -ne 1 -or $identity.host -cne $env:COMPUTERNAME -or ![guid]::TryParseExact($identity.nonce,'D',[ref]$nonce) -or $nonce -eq [guid]::Empty) { throw 'transport_mapping_identity_invalid' }
$checks=Join-Path $root '.mapping-checks'
[IO.Directory]::CreateDirectory($checks) | Out-Null
Assert-AuditNoLinks $checks
$challenge=[guid]::NewGuid().ToString()
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
function Test-GuestMapping {
    # Only fixed paths and canonical GUIDs enter this command. It neither
    # removes an old mapping nor writes into an unrecognized destination.
    $script=@'
$ErrorActionPreference='Stop'
$root='C:\ExVPN-Lifecycle-QA-Results'
if (!(Test-Path -LiteralPath $root -PathType Container)) { exit 78 }
$path=Join-Path $root '.mapping-identity.json'
if (!(Test-Path -LiteralPath $path -PathType Leaf)) { exit 79 }
$identity=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if ($identity.format -ne 1 -or $identity.nonce -cne '__NONCE__' -or $env:COMPUTERNAME -ieq $identity.host) { exit 79 }
$bytes=[Text.Encoding]::UTF8.GetBytes('{"challenge":"__CHALLENGE__","nonce":"__NONCE__","writable":true}')
$file=[IO.File]::Open((Join-Path $root '.mapping-checks\__CHALLENGE__.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
try { $file.Write($bytes,0,$bytes.Length) } finally { $file.Dispose() }
exit 0
'@
    $script=$script.Replace('__NONCE__',$identity.nonce).Replace('__CHALLENGE__',$challenge)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $start=[Diagnostics.ProcessStartInfo]::new($wsb)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach($argument in @('exec','--id',$SandboxId.ToString(),'--run-as','System','--command',('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded),'--raw')) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        [void]$process.Start(); $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) { $process.Kill($true); throw 'transport_mapping_probe_timeout' }
        $reply=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'transport_mapping_probe_failed' }
        [int]$reply.ExitCode
    } finally { $process.Dispose() }
}
$code=Test-GuestMapping
$created=$false
if ($code -eq 78) {
    $null=& $wsb share --id $SandboxId.ToString() --host-path $root --sandbox-path C:\ExVPN-Lifecycle-QA-Results --allow-write --raw
    if ($LASTEXITCODE -ne 0) { throw 'transport_initial_mapping_failed' }
    $created=$true
    $code=Test-GuestMapping
}
if ($code -ne 0) { throw 'transport_existing_mapping_unrecognized_or_unwritable' }
$ack=Get-Content -LiteralPath (Join-Path $checks ($challenge+'.json')) -Raw | ConvertFrom-Json -AsHashtable
if ($ack.Count -ne 3 -or $ack.challenge -cne $challenge -or $ack.nonce -cne $identity.nonce -or $ack.writable -isnot [bool] -or !$ack.writable) { throw 'transport_mapping_challenge_failed' }
[ordered]@{root=$root;created=$created;verified=$true}
