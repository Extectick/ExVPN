# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
. (Join-Path $PSScriptRoot 'shorebird-updater-notices.ps1')
# This standalone source collector has no network unless explicitly requested.
& (Join-Path $PSScriptRoot 'shorebird-updater-notices-test.ps1')
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
$helper = @{
    GoVersion='go1.27.2'
    Path='github.com/Extectick/ExVPN/native/appupdater'
    Main=@{Path='github.com/Extectick/ExVPN/native/appupdater'}
    Settings=$info.Settings
}
if ((Get-NoticeBinaryName 'Windows' $helper '1.27.2') -cne 'ui/exvpn-updater.exe' -or
    (Get-NoticeBinaryDependencies 'Windows' $helper '1.27.2').Count -ne 0) { throw 'Exact stdlib-only app updater was rejected.' }; $checks++
Assert-Rejected { Get-NoticeBinaryDependencies 'Windows' $info '1.27.2' }
$helper.Main.Path='github.com/Extectick/ExVPN/native/other'
Assert-Rejected { Get-NoticeBinaryDependencies 'Windows' $helper '1.27.2' }
$helper.Main.Path='github.com/Extectick/ExVPN/native/appupdater'
$helper.Path='github.com/Extectick/ExVPN/native/appupdater/cmd/other'
Assert-Rejected { Get-NoticeBinaryDependencies 'Windows' $helper '1.27.2' }
$helper.Path='github.com/Extectick/ExVPN/native/appupdater'
$helper.Deps=@(@{Path='example.invalid/unexpected';Version='v1.0.0';Sum='h1:synthetic'})
Assert-Rejected { Get-NoticeBinaryDependencies 'Windows' $helper '1.27.2' }
$helper.Remove('Deps')
$helper.Main.Replace=@{Path='example.invalid/replacement'}
Assert-Rejected { Get-NoticeBinaryDependencies 'Windows' $helper '1.27.2' }
$helper.Main.Remove('Replace')
Assert-Rejected { Get-NoticeBinaryDependencies 'Android' $helper '1.27.2' }
Assert-Rejected { Get-NoticeBinaryDependencies 'Windows' $helper '1.27.1' }
$info.Settings = @(@{Key='GOOS';Value='android'},@{Key='GOARCH';Value='arm64'},@{Key='-buildmode';Value='c-shared'})
if ((Get-NoticeBinaryName 'Android' $info '1.27.2') -cne 'lib/arm64-v8a/libexvpn.so') { throw 'Wrong Android ABI identity.' }
$checks++
$info.Settings[1].Value = 'amd64'
if ((Get-NoticeBinaryName 'Android' $info '1.27.2') -cne 'lib/x86_64/libexvpn.so') { throw 'Wrong x86_64 ABI identity.' }
$checks++

$inventory = [pscustomobject]@{schema=1;app=@{version='1.2.3+42'};dartLockSha256=$hash;nativeBinaries=@(@{name='service/exvpn-service.exe';sha256=$hash});components=@(@{name='ExVPN';version='1.2.3+42'},@{name='ExVPN copyright';version='1.2.3+42'})}
Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash}
$checks++
$helperHash='b' * 64
$inventory.nativeBinaries += @{name='ui/exvpn-updater.exe';sha256=$helperHash}
Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash;'ui/exvpn-updater.exe'=$helperHash}; $checks++
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash} }
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash;'ui/exvpn-updater.exe'=$hash} }
$inventory.nativeBinaries=@($inventory.nativeBinaries[0])
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
    $engineLicense = "synthetic $Kind engine component`n`nFull $Kind third-party license text.`n"
    Write-RuntimeFixture (Join-Path $Root 'engine/src/flutter/sky/packages/sky_engine/LICENSE') $engineLicense
    if ($Kind -ceq 'shorebird') {
        $updaterDeps = @'
vars = {
  "updater_git": "https://github.com/shorebirdtech/updater.git",
  "updater_rev": "70ff1e336798474e39586d3f5ac2ca386ef32d9e",
}
deps = {
  'engine/src/flutter/third_party/updater':
    Var('updater_git') + '@' + Var('updater_rev'),
}
'@
        Write-RuntimeFixture (Join-Path $Root 'DEPS') $updaterDeps.Replace("`r`n","`n")
    }
    $revision = Commit-RuntimeFixture $Root
    Write-RuntimeFixture (Join-Path $Root 'bin/cache/engine.stamp') "$Engine`n"
    Write-RuntimeFixture (Join-Path $Root 'bin/cache/pkg/sky_engine/LICENSE') $engineLicense
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

