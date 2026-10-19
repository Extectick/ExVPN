#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'shorebird-android-release-config.ps1')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path $repository ('.private/shorebird-release-config-tests/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$apk=Join-Path $fixture 'base.apk';$aab=Join-Path $fixture 'base.aab';$java=Join-Path $fixture 'GeneratedPluginRegistrant.java';$log=Join-Path $fixture 'private.log'
$state=Join-Path $fixture 'sealed-input.txt'
$script:configChecks=0
function Assert-ConfigurationTest([bool]$Condition,[string]$Name){if(!$Condition){throw "configuration_guard_failed_$Name"};$script:configChecks++}
function Reset-ConfigurationFixture {
    [IO.File]::WriteAllText($apk,'synthetic-apk');[IO.File]::WriteAllText($aab,'synthetic-aab');[IO.File]::WriteAllText($state,'sealed-input')
    [IO.File]::WriteAllText($java,'public final class GeneratedPluginRegistrant { IntegrationTestPlugin devOnly; }')
}
function Invoke-ConfigurationFixture([scriptblock]$Command) {
    Invoke-ShorebirdAndroidReleaseConfiguration -Flutter 'pinned/flutter.bat' -Apk $apk -Aab $aab -Registrant $java -PrivateLog $log `
        -ReadProtectedInputs {[ordered]@{state=[IO.File]::ReadAllText($state);pin='exact-runtime'}} -InvokeConfiguration $Command
}
function Assert-ConfigurationRefused([scriptblock]$Command,[string]$Code) {
    $refused=$false
    try{$null=Invoke-ConfigurationFixture $Command}catch{$refused=$_.Exception.Message -ceq $Code}
    Assert-ConfigurationTest $refused $Code
}
Reset-ConfigurationFixture
$args=@(Get-ShorebirdAndroidReleaseConfigurationArguments)
Assert-ConfigurationTest ($args[0] -ceq 'build' -and $args[1] -ceq 'apk' -and $args -ccontains '--config-only' -and $args -ccontains '--release' -and $args -ccontains '--pub') 'configuration_only_release_pub'
Assert-ConfigurationTest ($args -ccontains '--target-platform=android-arm64,android-x64' -and $args -ccontains '--dart-define=EXVPN_DART_UPDATE_TRACK=beta' -and $args -ccontains '--dart-define=EXVPN_DEMO=false') 'exact_platform_and_track'
Assert-ConfigurationTest ($args -cnotcontains 'shorebird' -and $args -cnotcontains 'release' -and $args -cnotcontains '--dry-run' -and $args -cnotcontains '--no-pub') 'no_registration_or_build_override'
$result=Invoke-ConfigurationFixture {param($Executable,$ConfigurationArguments,$Log)
    Assert-ConfigurationTest ($Executable -ceq 'pinned/flutter.bat' -and $ConfigurationArguments -ccontains '--config-only' -and $Log -ceq $log) 'adapter_exact_inputs'
    [IO.File]::WriteAllText($java,'public final class GeneratedPluginRegistrant {}')
    [IO.File]::WriteAllText($Log,'private fixture output')
    0
}
Assert-ConfigurationTest ($result.configurationOnly -and $result.artifactBytesUnchanged -and $result.protectedInputsUnchanged -and $result.releaseRegistrantVerified) 'success_binding'
foreach($path in @($apk,$aab)) {
    Reset-ConfigurationFixture
    Assert-ConfigurationRefused {param($Executable,$ConfigurationArguments,$Log);$original=[IO.File]::ReadAllText($path);[IO.File]::WriteAllText($path,('X'+$original.Substring(1)));0} 'shorebird_android_configuration_artifact_changed'
}
Reset-ConfigurationFixture
Assert-ConfigurationRefused {param($Executable,$ConfigurationArguments,$Log);[IO.File]::WriteAllText($state,'changed-input');0} 'shorebird_android_configuration_inputs_changed'
Reset-ConfigurationFixture
Assert-ConfigurationRefused {param($Executable,$ConfigurationArguments,$Log);7} 'shorebird_android_configuration_failed'
Reset-ConfigurationFixture
Assert-ConfigurationRefused {param($Executable,$ConfigurationArguments,$Log);0} 'shorebird_android_configuration_dev_plugin_present'
$wrapper=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shorebird-release.ps1'))
Assert-ConfigurationTest ($wrapper.IndexOf('$releaseConfiguration = Invoke-ShorebirdAndroidReleaseConfiguration') -gt $wrapper.IndexOf('$baseAot = @(Assert-ShorebirdAndroidAotBinding') -and $wrapper.IndexOf('$releaseConfiguration = Invoke-ShorebirdAndroidReleaseConfiguration') -lt $wrapper.IndexOf('$jvmStarted = [datetime]::UtcNow')) 'after_recorded_artifacts_before_jvm'
Assert-ConfigurationTest ($wrapper.Contains('Assert-AndroidNoticeSeal $repository $packageInputs.InputDirectory -FlutterRuntime shorebird -FlutterBuildMode release') -and $wrapper.Contains('snapshot=(Get-AndroidNoticeSnapshotState') -and $wrapper.Contains('source=(Get-ShorebirdSourceCommit')) 'seals_source_and_runtime_remain_guarded'
Write-Host "Shorebird Android release configuration: $script:configChecks checks PASS; no SDK, build or cloud mutation."
$global:LASTEXITCODE=0
