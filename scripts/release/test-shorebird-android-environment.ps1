# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Pure guard fixtures plus read-only Windows directory FileID/8.3 validation.
# No Flutter, Dart, SDK tool, app/native build, key, cloud or device invocation.
param([switch]$AnalyzerTempBindingOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$appDataBefore=$env:APPDATA; $javaBefore=$env:JAVA_HOME
$tempBefore=$env:TEMP;$tmpBefore=$env:TMP;$javaOptionsBefore=$env:JAVA_OPTS
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
function Test-AnalyzerTempBindingFixtures {
    $privateRoot='C:\QA-Analyzer\private-run'
    $extractionRoot=$privateRoot+'\analyzer-temp'
    $inventory=@('','BUNDLE-METADATA/','BUNDLE-METADATA/com.android.tools.build.debugsymbols/',
        'BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/',
        'BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libflutter.so.sym')
    $listingRoot=$extractionRoot+'\analyzer-probe.zip18446744073709551615\'
    $listing=(@($inventory | ForEach-Object {$listingRoot+$_.Replace('/','\')}) -join "`r`n")+"`r`n"
    Check (Test-ShorebirdAndroidAnalyzerListing $listing $extractionRoot) 'valid_20_digit_nonce_known_child_root'
    Check (!(Test-ShorebirdAndroidAnalyzerListing $listing 'C:\Different-Process-Temp')) 'ambient_temp_is_not_analyzer_binding'
    Check (!(Test-ShorebirdAndroidAnalyzerListing ($listing.Replace('18446744073709551615','18446744073709551616')) $extractionRoot)) 'uint64_boundary_still_strict'
    $shortTemp='C:\Users\RUNNER~1\AppData\Local\Temp'
    $capturedShape=$listing.Replace($extractionRoot,$shortTemp)
    Check (Test-ShorebirdAndroidAnalyzerListing $capturedShape $shortTemp) 'captured_20_digit_short_temp_shape'
    Check (!(Test-ShorebirdAndroidAnalyzerListing $capturedShape 'C:\Users\Runner Account\AppData\Local\Temp')) 'temp_spelling_must_be_explicit_not_assumed'

    $start=New-ShorebirdAndroidPrivateProcessStartInfo 'synthetic-dart.exe' @('probe.dart','argument with spaces') $privateRoot $extractionRoot
    Check ($start.Environment['TEMP'] -ceq $extractionRoot -and $start.Environment['TMP'] -ceq $extractionRoot) 'only_child_temp_tmp_bound'
    Check ($env:TEMP -ceq $tempBefore -and $env:TMP -ceq $tmpBefore -and $env:JAVA_OPTS -ceq $javaOptionsBefore) 'parent_temp_and_java_options_unchanged'
    Check ([string]$start.Environment['JAVA_OPTS'] -ceq [string]$javaOptionsBefore) 'child_java_options_not_overridden'
    Check (!$start.UseShellExecute -and $start.ArgumentList.Count -eq 2 -and $start.ArgumentList[1] -ceq 'argument with spaces') 'child_binding_preserves_direct_argument_list'
    $other=New-ShorebirdAndroidPrivateProcessStartInfo 'synthetic-git.exe' @('--version') $privateRoot
    Check ([string]$other.Environment['TEMP'] -ceq [string]$tempBefore -and [string]$other.Environment['TMP'] -ceq [string]$tmpBefore) 'other_private_processes_keep_inherited_temp'
    foreach($badRoot in @('C:\outside\analyzer-temp',($privateRoot+'\analyzer-temp-sibling'),($privateRoot+'\other'))){
        Reject { New-ShorebirdAndroidPrivateProcessStartInfo 'synthetic-dart.exe' @() $privateRoot $badRoot } 'shorebird_android_tool_path_invalid'
    }
    Reject { New-ShorebirdAndroidPrivateProcessStartInfo 'synthetic-dart.exe' @() $privateRoot ($privateRoot+'\..\analyzer-temp') } 'shorebird_android_tool_path_invalid'
    $classified=ConvertFrom-ShorebirdAndroidProcessProbe @{schema=1;exitCode=0;classFilesFailure=$false} $listing $extractionRoot
    Assert-ShorebirdAndroidToolProbe $classified;$script:checks++
}
Test-AnalyzerTempBindingFixtures
if($AnalyzerTempBindingOnly){
    Write-Host "Shorebird Android analyzer temp binding: $script:checks focused checks passed; SDK/build/cloud/device invocations=0."
    return
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
$inventory=@('','BUNDLE-METADATA/','BUNDLE-METADATA/com.android.tools.build.debugsymbols/',
    'BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/',
    'BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libflutter.so.sym')
$archiveListing=(@($inventory | ForEach-Object {'/'+$_}) -join "`r`n")+"`r`n"
$tempRoot='C:\QA-Temp'
$hostRoot=$tempRoot+'\analyzer-probe.zip1234567890123456789\'
$hostListing=(@($inventory | ForEach-Object {$hostRoot+$_.Replace('/','\')}) -join "`r`n")+"`r`n"
Check (Test-ShorebirdAndroidAnalyzerListing $archiveListing $tempRoot) 'exact_archive_rooted_inventory'
Check (Test-ShorebirdAndroidAnalyzerListing $hostListing $tempRoot) 'exact_hosted_windows_temp_inventory'
Check (Test-ShorebirdAndroidAnalyzerListing ($archiveListing.Replace("`r`n","`n")) $tempRoot) 'exact_lf_inventory'
Check (!(Test-ShorebirdAndroidAnalyzerListing $hostListing 'C:\Other-Temp')) 'listing_root_must_be_current_process_temp'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($hostListing.Replace('QA-Temp\','QA-Temp-sibling\')) $tempRoot)) 'temp_prefix_is_not_parent_equality'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($hostListing.Replace('analyzer-probe.zip1234567890123456789','other.zip1234567890123456789')) $tempRoot)) 'fixed_synthetic_archive_leaf_required'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($hostListing.Replace('1234567890123456789','18446744073709551616')) $tempRoot)) 'temp_nonce_must_fit_unsigned64'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($hostListing.Replace('1234567890123456789','0123456789012345678')) $tempRoot)) 'temp_nonce_is_canonical_decimal'
Check (!(Test-ShorebirdAndroidAnalyzerListing (($archiveListing -split "`r`n" | Select-Object -Skip 1) -join "`r`n") $tempRoot)) 'missing_root_row_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($archiveListing+"/extra`r`n") $tempRoot)) 'extra_inventory_row_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($archiveListing.Replace('libflutter.so.sym','unrelated.sym')) $tempRoot)) 'missing_expected_file_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($archiveListing.Replace('/BUNDLE-METADATA/','/prefix/BUNDLE-METADATA/')) $tempRoot)) 'basename_under_wrong_prefix_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($archiveListing.Replace('/BUNDLE-METADATA/','/../BUNDLE-METADATA/')) $tempRoot)) 'relative_traversal_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ("usage`r`n"+$archiveListing) $tempRoot)) 'usage_or_warning_output_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($hostListing.Replace('BUNDLE-METADATA\','BUNDLE-METADATA/')) $tempRoot)) 'mixed_windows_separators_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($archiveListing.Replace('/arm64-v8a/','\arm64-v8a\')) $tempRoot)) 'mixed_archive_separators_refused'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($archiveListing.Replace('BUNDLE-METADATA','bundle-metadata')) $tempRoot)) 'archive_names_remain_case_exact'
Check (!(Test-ShorebirdAndroidAnalyzerListing ($archiveListing+[char]0) $tempRoot)) 'nonprintable_output_refused'
$processProbe=@{schema=1;exitCode=0;classFilesFailure=$false}
$classified=ConvertFrom-ShorebirdAndroidProcessProbe $processProbe $hostListing $tempRoot
Assert-ShorebirdAndroidToolProbe $classified;$script:checks++
Reject { ConvertFrom-ShorebirdAndroidProcessProbe @{schema=1;exitCode=0;classFilesFailure='false'} $hostListing $tempRoot } 'shorebird_android_tool_probe_failed'
Reject { ConvertFrom-ShorebirdAndroidProcessProbe (@{}+$processProbe+@{extra='unexpected'}) $hostListing $tempRoot } 'shorebird_android_tool_probe_failed'
Reject { $bad=ConvertFrom-ShorebirdAndroidProcessProbe @{schema=1;exitCode=1;classFilesFailure=$false} $hostListing $tempRoot;Assert-ShorebirdAndroidToolProbe $bad } 'shorebird_android_tool_probe_failed'
Reject { $bad=ConvertFrom-ShorebirdAndroidProcessProbe @{schema=1;exitCode=0;classFilesFailure=$true} $hostListing $tempRoot;Assert-ShorebirdAndroidToolProbe $bad } 'shorebird_android_tool_probe_failed'
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