# Resolve actual process configuration, never a fixture-specific runner path.
# Every failure must preserve the environment and must not try another SDK.
$sdkHome = Join-Path $fixture 'SDK resolution/home with spaces'
$sdkLegacy = Join-Path $fixture 'SDK resolution/legacy'
$sdkLocalAppData = Join-Path $fixture 'SDK resolution/local'
$sdkDefault = Join-Path $sdkLocalAppData 'Android/Sdk'
$sdkMissing = Join-Path $fixture 'SDK resolution/missing'
New-Item -ItemType Directory -Path $sdkHome,$sdkLegacy,$sdkDefault -Force | Out-Null
$sdkNotDirectory = Join-Path $fixture 'SDK resolution/file'
[IO.File]::WriteAllText($sdkNotDirectory, 'not an SDK directory')
$sdkAlias = Join-Path $fixture 'SDK resolution/home alias'
$sdkEquivalentAlias = Join-Path $fixture 'SDK resolution/equivalent alias'
$sdkDifferentAlias = Join-Path $fixture 'SDK resolution/different alias'
$sdkAliasChain = Join-Path $fixture 'SDK resolution/alias chain'
$sdkLinkedAncestor = Join-Path $fixture 'linked SDK parent'
New-Item -ItemType Junction -Path $sdkAlias -Target $sdkHome | Out-Null
New-Item -ItemType Junction -Path $sdkEquivalentAlias -Target $sdkHome | Out-Null
New-Item -ItemType Junction -Path $sdkDifferentAlias -Target $sdkLegacy | Out-Null
New-Item -ItemType Junction -Path $sdkAliasChain -Target $sdkAlias | Out-Null
New-Item -ItemType Junction -Path $sdkLinkedAncestor -Target (Split-Path $sdkHome) | Out-Null
$sdkEnvironmentBefore = @{}
foreach ($name in @('ANDROID_HOME','ANDROID_SDK_ROOT','LOCALAPPDATA')) { $sdkEnvironmentBefore[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:ANDROID_HOME=$sdkHome; $env:ANDROID_SDK_ROOT=$sdkLegacy; $env:LOCALAPPDATA=$sdkLocalAppData
    if ((Get-ReleaseAndroidSdkPath $sdkDefault) -cne $sdkDefault) { throw 'Explicit SDK did not override conflicting environment roots.' }; $checks++
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath } 'android_sdk_environment_conflict'
    if ($env:ANDROID_HOME -cne $sdkHome -or $env:ANDROID_SDK_ROOT -cne $sdkLegacy -or $env:LOCALAPPDATA -cne $sdkLocalAppData) { throw 'SDK resolver mutated process configuration.' }; $checks++
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath $sdkMissing } 'android_sdk_directory_missing'
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath $sdkNotDirectory } 'android_sdk_directory_missing'
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath 'relative-sdk' } 'android_sdk_path_invalid'
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath ($sdkHome + [char]0) } 'android_sdk_path_invalid'
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath ' ' } 'android_sdk_path_invalid'
    $env:ANDROID_SDK_ROOT=Join-Path $sdkHome './'
    if ((Get-ReleaseAndroidSdkPath) -cne $sdkHome) { throw 'Equivalent environment SDK paths conflicted.' }; $checks++
    if ((Get-ReleaseAndroidSdkPath $sdkAlias) -cne $sdkHome) { throw 'Root SDK alias did not return the physical directory.' }; $checks++
    $env:ANDROID_HOME=$sdkAlias; $env:ANDROID_SDK_ROOT=$sdkEquivalentAlias
    if ((Get-ReleaseAndroidSdkPath) -cne $sdkHome) { throw 'Equivalent SDK aliases conflicted.' }; $checks++
    $env:ANDROID_SDK_ROOT=$sdkHome
    if ((Get-ReleaseAndroidSdkPath) -cne $sdkHome) { throw 'Alias and physical SDK paths conflicted.' }; $checks++
    $env:ANDROID_SDK_ROOT=$sdkDifferentAlias
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath } 'android_sdk_environment_conflict'
    if ((Get-ReleaseAndroidSdkPath $sdkAlias) -cne $sdkHome) { throw 'Explicit SDK alias did not override conflicting environment.' }; $checks++
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath $sdkAliasChain } 'linked_input_not_allowed'
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath (Join-Path $sdkLinkedAncestor 'home with spaces') } 'linked_input_not_allowed'
    # The general audit policy remains strict even for the accepted SDK alias.
    Assert-RuntimeRefused { Assert-AuditNoLinks $sdkAlias } 'linked_input_not_allowed'
    if ($env:ANDROID_HOME -cne $sdkAlias -or $env:ANDROID_SDK_ROOT -cne $sdkDifferentAlias) { throw 'SDK alias resolution changed the process environment.' }; $checks++
    $env:ANDROID_HOME=$sdkHome
    [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $null, 'Process')
    if ((Get-ReleaseAndroidSdkPath) -cne $sdkHome) { throw 'ANDROID_HOME did not override the local default.' }; $checks++
    $env:ANDROID_HOME=$sdkMissing
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath } 'android_sdk_directory_missing'
    $env:ANDROID_HOME=' '
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath } 'android_sdk_path_invalid'
    [Environment]::SetEnvironmentVariable('ANDROID_HOME', $null, 'Process')
    $env:ANDROID_SDK_ROOT=$sdkLegacy
    if ((Get-ReleaseAndroidSdkPath) -cne $sdkLegacy) { throw 'Legacy-only SDK configuration was lost.' }; $checks++
    $env:ANDROID_SDK_ROOT=$sdkMissing
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath } 'android_sdk_directory_missing'
    [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $null, 'Process')
    if ((Get-ReleaseAndroidSdkPath) -cne $sdkDefault) { throw 'Existing local SDK default changed.' }; $checks++
    $env:LOCALAPPDATA=$sdkMissing
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath } 'android_sdk_directory_missing'
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $null, 'Process')
    Assert-RuntimeRefused { Get-ReleaseAndroidSdkPath } 'android_sdk_path_unavailable'
} finally {
    foreach ($name in $sdkEnvironmentBefore.Keys) {
        if ($null -eq $sdkEnvironmentBefore[$name]) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $sdkEnvironmentBefore[$name], 'Process') }
    }
}
foreach ($name in $sdkEnvironmentBefore.Keys) {
    if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $sdkEnvironmentBefore[$name]) { throw 'SDK fixture did not restore its environment.' }
}
$checks++

