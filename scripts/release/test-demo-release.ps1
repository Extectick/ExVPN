# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'demo-release-lib.ps1')
$checks=0
function Assert-Refused([scriptblock]$Action) {
    $failed=$false
    try { & $Action } catch { $failed=$true }
    if (!$failed) { throw 'demo_negative_fixture_accepted' }
    $script:checks++
}
function New-Report([string]$Target) {
    [pscustomobject]@{
        schema=1;target=$Target;appVersion='0.1.0+18';expectedAppVersion='0.1.0+18'
        artifact=[pscustomobject]@{sha256=('a'*64)}
        flutterRuntime=[pscustomobject]@{engineBytesBound=$true;identity=[pscustomobject]@{kind='ordinary';buildMode='release'}}
        noticeEvidence=[pscustomobject]@{xraySource=[pscustomobject]@{matched=$true;patch=[pscustomobject]@{included=$true}}}
        signature=[pscustomobject]@{verified=$true;trustedSignerMatched=$true;debug=$false}
        noticeSource=$(if($Target -ceq 'Android'){'actual-apk-entries'}else{'installer-payload-verified'})
        nsisExtraction=[pscustomobject]@{verified=$true}
        complete=$false;releaseReady=$false
        findings=@([pscustomobject]@{code='dart_flutter_runtime_link_inventory_incomplete'})
    }
}
foreach($target in @('Android','Windows')) {
    $report=New-Report $target
    Assert-DemoAudit $report $target ('a'*64);$checks++
    foreach($mutation in @(
        {param($r)$r.appVersion='0.1.0+17'},
        {param($r)$r.expectedAppVersion='0.1.0+17'},
        {param($r)$r.artifact.sha256=('b'*64)},
        {param($r)$r.flutterRuntime.engineBytesBound=$false},
        {param($r)$r.flutterRuntime.identity.kind='shorebird'},
        {param($r)$r.flutterRuntime.identity.buildMode='debug'},
        {param($r)$r.noticeEvidence.xraySource.matched=$false},
        {param($r)$r.noticeEvidence.xraySource.patch.included=$false},
        {param($r)$r.releaseReady=$true},
        {param($r)$r.complete=$true},
        {param($r)$r.findings=@([pscustomobject]@{code='xray_source_does_not_match_linked_module'})},
        {param($r)$r.noticeSource='external-sidecar'}
    )) {
        $copy=New-Report $target
        & $mutation $copy
        Assert-Refused { Assert-DemoAudit $copy $target ('a'*64) }
    }
}
foreach($field in @('verified','trustedSignerMatched')) {
    $report=New-Report 'Android';$report.signature.$field=$false
    Assert-Refused { Assert-DemoAudit $report Android ('a'*64) }
}
$report=New-Report 'Android';$report.signature.debug=$true
Assert-Refused { Assert-DemoAudit $report Android ('a'*64) }
$report=New-Report 'Windows';$report.nsisExtraction.verified=$false
Assert-Refused { Assert-DemoAudit $report Windows ('a'*64) }
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path $repository ('artifacts/qa/demo-policy-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$file=Join-Path $fixture 'synthetic.txt'
[IO.File]::WriteAllText($file,'synthetic demo fixture')
$first=Get-DemoAssetRecord $file
[IO.File]::AppendAllText($file,' changed')
$second=Get-DemoAssetRecord $file
if($first.sha256 -ceq $second.sha256 -or $first.bytes -eq $second.bytes){throw 'demo_tamper_not_detected'}
$checks++
Assert-Refused { Get-DemoAssetRecord $fixture }
$empty=Join-Path $fixture 'empty.txt';[IO.File]::WriteAllBytes($empty,[byte[]]@())
Assert-Refused { Get-DemoAssetRecord $empty }
Write-Host "Demo delivery policy: $checks checks PASS; no account changes or publication."
