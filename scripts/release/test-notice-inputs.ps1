# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$checks = 0
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Invalid notice input was accepted.' }
    $script:checks++
}
$identity = "const appVersion = '1.2.3';`nconst appBuild = 42;"
if ((Get-NoticeAppVersion 'version: 1.2.3+42' $identity) -cne '1.2.3+42') { throw 'Application identity mismatch.' }
$checks++
Assert-Rejected { Get-NoticeAppVersion 'version: 1.2.3+41' $identity }
Assert-Rejected { Get-NoticeAppVersion "version: 1.2.3+42`nversion: 1.2.3+42" $identity }
Assert-Rejected { Get-NoticeAppVersion 'version: 1.2.3+42' ("// " + $identity) }
Assert-Rejected { Get-NoticeAppVersion 'version: 1.2.3+42' ($identity + "`nconst appBuild = 41;") }

# Own disposable source/cache fixture. No native runtime, downloads or service
# installation. Keep evidence instead of recursively deleting directories.
$fixture = Join-Path $repository ('artifacts/qa/notice-fixture-' + [Guid]::NewGuid().ToString('N'))
$app = Join-Path $fixture 'apps/exvpn'
$configPath = Join-Path $app '.dart_tool/package_config.json'
$package = Join-Path $fixture '.tools/cache/pub/hosted/pub.dev/sample-1.0.0'
$hashFile = Join-Path $fixture '.tools/cache/pub/hosted-hashes/pub.dev/sample-1.0.0.sha256'
New-Item -ItemType Directory -Path (Split-Path $configPath),$package,(Split-Path $hashFile) -Force | Out-Null
$hash = 'a' * 64
Set-Content -LiteralPath (Join-Path $package 'pubspec.yaml') -Value "name: sample`nversion: 1.0.0 # pinned source comment"
Set-Content -LiteralPath $hashFile -Value $hash
$lock = @"
packages:
  sample:
    dependency: transitive
    description:
      name: sample
      sha256: "$hash"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
sdks:
  dart: ">=3.13.0 <4.0.0"
"@
$config = [ordered]@{configVersion=2;packages=@(@{name='sample';rootUri=([Uri]::new($package)).AbsoluteUri},@{name='exvpn';rootUri='../'})}
function Save-Config { $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath }
Save-Config
$resolved = @(Get-NoticeDartInputs $fixture $lock $configPath)
if ($resolved.Count -ne 1 -or $resolved[0].archiveSha256 -cne $hash) { throw 'Valid locked package was lost.' }
$checks++
Assert-Rejected { Get-NoticeDartInputs $fixture ($lock.Replace('version: "1.0.0"','version: "1.0.1"')) $configPath }
Assert-Rejected { Get-NoticeDartInputs $fixture ($lock.Replace('https://pub.dev','https://untrusted.invalid')) $configPath }
Assert-Rejected { Get-NoticeDartInputs $fixture ($lock.Replace('source: hosted',"source: hosted`n    source: hosted")) $configPath }
Set-Content -LiteralPath $hashFile -Value ('b' * 64)
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }
Set-Content -LiteralPath $hashFile -Value $hash
Set-Content -LiteralPath (Join-Path $package 'pubspec.yaml') -Value "name: sample`nversion: 1.0.1"
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }
Set-Content -LiteralPath (Join-Path $package 'pubspec.yaml') -Value "name: sample`nversion: 1.0.0"
$config.packages = @($config.packages[1]); Save-Config
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }
$config.packages = @(@{name='sample';rootUri=([Uri]::new($package)).AbsoluteUri},@{name='sample';rootUri=([Uri]::new($package)).AbsoluteUri},@{name='exvpn';rootUri='../'}); Save-Config
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }

$info = @{GoVersion='go1.27.2';Settings=@(@{Key='GOOS';Value='windows'},@{Key='GOARCH';Value='amd64'},@{Key='-buildmode';Value='exe'})}
if ((Get-NoticeBinaryName 'Windows' $info '1.27.2') -cne 'service/exvpn-service.exe') { throw 'Wrong Windows binary identity.' }
$checks++
Assert-Rejected { Get-NoticeBinaryName 'Android' $info '1.27.2' }
Assert-Rejected { Get-NoticeBinaryName 'Windows' $info '1.27.1' }
$info.Settings = @(@{Key='GOOS';Value='android'},@{Key='GOARCH';Value='arm64'},@{Key='-buildmode';Value='c-shared'})
if ((Get-NoticeBinaryName 'Android' $info '1.27.2') -cne 'lib/arm64-v8a/libexvpn.so') { throw 'Wrong Android ABI identity.' }
$checks++
$info.Settings[1].Value = 'amd64'
if ((Get-NoticeBinaryName 'Android' $info '1.27.2') -cne 'lib/x86_64/libexvpn.so') { throw 'Wrong x86_64 ABI identity.' }
$checks++

