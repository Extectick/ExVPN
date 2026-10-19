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
}
Check ($env:APPDATA -ceq $appDataBefore -and $env:JAVA_HOME -ceq $javaBefore) 'environment_unchanged'
Write-Host "Shorebird Android environment: $script:checks focused checks passed; SDK/build/cloud/device invocations=0."
