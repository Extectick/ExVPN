#requires -Version 7.0
<#
.SYNOPSIS
Builds a pinned Shorebird beta base release with signed-patch verification.
.DESCRIPTION
Dry-run by default. -PublishCloud explicitly authorizes the single official
build-and-publish operation; packaged audit then gates distribution of its bytes.
Native JNI/service builds are separate and are not rebuilt by this wrapper.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Android', 'Windows')][string]$Target,
    [string]$AndroidSdkPath = '',
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [switch]$PublishCloud,
    [switch]$RecoverWindowsBase,
    [switch]$Independent,
    [string]$IndependentBaseFingerprint = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Independent -and ($PublishCloud -or $RecoverWindowsBase)) { throw 'independent_base_cloud_operation_forbidden' }
if ($Independent -and $IndependentBaseFingerprint -cnotmatch '^[a-f0-9]{64}$') { throw 'independent_base_fingerprint_missing' }
if (!$Independent -and $IndependentBaseFingerprint) { throw 'independent_base_switch_required' }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-preview-lib.ps1')
. (Join-Path $PSScriptRoot 'demo-android-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-runtime-notices.ps1')
. (Join-Path $PSScriptRoot 'shorebird-android-environment.ps1')
. (Join-Path $PSScriptRoot 'shorebird-android-release-config.ps1')
if ($Independent) {
    . (Join-Path $repository 'scripts/ota/aot-inputs.ps1')
    if ((Get-ExvpnOtaInputsFingerprint @(Get-ExvpnOtaProtectedInputs $repository)) -cne $IndependentBaseFingerprint) { throw 'independent_base_fingerprint_mismatch' }
}
$sourceCommit = Get-ShorebirdSourceCommit $repository
$compiledSourceCommit=$sourceCommit;$recoveryProof=$null;$recoveryEquivalence=$null
if($RecoverWindowsBase){
    $recoveryPolicy=Get-ShorebirdWindowsRecoveryPolicy
    if($Target -cne 'Windows' -or $ReleaseVersion -cne $recoveryPolicy.version){throw 'shorebird_recovery_version_mismatch'}
    $recoveryEquivalence=Assert-ShorebirdRecoverySource $repository $sourceCommit
    $compiledSourceCommit=$recoveryPolicy.compiledSourceCommit
}
if ($Target -eq 'Android') { $AndroidSdkPath = Get-ReleaseAndroidSdkPath $AndroidSdkPath }
function Read-ExVpnUpdaterConfig([string]$Text, [switch]$Compiled) {
    # Deliberately accept only this project's flat config, not arbitrary YAML.
    # Quoted/indented keys, aliases, extra endpoints and multiline values fail.
    $allowed = @('app_id', 'auto_update', 'patch_verification')
    if ($Compiled) { $allowed += 'patch_public_key'; if ($Independent) { $allowed += 'base_url' } }
    $values = @{}
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*(#.*)?$') { continue }
        $field = [regex]::Match($line, '^([a-z_]+): *([^\r\n]+)$')
        if (!$field.Success -or $field.Groups[1].Value -cnotin $allowed -or
            $values.ContainsKey($field.Groups[1].Value)) { throw 'Unexpected or duplicate updater configuration field.' }
        $value = $field.Groups[2].Value.Trim()
        if ($Compiled -and $field.Groups[1].Value -ceq 'patch_public_key') {
            $keyValue = [regex]::Match($value, '^(?:"(?<key>[A-Za-z0-9+/]+={0,2})"|''(?<key>[A-Za-z0-9+/]+={0,2})''|(?<key>[A-Za-z0-9+/]+={0,2}))$')
            if (!$keyValue.Success) { throw 'Invalid packaged public key scalar.' }
            $value = $keyValue.Groups['key'].Value
        }
        $values[$field.Groups[1].Value] = $value
    }
    if ($values.Count -ne $allowed.Count -or $values.app_id -cnotmatch '^[a-f0-9-]{36}$' -or
        $values.auto_update -cne 'false' -or $values.patch_verification -cne 'strict') {
        throw 'Incomplete or unsupported updater policy.'
    }
    if ($Compiled -and $values.patch_public_key -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') { throw 'Invalid packaged public key encoding.' }
    if ($Compiled -and $Independent -and $values.base_url -cne 'http://127.0.0.1:57791') { throw 'independent_base_endpoint_mismatch' }
    $values
}
function Assert-ExVpnShorebirdCache([string]$CliRoot, [string]$CliRevision, [string]$FlutterRevision) {
    # Mirror the pinned upstream bootstrap's invalidation conditions. A release
    # must never trigger its implicit git fetch / unlocked dart pub get path.
    $paths = @('bin/cache/shorebird.snapshot', 'bin/cache/shorebird.stamp',
        'packages/shorebird_cli/pubspec.yaml', 'pubspec.lock', 'bin/internal/flutter.version')
    $files = @{}
    foreach ($path in $paths) {
        $full = Join-Path $CliRoot $path
        Assert-AuditNoLinks $full
        $file = Get-Item -LiteralPath $full -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -le 0) { throw 'Shorebird CLI cache is not prepared.' }
        $files[$path] = $file
    }
    $stamp = @([IO.File]::ReadAllLines($files['bin/cache/shorebird.stamp'].FullName))
    $flutterPin = @([IO.File]::ReadAllLines($files['bin/internal/flutter.version'].FullName))
    if ($stamp.Count -ne 1 -or $stamp[0] -cne $CliRevision -or
        $flutterPin.Count -ne 1 -or $flutterPin[0] -cne $FlutterRevision -or
        $files['packages/shorebird_cli/pubspec.yaml'].LastWriteTimeUtc -gt $files['pubspec.lock'].LastWriteTimeUtc) {
        throw 'Shorebird CLI cache is stale; prepare and verify the pinned CLI separately before release.'
    }
}
$pin = Get-Content -Raw (Join-Path $repository 'scripts/bootstrap/shorebird.lock.json') | ConvertFrom-Json
$runtime = Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release
$flutter = Join-Path $runtime.SdkRoot 'bin/flutter.bat'
$shorebird = Join-Path $repository ".tools/$($pin.cli.folder)/bin/shorebird.ps1"
if (!$Independent) { Assert-ExVpnShorebirdCache (Join-Path $repository ".tools/$($pin.cli.folder)") $pin.cli.revision $pin.flutter.revision }
$app = Join-Path $repository 'apps/exvpn'
$version = Get-NoticeAppVersion ([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml'))) ([IO.File]::ReadAllText((Join-Path $app 'lib/build_identity.dart')))
if ($version -cne $ReleaseVersion) { throw 'shorebird_source_version_mismatch' }
$versionParts = $version.Split('+')
if (!$Independent) { $null = Get-ShorebirdCli $repository }
$publicKeyPath = Join-Path $repository 'config/signing/shorebird-beta-public.pem'
$publicKey = [Security.Cryptography.RSA]::Create()
try {
    $publicKey.ImportFromPem([IO.File]::ReadAllText($publicKeyPath))
    if ($publicKey.KeySize -lt 3072) { throw 'The beta patch verification key is too small.' }
    if ($Independent -and $publicKey.KeySize -ne 4096) { throw 'independent_base_rsa4096_required' }
    $compiledPublicKey = [Convert]::ToBase64String($publicKey.ExportRSAPublicKey())
} finally { $publicKey.Dispose() }
$sourceConfig = [IO.File]::ReadAllText((Join-Path $app 'shorebird.yaml'))
$sourceConfigBytes = [IO.File]::ReadAllBytes((Join-Path $app 'shorebird.yaml'))
$sourceConfigMtime = (Get-Item -LiteralPath (Join-Path $app 'shorebird.yaml')).LastWriteTimeUtc
$independentConfigLeased = $false
$independentConfigHash = $null
$appId = (Read-ExVpnUpdaterConfig $sourceConfig).app_id
if ($appId -cne 'ea97a683-02e5-4d86-9aa1-779d6b4bc81e') {
    throw 'The beta updater configuration does not match the reviewed project policy.'
}
$runId = [Guid]::NewGuid().ToString('N')
$privateRun = New-ShorebirdPrivateDirectory $repository 'base'
$output = Join-Path $repository "artifacts/shorebird/$version-$($Target.ToLowerInvariant())-$runId"
$stage = Join-Path $privateRun 'public'
New-Item -ItemType Directory -Path $stage | Out-Null
$lockHash = (Get-FileHash (Join-Path $app 'pubspec.lock') -Algorithm SHA256).Hash
$configHash = (Get-FileHash (Join-Path $app 'shorebird.yaml') -Algorithm SHA256).Hash
$environmentNames = @('PATH','APPDATA','PUB_CACHE','GRADLE_USER_HOME','CI','FLUTTER_SUPPRESS_ANALYTICS',
    'DART_SUPPRESS_ANALYTICS','FLUTTER_STORAGE_BASE_URL','ANDROID_HOME','ANDROID_SDK_ROOT',
    'GOTOOLCHAIN','GOPATH','GOCACHE','GOPROXY','GOSUMDB','GONOSUMDB','GOWORK',
    'JAVA_HOME','EXVPN_ANDROID_PACKAGE_INPUTS','EXVPN_FLUTTER_RUNTIME','EXVPN_FLUTTER_BUILD_MODE',
    'EXVPN_DEMO_MAVEN_GRAPH',
    'EXVPN_ANDROID_KEYSTORE','EXVPN_ANDROID_KEY_ALIAS','EXVPN_ANDROID_STORE_PASSWORD','EXVPN_ANDROID_KEY_PASSWORD')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$passwordBytes = $null
$packageInputs = $null
$hook = $null; $hookOwned = $false; $hookHash = $null
$cloudRelease = $null
$cloudRegisteredVerified = $false
$recoveryPath = $null
$phase = 'environment'
$subphase='pub';$recoveredUi=$null
$releaseStartedUtc=[datetime]::MinValue
$releaseProcessPathLength=0

function Assert-CompiledUpdater([string]$Text) {
    $compiled = Read-ExVpnUpdaterConfig $Text -Compiled
    if ($compiled.app_id -cne $appId -or $compiled.patch_public_key -cne $compiledPublicKey) {
        throw 'Packaged Shorebird key or updater policy differs from the expected beta base.'
    }
}
function Restore-IndependentUpdaterConfig {
    if (!$script:independentConfigLeased) { return }
    $path = Join-Path $app 'shorebird.yaml'
    if ((Get-AuditSha256 $path) -cne $script:independentConfigHash) { throw 'independent_config_lease_modified' }
    [IO.File]::WriteAllBytes($path,$sourceConfigBytes)
    [IO.File]::SetLastWriteTimeUtc($path,$sourceConfigMtime)
    $script:independentConfigLeased = $false
}
function Assert-ZipUpdater([string]$Path, [string]$EntryPath) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($zip.Entries | Where-Object FullName -CEQ $EntryPath)
        if ($entries.Count -ne 1 -or $entries[0].Length -gt 16384) { throw 'Missing/duplicate/oversized packaged updater configuration.' }
        $reader = [IO.StreamReader]::new($entries[0].Open())
        try { Assert-CompiledUpdater $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

Push-Location $app
try {
    if($PublishCloud -or $RecoverWindowsBase){
        $recoveryPath=Write-ShorebirdRecovery -Repository $repository -Action base -Version $version -Target $Target -SourceCommit $sourceCommit -Status attempting -CloudOutcome unknown -Phase $phase -Subphase $subphase
    }
    $env:PUB_CACHE = Join-Path $repository '.tools/cache/pub'
    $env:GRADLE_USER_HOME = Join-Path $repository '.tools/cache/gradle'
    $env:CI = 'true'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DART_SUPPRESS_ANALYTICS = 'true'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://download.shorebird.dev'
    if (!$env:JAVA_HOME) { $env:JAVA_HOME = 'C:\PROGRA~1\Android\ANDROI~1\jbr' }
    if ($Target -eq 'Android') {
        $env:ANDROID_HOME = $AndroidSdkPath
        $env:ANDROID_SDK_ROOT = $AndroidSdkPath
    }
    $env:PATH = (Join-Path $runtime.SdkRoot 'bin') + [IO.Path]::PathSeparator + $savedEnvironment.PATH
    if ($Target -ceq 'Android' -and $env:GITHUB_ACTIONS -ceq 'true') {
        $null = Initialize-ShorebirdAndroidToolEnvironment -Repository $repository -FlutterSdkRoot $runtime.SdkRoot -AndroidSdkPath $AndroidSdkPath -PrivateDirectory $privateRun
    }
    & $flutter pub get --offline --enforce-lockfile *> (Join-Path $privateRun 'pub-private.log')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned Flutter dependency resolution failed; inspect private build log.' }
    if ($Target -eq 'Android') {
        if (!$env:EXVPN_ANDROID_KEYSTORE -and !$env:EXVPN_ANDROID_STORE_PASSWORD -and !$env:EXVPN_ANDROID_KEY_PASSWORD -and !$env:EXVPN_ANDROID_KEY_ALIAS) {
            $signingRoot = Join-Path $repository '.private/signing/android'
            Assert-AuditNoLinks $signingRoot
            $passwordBytes = [Security.Cryptography.ProtectedData]::Unprotect(
                [IO.File]::ReadAllBytes((Join-Path $signingRoot 'store-password.dpapi')), $null,
                [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $env:EXVPN_ANDROID_KEYSTORE = Join-Path $signingRoot 'release.p12'
            $env:EXVPN_ANDROID_KEY_ALIAS = 'exvpn'
            $env:EXVPN_ANDROID_STORE_PASSWORD = [Text.Encoding]::UTF8.GetString($passwordBytes)
            $env:EXVPN_ANDROID_KEY_PASSWORD = $env:EXVPN_ANDROID_STORE_PASSWORD
        }
        $subphase='android_signer'
        $signing = Get-DemoAndroidSigningInput
        $expectedSigner = Get-DemoAndroidCertificateSha256 (Join-Path $repository 'config/signing/android-release-cert.pem') -Pem
        $keytool = Join-Path $env:JAVA_HOME 'bin/keytool.exe'
        $exportedCertificate = Join-Path $privateRun 'signer.der'
        $null = Invoke-AuditTool $keytool @('-exportcert','-alias',$signing.Alias,'-keystore',$signing.Path,
            '-storepass:env','EXVPN_ANDROID_STORE_PASSWORD','-file',$exportedCertificate)
        if ((Get-DemoAndroidCertificateSha256 $exportedCertificate) -cne $expectedSigner) { throw 'shorebird_apk_signer_mismatch' }
        $subphase='android_notices'
        $packageInputs = & (Join-Path $PSScriptRoot 'prepare-android-notices.ps1') -FlutterRuntime shorebird -FlutterBuildMode release
        if (!$packageInputs.InputDirectory) { throw 'A fresh Android native/notices snapshot is required.' }
        $env:EXVPN_ANDROID_PACKAGE_INPUTS = $packageInputs.InputDirectory
        $subphase='maven_hook'
        $rawGraph = Join-Path $privateRun 'android-maven-inputs.json'
        $env:EXVPN_DEMO_MAVEN_GRAPH = $rawGraph
        $hookDirectory = Join-Path $env:GRADLE_USER_HOME 'init.d'
        New-Item -ItemType Directory -Path $hookDirectory -Force | Out-Null
        Assert-AuditNoLinks $hookDirectory
        $hook = Join-Path $hookDirectory 'exvpn-demo-maven-notices.gradle'
        $hookSource = Join-Path $PSScriptRoot 'prepare-demo-maven-notices.init.gradle'
        $hookHash = Get-AuditSha256 $hookSource
        $hookStream = [IO.File]::Open($hook,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $hookOwned = $true
        try { $bytes = [IO.File]::ReadAllBytes($hookSource); $hookStream.Write($bytes,0,$bytes.Length) }
        finally { $hookStream.Dispose() }
    }
    $env:EXVPN_FLUTTER_RUNTIME = 'shorebird'
    $env:EXVPN_FLUTTER_BUILD_MODE = 'release'
    # The collector can enter the ordinary tool environment. Reset PATH so the
    # CLI's final system-Flutter pub get also uses the exact Shorebird SDK.
    $env:PATH = (Join-Path $runtime.SdkRoot 'bin') + [IO.Path]::PathSeparator + $savedEnvironment.PATH
    if($RecoverWindowsBase){
        $phase='cloud_recovery';$subphase='recovery_readback'
        $readback=Invoke-ShorebirdJson $shorebird @('releases','info',"--app-id=$appId","--release-version=$version") 'releases info' $privateRun 'recovery-release'
        Assert-ShorebirdCloudRelease $readback.release $version Windows $recoveryPolicy.releaseId
        $cloudRelease=$readback.release;$cloudRegisteredVerified=$true
        $null=Write-ShorebirdRecovery -Repository $repository -Action base -Version $version -Target $Target -SourceCommit $sourceCommit -Status cloud_registered -CloudOutcome registered -Phase $phase -Subphase $subphase -ReleaseId $cloudRelease.id -Path $recoveryPath
        $subphase='recovery_artifact'
        $artifact=Get-ShorebirdRecoveryArtifact $shorebird $privateRun
        $subphase='recovery_download'
        $archive=Receive-ShorebirdRecoveryArchive $artifact $privateRun
        $recoveredUi=Join-Path $privateRun 'recovered-ui'
        $recoveredFiles=Expand-ShorebirdRecoveryArchive $archive $recoveredUi
        if($recoveredFiles.Count -ne $recoveryPolicy.files -or
            (Get-Item -LiteralPath (Join-Path $recoveredUi 'exvpn.exe')).VersionInfo.ProductVersion -cne $version){throw 'shorebird_recovery_ui_identity_invalid'}
        $tree=@($recoveredFiles.Keys | Sort-Object | ForEach-Object {[ordered]@{path=$_;sha256=$recoveredFiles[$_].sha256;size=$recoveredFiles[$_].size}})
        $recoveryProof=[ordered]@{compiledSourceCommit=$compiledSourceCommit;sourceCommit=$sourceCommit;releaseId=$cloudRelease.id
            artifactId=$recoveryPolicy.artifactId;archiveSha256=$recoveryPolicy.sha256;archiveBytes=$recoveryPolicy.bytes
            uiFiles=$recoveredFiles.Count;uiTreeSha256=(Get-AuditTextHash ($tree | ConvertTo-Json -Depth 5 -Compress))
            sourceEquivalence=$recoveryEquivalence;uiBuildPerformed=$false;cloudUploadPerformed=$false}
        Assert-ShorebirdRecoveryProof $recoveryProof $sourceCommit
    } elseif ($Independent) {
        $phase='independent_base';$subphase='compiled_updater_lease'
        # The legacy source policy remains unchanged. Only the packaged asset
        # receives the local adapter endpoint and the pinned native RSA key.
        $compiledConfig="app_id: $appId`nauto_update: false`npatch_verification: strict`nbase_url: http://127.0.0.1:57791`npatch_public_key: $compiledPublicKey`n"
        Assert-CompiledUpdater $compiledConfig
        [IO.File]::WriteAllText((Join-Path $app 'shorebird.yaml'),$compiledConfig,[Text.UTF8Encoding]::new($false))
        $independentConfigHash=Get-AuditSha256 (Join-Path $app 'shorebird.yaml')
        $independentConfigLeased=$true
        $defines=@('--dart-define=EXVPN_DEMO=false','--dart-define=EXVPN_DART_UPDATE_TRACK=beta',
            '--dart-define=EXVPN_OTA_PROVIDER=exvpn',"--dart-define=EXVPN_OTA_BASE_FINGERPRINT=$IndependentBaseFingerprint")
        $releaseStartedUtc=[datetime]::UtcNow
        $releaseProcessPathLength=$(if($env:PATH){$env:PATH.Length}else{0})
        if ($Target -ceq 'Android') {
            $subphase='aab'
            & $flutter build appbundle --release --pub --target=lib/main.dart --target-platform=android-arm64,android-x64 @defines *> (Join-Path $privateRun 'independent-aab.log')
            if ($LASTEXITCODE -ne 0) { throw 'independent_base_aab_failed' }
            $subphase='apk'
            & $flutter build apk --release --pub --target=lib/main.dart --target-platform=android-arm64,android-x64 @defines *> (Join-Path $privateRun 'independent-apk.log')
            if ($LASTEXITCODE -ne 0) { throw 'independent_base_apk_failed' }
        } else {
            $subphase='windows'
            & $flutter build windows --release --no-pub --target=lib/main.dart @defines *> (Join-Path $privateRun 'independent-windows.log')
            if ($LASTEXITCODE -ne 0) { throw 'independent_base_windows_failed' }
        }
        Restore-IndependentUpdaterConfig
    } else {
    $arguments = @('release', $Target.ToLowerInvariant(), "--flutter-version=$($pin.flutter.revision)",
        "--public-key-path=$publicKeyPath", '--dart-define=EXVPN_DART_UPDATE_TRACK=beta','--dart-define=EXVPN_DEMO=false')
    if ($Target -eq 'Android') { $arguments += @('--artifact=apk','--target-platform=android-arm64,android-x64') }
    if (!$PublishCloud) { $arguments += '--dry-run' }
    # Android's release plugin registrant is regenerated only when --pub is
    # enabled. Shorebird resets it with a normal pub get between AAB and APK,
    # so --no-pub would leave dev-only integration_test in release Java code.
    # Dependencies were verified offline above; reject any lock change below.
    $arguments += @(Get-ShorebirdBaseForwardingArguments $Target ($env:GITHUB_ACTIONS -ceq 'true'))
    $phase = 'shorebird_release'
    $subphase='release'
    if ($PublishCloud) {
        $null=Write-ShorebirdRecovery -Repository $repository -Action base -Version $version -Target $Target -SourceCommit $sourceCommit -Status attempting -CloudOutcome unknown -Phase $phase -Subphase $subphase -Path $recoveryPath
    }
    $releaseStartedUtc=[datetime]::UtcNow
    $releaseProcessPathLength=$(if($env:PATH){$env:PATH.Length}else{0})
    $cloud = Invoke-ShorebirdJson $shorebird $arguments 'release' $privateRun 'release'
    if ($PublishCloud) {
        if ($cloud.app_id -cne $appId -or @($cloud.releases).Count -ne 1) { throw 'shorebird_cloud_release_invalid' }
        $cloudRelease = $cloud.releases[0]
        Assert-ShorebirdCloudRelease $cloudRelease $version $Target
        $cloudRegisteredVerified = $true
        $null=Write-ShorebirdRecovery -Repository $repository -Action base -Version $version -Target $Target -SourceCommit $sourceCommit -Status cloud_registered -CloudOutcome registered -Phase $phase -ReleaseId $cloudRelease.id -Path $recoveryPath
        # Preserve cloud-registration evidence immediately. A later audit failure
        # must not be mistaken for an unpublished release or retried blindly.
        [ordered]@{schemaVersion=1;action='cloud_registered';version=$version;target=$Target;sourceCommit=$sourceCommit;releaseId=$cloudRelease.id;published=$true;distributionApproved=$false} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $privateRun 'cloud-registered.json') -Encoding utf8NoBOM
    } elseif (!$cloud.dry_run -or $cloud.release_version -cne $version) { throw 'shorebird_dry_run_response_invalid' }
    }
    if ($hookOwned) { Remove-DemoAndroidOwnedHook $hook $hookHash; $hookOwned = $false }
    $phase = 'package_audit'
    $subphase='lock_check'
    if ((Get-FileHash (Join-Path $app 'pubspec.lock')).Hash -cne $lockHash -or
        (Get-FileHash (Join-Path $app 'shorebird.yaml')).Hash -cne $configHash) {
        throw 'Source lock or updater policy changed during the build.'
    }
    $subphase='runtime_check'
    $runtimeAfter = Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release
    if (($runtime.Evidence | ConvertTo-Json -Depth 16 -Compress) -cne ($runtimeAfter.Evidence | ConvertTo-Json -Depth 16 -Compress)) {
        throw 'Pinned runtime changed during the build.'
    }
    if ($Target -eq 'Android') {
        . (Join-Path $PSScriptRoot 'android-notice-inputs.ps1')
        $subphase='android_runtime'
        $noticeBundle = Join-Path $packageInputs.InputDirectory 'assets/exvpn_notices'
        $noticeInventory = Get-Content -LiteralPath (Join-Path $noticeBundle 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-ShorebirdRuntimeNotices $noticeInventory (Get-ShorebirdRuntimeNotices $repository $runtimeAfter) $noticeBundle
        $apk = Join-Path $app 'build/app/outputs/flutter-apk/app-release.apk'
        $aab = Join-Path $app 'build/app/outputs/bundle/release/app-release.aab'
        $packagedRuntime = Assert-AndroidPackagedNotices $repository $packageInputs.InputDirectory $apk `
            -FlutterRuntime shorebird -FlutterBuildMode release -PassThruRuntime -AndroidSdkPath $AndroidSdkPath
        Assert-ZipUpdater $apk 'assets/flutter_assets/shorebird.yaml'
        Assert-ZipUpdater $aab 'base/assets/flutter_assets/shorebird.yaml'
        # Shorebird records the AAB's Dart libraries, but testers install the
        # APK. Both base libraries must be identical before distribution.
        $baseAot = @(Assert-ShorebirdAndroidAotBinding $apk $aab)
        # Upstream finishes with an ordinary pub get, restoring dev-only
        # integration_test registration after its APK/AAB build. Regenerate only
        # release configuration; preserve exact cloud-recorded package bytes.
        $subphase='android_release_configuration'
        $releaseConfiguration = Invoke-ShorebirdAndroidReleaseConfiguration -Flutter $flutter -Apk $apk -Aab $aab `
            -Registrant (Join-Path $app 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java') `
            -PrivateLog (Join-Path $privateRun 'release-configuration.log') -ReadProtectedInputs {
                Assert-AndroidNoticeSeal $repository $packageInputs.InputDirectory -FlutterRuntime shorebird -FlutterBuildMode release
                [ordered]@{
                    seal=(Get-AuditSha256 (Join-Path $packageInputs.InputDirectory 'seal.json'))
                    snapshot=(Get-AndroidNoticeSnapshotState $repository $packageInputs.InputDirectory -FlutterRuntime shorebird -FlutterBuildMode release)
                    updater=(Get-AuditSha256 (Join-Path $app 'shorebird.yaml'))
                    source=(Get-ShorebirdSourceCommit $repository)
                }
            }
        $subphase='android_jvm'
        $jvmStarted = [datetime]::UtcNow
        Push-Location (Join-Path $app 'android')
        try {
            & './gradlew.bat' @(Get-DemoAndroidJvmArguments) *> (Join-Path $privateRun 'jvm.log')
            if ($LASTEXITCODE -ne 0) { throw 'shorebird_android_jvm_failed' }
        } finally { Pop-Location }
        $jvm = Get-DemoAndroidJvmSummary (Join-Path $app 'build/app/test-results/testReleaseUnitTest') $jvmStarted
        $subphase='android_identity'
        $signatureText = Invoke-AuditTool (Join-Path $env:JAVA_HOME 'bin/java.exe') @('-jar',(Join-Path $AndroidSdkPath 'build-tools/36.0.0/lib/apksigner.jar'),'verify','--verbose','--print-certs',$apk)
        $signature = ConvertFrom-DemoAndroidSignature $signatureText $expectedSigner
        $identity = ConvertFrom-DemoAndroidIdentity (Invoke-AuditTool (Join-Path $AndroidSdkPath 'build-tools/36.0.0/aapt2.exe') @('dump','badging',$apk)) $version
        Copy-Item -LiteralPath $apk -Destination (Join-Path $stage "ExVPN-$($versionParts[0])-$($versionParts[1])-android.apk")
        Copy-Item -LiteralPath $aab -Destination (Join-Path $stage "ExVPN-$($versionParts[0])-$($versionParts[1])-android.aab")
        # Retain the exact sealed JNI/notices inputs for later Dart-only patches.
        Copy-Item -LiteralPath $packageInputs.InputDirectory -Destination (Join-Path $stage 'patch-inputs') -Recurse
        [IO.Compression.ZipFile]::CreateFromDirectory($noticeBundle,(Join-Path $stage 'android-notices.zip'))
        $subphase='android_notice_supplement'
        & (Join-Path $PSScriptRoot 'prepare-demo-maven-notices.ps1') -ResolvedGraph $rawGraph -ArtifactPath $apk -AppVersion $version -OutputDirectory $stage -FlutterRuntime shorebird *> (Join-Path $privateRun 'maven-notices.log')
        if (!$?) { throw 'shorebird_maven_notices_failed' }
        Export-ShorebirdPreviewAudit $repository Android $apk $stage $version $privateRun $AndroidSdkPath $expectedSigner
    } else {
        $subphase='windows_ui_binding'
        $ui = if($RecoverWindowsBase){$recoveredUi}else{Join-Path $app 'build/windows/x64/runner/Release'}
        if ($Independent) {
            $windowsRegistrant=Join-Path $app 'windows/flutter/generated_plugin_registrant.cc'
            if ([IO.File]::ReadAllText($windowsRegistrant) -match 'IntegrationTestPlugin|integration_test') { throw 'independent_windows_development_plugin_present' }
        }
        $null = Get-AuditTreeFiles $ui
        Assert-CompiledUpdater ([IO.File]::ReadAllText((Join-Path $ui 'data/flutter_assets/shorebird.yaml')))
        $baseAot = @([ordered]@{platform='windows';arch='x86_64';sha256=(Get-AuditSha256 (Join-Path $ui 'data/app.so'));bytes=(Get-Item -LiteralPath (Join-Path $ui 'data/app.so')).Length})
        Copy-Item -LiteralPath $ui -Destination (Join-Path $stage 'ui') -Recurse
        . (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
        $packagedRuntime = Get-ReleasePackagedFlutterEvidence $runtimeAfter.Evidence (Get-AuditTreeFiles $stage) -RequireByteMatch
        $packageRoot = Join-Path $repository 'artifacts/windows'
        $previous = @(Get-ChildItem -LiteralPath $packageRoot -Directory -Filter 'package-*' | ForEach-Object FullName)
        $subphase='windows_msvc'
        $msvc = & (Join-Path $repository 'scripts/windows/prepare-ci-msvc-runtime.ps1')
        $subphase='windows_installer'
        & (Join-Path $repository 'scripts/windows/build-installer.ps1') -FlutterRuntime shorebird -UiDirectory (Join-Path $stage 'ui') -RuntimeDirectory $msvc.RuntimeDirectory -DumpbinPath $msvc.DumpbinPath *> (Join-Path $privateRun 'installer.log')
        if (!$?) { throw 'shorebird_installer_failed' }
        $packages = @(Get-ChildItem -LiteralPath $packageRoot -Directory -Filter 'package-*' | Where-Object FullName -CNotIn $previous)
        if ($packages.Count -ne 1) { throw 'shorebird_installer_ambiguous' }
        $artifact = Get-Content -LiteralPath (Join-Path $packages[0].FullName 'artifact.json') -Raw | ConvertFrom-Json
        $noticeBundle = Join-Path $packages[0].FullName 'payload/control/notices'
        $subphase='windows_notice_binding'
        $noticeInventory = Get-Content -LiteralPath (Join-Path $noticeBundle 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-ShorebirdRuntimeNotices $noticeInventory (Get-ShorebirdRuntimeNotices $repository $runtimeAfter) $noticeBundle
        Copy-Item -LiteralPath (Join-Path $packages[0].FullName $artifact.file) -Destination (Join-Path $stage $artifact.file)
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $packages[0].FullName 'payload/control'),(Join-Path $stage 'windows-notices.zip'))
        $subphase='windows_audit'
        Export-ShorebirdPreviewAudit $repository Windows $packages[0].FullName $stage $version $privateRun
    }
    if (!$packagedRuntime.engineBytesBound) {
        throw 'Packaged Flutter engine is not bound to the pinned SDK or verified Android strip transform.'
    }
    $subphase='source_final'
    if ((Get-ShorebirdSourceCommit $repository) -cne $sourceCommit) { throw 'shorebird_source_changed' }
    $phase = 'promotion'
    $subphase='promotion'
    [ordered]@{
        schemaVersion=2; action='base'; version=$version; target=$Target; track='beta'; published=([bool]$PublishCloud -or [bool]$RecoverWindowsBase)
        delivery=$(if ($Independent) {'independent'} else {'shorebird_cloud'})
        appId=$appId; sourceCommit=$sourceCommit; releaseId=$(if ($cloudRelease) { $cloudRelease.id } else { $null })
        compiledSourceCommit=$compiledSourceCommit;recoveryProof=$recoveryProof
        auditAccepted=$true; stableReady=$false
        baseAot=$baseAot
        publicKeySha256=(Get-FileHash $publicKeyPath -Algorithm SHA256).Hash.ToLowerInvariant()
        updaterPolicyVerified=$true; autoUpdate=$false; patchVerification='strict'
        runtime=$runtimeAfter.Evidence; packagedRuntime=$packagedRuntime; sourceLockUnchanged=$true
        android=$(if ($Target -ceq 'Android') { $identity } else { $null }); signature=$(if ($Target -ceq 'Android') { $signature } else { $null })
        jvm=$(if ($Target -ceq 'Android') { $jvm } else { $null })
        androidReleaseConfiguration=$(if ($Target -ceq 'Android') { $releaseConfiguration } else { $null })
        files=@(Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
            [ordered]@{path=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        })
        limitations=@('Controlled beta base; not stable VPN acceptance.','Patch download/restart/rollback and channel isolation need device tests.','Native signing and complete release audit are separate checks.')
    } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $stage 'build.json') -Encoding utf8NoBOM
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($output)) -Force | Out-Null
    Assert-AuditNoLinks ([IO.Path]::GetDirectoryName($output))
    Move-Item -LiteralPath $stage -Destination $output
    if ($recoveryPath) {
        $null=Write-ShorebirdRecovery -Repository $repository -Action base -Version $version -Target $Target -SourceCommit $sourceCommit -Status ready -CloudOutcome registered -Phase $phase -Subphase $subphase -ReleaseId $cloudRelease.id -Path $recoveryPath
    }
} catch {
    $safeErrorCode=Get-ShorebirdSafeFailureCode $_.Exception.Message
    $safeFailureLeaf=Get-ShorebirdSafeFailureLeaf $_.InvocationInfo.ScriptName
    $safeFailureLine=$_.InvocationInfo.ScriptLineNumber
    if($Target -ceq 'Android' -and $phase -ceq 'shorebird_release' -and $releaseStartedUtc -ne [datetime]::MinValue){
        # Diagnostics must never replace the original CLI failure or weaken
        # Flutter's strip validation. Paths and raw process logs stay private.
        try{$null=Write-ShorebirdAndroidFailureDiagnostic $repository $runtime.SdkRoot $AndroidSdkPath $privateRun $releaseStartedUtc $releaseProcessPathLength}catch{ }
    }
    ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $privateRun 'failure.log') -Encoding utf8NoBOM
    if ($recoveryPath) {
        $null=Write-ShorebirdRecovery -Repository $repository -Action base -Version $version -Target $Target -SourceCommit $sourceCommit -Status failed -CloudOutcome $(if ($cloudRegisteredVerified) {'registered'} else {'unknown'}) -Phase $phase -Subphase $subphase -ErrorCode $safeErrorCode -FailureLeaf $safeFailureLeaf -FailureLine $safeFailureLine -ReleaseId $(if ($cloudRegisteredVerified) {$cloudRelease.id} else {0}) -Path $recoveryPath
    }
    throw "shorebird_base_failed phase=$phase subphase=$subphase code=$safeErrorCode; private diagnostics retained; inspect cloud registration before retry"
} finally {
    Pop-Location
    try {
        Restore-IndependentUpdaterConfig
        if ($hookOwned) { Remove-DemoAndroidOwnedHook $hook $hookHash }
    }
    finally {
        if ($passwordBytes) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($passwordBytes) }
        foreach ($name in $savedEnvironment.Keys) {
            if ($null -eq $savedEnvironment[$name]) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
        }
    }
}
[pscustomobject]@{OutputDirectory=$output; PrivateLogDirectory=$privateRun; Published=([bool]$PublishCloud -or [bool]$RecoverWindowsBase); Version=$version; Target=$Target}
