# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Pure guard fixtures plus read-only Windows directory FileID/8.3 validation.
# No Flutter, Dart, SDK tool, app/native build, key, cloud or device invocation.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$appDataBefore=$env:APPDATA; $javaBefore=$env:JAVA_HOME
. (Join-Path $PSScriptRoot 'shorebird-android-environment.ps1')
$script:checks=0
function Check([bool]$Passed,[string]$Label) {
    if (!$Passed) { throw "shorebird_android_environment_test_$Label" }
    $script:checks++
}
function Reject([scriptblock]$Body,[string]$Code) {
    $failed=$false
    try { & $Body | Out-Null } catch {
        $failed=$true
        if ($_.Exception.Message -cne $Code) { throw "Expected $Code; received $($_.Exception.Message)" }
    }
    Check $failed $Code
}
Check ($env:APPDATA -ceq $appDataBefore -and $env:JAVA_HOME -ceq $javaBefore) 'dot_source_inert'
$directory=@{Identity='00112233:0000000000000001';Directory=$true;Reparse=$false;Links=1}
$same=@{}+$directory
Assert-ShorebirdAndroidToolPair $directory $same $true; $script:checks++
$other=@{}+$same; $other.Identity='00112233:0000000000000002'
Reject { Assert-ShorebirdAndroidToolPair $directory $other $true } 'shorebird_android_tool_identity_mismatch'
$other=@{}+$same; $other.Reparse=$true
Reject { Assert-ShorebirdAndroidToolPair $directory $other $true } 'shorebird_android_tool_identity_mismatch'
$other=@{}+$same; $other.Directory=$false
Reject { Assert-ShorebirdAndroidToolPair $directory $other $true } 'shorebird_android_tool_identity_mismatch'
$file=@{}+$directory; $file.Directory=$false
$same=@{}+$file
Assert-ShorebirdAndroidToolPair $file $same $false; $script:checks++
$other=@{}+$same; $other.Links=2
Reject { Assert-ShorebirdAndroidToolPair $file $other $false } 'shorebird_android_tool_identity_mismatch'
$sdk='C:\PROGRA~1\Android\SDK'; $jdk='C:\Program Files\Java\jdk-21'
$settings=@{'android-sdk'=$sdk;'jdk-dir'=$jdk} | ConvertTo-Json -Compress
Assert-ShorebirdAndroidToolSettings $settings $sdk $jdk; $script:checks++
Reject { Assert-ShorebirdAndroidToolSettings $settings 'C:\other-sdk' $jdk } 'shorebird_android_tool_config_invalid'
Reject { Assert-ShorebirdAndroidToolSettings $settings $sdk 'C:\other-java' } 'shorebird_android_tool_config_invalid'
$extra=@{'android-sdk'=$sdk;'jdk-dir'=$jdk;'extra'='unexpected'} | ConvertTo-Json -Compress
Reject { Assert-ShorebirdAndroidToolSettings $extra $sdk $jdk } 'shorebird_android_tool_config_invalid'
Reject { Assert-ShorebirdAndroidToolSettings '{"android-sdk":"a","android-sdk":"b","jdk-dir":"c"}' 'b' 'c' } 'shorebird_android_tool_config_invalid'
Reject { Assert-ShorebirdAndroidToolSettings '{"android-sdk":3,"jdk-dir":"c"}' '3' 'c' } 'shorebird_android_tool_config_invalid'
Reject { Assert-ShorebirdAndroidToolSettings '{"android-sdk":"a"}' 'a' 'c' } 'shorebird_android_tool_config_invalid'
Reject { Assert-ShorebirdAndroidToolSettings '{' $sdk $jdk } 'shorebird_android_tool_config_invalid'
$probe=@{schema=1;exitCode=0;expectedMetadataListed=$true;classFilesFailure=$false}
Assert-ShorebirdAndroidToolProbe $probe; $script:checks++
foreach ($change in @(@{exitCode=1},@{expectedMetadataListed=$false},@{expectedMetadataListed='true'},
        @{classFilesFailure=$true},@{schema='1'})) {
    $bad=@{}+$probe
    foreach ($key in $change.Keys) { $bad[$key]=$change[$key] }
    Reject { Assert-ShorebirdAndroidToolProbe $bad } 'shorebird_android_tool_probe_failed'
}
Reject { Assert-ShorebirdAndroidToolProbe @{schema=1} } 'shorebird_android_tool_probe_failed'
foreach ($invalid in @('relative/sdk','C:\sdk\..\other','C:\sdk\tool:stream','C:\sdk\trailing.','\\server\sdk')) {
    Reject { Assert-ShorebirdAndroidToolPath $invalid } 'shorebird_android_tool_path_invalid'
}
foreach ($invalid in @('C:\Program Files\sdk','C:\sdk\..\other','C:\sdk\\bin','C:\sdk\trailing.','C:\sdk\tool:stream',('C:\'+('a'*2048)))) {
    Reject { Assert-ShorebirdAndroidLiteralToolPath $invalid } 'shorebird_android_tool_literal_invalid'
}
Check ((Get-ShorebirdAndroidToolFailureReason 'shorebird_android_tool_path_alias') -ceq 'shorebird_android_tool_path_alias') 'known_path_refusal_is_safe_reason'
Check ((Get-ShorebirdAndroidToolFailureReason 'private_acl') -ceq 'private_acl') 'known_acl_refusal_is_safe_reason'
Check ((Get-ShorebirdAndroidToolFailureReason 'PRIVATE_ACL') -ceq 'unclassified') 'reason_allowlist_is_case_exact'
Check ((Get-ShorebirdAndroidToolFailureReason 'SYNTHETIC-PRIVATE-PATH C:\fixture') -ceq 'unclassified') 'unknown_exception_is_never_public_reason'
if ([OperatingSystem]::IsWindows()) {
    Initialize-ShorebirdAndroidPathInterop
    $physical=Assert-ShorebirdAndroidToolPath $env:ProgramFiles
    $rawShort=[ExVpnShorebirdAndroidPath]::ShortPath($physical)
    $short=Assert-ShorebirdAndroidLiteralToolPath $rawShort
    Check ($physical.Contains(' ') -and !$rawShort.Contains(' ')) 'real_spaced_directory_has_8_3_alias'
    Check ($short -ceq $rawShort -and !$short.Contains(' ')) 'literal_8_3_not_expanded_to_physical'
    $analyzerSpelling=$short+'\cmdline-tools\latest\bin\apkanalyzer.bat'
    Check ((Assert-ShorebirdAndroidLiteralToolPath $analyzerSpelling) -ceq $analyzerSpelling) 'literal_child_spelling_not_expanded'
    $first=[ExVpnShorebirdAndroidPath]::Hold($physical,$true)
    $second=[ExVpnShorebirdAndroidPath]::Hold($short,$true)
    try { Assert-ShorebirdAndroidToolPair $first $second $true; $script:checks++ }
    finally { $first.Dispose(); $second.Dispose() }

    # Exercise the early-failure spool before any caller private path or ACL
    # was accepted. Generic encryption is tested in the pipeline suite; this
    # fixture deliberately has no recipient and invokes no SDK/process/cloud.
    . (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
    . (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
    $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $parent=Join-Path $repository '.private/shorebird-builds'
    $before=@(Get-ChildItem -LiteralPath $parent -Directory -Filter 'android-tool-failure-*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $savedRecipient=$env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64
    $spools=@()
    try {
        $env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64=$null
        $captured=$null
        try { throw 'SYNTHETIC-EARLY-EXCEPTION' } catch { $captured=$_ }
        $encrypted=Write-ShorebirdAndroidToolFailureDiagnostic $repository 'not-an-accepted-directory' $false $captured 'paths' 'android_sdk_physical' @{
            repository=$repository;androidSdkPath='SYNTHETIC-PRIVATE-INPUT';privateDirectory='not-an-accepted-directory'}
        Check (!$encrypted) 'missing_recipient_never_exports_plaintext'
        $spools=@(Get-ChildItem -LiteralPath $parent -Directory -Filter 'android-tool-failure-*' | Where-Object FullName -CNotIn $before)
        Check ($spools.Count -eq 1) 'early_refusal_gets_one_owned_spool'
        $spool=Assert-ShorebirdAndroidPrivateDirectory $spools[0].FullName $repository
        $script:checks++
        $pair=Join-Path $spool 'analyzer-export.json'
        $detail=[IO.File]::ReadAllText([IO.Path]::ChangeExtension($pair,'.log'))
        Check ((Get-Item -LiteralPath $pair).Length -eq 0 -and $detail.Contains('ExVPN/android-tool-context/v1')) 'early_failure_has_paired_bounded_context'
        Check ($detail.Contains('SYNTHETIC-EARLY-EXCEPTION') -and $detail.Contains('SYNTHETIC-PRIVATE-INPUT')) 'exact_early_exception_and_inputs_retained_privately'
        Check (!(Test-Path -LiteralPath (Join-Path $repository 'not-an-accepted-directory'))) 'rejected_caller_directory_is_not_used'
        Check ($env:APPDATA -ceq $appDataBefore -and $env:JAVA_HOME -ceq $javaBefore) 'diagnostic_spool_does_not_change_environment'
    } finally {
        $env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64=$savedRecipient
        foreach($spool in $spools){
            $full=[IO.Path]::GetFullPath($spool.FullName)
            if(!$full.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($full) -cnotmatch '^android-tool-failure-[a-f0-9]{32}$'){throw 'fixture_cleanup_scope_invalid'}
            $null=Assert-ShorebirdAndroidPrivateDirectory $full $repository
            $null=Get-AuditTreeFiles $full
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
}
Check ($env:APPDATA -ceq $appDataBefore -and $env:JAVA_HOME -ceq $javaBefore) 'environment_unchanged'
Write-Host "Shorebird Android environment: $script:checks focused checks passed; SDK/build/cloud/device invocations=0."