$inventory = [pscustomobject]@{schema=1;app=@{version='1.2.3+42'};dartLockSha256=$hash;nativeBinaries=@(@{name='service/exvpn-service.exe';sha256=$hash});components=@(@{name='ExVPN';version='1.2.3+42'},@{name='ExVPN copyright';version='1.2.3+42'})}
Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash}
$checks++
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+43' $hash @{'service/exvpn-service.exe'=$hash} }
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' ('b' * 64) @{'service/exvpn-service.exe'=$hash} }
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=('b' * 64)} }
$inventory.components[0].version='1.2.3+1'
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash} }
$patchDirectory = Join-Path $fixture 'native/patches'
New-Item -ItemType Directory -Path $patchDirectory -Force | Out-Null
$patchPath = Join-Path $patchDirectory 'xray-lifecycle.patch'
$patchLockPath = Join-Path $patchDirectory 'xray-lifecycle.lock.json'
[IO.File]::WriteAllText($patchPath, 'synthetic patch fixture')
$patchPin = [ordered]@{
    schemaVersion=1; module='github.com/xtls/xray-core'
    upstream=@{commit=('a' * 40)}
    patch=@{path='xray-lifecycle.patch';sha256=(Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    patched=@{version='v1.0.0-exvpn.1';sum='h1:synthetic'}
}
function Save-PatchPin { $patchPin | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $patchLockPath -Encoding utf8NoBOM }
Save-PatchPin
$provenance = Get-NoticeXrayPatch $fixture 'v1.0.0-exvpn.1' 'h1:synthetic'
if ($provenance.sourceUrl -notlike 'https://github.com/Extectick/ExVPN/*' -or
    $provenance.patchSha256 -cne $patchPin.patch.sha256) { throw 'Modified source provenance was lost.' }
$checks++
if ($null -ne (Get-NoticeXrayPatch $fixture 'v1.0.0' 'h1:stock')) { throw 'Historical stock Xray was relabeled as modified.' }
$checks++
$sourceBundle = @{
    'sources/xray-lifecycle.patch' = @{sha256=$provenance.patchSha256}
    'sources/xray-lifecycle.lock.json' = @{sha256=(Get-FileHash -LiteralPath $patchLockPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    'sources/XRAY-EXVPN-NOTICE.txt' = @{sha256=('b' * 64)}
}
Assert-NoticeXraySourceBundle $provenance $sourceBundle
$checks++
foreach ($entry in @($sourceBundle.Keys)) {
    $savedEntry=$sourceBundle[$entry]
    $sourceBundle.Remove($entry)
    Assert-Rejected { Assert-NoticeXraySourceBundle $provenance $sourceBundle }
    $sourceBundle[$entry]=$savedEntry
}
foreach ($entry in @('sources/xray-lifecycle.patch','sources/xray-lifecycle.lock.json')) {
    $savedHash=$sourceBundle[$entry].sha256
    $sourceBundle[$entry].sha256='0' * 64
    Assert-Rejected { Assert-NoticeXraySourceBundle $provenance $sourceBundle }
    $sourceBundle[$entry].sha256=$savedHash
}
Assert-Rejected { Get-NoticeXrayPatch $fixture 'v1.0.0-exvpn.2' 'h1:synthetic' }
Assert-Rejected { Get-NoticeXrayPatch $fixture 'v1.0.0-exvpn.1' 'h1:other' }
$patchPin.patch.path='../untrusted.patch'; Save-PatchPin
Assert-Rejected { Get-NoticeXrayPatch $fixture 'v1.0.0-exvpn.1' 'h1:synthetic' }
$patchPin.patch.path='xray-lifecycle.patch'; Save-PatchPin
[IO.File]::WriteAllText($patchPath, 'mutated patch fixture')
Assert-Rejected { Get-NoticeXrayPatch $fixture 'v1.0.0-exvpn.1' 'h1:synthetic' }
function Write-RuntimeFixture([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Commit-RuntimeFixture([string]$Root) {
    & git -C $Root init --quiet --initial-branch=fixture
    if ($LASTEXITCODE) { throw 'Fixture Git init failed.' }
    & git -C $Root -c core.autocrlf=false add --all
    & git -C $Root -c core.hooksPath=NUL -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --quiet -m fixture
    if ($LASTEXITCODE) { throw 'Fixture Git commit failed.' }
    (& git -C $Root rev-parse HEAD).Trim()
}
function New-RuntimeSdk([string]$Root, [string]$Engine, [string]$Kind) {
    Write-RuntimeFixture (Join-Path $Root '.gitignore') "/bin/cache/`n"
    Write-RuntimeFixture (Join-Path $Root 'bin/internal/engine.version') "$Engine`n"
    Write-RuntimeFixture (Join-Path $Root 'LICENSE') "synthetic $Kind SDK license"
    $revision = Commit-RuntimeFixture $Root
    Write-RuntimeFixture (Join-Path $Root 'bin/cache/engine.stamp') "$Engine`n"
    Write-RuntimeFixture (Join-Path $Root 'bin/cache/dart-sdk/version') '3.13.5'
    Write-RuntimeFixture (Join-Path $Root 'bin/cache/dart-sdk/LICENSE') "synthetic $Kind Dart license"
    Write-AuditJson (Join-Path $Root 'bin/cache/flutter.version.json') ([ordered]@{frameworkVersion='3.47.7';frameworkRevision=$revision;engineRevision=$Engine;dartSdkVersion='3.13.5'})
    foreach ($abi in @(@('android-arm64','arm64-v8a'),@('android-x64','x86_64'))) {
        foreach ($suffix in @('','-release')) {
            $dir = Join-Path $Root "bin/cache/artifacts/engine/$($abi[0])$suffix"
            Write-RuntimeFixture (Join-Path $dir 'license.flutter_jar_zip.md') "synthetic $Kind $($abi[0])$suffix notice"
            $zip = [IO.Compression.ZipFile]::Open((Join-Path $dir 'flutter.jar'), [IO.Compression.ZipArchiveMode]::Create)
            try {
                $stream = $zip.CreateEntry("lib/$($abi[1])/libflutter.so").Open()
                try { $bytes=[Text.Encoding]::UTF8.GetBytes("synthetic $Kind $($abi[0])$suffix engine"); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
            } finally { $zip.Dispose() }
        }
    }
    Write-RuntimeFixture (Join-Path $Root 'bin/cache/artifacts/engine/windows-x64-release/license.windows_flutter.md') "synthetic $Kind Windows notice"
    Write-RuntimeFixture (Join-Path $Root 'bin/cache/artifacts/engine/windows-x64-release/flutter_windows.dll') "synthetic $Kind Windows engine"
    $revision
}
function Assert-RuntimeRefused([scriptblock]$Action, [string]$Code) {
    $actual = ''
    try { & $Action | Out-Null } catch { $actual=$_.Exception.Message }
    if ($actual -cne $Code) { throw "Runtime fixture expected $Code, got $actual" }
    $script:checks++
}
$runtimeFixture = Join-Path $fixture 'runtimes'
$ordinarySdk = Join-Path $runtimeFixture '.tools/flutter'
$ordinaryRevision = New-RuntimeSdk $ordinarySdk ('a' * 40) 'ordinary'
$ordinaryPin = [ordered]@{schemaVersion=1;flutter=@{version='3.47.7';dartVersion='3.13.5';revision=$ordinaryRevision;folder='flutter'}}
Write-RuntimeFixture (Join-Path $runtimeFixture 'scripts/bootstrap/toolchain.lock.json') ($ordinaryPin | ConvertTo-Json -Depth 6)
$ordinary = Get-ReleaseFlutterRuntime $runtimeFixture Android
if ($ordinary.Identity.kind -cne 'ordinary' -or $ordinary.Identity.buildMode -cne 'debug' -or $ordinary.Evidence.engineBinaries.Count -ne 2) { throw 'Default ordinary runtime changed.' }
$checks++
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Windows -FlutterBuildMode debug } 'flutter_runtime_mode_unsupported'
$stamp = Join-Path $ordinarySdk 'bin/cache/engine.stamp'
Write-RuntimeFixture $stamp ('b' * 40)
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android } 'flutter_runtime_engine_stamp_mismatch'
Write-RuntimeFixture $stamp ('a' * 40)
Write-RuntimeFixture (Join-Path $ordinarySdk 'bin/cache/dart-sdk/version') '3.13.4'
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android } 'flutter_runtime_dart_version_mismatch'
Write-RuntimeFixture (Join-Path $ordinarySdk 'bin/cache/dart-sdk/version') '3.13.5'
Write-RuntimeFixture (Join-Path $ordinarySdk 'LICENSE') 'tampered SDK'
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android } 'flutter_runtime_checkout_modified'
Write-RuntimeFixture (Join-Path $ordinarySdk 'LICENSE') 'synthetic ordinary SDK license'
$ordinaryPin.flutter.revision='c' * 40
Write-AuditJson (Join-Path $runtimeFixture 'scripts/bootstrap/toolchain.lock.json') $ordinaryPin
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android } 'flutter_runtime_checkout_mismatch'
$ordinaryPin.flutter.revision=$ordinaryRevision
Write-AuditJson (Join-Path $runtimeFixture 'scripts/bootstrap/toolchain.lock.json') $ordinaryPin
$versionPath=Join-Path $ordinarySdk 'bin/cache/flutter.version.json'
$versionBytes=[IO.File]::ReadAllText($versionPath)
Write-RuntimeFixture $versionPath ($versionBytes.Replace('3.47.7','3.47.6'))
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android } 'flutter_runtime_version_metadata_mismatch'
Write-RuntimeFixture $versionPath $versionBytes

$cliRoot = Join-Path $runtimeFixture '.tools/shorebird-1.6.129'
Write-RuntimeFixture (Join-Path $cliRoot '.gitignore') "/bin/cache/`n"
Write-RuntimeFixture (Join-Path $cliRoot 'bin/shorebird.ps1') 'synthetic CLI, never executed'
Write-RuntimeFixture (Join-Path $cliRoot 'pubspec.lock') 'synthetic CLI dependencies'
$cliRevision = Commit-RuntimeFixture $cliRoot
$sdkStaging = Join-Path $cliRoot 'bin/cache/flutter/fixture'
$shorebirdRevision = New-RuntimeSdk $sdkStaging ('b' * 40) 'shorebird'
# Move only this exact new fixture directory to its derived pinned path.
$shorebirdSdk = Join-Path $cliRoot "bin/cache/flutter/$shorebirdRevision"
if (![IO.Path]::GetFullPath($sdkStaging).StartsWith([IO.Path]::GetFullPath($runtimeFixture)+[IO.Path]::DirectorySeparatorChar) -or
    ![IO.Path]::GetFullPath($shorebirdSdk).StartsWith([IO.Path]::GetFullPath($runtimeFixture)+[IO.Path]::DirectorySeparatorChar)) { throw 'Fixture move outside owned root.' }
Move-Item -LiteralPath $sdkStaging -Destination $shorebirdSdk
$shorebirdPin = [ordered]@{schemaVersion=1;cli=@{version='1.6.129';revision=$cliRevision;folder='shorebird-1.6.129';repository='https://github.com/shorebirdtech/shorebird.git';powershellEntrypointSha256=(Get-AuditSha256 (Join-Path $cliRoot 'bin/shorebird.ps1'));pubspecLockSha256=(Get-AuditSha256 (Join-Path $cliRoot 'pubspec.lock'))};flutter=@{repository='https://github.com/shorebirdtech/flutter.git';version='3.47.7';revision=$shorebirdRevision;engineRevision=('b' * 40);dartVersion='3.13.5'}}
Write-AuditJson (Join-Path $runtimeFixture 'scripts/bootstrap/shorebird.lock.json') $shorebirdPin
$shorebird = Get-ReleaseFlutterRuntime $runtimeFixture Android -FlutterRuntime shorebird
if ($shorebird.Identity.buildMode -cne 'release' -or $shorebird.Identity.engineRevision -ceq $ordinary.Identity.engineRevision -or
    ($shorebird.Evidence | ConvertTo-Json -Depth 12) -match [regex]::Escape($runtimeFixture)) { throw 'Shorebird identity or path-free evidence failed.' }
$checks++
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android -FlutterRuntime shorebird -FlutterBuildMode debug } 'flutter_runtime_mode_unsupported'
$shorebirdPin.cli.powershellEntrypointSha256='0' * 64
Write-AuditJson (Join-Path $runtimeFixture 'scripts/bootstrap/shorebird.lock.json') $shorebirdPin
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android -FlutterRuntime shorebird } 'flutter_runtime_cli_pin_mismatch'
$shorebirdPin.cli.powershellEntrypointSha256=Get-AuditSha256 (Join-Path $cliRoot 'bin/shorebird.ps1')
$shorebirdPin.flutter.engineRevision='c' * 40
Write-AuditJson (Join-Path $runtimeFixture 'scripts/bootstrap/shorebird.lock.json') $shorebirdPin
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android -FlutterRuntime shorebird } 'flutter_runtime_engine_pin_mismatch'
$shorebirdPin.flutter.engineRevision='b' * 40
Write-AuditJson (Join-Path $runtimeFixture 'scripts/bootstrap/shorebird.lock.json') $shorebirdPin
$shorebird = Get-ReleaseFlutterRuntime $runtimeFixture Android -FlutterRuntime shorebird
$sdkConfigPath=Join-Path $runtimeFixture 'apps/exvpn/.dart_tool/package_config.json'
$sdkLock="packages:`n  flutter:`n    dependency: direct main`n    description: flutter`n    source: sdk`n    version: 0.0.0`nsdks:`n  dart: '>=3.13.0 <4.0.0'`n"
New-Item -ItemType Directory -Path (Join-Path $shorebirdSdk 'packages/flutter') -Force | Out-Null
Write-RuntimeFixture $sdkConfigPath (@{configVersion=2;packages=@(@{name='exvpn';rootUri='../'},@{name='flutter';rootUri=([Uri]::new((Join-Path $shorebirdSdk 'packages/flutter'))).AbsoluteUri})} | ConvertTo-Json -Depth 6)
Get-NoticeDartInputs $runtimeFixture $sdkLock $sdkConfigPath -FlutterSdkRoot $shorebirdSdk | Out-Null
$checks++
Assert-RuntimeRefused { Get-NoticeDartInputs $runtimeFixture $sdkLock $sdkConfigPath -FlutterSdkRoot $ordinarySdk } 'flutter_runtime_dart_sdk_root_mismatch'
$runtimeInventory = [ordered]@{runtime=$shorebird.Evidence;components=@($shorebird.Evidence.notices | ForEach-Object { [ordered]@{name=$_.name;version=$_.version;notices=@(@{sha256=$_.sha256})} })}
Assert-ReleaseFlutterNotices $runtimeInventory $shorebird.Evidence
$checks++
Assert-RuntimeRefused { Assert-ReleaseFlutterNotices $runtimeInventory $ordinary.Evidence } 'flutter_runtime_evidence_mismatch'
$runtimeInventory.components[0].notices[0].sha256='0' * 64
Assert-RuntimeRefused { Assert-ReleaseFlutterNotices $runtimeInventory $shorebird.Evidence } 'flutter_runtime_notice_mismatch'
$runtimeInventory.components[0].notices[0].sha256=$shorebird.Evidence.notices[0].sha256
$runtimeInventory.runtime=$null
Assert-RuntimeRefused { Assert-ReleaseFlutterNotices $runtimeInventory $shorebird.Evidence } 'flutter_runtime_evidence_mismatch'
$files = New-AuditFileMap
foreach ($file in $shorebird.Evidence.engineBinaries) { $files.Add($file.path, $file) }
foreach ($abi in @('arm64-v8a','x86_64')) { $files.Add("lib/$abi/libapp.so", @{sha256=('c' * 64);size=20}) }
$packaged = Get-ReleasePackagedFlutterEvidence $shorebird.Evidence $files
if (!$packaged.engineBytesBound -or $packaged.dartBinaries.Count -ne 2 -or $packaged.completeLinkInventory) { throw 'Runtime packaged byte evidence failed.' }
$checks++
$files['lib/arm64-v8a/libflutter.so'] = @{sha256=('d' * 64);size=30}
$packaged = Get-ReleasePackagedFlutterEvidence $shorebird.Evidence $files
if ($packaged.engineBytesBound -or $packaged.engineBinaries[0].sha256 -cne ('d' * 64)) { throw 'Transformed Android engine was falsely bound.' }
$checks++
Assert-RuntimeRefused { Get-ReleasePackagedFlutterEvidence $shorebird.Evidence $files -RequireByteMatch } 'flutter_runtime_packaged_engine_mismatch'
$files.Remove('lib/x86_64/libapp.so') | Out-Null
Assert-RuntimeRefused { Get-ReleasePackagedFlutterEvidence $shorebird.Evidence $files } 'flutter_runtime_packaged_dart_missing'
$windows = Get-ReleaseFlutterRuntime $runtimeFixture Windows -FlutterRuntime shorebird
$files = New-AuditFileMap
$files.Add('ui/flutter_windows.dll', $windows.Evidence.engineBinaries[0])
$files.Add('ui/data/app.so', @{sha256=('e' * 64);size=21})
$packaged = Get-ReleasePackagedFlutterEvidence $windows.Evidence $files -RequireByteMatch
if (!$packaged.engineBytesBound -or $packaged.dartBinaries.Count -ne 1) { throw 'Windows runtime byte binding failed.' }
$checks++
$files['ui/flutter_windows.dll'] = @{sha256=('f' * 64);size=22}
Assert-RuntimeRefused { Get-ReleasePackagedFlutterEvidence $windows.Evidence $files -RequireByteMatch } 'flutter_runtime_packaged_engine_mismatch'