$runtimeFixture = Join-Path $fixture 'runtimes'
$ordinarySdk = Join-Path $runtimeFixture '.tools/flutter'
$ordinaryRevision = New-RuntimeSdk $ordinarySdk ('a' * 40) 'ordinary'
$ordinaryPin = [ordered]@{schemaVersion=1;flutter=@{version='3.47.7';dartVersion='3.13.5';revision=$ordinaryRevision;folder='flutter'}}
Write-RuntimeFixture (Join-Path $runtimeFixture 'scripts/bootstrap/toolchain.lock.json') ($ordinaryPin | ConvertTo-Json -Depth 6)
$ordinary = Get-ReleaseFlutterRuntime $runtimeFixture Android
if ($ordinary.Identity.kind -cne 'ordinary' -or $ordinary.Identity.buildMode -cne 'debug' -or $ordinary.Evidence.engineBinaries.Count -ne 2) { throw 'Default ordinary runtime changed.' }
$checks++
$ordinaryEngineLicensePath=Join-Path $ordinarySdk 'bin/cache/pkg/sky_engine/LICENSE'
$ordinaryEngineLicenseBytes=[IO.File]::ReadAllText($ordinaryEngineLicensePath)
Write-RuntimeFixture $ordinaryEngineLicensePath 'tampered engine license'
Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android } 'flutter_runtime_engine_license_mismatch'
Write-RuntimeFixture $ordinaryEngineLicensePath $ordinaryEngineLicenseBytes
$missingEngineLicensePath=Join-Path $ordinarySdk 'bin/cache/pkg/sky_engine/LICENSE.fixture-missing'
[IO.File]::Move($ordinaryEngineLicensePath,$missingEngineLicensePath)
try { Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android } 'flutter_runtime_engine_license_missing' }
finally { [IO.File]::Move($missingEngineLicensePath,$ordinaryEngineLicensePath) }
$fullEngineNotice=@($ordinary.Evidence.notices | Where-Object name -CEQ 'Flutter engine third-party licenses')
if ($fullEngineNotice.Count -ne 1 -or $fullEngineNotice[0].version -cne $ordinary.Identity.engineRevision -or
    $fullEngineNotice[0].path -cne 'bin/cache/pkg/sky_engine/LICENSE' -or
    $fullEngineNotice[0].sha256 -cne (Get-AuditSha256 $ordinaryEngineLicensePath)) { throw 'Full engine license is absent from runtime evidence.' }; $checks++
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
# Copy only this exact new fixture directory to its derived pinned path.
$shorebirdSdk = Join-Path $cliRoot "bin/cache/flutter/$shorebirdRevision"
if (![IO.Path]::GetFullPath($sdkStaging).StartsWith([IO.Path]::GetFullPath($runtimeFixture)+[IO.Path]::DirectorySeparatorChar) -or
    ![IO.Path]::GetFullPath($shorebirdSdk).StartsWith([IO.Path]::GetFullPath($runtimeFixture)+[IO.Path]::DirectorySeparatorChar)) { throw 'Fixture copy outside owned root.' }
