#requires -Version 7.0
<#
.SYNOPSIS
Builds a pinned Shorebird beta base release with signed-patch verification.
.DESCRIPTION
Uses Shorebird's online dry-run: it builds but does not publish. Cloud publication
requires a separate reviewed step after validation of the packaged bytes.
Native JNI/service builds are separate and are not rebuilt by this wrapper.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Android', 'Windows')][string]$Target
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
function Read-ExVpnUpdaterConfig([string]$Text, [switch]$Compiled) {
    # Deliberately accept only this project's flat config, not arbitrary YAML.
    # Quoted/indented keys, aliases, extra endpoints and multiline values fail.
    $allowed = @('app_id', 'auto_update', 'patch_verification')
    if ($Compiled) { $allowed += 'patch_public_key' }
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
Assert-ExVpnShorebirdCache (Join-Path $repository ".tools/$($pin.cli.folder)") $pin.cli.revision $pin.flutter.revision
$app = Join-Path $repository 'apps/exvpn'
$version = Get-NoticeAppVersion ([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml'))) ([IO.File]::ReadAllText((Join-Path $app 'lib/build_identity.dart')))
$publicKeyPath = Join-Path $repository 'config/signing/shorebird-beta-public.pem'
$publicKey = [Security.Cryptography.RSA]::Create()
try {
    $publicKey.ImportFromPem([IO.File]::ReadAllText($publicKeyPath))
    if ($publicKey.KeySize -lt 3072) { throw 'The beta patch verification key is too small.' }
    $compiledPublicKey = [Convert]::ToBase64String($publicKey.ExportRSAPublicKey())
} finally { $publicKey.Dispose() }
$sourceConfig = [IO.File]::ReadAllText((Join-Path $app 'shorebird.yaml'))
$appId = (Read-ExVpnUpdaterConfig $sourceConfig).app_id
if ($appId -cne 'ea97a683-02e5-4d86-9aa1-779d6b4bc81e') {
    throw 'The beta updater configuration does not match the reviewed project policy.'
}
$runId = [Guid]::NewGuid().ToString('N')
$privateRun = Join-Path $repository ".private/shorebird-builds/$runId"
$output = Join-Path $repository "artifacts/shorebird/$version-$($Target.ToLowerInvariant())-$runId"
New-Item -ItemType Directory -Path $privateRun, $output | Out-Null
$lockHash = (Get-FileHash (Join-Path $app 'pubspec.lock') -Algorithm SHA256).Hash
$configHash = (Get-FileHash (Join-Path $app 'shorebird.yaml') -Algorithm SHA256).Hash
$environmentNames = @('PATH','PUB_CACHE','GRADLE_USER_HOME','CI','FLUTTER_SUPPRESS_ANALYTICS',
    'DART_SUPPRESS_ANALYTICS','FLUTTER_STORAGE_BASE_URL','ANDROID_HOME','ANDROID_SDK_ROOT',
    'GOTOOLCHAIN','GOPATH','GOCACHE','GOPROXY','GOSUMDB','GONOSUMDB','GOWORK',
    'JAVA_HOME','EXVPN_ANDROID_PACKAGE_INPUTS','EXVPN_FLUTTER_RUNTIME','EXVPN_FLUTTER_BUILD_MODE',
    'EXVPN_ANDROID_KEYSTORE','EXVPN_ANDROID_KEY_ALIAS','EXVPN_ANDROID_STORE_PASSWORD','EXVPN_ANDROID_KEY_PASSWORD')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$passwordBytes = $null
$packageInputs = $null

function Assert-CompiledUpdater([string]$Text) {
    $compiled = Read-ExVpnUpdaterConfig $Text -Compiled
    if ($compiled.app_id -cne $appId -or $compiled.patch_public_key -cne $compiledPublicKey) {
        throw 'Packaged Shorebird key or updater policy differs from the expected beta base.'
    }
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
    $env:PUB_CACHE = Join-Path $repository '.tools/cache/pub'
    $env:GRADLE_USER_HOME = Join-Path $repository '.tools/cache/gradle'
    $env:CI = 'true'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DART_SUPPRESS_ANALYTICS = 'true'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://download.shorebird.dev'
    $env:JAVA_HOME = 'C:\PROGRA~1\Android\ANDROI~1\jbr'
    $env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'Android/Sdk'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:PATH = (Join-Path $runtime.SdkRoot 'bin') + [IO.Path]::PathSeparator + $savedEnvironment.PATH
    & $flutter pub get --offline --enforce-lockfile *> (Join-Path $privateRun 'pub-private.log')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned Flutter dependency resolution failed; inspect private build log.' }
    if ($Target -eq 'Android') {
        $signingRoot = Join-Path $repository '.private/signing/android'
        $passwordBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            [IO.File]::ReadAllBytes((Join-Path $signingRoot 'store-password.dpapi')), $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $env:EXVPN_ANDROID_KEYSTORE = Join-Path $signingRoot 'release.p12'
        $env:EXVPN_ANDROID_KEY_ALIAS = 'exvpn'
        $env:EXVPN_ANDROID_STORE_PASSWORD = [Text.Encoding]::UTF8.GetString($passwordBytes)
        $env:EXVPN_ANDROID_KEY_PASSWORD = $env:EXVPN_ANDROID_STORE_PASSWORD
        $packageInputs = & (Join-Path $PSScriptRoot 'prepare-android-notices.ps1') -FlutterRuntime shorebird -FlutterBuildMode release
        if (!$packageInputs.InputDirectory) { throw 'A fresh Android native/notices snapshot is required.' }
        $env:EXVPN_ANDROID_PACKAGE_INPUTS = $packageInputs.InputDirectory
    }
    $env:EXVPN_FLUTTER_RUNTIME = 'shorebird'
    $env:EXVPN_FLUTTER_BUILD_MODE = 'release'
    # The collector can enter the ordinary tool environment. Reset PATH so the
    # CLI's final system-Flutter pub get also uses the exact Shorebird SDK.
    $env:PATH = (Join-Path $runtime.SdkRoot 'bin') + [IO.Path]::PathSeparator + $savedEnvironment.PATH
    $arguments = @('release', $Target.ToLowerInvariant(), "--flutter-version=$($pin.flutter.revision)",
        "--public-key-path=$publicKeyPath", '--dart-define=EXVPN_DART_UPDATE_TRACK=beta')
    if ($Target -eq 'Android') { $arguments += @('--artifact=apk','--target-platform=android-arm64,android-x64') }
    $arguments += '--dry-run'
    # Android's release plugin registrant is regenerated only when --pub is
    # enabled. Shorebird resets it with a normal pub get between AAB and APK,
    # so --no-pub would leave dev-only integration_test in release Java code.
    # Dependencies were verified offline above; reject any lock change below.
    $arguments += @('--', $(if ($Target -eq 'Android') { '--pub' } else { '--no-pub' }))
    & $shorebird @arguments *> (Join-Path $privateRun 'shorebird-private.log')
    if ($LASTEXITCODE -ne 0) { throw "Shorebird build failed (exit $LASTEXITCODE); inspect private build log." }
    if ((Get-FileHash (Join-Path $app 'pubspec.lock')).Hash -cne $lockHash -or
        (Get-FileHash (Join-Path $app 'shorebird.yaml')).Hash -cne $configHash) {
        throw 'Source lock or updater policy changed during the build.'
    }
    $runtimeAfter = Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release
    if (($runtime.Evidence | ConvertTo-Json -Depth 16 -Compress) -cne ($runtimeAfter.Evidence | ConvertTo-Json -Depth 16 -Compress)) {
        throw 'Pinned runtime changed during the build.'
    }
    if ($Target -eq 'Android') {
        . (Join-Path $PSScriptRoot 'android-notice-inputs.ps1')
        $apk = Join-Path $app 'build/app/outputs/flutter-apk/app-release.apk'
        $aab = Join-Path $app 'build/app/outputs/bundle/release/app-release.aab'
        $packagedRuntime = Assert-AndroidPackagedNotices $repository $packageInputs.InputDirectory $apk `
            -FlutterRuntime shorebird -FlutterBuildMode release -PassThruRuntime
        Assert-ZipUpdater $apk 'assets/flutter_assets/shorebird.yaml'
        Assert-ZipUpdater $aab 'base/assets/flutter_assets/shorebird.yaml'
        Copy-Item -LiteralPath $apk -Destination (Join-Path $output "ExVPN-$version-shorebird-beta.apk")
        Copy-Item -LiteralPath $aab -Destination (Join-Path $output "ExVPN-$version-shorebird-beta.aab")
    } else {
        $ui = Join-Path $app 'build/windows/x64/runner/Release'
        Assert-CompiledUpdater ([IO.File]::ReadAllText((Join-Path $ui 'data/flutter_assets/shorebird.yaml')))
        Copy-Item -LiteralPath $ui -Destination (Join-Path $output 'ui') -Recurse
        . (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
        $packagedRuntime = Get-ReleasePackagedFlutterEvidence $runtimeAfter.Evidence (Get-AuditTreeFiles $output) -RequireByteMatch
    }
    if (!$packagedRuntime.engineBytesBound) {
        throw 'Packaged Flutter engine is not bound to the pinned SDK or verified Android strip transform.'
    }
    [ordered]@{
        schemaVersion=1; version=$version; target=$Target; track='beta'; published=$false
        publicKeySha256=(Get-FileHash $publicKeyPath -Algorithm SHA256).Hash.ToLowerInvariant()
        updaterPolicyVerified=$true; autoUpdate=$false; patchVerification='strict'
        runtime=$runtimeAfter.Evidence; packagedRuntime=$packagedRuntime; sourceLockUnchanged=$true
        files=@(Get-ChildItem -LiteralPath $output -File -Recurse | ForEach-Object {
            [ordered]@{path=[IO.Path]::GetRelativePath($output,$_.FullName).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        })
        limitations=@('Controlled beta base; not stable VPN acceptance.','Patch download/restart/rollback and channel isolation need device tests.','Native signing and complete release audit are separate checks.')
    } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $output 'build.json') -Encoding utf8NoBOM
} finally {
    Pop-Location
    if ($passwordBytes) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($passwordBytes) }
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
[pscustomobject]@{OutputDirectory=$output; PrivateLogDirectory=$privateRun; Published=$false; Version=$version; Target=$Target}