# Android transform fixtures execute the real validation/extraction/comparison
# path with a deterministic strip double. Only the separate actual APK check
# executes pinned llvm-strip; unit tests need no installed NDK or native build.
$stripPinRelative='scripts/release/android-engine-transform.lock.json'
$stripPinPath=Join-Path $runtimeFixture $stripPinRelative
New-Item -ItemType Directory -Path (Split-Path $stripPinPath) -Force | Out-Null
$stripSdk=Join-Path $runtimeFixture 'android-sdk'
$stripNdk=Join-Path $stripSdk 'ndk/28.2.13676358'
$stripToolPath=Join-Path $stripNdk 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe'
$stripPropsPath=Join-Path $stripNdk 'source.properties'
Write-RuntimeFixture $stripToolPath 'synthetic strip, never executed'
Write-RuntimeFixture $stripPropsPath "Pkg.Desc = Android NDK`nPkg.Revision = 28.2.13676358`n"
$stripPin=Get-Content (Join-Path $PSScriptRoot 'android-engine-transform.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$stripPin.tool.sha256=Get-AuditSha256 $stripToolPath; $stripPin.tool.size=(Get-Item $stripToolPath).Length
$stripPin.sourceProperties.sha256=Get-AuditSha256 $stripPropsPath; $stripPin.sourceProperties.size=(Get-Item $stripPropsPath).Length
Write-AuditJson $stripPinPath $stripPin
$stripFiles=New-AuditFileMap
foreach($abi in @(@('android-arm64','arm64-v8a'),@('android-x64','x86_64'))) {
    $text="synthetic shorebird $($abi[0])-release engine -> synthetic stripped"
    $stripFiles.Add("lib/$($abi[1])/libflutter.so",@{sha256=(Get-AuditTextHash $text);size=[Text.Encoding]::UTF8.GetByteCount($text)})
    $stripFiles.Add("lib/$($abi[1])/libapp.so",@{sha256=('c' * 64);size=20})
}
$savedStrip=(Get-Item Function:Invoke-ReleaseRuntimeStrip).ScriptBlock
$script:stripInvocations=0; $script:stripTamperTool=$false
try {
    function Invoke-ReleaseRuntimeStrip([string]$Executable,[string]$InputPath,[string]$OutputPath) {
        if ($Executable -cne $stripToolPath -or !(Test-Path -LiteralPath $InputPath) -or (Test-Path -LiteralPath $OutputPath)) { throw 'fixture_strip_boundary_invalid' }
        $script:stripInvocations++
        [IO.File]::WriteAllText($OutputPath,([IO.File]::ReadAllText($InputPath)+' -> synthetic stripped'),[Text.UTF8Encoding]::new($false))
        if ($script:stripTamperTool) { [IO.File]::WriteAllText($Executable,'changed tool') }
    }
    $transformed=Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk
    if (!$transformed.engineBytesBound -or $transformed.rawSdkBytesMatched -or $transformed.bindingMethod -cne 'verified_ndk_strip' -or
        $script:stripInvocations -ne 2 -or @($transformed.engineBinaries | Where-Object { $_.sdkBytesMatched -or !$_.transformation.outputBytesMatched -or !$_.transformation.recalculated }).Count -ne 0 -or
        ($transformed | ConvertTo-Json -Depth 20) -match [regex]::Escape($runtimeFixture)) { throw 'Actual transform evidence was missing, overstated, or leaked paths.' }
    $checks++
    $originalHash=$stripFiles['lib/arm64-v8a/libflutter.so'].sha256
    $stripFiles['lib/arm64-v8a/libflutter.so'].sha256='d' * 64
    $unbound=Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk
    if ($unbound.engineBytesBound -or $unbound.bindingMethod -cne 'unbound' -or $unbound.engineBinaries[0].transformation.outputBytesMatched) { throw 'Arbitrary package hash mismatch was accepted.' }
    $checks++; $stripFiles['lib/arm64-v8a/libflutter.so'].sha256=$originalHash
    $stripFiles['lib/arm64-v8a/libflutter.so'].size++
    $unbound=Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk
    if ($unbound.engineBytesBound) { throw 'Package size mismatch was accepted.' }
    $checks++; $stripFiles['lib/arm64-v8a/libflutter.so'].size--
    $stripPin.arguments=@('--strip-all','-o','output','input'); Write-AuditJson $stripPinPath $stripPin
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_strip_pin_invalid'
    $stripPin.arguments=@('--strip-unneeded','-o','output','input')
    $stripPin.tool.path='other.exe'; Write-AuditJson $stripPinPath $stripPin
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_strip_pin_invalid'
    $stripPin.tool.path='toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe'; Write-AuditJson $stripPinPath $stripPin
    $callsBefore=$script:stripInvocations
    Write-RuntimeFixture $stripToolPath 'tampered before execution'
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_strip_tool_mismatch'
    if ($script:stripInvocations -ne $callsBefore) { throw 'Unpinned strip executable was invoked.' }; $checks++
    Write-RuntimeFixture $stripToolPath 'synthetic strip, never executed'
    Write-RuntimeFixture $stripPropsPath "Pkg.Revision = 27.0.0`n"
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_strip_tool_mismatch'
    $propsHash=$stripPin.sourceProperties.sha256; $propsSize=$stripPin.sourceProperties.size
    $stripPin.sourceProperties.sha256=Get-AuditSha256 $stripPropsPath; $stripPin.sourceProperties.size=(Get-Item $stripPropsPath).Length; Write-AuditJson $stripPinPath $stripPin
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_strip_ndk_mismatch'
    Write-RuntimeFixture $stripPropsPath "Pkg.Desc = Android NDK`nPkg.Revision = 28.2.13676358`n"
    $stripPin.sourceProperties.sha256=$propsHash; $stripPin.sourceProperties.size=$propsSize; Write-AuditJson $stripPinPath $stripPin
    $sourceHash=$shorebird.Evidence.engineBinaries[0].sha256
    $shorebird.Evidence.engineBinaries[0].sha256='e' * 64
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_evidence_mismatch'
    $shorebird.Evidence.engineBinaries[0].sha256=$sourceHash
    $jarHash=$shorebird.Evidence.sdkArtifacts[0].sha256
    $shorebird.Evidence.sdkArtifacts[0].sha256='f' * 64
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_evidence_mismatch'
    $shorebird.Evidence.sdkArtifacts[0].sha256=$jarHash
    $script:stripTamperTool=$true
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_strip_tool_mismatch'
    $script:stripTamperTool=$false; Write-RuntimeFixture $stripToolPath 'synthetic strip, never executed'
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $windows $files $runtimeFixture -AndroidSdkPath $stripSdk } 'flutter_runtime_strip_target_invalid'
    $rawFiles=New-AuditFileMap
    foreach($engine in $shorebird.Evidence.engineBinaries){$rawFiles.Add($engine.path,$engine)}
    foreach($abi in @('arm64-v8a','x86_64')){$rawFiles.Add("lib/$abi/libapp.so",@{sha256=('c' * 64);size=20})}
    $callsBefore=$script:stripInvocations
    $rawResult=Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $rawFiles $runtimeFixture -AndroidSdkPath 'unused; no NDK needed for raw match'
    if (!$rawResult.rawSdkBytesMatched -or !$rawResult.engineBytesBound -or $rawResult.bindingMethod -cne 'raw_sdk' -or $script:stripInvocations -ne $callsBefore) { throw 'Raw SDK byte match behavior changed.' }; $checks++
    $files['ui/flutter_windows.dll']=$windows.Evidence.engineBinaries[0]
    $windowsUnchanged=Get-ReleasePackagedFlutterEvidence $windows.Evidence $files -RequireByteMatch
    if (($windowsUnchanged.Keys -join ',') -cne 'schema,identity,engineBytesBound,engineBinaries,dartBinaries,completeLinkInventory') { throw 'Existing Windows runtime evidence shape changed.' }; $checks++
} finally { Set-Item Function:Invoke-ReleaseRuntimeStrip $savedStrip }

