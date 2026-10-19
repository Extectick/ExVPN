#requires -Version 7.0
# Regenerate release-only generated Android inputs after Shorebird's cleanup
# pub get. Never invoke Shorebird or compile/package an APK a second time.
Set-StrictMode -Version Latest

function Get-ShorebirdAndroidReleaseConfigurationArguments {
    @('build','apk','--config-only','--release','--pub','--target=lib/main.dart',
      '--target-platform=android-arm64,android-x64',
      '--dart-define=EXVPN_DART_UPDATE_TRACK=beta','--dart-define=EXVPN_DEMO=false')
}

function Invoke-ShorebirdAndroidReleaseConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Flutter,
        [Parameter(Mandatory)][string]$Apk,
        [Parameter(Mandatory)][string]$Aab,
        [Parameter(Mandatory)][string]$Registrant,
        [Parameter(Mandatory)][string]$PrivateLog,
        [Parameter(Mandatory)][scriptblock]$ReadProtectedInputs,
        [scriptblock]$InvokeConfiguration = {
            param($Executable,$ConfigurationArguments,$Log)
            & $Executable @ConfigurationArguments *> $Log
            $LASTEXITCODE
        }
    )
    $before=@{}
    foreach($path in @($Apk,$Aab)) {
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        if($item.PSIsContainer -or $item.Length -le 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'shorebird_android_configuration_artifact_invalid'}
        $before[$path]=[ordered]@{sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;bytes=$item.Length}
    }
    $protectedBefore=(& $ReadProtectedInputs | ConvertTo-Json -Depth 24 -Compress)
    if(!$protectedBefore -or $protectedBefore -ceq 'null'){throw 'shorebird_android_configuration_inputs_missing'}
    $configurationArguments=@(Get-ShorebirdAndroidReleaseConfigurationArguments)
    $exitCode=& $InvokeConfiguration $Flutter $configurationArguments $PrivateLog
    if($exitCode -isnot [int] -or $exitCode -ne 0){throw 'shorebird_android_configuration_failed'}
    foreach($path in @($Apk,$Aab)) {
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
           $item.Length -ne $before[$path].bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $before[$path].sha256) {throw 'shorebird_android_configuration_artifact_changed'}
    }
    $protectedAfter=(& $ReadProtectedInputs | ConvertTo-Json -Depth 24 -Compress)
    if($protectedAfter -cne $protectedBefore){throw 'shorebird_android_configuration_inputs_changed'}
    $java=Get-Item -LiteralPath $Registrant -ErrorAction Stop
    if($java.PSIsContainer -or $java.Length -le 0 -or $java.Length -gt 1MB -or
       ($java.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'shorebird_android_configuration_registrant_invalid'}
    $text=[IO.File]::ReadAllText($Registrant)
    if(!$text.Contains('public final class GeneratedPluginRegistrant') -or
       $text -match 'IntegrationTestPlugin|integration_test') {throw 'shorebird_android_configuration_dev_plugin_present'}
    [ordered]@{configurationOnly=$true;artifactBytesUnchanged=$true;protectedInputsUnchanged=$true;releaseRegistrantVerified=$true}
}