# Retain both owned fixtures. Directory renaming can be refused on Windows;
# copying their small synthetic inputs also preserves hidden Git metadata.
$sdkFixtureFiles=@([IO.Directory]::EnumerateFiles($sdkStaging,'*',[IO.SearchOption]::AllDirectories))
if ($sdkFixtureFiles.Count -gt 256 -or (Test-Path -LiteralPath $shorebirdSdk)) { throw 'Unexpected SDK fixture copy inputs.' }
foreach ($file in $sdkFixtureFiles) {
    Assert-AuditNoLinks $file
    if ((Get-Item -LiteralPath $file -Force).Length -gt 1MB) { throw 'Unexpected SDK fixture file size.' }
    $destination=Join-Path $shorebirdSdk ([IO.Path]::GetRelativePath($sdkStaging,$file))
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::Copy($file,$destination,$false)
}
$shorebirdPin = [ordered]@{schemaVersion=1;cli=@{version='1.6.129';revision=$cliRevision;folder='shorebird-1.6.129';repository='https://github.com/shorebirdtech/shorebird.git';powershellEntrypointSha256=(Get-AuditSha256 (Join-Path $cliRoot 'bin/shorebird.ps1'));pubspecLockSha256=(Get-AuditSha256 (Join-Path $cliRoot 'pubspec.lock'))};flutter=@{repository='https://github.com/shorebirdtech/flutter.git';version='3.47.7';revision=$shorebirdRevision;engineRevision=('b' * 40);dartVersion='3.13.5'}}
Write-AuditJson (Join-Path $runtimeFixture 'scripts/bootstrap/shorebird.lock.json') $shorebirdPin
$shorebird = Get-ReleaseFlutterRuntime $runtimeFixture Android -FlutterRuntime shorebird
if ($shorebird.Identity.buildMode -cne 'release' -or $shorebird.Identity.engineRevision -ceq $ordinary.Identity.engineRevision -or
    ($shorebird.Evidence | ConvertTo-Json -Depth 12) -match [regex]::Escape($runtimeFixture)) { throw 'Shorebird identity or path-free evidence failed.' }
$checks++
$shorebirdEngineLicensePath=Join-Path $shorebirdSdk 'bin/cache/pkg/sky_engine/LICENSE'
$shorebirdEngineLicenseBytes=[IO.File]::ReadAllText($shorebirdEngineLicensePath)
# Both SDKs are valid on their own. Copying the other runtime's full text into
# this ignored cache must still fail against the selected commit's blob.
Write-RuntimeFixture $shorebirdEngineLicensePath $ordinaryEngineLicenseBytes
try {
    Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Android -FlutterRuntime shorebird } 'flutter_runtime_engine_license_mismatch'
    Assert-RuntimeRefused { Get-ReleaseFlutterRuntime $runtimeFixture Windows -FlutterRuntime shorebird } 'flutter_runtime_engine_license_mismatch'
} finally { Write-RuntimeFixture $shorebirdEngineLicensePath $shorebirdEngineLicenseBytes }
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