# Execute the actual collector's failure path with an isolated bootstrap and
# runtime-resolver double. No real SDK/cache entry or dependency work occurs.
$environmentFixture = Join-Path $fixture 'collector-environment'
$copiedCollector = Join-Path $environmentFixture 'scripts/release/collect-notices.ps1'
Write-RuntimeFixture $copiedCollector ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'collect-notices.ps1')))
Write-RuntimeFixture (Join-Path $environmentFixture 'scripts/bootstrap/toolchain.lock.json') '{}'
Write-RuntimeFixture (Join-Path $environmentFixture 'scripts/bootstrap/enter-environment.ps1') @'
$env:PATH='fixture path'
$env:GOPROXY='fixture proxy'
$env:PUB_CACHE='fixture pub'
$env:GOWORK='fixture work'
'@
Write-RuntimeFixture (Join-Path $environmentFixture 'scripts/release/notice-inputs.ps1') "function Get-ReleaseFlutterRuntime { throw 'fixture_runtime_refused' }"
$environmentBefore=@{}
foreach($name in @('PATH','GOPROXY','PUB_CACHE','GOWORK')) { $environmentBefore[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
    $env:GOPROXY='caller proxy'; $env:PUB_CACHE='caller pub'; Remove-Item -LiteralPath Env:\GOWORK -ErrorAction SilentlyContinue
    Assert-RuntimeRefused { & $copiedCollector -Target Windows -NativeBinaries 'unused' } 'fixture_runtime_refused'
    if ($env:PATH -cne $environmentBefore.PATH -or $env:GOPROXY -cne 'caller proxy' -or $env:PUB_CACHE -cne 'caller pub' -or
        $null -ne [Environment]::GetEnvironmentVariable('GOWORK','Process')) { throw 'Collector leaked its process environment after failure.' }
    $checks++
} finally {
    foreach($name in $environmentBefore.Keys) {
        if ($null -eq $environmentBefore[$name]) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name,$environmentBefore[$name],'Process') }
    }
}

