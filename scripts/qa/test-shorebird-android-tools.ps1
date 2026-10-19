# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'shorebird-android-tools.ps1')
$checks=0
function Check([bool]$Condition) { if (!$Condition) { throw 'shorebird_tools_fixture_failed' }; $script:checks++ }
function Refuse([scriptblock]$Action) {
    $failed=$false
    try { $null=& $Action } catch { $failed=$true }
    Check $failed
}
function Fixture($Current,$Next,[int]$Ui=0,[bool]$Available=$true) {
    @{schema=1;application='ExVPN';version='0.1.8+29';uiRevision=$Ui;platform='android';coreVersion='26.10.10-exvpn.5'
      vpnPhase='disconnected';processCrashProtection=$false;errorCode=$null;secureStorageAvailable=$true
      updates=@{dataRevision=$null;dataChannel='stable';dartAvailable=$Available;currentDartPatch=$Current
        nextDartPatch=$Next;dartRestartRequired=($Current -ne $Next);dartTrack='beta'}} | ConvertTo-Json -Depth 5 -Compress
}
$base=ConvertFrom-AndroidShorebirdDiagnostics (Fixture $null $null)
Check (!$base.nativeInitializationProven)
$staged=ConvertFrom-AndroidShorebirdDiagnostics (Fixture $null 3)
Check ((Assert-AndroidShorebirdPhase $staged staged 3).restartRequired)
$applied=ConvertFrom-AndroidShorebirdDiagnostics (Fixture 3 3 1)
Check ((Assert-AndroidShorebirdPhase $applied applied 3).nativeInitializationProven)
$rollback=ConvertFrom-AndroidShorebirdDiagnostics (Fixture 3 $null 1)
Check ((Assert-AndroidShorebirdPhase $rollback rollbackStaged 3).restartRequired)
Check ((Assert-AndroidShorebirdPhase $base rolledBack 3).uiRevision -eq 0)
Refuse { Assert-AndroidShorebirdPhase $base applied 3 }
Refuse { Assert-AndroidShorebirdPhase (ConvertFrom-AndroidShorebirdDiagnostics (Fixture $null $null 0 $false)) base 3 }
Refuse { ConvertFrom-AndroidShorebirdDiagnostics ((Fixture 3 3 1).Replace('"beta"','"stable"')) }
Refuse { ConvertFrom-AndroidShorebirdDiagnostics ((Fixture 3 3 1).Replace('"currentDartPatch":3','"currentDartPatch":"3"')) }
Refuse { ConvertFrom-AndroidShorebirdDiagnostics ((Fixture $null $null).Replace('"schema":1','"unexpectedSecret":"fixture","schema":1')) }
$identity=@{version='0.1.8';build=29;uid=10169;apkSha256=('a'*64)}
Check (Assert-AndroidShorebirdUnchangedApk $identity $identity ('a'*64))
Refuse { Assert-AndroidShorebirdUnchangedApk $identity (@{version='0.1.8';build=29;uid=10170;apkSha256=('a'*64)}) ('a'*64) }
Refuse { Assert-AndroidShorebirdUnchangedApk $identity (@{version='0.1.8';build=29;uid=10169;apkSha256=('b'*64)}) ('a'*64) }
$escaped=[Security.SecurityElement]::Escape((Fixture 3 3 1))
[xml]$tree="<hierarchy><node package='ru.exvpn.exvpn' text='$escaped' content-desc='' /></hierarchy>"
Check ((Get-AndroidShorebirdDiagnosticsFromUi $tree).current -eq 3)
Write-Host "Shorebird Android tools: $checks synthetic checks PASS; no ADB/build/cloud actions."