# Native updater source inputs are a separate, offline component. Use the
# checked-in upstream license/lock bytes and an actual committed SDK fixture.
$updaterPinPath = Join-Path $runtimeFixture 'scripts/release/shorebird-updater-notices.lock.json'
New-Item -ItemType Directory -Path (Split-Path $updaterPinPath) -Force | Out-Null
$updaterPin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'shorebird-updater-notices.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$updaterPin.flutter.revision=$shorebirdRevision; $updaterPin.flutter.engineRevision='b' * 40
$updaterPin.flutter.depsSha256=Get-AuditSha256 (Join-Path $shorebirdSdk 'DEPS')
$updaterPin.flutter.depsSize=(Get-Item -LiteralPath (Join-Path $shorebirdSdk 'DEPS')).Length
$updaterPin.flutter.depsGitBlob=Invoke-ReleaseRuntimeGit $shorebirdSdk @('rev-parse','--verify',"${shorebirdRevision}:DEPS")
function Save-UpdaterPin { Write-AuditJson $updaterPinPath $updaterPin }
Save-UpdaterPin
$updaterRelative="scripts/release/licenses/shorebird-updater-$($updaterPin.updater.revision)"
$updaterRoot=Join-Path $runtimeFixture $updaterRelative
New-Item -ItemType Directory -Path $updaterRoot -Force | Out-Null
foreach($name in @('Cargo.lock','LICENSE-APACHE','LICENSE-MIT','.gitattributes')) {
    [IO.File]::Copy((Join-Path $repository "$updaterRelative/$name"),(Join-Path $updaterRoot $name),$false)
}
$updaterExpected=Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird
if ($updaterExpected.Version -cne '70ff1e336798474e39586d3f5ac2ca386ef32d9e' -or
    $updaterExpected.Evidence.cargoLock.sha256 -cne '5c189f184ccf4cd52ed8bda705fddfc187ae393a3906dea3aa722823a01f62b1' -or
    $updaterExpected.Evidence.notices.Count -ne 2 -or $updaterExpected.Evidence.binaryDependencyClosureVerified -or
    $updaterExpected.Evidence.completeLicenseCoverage -or ($updaterExpected.Evidence | ConvertTo-Json -Depth 10) -match [regex]::Escape($runtimeFixture)) { throw 'Updater provenance or incomplete boundary changed.' }; $checks++