# Extract only the real flat-config parser. Never execute the wrapper's key,
# environment, Flutter, Shorebird or publication paths in these fixtures.
$updaterTokens=$null; $updaterErrors=$null
$updaterAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'shorebird-release.ps1'),[ref]$updaterTokens,[ref]$updaterErrors)
if ($updaterErrors.Count) { throw 'Updater wrapper parse failed.' }
$updaterFunctions=@($updaterAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-ExVpnUpdaterConfig'},$false))
if ($updaterFunctions.Count -ne 1) { throw 'Expected exactly one actual updater config parser.' }
. ([scriptblock]::Create($updaterFunctions[0].Extent.Text))
$updaterSource=[IO.File]::ReadAllText((Join-Path $repository 'apps/exvpn/shorebird.yaml'))
$updaterValues=Read-ExVpnUpdaterConfig $updaterSource
if ($updaterValues.Count -ne 3 -or $updaterValues.auto_update -cne 'false' -or $updaterValues.patch_verification -cne 'strict') { throw 'Current updater policy was lost.' }
$checks++
foreach($scalar in @('AQIDBA==','"AQIDBA=="',"'AQIDBA=='")) {
    $compiledValues=Read-ExVpnUpdaterConfig ($updaterSource+"`npatch_public_key: $scalar`n") -Compiled
    if ($compiledValues.patch_public_key -cne 'AQIDBA==' -or $compiledValues.app_id -cne $updaterValues.app_id) { throw 'Packaged padded public-key scalar was altered.' }
}
$checks++
Assert-Rejected { Read-ExVpnUpdaterConfig ($updaterSource+"`n'base_url': https://example.invalid`n") }
Assert-Rejected { Read-ExVpnUpdaterConfig ($updaterSource+"`nunknown: value`n") }
Assert-Rejected { Read-ExVpnUpdaterConfig ($updaterSource+"`nauto_update: false`n") }
Assert-Rejected { Read-ExVpnUpdaterConfig ($updaterSource.Replace('auto_update: false','auto_update: true')) }
Assert-Rejected { Read-ExVpnUpdaterConfig ($updaterSource.Replace('patch_verification: strict','patch_verification: *policy')) }
Assert-Rejected { Read-ExVpnUpdaterConfig ($updaterSource+"`npatch_public_key: AQID%==`n") -Compiled }
Assert-Rejected { Read-ExVpnUpdaterConfig ($updaterSource+"`npatch_public_key: `"AQIDBA=='`n") -Compiled }
Write-Host "Notice input validation: $checks checks passed."
