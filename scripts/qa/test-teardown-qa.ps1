# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'teardown-qa-lib.ps1')
$script:checks=0
function Check([string]$Name,[scriptblock]$Body){& $Body;$script:checks++;Write-Host ('PASS '+$Name)}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body}catch{$rejected=$true};if(!$rejected){throw 'invalid value accepted'}}
Check 'canonical run' {Assert-TeardownRunId '11111111-1111-4111-8111-111111111111'}
foreach($bad in @('','../x','00000000-0000-0000-0000-000000000000','AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA','{11111111-1111-4111-8111-111111111111}')){Check 'invalid run rejected' {Reject {Assert-TeardownRunId $bad}}}
Check 'immutable per-run input path' {if((Get-TeardownGuestInputRoot '11111111-1111-4111-8111-111111111111') -cne 'C:\ExVPN-Teardown-Input-11111111-1111-4111-8111-111111111111'){throw 'wrong input path'}}
Check 'second run cannot rebind input' {if((Get-TeardownGuestInputRoot '11111111-1111-4111-8111-111111111111') -ceq (Get-TeardownGuestInputRoot '22222222-2222-4222-8222-222222222222')){throw 'input path reused'}}
Check 'input path rejects escape' {Reject {Get-TeardownGuestInputRoot '..\payload'}}
$start=[DateTime]::SpecifyKind([DateTime]::new(2026,10,17),[DateTimeKind]::Utc)
$process=[pscustomobject]@{Id=42;Path='C:\Protected\owned.exe';StartTime=$start}
Check 'exact process' {Assert-TeardownProcessIdentity $process 42 $start.ToFileTimeUtc() 'C:\Protected\owned.exe'}
Check 'foreign PID' {Reject {Assert-TeardownProcessIdentity $process 43 $start.ToFileTimeUtc() 'C:\Protected\owned.exe'}}
Check 'reused PID' {Reject {Assert-TeardownProcessIdentity $process 42 ($start.ToFileTimeUtc()+1) 'C:\Protected\owned.exe'}}
Check 'foreign path' {Reject {Assert-TeardownProcessIdentity $process 42 $start.ToFileTimeUtc() 'C:\Other\owned.exe'}}
Check 'missing process' {Reject {Assert-TeardownProcessIdentity $null 42 $start.ToFileTimeUtc() 'C:\Protected\owned.exe'}}
Check 'guest System identity' {Assert-TeardownGuestContext 'GUEST' 'HOST' 'S-1-5-18' 'C:\Protected' 'C:\Protected'}
Check 'host rejected' {Reject {Assert-TeardownGuestContext 'HOST' 'HOST' 'S-1-5-18' 'C:\Protected' 'C:\Protected'}}
Check 'empty forbidden host rejected' {Reject {Assert-TeardownGuestContext 'GUEST' '' 'S-1-5-18' 'C:\Protected' 'C:\Protected'}}
Check 'ordinary user rejected' {Reject {Assert-TeardownGuestContext 'GUEST' 'HOST' 'S-1-5-21-1' 'C:\Protected' 'C:\Protected'}}
Check 'foreign script rejected' {Reject {Assert-TeardownGuestContext 'GUEST' 'HOST' 'S-1-5-18' 'C:\Other' 'C:\Protected'}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('exvpn-teardown-unit-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
$file=Join-Path $temp 'one.json'
try {
    Check 'checkpoint exact payload' {Write-TeardownCheckpoint $file ([ordered]@{value=7});if((Get-Content $file -Raw|ConvertFrom-Json).value -ne 7){throw 'wrong payload'}}
    Check 'checkpoint replacement rejected' {Reject {Write-TeardownCheckpoint $file ([ordered]@{value=9})};if((Get-Content $file -Raw|ConvertFrom-Json).value -ne 7){throw 'evidence replaced'}}
    Check 'temporary checkpoints removed' {if(@(Get-ChildItem -LiteralPath $temp -File).Count -ne 1){throw 'temporary file left'}}
} finally {if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file};[IO.Directory]::Delete($temp,$false)}
Write-Host ("Teardown QA: $script:checks checks PASS. No service, WFP or network changes.")