$depsFixturePath=Join-Path $shorebirdSdk 'DEPS'; $depsFixtureBytes=[IO.File]::ReadAllBytes($depsFixturePath)
Invoke-ReleaseRuntimeGit $shorebirdSdk @('config','core.autocrlf','true') | Out-Null
try {
    [IO.File]::WriteAllText($depsFixturePath,[Text.Encoding]::UTF8.GetString($depsFixtureBytes).Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false))
    # Refresh the fixture index after changing checkout EOLs. The committed
    # blob/HEAD stay fixed and are checked independently by the real helper.
    Invoke-ReleaseRuntimeGit $shorebirdSdk @('add','--','DEPS') | Out-Null
    $crlfUpdater=Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird
    if ($crlfUpdater.Evidence.deps.sha256 -cne $updaterExpected.Evidence.deps.sha256 -or
        $crlfUpdater.Evidence.deps.gitBlob -cne $updaterExpected.Evidence.deps.gitBlob -or
        $crlfUpdater.Evidence.deps.checkoutSha256 -ceq $updaterExpected.Evidence.deps.checkoutSha256) { throw 'CRLF checkout did not preserve exact source binding.' }; $checks++
} finally {
    [IO.File]::WriteAllBytes($depsFixturePath,$depsFixtureBytes)
    Invoke-ReleaseRuntimeGit $shorebirdSdk @('add','--','DEPS') | Out-Null
}
if ($null -ne (Get-ShorebirdUpdaterNotices (Join-Path $fixture 'missing-updater-inputs') $ordinary)) { throw 'Ordinary runtime acquired an updater dependency.' }; $checks++
$badRuntime=@{Identity=@{kind='other'}}
Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $badRuntime } 'shorebird_updater_runtime_invalid'
$shorebird.Identity.buildMode='debug'
try { Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_runtime_invalid' }
finally { $shorebird.Identity.buildMode='release' }
$shorebird.Identity.engineRevision='c' * 40
try { Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_runtime_mismatch' }
finally { $shorebird.Identity.engineRevision='b' * 40 }
$savedSdkRoot=$shorebird.SdkRoot; $shorebird.SdkRoot=$ordinarySdk
try { Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'flutter_runtime_checkout_mismatch' }
finally { $shorebird.SdkRoot=$savedSdkRoot }
$updaterPin.updater.revision='d' * 40; Save-UpdaterPin
Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_deps_selection_mismatch'
$updaterPin.updater.revision=$updaterExpected.Version
$savedDepsHash=$updaterPin.flutter.depsSha256; $updaterPin.flutter.depsSha256='0' * 64; Save-UpdaterPin
Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_deps_mismatch'
$updaterPin.flutter.depsSha256=$savedDepsHash
$updaterPin.updater.notices[0].path='../LICENSE-APACHE'; Save-UpdaterPin
Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_pin_invalid'
$updaterPin.updater.notices[0].path='LICENSE-APACHE'
$savedBlob=$updaterPin.updater.cargoLock.gitBlob; $updaterPin.updater.cargoLock.gitBlob='0' * 40; Save-UpdaterPin
Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_input_mismatch'
$updaterPin.updater.cargoLock.gitBlob=$savedBlob; Save-UpdaterPin
foreach($name in @('Cargo.lock','LICENSE-APACHE','LICENSE-MIT')) {
    $path=Join-Path $updaterRoot $name; $savedBytes=[IO.File]::ReadAllBytes($path)
    try {
        [IO.File]::WriteAllText($path,'tampered input')
        Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_input_mismatch'
    } finally { [IO.File]::WriteAllBytes($path,$savedBytes) }
    $missingPath=Join-Path $fixture "missing-updater-$name"
    [IO.File]::Move($path,$missingPath)
    try { Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_input_missing' }
    finally { [IO.File]::Move($missingPath,$path) }
}
$unexpectedLicense=Join-Path $updaterRoot 'LICENSE-EXTRA'
[IO.File]::WriteAllText($unexpectedLicense,'unreviewed')
try { Assert-RuntimeRefused { Get-ShorebirdUpdaterNotices $runtimeFixture $shorebird } 'shorebird_updater_input_unexpected' }
finally { [IO.File]::Delete($unexpectedLicense) }

# Execute the full collector through its real SDK/source preflight. The missing
# updater input must be refused before output creation or native/dependency work.
foreach($name in @('collect-notices.ps1','notice-inputs.ps1','flutter-runtime-inputs.ps1','artifact-audit-lib.ps1','shorebird-updater-notices.ps1')) {
    [IO.File]::Copy((Join-Path $PSScriptRoot $name),(Join-Path $runtimeFixture "scripts/release/$name"),$false)
}
Write-RuntimeFixture (Join-Path $runtimeFixture 'scripts/bootstrap/enter-environment.ps1') '# Isolated fixture: no environment changes, commands or dependencies.'
$missingLock=Join-Path $fixture 'updater-preflight-missing-lock'
[IO.File]::Move((Join-Path $updaterRoot 'Cargo.lock'),$missingLock)
$refusedOutput=Join-Path $fixture 'refused-updater-output'
try {
    Assert-RuntimeRefused { & (Join-Path $runtimeFixture 'scripts/release/collect-notices.ps1') -Target Windows -FlutterRuntime shorebird -NativeBinaries unused -OutputDirectory $refusedOutput } 'shorebird_updater_input_missing'
    if (Test-Path -LiteralPath $refusedOutput) { throw 'Collector created an incomplete updater notice bundle.' }; $checks++
} finally { [IO.File]::Move($missingLock,(Join-Path $updaterRoot 'Cargo.lock')) }

# Run the actual collector's notice-copy functions and runtime loop, without
# bootstrap, native binaries or dependency resolution. This proves that the
# distributed file contains the full text, not only the engine markdown link.
$collectorTokens=$null; $collectorErrors=$null
$collectorAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'collect-notices.ps1'),[ref]$collectorTokens,[ref]$collectorErrors)
if ($collectorErrors.Count) { throw 'Notice collector parse failed.' }
foreach ($name in @('Hash-Text','Add-SingleNotice','Add-Notice')) {
    $definitions=@($collectorAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false))
    if ($definitions.Count -ne 1) { throw 'Expected one actual notice-copy function.' }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$copyLoops=@($collectorAst.FindAll({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and
    $node.Variable.VariablePath.UserPath -ceq 'notice' -and $node.Condition.Extent.Text -ceq '$runtime.Evidence.notices'},$false))
if ($copyLoops.Count -ne 1) { throw 'Expected one actual runtime-notice copy loop.' }
$updaterCopy=@($collectorAst.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -ceq '$updaterNotices' -and $node.Extent.Text.Contains("'engine-source-updater'")},$false))
if ($updaterCopy.Count -ne 1) { throw 'Expected one actual updater-notice copy branch.' }
foreach ($runtime in @($ordinary,$shorebird,$windows)) {
    $FlutterRuntime=$runtime.Identity.kind
    $output=Join-Path $fixture ("copied-engine-notices-$FlutterRuntime-$($runtime.Identity.target)")
    $components=[Collections.Generic.List[object]]::new()
    & ([scriptblock]::Create($copyLoops[0].Extent.Text))
    $updaterNotices=Get-ShorebirdUpdaterNotices $runtimeFixture $runtime
    & ([scriptblock]::Create($updaterCopy[0].Extent.Text))
    $copiedInventory=[ordered]@{runtime=$runtime.Evidence;components=$components.ToArray()}
    if ($updaterNotices) { $copiedInventory.shorebirdUpdater=$updaterNotices.Evidence }
    Assert-ShorebirdUpdaterNotices $copiedInventory $updaterNotices $output
    $checks++
    if ($updaterNotices) {
        $native=@($components | Where-Object name -CEQ 'Shorebird native updater')
        foreach($expectedNotice in $updaterNotices.Evidence.notices) {
            $copied=@($native[0].notices | Where-Object { [IO.Path]::GetFileName($_.path) -ceq $expectedNotice.path })
            if ($copied.Count -ne 1 -or (Get-AuditSha256 (Join-Path $output $copied[0].path)) -cne $expectedNotice.sha256) { throw 'Full upstream updater license was not distributed.' }; $checks++
        }
        $copiedInventory.components=@($components | Where-Object name -CNE 'Shorebird native updater')
        Assert-RuntimeRefused { Assert-ShorebirdUpdaterNotices $copiedInventory $updaterNotices $output } 'shorebird_updater_notice_mismatch'
        $copiedInventory.components=$components.ToArray()
        $copiedFile=Join-Path $output $native[0].notices[0].path
        $originalBytes=[IO.File]::ReadAllBytes($copiedFile)
        try {
            [IO.File]::WriteAllText($copiedFile,'post-copy mutation')
            Assert-RuntimeRefused { Assert-ShorebirdUpdaterNotices $copiedInventory $updaterNotices $output } 'shorebird_updater_notice_mismatch'
        } finally { [IO.File]::WriteAllBytes($copiedFile,$originalBytes) }
        Assert-RuntimeRefused { Assert-ShorebirdUpdaterNotices $copiedInventory $null $output } 'shorebird_updater_notice_unexpected'
    }
    Assert-ReleaseFlutterNotices $copiedInventory $runtime.Evidence
    $full=@($components | Where-Object name -CEQ 'Flutter engine third-party licenses')
    $repositoryUrl=if($FlutterRuntime -ceq 'ordinary'){'https://github.com/flutter/flutter'}else{'https://github.com/shorebirdtech/flutter'}
    if ($full.Count -ne 1 -or $full[0].notices.Count -ne 1 -or
        [IO.File]::ReadAllText((Join-Path $output $full[0].notices[0].path)) -cne [IO.File]::ReadAllText((Join-Path $runtime.SdkRoot 'bin/cache/pkg/sky_engine/LICENSE')) -or
        $full[0].source -cne "$repositoryUrl/blob/$($runtime.Identity.flutterRevision)/engine/src/flutter/sky/packages/sky_engine/LICENSE") { throw 'Collector did not distribute the full pinned engine notice.' }; $checks++
    $copiedInventory.components=@($components | Where-Object name -CNE 'Flutter engine third-party licenses')
    Assert-RuntimeRefused { Assert-ReleaseFlutterNotices $copiedInventory $runtime.Evidence } 'flutter_runtime_notice_mismatch'
    $copiedInventory.components=$components.ToArray()
    $full[0].notices[0].sha256='0' * 64
    Assert-RuntimeRefused { Assert-ReleaseFlutterNotices $copiedInventory $runtime.Evidence } 'flutter_runtime_notice_mismatch'
}
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
$stripSdkAlias=Join-Path $runtimeFixture 'android-sdk-alias'
$stripNdk=Join-Path $stripSdk 'ndk/28.2.13676358'
$stripToolPath=Join-Path $stripNdk 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe'
$stripPropsPath=Join-Path $stripNdk 'source.properties'
Write-RuntimeFixture $stripToolPath 'synthetic strip, never executed'
Write-RuntimeFixture $stripPropsPath "Pkg.Desc = Android NDK`nPkg.Revision = 28.2.13676358`n"
New-Item -ItemType Junction -Path $stripSdkAlias -Target $stripSdk | Out-Null
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
    $viaSdkAlias=Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdkAlias
    Assert-ReleaseFlutterRuntimeEvidence $viaSdkAlias $transformed
    $resolvedAliasTool=Get-ReleaseAndroidStripTool $runtimeFixture $stripSdkAlias
    if ($resolvedAliasTool.SdkRoot -cne $stripSdk -or $resolvedAliasTool.Executable -cne $stripToolPath) { throw 'SDK alias leaked into the pinned executable path.' }; $checks++
    $nestedLinkSdk=Join-Path $runtimeFixture 'nested-link-sdk'
    New-Item -ItemType Directory -Path $nestedLinkSdk | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $nestedLinkSdk 'ndk') -Target (Join-Path $stripSdk 'ndk') | Out-Null
    $callsBefore=$script:stripInvocations
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $nestedLinkSdk } 'linked_input_not_allowed'
    if ($script:stripInvocations -ne $callsBefore) { throw 'Linked NDK input reached execution.' }; $checks++
    # Regression for the actual CI caller: its SDK is supplied by ANDROID_HOME,
    # while LOCALAPPDATA has no SDK. No explicit path or native binary is used.
    $sdkEnvironmentBefore=@{}
    foreach ($name in @('ANDROID_HOME','ANDROID_SDK_ROOT','LOCALAPPDATA')) { $sdkEnvironmentBefore[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        $env:ANDROID_HOME=$stripSdk; $env:LOCALAPPDATA=$sdkMissing
        [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT',$null,'Process')
        $fromEnvironment=Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture
        if (!$fromEnvironment.engineBytesBound -or $fromEnvironment.bindingMethod -cne 'verified_ndk_strip' -or
            ($fromEnvironment | ConvertTo-Json -Depth 20 -Compress) -cne ($transformed | ConvertTo-Json -Depth 20 -Compress)) { throw 'CI environment SDK did not produce the same pinned evidence.' }; $checks++
        $env:ANDROID_HOME=$sdkLegacy # Existing directory without the pinned NDK.
        $callsBefore=$script:stripInvocations
        Assert-Rejected { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture }
        if ($script:stripInvocations -ne $callsBefore -or $env:ANDROID_HOME -cne $sdkLegacy) { throw 'Missing pinned NDK fell back or mutated the environment.' }; $checks++
    } finally {
        foreach ($name in $sdkEnvironmentBefore.Keys) {
            if ($null -eq $sdkEnvironmentBefore[$name]) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name,$sdkEnvironmentBefore[$name],'Process') }
        }
    }
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
    Assert-RuntimeRefused { Get-ReleaseAndroidPackagedFlutterEvidence $shorebird $stripFiles $runtimeFixture -AndroidSdkPath $stripSdkAlias } 'flutter_runtime_strip_tool_mismatch'
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
$env:ANDROID_HOME='fixture SDK'
$env:ANDROID_SDK_ROOT='fixture legacy SDK'
'@
Write-RuntimeFixture (Join-Path $environmentFixture 'scripts/release/notice-inputs.ps1') "function Get-ReleaseFlutterRuntime { throw 'fixture_runtime_refused' }"
$environmentBefore=@{}
foreach($name in @('PATH','GOPROXY','PUB_CACHE','GOWORK','ANDROID_HOME','ANDROID_SDK_ROOT')) { $environmentBefore[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
    $env:GOPROXY='caller proxy'; $env:PUB_CACHE='caller pub'; Remove-Item -LiteralPath Env:\GOWORK -ErrorAction SilentlyContinue
    $env:ANDROID_HOME='caller SDK'; Remove-Item -LiteralPath Env:\ANDROID_SDK_ROOT -ErrorAction SilentlyContinue
    Assert-RuntimeRefused { & $copiedCollector -Target Windows -NativeBinaries 'unused' } 'fixture_runtime_refused'
    if ($env:PATH -cne $environmentBefore.PATH -or $env:GOPROXY -cne 'caller proxy' -or $env:PUB_CACHE -cne 'caller pub' -or
        $null -ne [Environment]::GetEnvironmentVariable('GOWORK','Process') -or $env:ANDROID_HOME -cne 'caller SDK' -or
        $null -ne [Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT','Process')) { throw 'Collector leaked its process environment after failure.' }
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
# Exercise the real wrapper cleanup without running a build, reading keys, or
# contacting Shorebird. Preserve unset SDK variables as unset, not empty strings.
$wrapperFinally=@($updaterAst.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and
    $null -ne $node.Finally -and $node.Finally.Extent.Text.Contains('$savedEnvironment.Keys')},$false))
if ($wrapperFinally.Count -ne 1) { throw 'Expected exactly one actual wrapper environment cleanup.' }
$sdkEnvironmentBefore=@{}
foreach ($name in @('ANDROID_HOME','ANDROID_SDK_ROOT')) { $sdkEnvironmentBefore[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
    $savedEnvironment=@{ANDROID_HOME='preserved caller SDK';ANDROID_SDK_ROOT=$null}; $passwordBytes=$null
    $env:ANDROID_HOME='temporary SDK'; $env:ANDROID_SDK_ROOT='temporary SDK'
    $beforeLocation=Get-Location
    Push-Location $fixture
    & ([scriptblock]::Create(($wrapperFinally[0].Finally.Statements.Extent.Text -join "`n")))
    if ($env:ANDROID_HOME -cne 'preserved caller SDK' -or $null -ne [Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT','Process') -or
        (Get-Location).Path -cne $beforeLocation.Path) { throw 'Wrapper did not restore its SDK environment/location.' }
    $checks++
} finally {
    foreach ($name in $sdkEnvironmentBefore.Keys) {
        if ($null -eq $sdkEnvironmentBefore[$name]) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name,$sdkEnvironmentBefore[$name],'Process') }
    }
}
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
