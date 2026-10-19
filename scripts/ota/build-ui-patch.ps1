# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('BaseReceiptPath')][string]$BaseReceipt,
    [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$PatchNumber,
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [string]$Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$OutputDirectory,
    [switch]$PlanOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aot-inputs.ps1')
. (Join-Path $PSScriptRoot 'source-driver.ps1')

function Assert-OtaPinnedTool([string]$Root, [object]$Record, [string]$ExpectedRelative) {
    if ($null -eq $Record -or $Record.path -isnot [string] -or $Record.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'ota_tool_pin_missing' }
    if ($ExpectedRelative -and $Record.path.Replace('\','/') -cne $ExpectedRelative) { throw 'ota_tool_path_mismatch' }
    $path = Resolve-ExvpnOtaPath $Root $Record.path
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-ExvpnOtaSha256 $path) -cne $Record.sha256) { throw 'ota_tool_hash_mismatch' }
    $path
}

function Invoke-OtaPinnedProcess([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory, [string]$LogPath, [hashtable]$EnvironmentOverrides=@{}) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['FLUTTER_SUPPRESS_ANALYTICS'] = 'true'
    $info.Environment['CI'] = 'true'
    foreach($name in $EnvironmentOverrides.Keys){$info.Environment[$name]=$EnvironmentOverrides[$name]}
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (!$process.Start()) { throw 'ota_tool_start_failed' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [IO.File]::WriteAllText($LogPath, ($stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()), [Text.UTF8Encoding]::new($false))
        if ($process.ExitCode -ne 0) { throw 'ota_aot_tool_failed' }
    } finally { $process.Dispose() }
}

$root = Resolve-ExvpnOtaPath (Get-Location).Path $Repository
$receiptPath = Resolve-ExvpnOtaPath $root $BaseReceipt
if ((Get-Item -LiteralPath $receiptPath).Length -gt 16777216) { throw 'ota_receipt_too_large' }
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
if ($receipt.schemaVersion -ne 1 -or $receipt.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
    $receipt.flutterRevision -cne '5bef02a16146a0effc07da4acccaafe90a2739ce' -or
    $receipt.engineRevision -cne '4b936a0c03e13389ddfb1ac48823f187964975c2' -or
    $receipt.appRoot -cne 'apps/exvpn' -or $receipt.dartEntrypoint -cne 'lib/main.dart') { throw 'ota_base_receipt_invalid' }
Assert-ExvpnOtaVersion $root $receipt.version
$fingerprint = Assert-ExvpnOtaProtectedInputs $root @($receipt.protectedInputs)
if ($receipt.protectedInputsSha256 -cne $fingerprint) { throw 'ota_receipt_fingerprint_mismatch' }
$expectedDefines = @('EXVPN_DEMO=false','EXVPN_DART_UPDATE_TRACK=beta','EXVPN_OTA_PROVIDER=exvpn',('EXVPN_OTA_BASE_FINGERPRINT=' + $fingerprint))
if ((ConvertTo-Json -InputObject @($receipt.dartDefines) -Compress) -cne (ConvertTo-Json -InputObject $expectedDefines -Compress)) { throw 'ota_dart_defines_changed' }
$sourceCommit = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'ota_source_commit_invalid' }
& git -C $root merge-base --is-ancestor $receipt.sourceCommit $sourceCommit
if ($LASTEXITCODE -ne 0) { throw 'ota_base_not_ancestor' }
& git -C $root diff --quiet HEAD -- apps/exvpn/lib packages
if ($LASTEXITCODE -ne 0) { throw 'ota_dart_source_dirty' }
$untracked = @(& git -C $root ls-files --others --exclude-standard -- apps/exvpn/lib packages)
if ($LASTEXITCODE -ne 0 -or @($untracked | Where-Object { $_ -match '\.dart$' }).Count -gt 0) { throw 'ota_dart_source_untracked' }
$sdk = Resolve-ExvpnOtaPath $root $receipt.tools.flutterSdkRoot
$sdkCommit = (& git -C $sdk rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sdkCommit -cne $receipt.flutterRevision) { throw 'ota_flutter_revision_mismatch' }
if ([IO.File]::ReadAllText((Join-Path $sdk 'bin/internal/engine.version')).Trim() -cne $receipt.engineRevision) { throw 'ota_engine_revision_mismatch' }
$dart = Assert-OtaPinnedTool $sdk $receipt.tools.dart 'bin/cache/dart-sdk/bin/dart.exe'
# Retain the base's host-JIT hash as provenance, but never execute that cache:
# its bytes embed checkout paths and cannot match a different CI machine.
if($receipt.tools.flutter.path -cne 'bin/cache/flutter_tools.snapshot' -or $receipt.tools.flutter.sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'ota_flutter_driver_metadata_invalid'}
Assert-ExvpnOtaDriverCheckout $sdk $receipt.flutterRevision
$null = Assert-OtaPinnedTool $sdk $receipt.tools.frontend 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'
$null = Assert-OtaPinnedTool $sdk $receipt.tools.dartAotRuntime 'bin/cache/dart-sdk/bin/dartaotruntime.exe'
$null = Assert-OtaPinnedTool $sdk $receipt.tools.platformDill 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill'
$patchTool = Assert-OtaPinnedTool $root $receipt.tools.patch '.tools/shorebird-1.6.129/bin/cache/artifacts/patch/patch.exe'
$publicPath = Assert-OtaPinnedTool $root $receipt.signingPublicKey ''
$publicKey = [Security.Cryptography.RSA]::Create()
$privateKey = $null
$privateText = $null
try {
    $publicKey.ImportFromPem([IO.File]::ReadAllText($publicPath))
    if ($publicKey.KeySize -ne 4096) { throw 'ota_public_key_invalid' }
    $plan = @(Get-ExvpnOtaAotPlan $Target)
    $receiptDirectory = Split-Path -Parent $receiptPath
    foreach ($item in $plan) {
        if (!$receipt.baseAot.ContainsKey($item.key) -or !$receipt.tools.genSnapshot.ContainsKey($item.key)) { throw 'ota_architecture_missing' }
        $base = $receipt.baseAot[$item.key]
        $basePath = Resolve-ExvpnOtaPath $receiptDirectory $base.path
        if ($base.sha256 -cnotmatch '^[a-f0-9]{64}$' -or [long]$base.size -lt 4096 -or
            (Get-Item -LiteralPath $basePath).Length -ne [long]$base.size -or (Get-ExvpnOtaSha256 $basePath) -cne $base.sha256) { throw 'ota_base_aot_invalid' }
        Assert-ExvpnOtaElf $basePath $item.arch
        $item['basePath'] = $basePath
        $item['baseSha256'] = $base.sha256
        $item['snapshotPath'] = Assert-OtaPinnedTool $sdk $receipt.tools.genSnapshot[$item.key] $item.genSnapshot
    }
    if ($PlanOnly) {
        [ordered]@{schemaVersion=1;version=$receipt.version;target=$Target;patchNumber=$PatchNumber;sourceCommit=$sourceCommit;baseSourceCommit=$receipt.sourceCommit;protectedInputsSha256=$fingerprint;architectures=@($plan | ForEach-Object {$_.key});cloudCalls=$false;nativeBuild=$false} | ConvertTo-Json -Depth 6
        return
    }
    $privatePath = Resolve-ExvpnOtaPath $root $PrivateKeyPath
    $privateRoot = [IO.Path]::GetFullPath((Join-Path $root '.private')) + [IO.Path]::DirectorySeparatorChar
    if (!$privatePath.StartsWith($privateRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'ota_private_key_location_invalid' }
    $privateText = [IO.File]::ReadAllText($privatePath)
    $privateKey = [Security.Cryptography.RSA]::Create()
    $privateKey.ImportFromPem($privateText)
    if ($privateKey.KeySize -ne 4096 -or [Convert]::ToBase64String($privateKey.ExportRSAPublicKey()) -cne [Convert]::ToBase64String($publicKey.ExportRSAPublicKey())) { throw 'ota_signing_key_mismatch' }
    $privateText = $null
    $id = [Guid]::NewGuid().ToString('N')
    if (!$OutputDirectory) { $OutputDirectory = Join-Path $root ('artifacts/ota/ui-' + $Target.ToLowerInvariant() + '-' + $PatchNumber + '-' + $id) }
    $output = Resolve-ExvpnOtaPath $root $OutputDirectory
    if (Test-Path -LiteralPath $output) { throw 'ota_output_already_exists' }
    New-Item -ItemType Directory -Path $output | Out-Null
    $logs = Join-Path $root ('.private/ota-builds/' + $id)
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $app = Join-Path $root 'apps/exvpn'
    $packageConfigPath = Join-Path $app '.dart_tool/package_config.json'
    $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $flutterPackage = @($packageConfig.packages | Where-Object name -CEQ 'flutter')
    if ($flutterPackage.Count -ne 1) { throw 'ota_flutter_package_missing' }
    $packageRoot = [uri]::new([uri]::new($packageConfigPath),$flutterPackage[0].rootUri).LocalPath
    if (![string]::Equals([IO.Path]::GetFullPath($packageRoot).TrimEnd('\','/'),[IO.Path]::GetFullPath((Join-Path $sdk 'packages/flutter')).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)) { throw 'ota_flutter_package_sdk_mismatch' }
    $artifacts = [Collections.Generic.List[object]]::new()
    $started = [DateTime]::UtcNow
    $driver=Initialize-ExvpnOtaSourceDriver $root $sdk $dart $logs
    foreach ($item in $plan) {
        $archOutput = Join-Path $output $item.key
        New-Item -ItemType Directory -Path $archOutput | Out-Null
        $buildOutputs = Join-Path $logs ($item.key + '-outputs.txt')
        $encodedDefines = (@($expectedDefines | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }) -join ',')
        Assert-ExvpnOtaSourceDriver $sdk $driver
        $arguments = @(('--packages='+$driver.packageConfig),$driver.entrypoint,'--no-version-check','--suppress-analytics','assemble',('--output=' + $archOutput),('--build-outputs=' + $buildOutputs),
            ('-dTargetPlatform=' + $item.platform),'-dBuildMode=release','-dTargetFile=lib/main.dart','-dTrackWidgetCreation=false','-dDartObfuscation=false',('-dDartDefines=' + $encodedDefines),'kernel_snapshot_program')
        Invoke-OtaPinnedProcess $dart $arguments $app (Join-Path $logs ($item.key + '-kernel.log')) @{FLUTTER_ROOT=$sdk}
        $kernels = @(Get-Content -LiteralPath $buildOutputs | Where-Object { $_.Replace('\','/') -match '/app\.dill$' })
        if ($kernels.Count -ne 1) { throw 'ota_kernel_output_ambiguous' }
        $kernel = Resolve-ExvpnOtaPath $app $kernels[0]
        $registrants = @(Get-ChildItem -LiteralPath (Join-Path $app '.dart_tool/flutter_build') -Filter dart_plugin_registrant.dart -Recurse -File -ErrorAction SilentlyContinue)
        foreach ($registrant in $registrants) {
            if ([IO.File]::ReadAllText($registrant.FullName) -match 'integration_test|integrationTest') { throw 'ota_development_plugin_in_release' }
        }
        $aot = Join-Path $archOutput 'app.so'
        Invoke-OtaPinnedProcess $item.snapshotPath @('--deterministic','--snapshot_kind=app-aot-elf',('--elf=' + $aot),'--strip',$kernel) $app (Join-Path $logs ($item.key + '-snapshot.log'))
        $aotHash = Get-ExvpnOtaSha256 $aot
        Assert-ExvpnOtaElf $aot $item.arch
        $signature = New-ExvpnOtaHashSignature $aotHash $privateKey
        if (!$publicKey.VerifyData([Text.Encoding]::UTF8.GetBytes($aotHash), [Convert]::FromBase64String($signature), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'ota_signature_public_check_failed' }
        $diff = Join-Path $archOutput 'diff.patch'
        Invoke-OtaPinnedProcess $patchTool @($item.basePath,$aot,$diff) $app (Join-Path $logs ($item.key + '-diff.log'))
        $diffSize = (Get-Item -LiteralPath $diff).Length
        if ($diffSize -le 0 -or $diffSize -gt 67108864) { throw 'ota_diff_size_invalid' }
        $artifacts.Add([ordered]@{arch=$item.arch;key=$item.key;baseSha256=$item.baseSha256;aotSha256=$aotHash;aotSize=(Get-Item -LiteralPath $aot).Length;hashSignature=$signature;diffPath=($item.key + '/diff.patch');diffSha256=(Get-ExvpnOtaSha256 $diff);diffSize=$diffSize;aotPath=($item.key + '/app.so')})
    }
    $null = Assert-ExvpnOtaProtectedInputs $root @($receipt.protectedInputs)
    & git -C $root diff --quiet HEAD -- apps/exvpn/lib packages
    if ($LASTEXITCODE -ne 0 -or (& git -C $root rev-parse HEAD).Trim() -cne $sourceCommit) { throw 'ota_sources_changed_during_compile' }
    foreach ($item in $plan) {
        if ((Get-ExvpnOtaSha256 $item.basePath) -cne $item.baseSha256) { throw 'ota_base_changed_during_compile' }
        $null = Assert-OtaPinnedTool $sdk $receipt.tools.genSnapshot[$item.key] $item.genSnapshot
    }
    $null = Assert-OtaPinnedTool $root $receipt.tools.patch '.tools/shorebird-1.6.129/bin/cache/artifacts/patch/patch.exe'
    $null = Assert-OtaPinnedTool $sdk $receipt.tools.dart 'bin/cache/dart-sdk/bin/dart.exe'
    Assert-ExvpnOtaSourceDriver $sdk $driver
    $null = Assert-OtaPinnedTool $sdk $receipt.tools.frontend 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'
    $null = Assert-OtaPinnedTool $sdk $receipt.tools.dartAotRuntime 'bin/cache/dart-sdk/bin/dartaotruntime.exe'
    $null = Assert-OtaPinnedTool $sdk $receipt.tools.platformDill 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill'
    $driverEvidence=[ordered]@{kind=$driver.kind;sdkCommit=$driver.sdkCommit;entrypointSha256=$driver.entrypointSha256;dependencyLockSha256=$driver.dependencyLockSha256;packageConfigSha256=$driver.packageConfigSha256}
    $result = [ordered]@{schemaVersion=1;version=$receipt.version;baseSourceCommit=$receipt.sourceCommit;sourceCommit=$sourceCommit;target=$Target;patchNumber=$PatchNumber;flutterRevision=$receipt.flutterRevision;engineRevision=$receipt.engineRevision;protectedInputsSha256=$fingerprint;baseReceiptSha256=(Get-ExvpnOtaSha256 $receiptPath);signingPublicKeySha256=(Get-ExvpnOtaSha256 $publicPath);artifacts=$artifacts.ToArray();buildDriver=$driverEvidence;cloudCalls=$false;nativeBuild=$false;startedAt=$started.ToString('o');completedAt=[DateTime]::UtcNow.ToString('o');elapsedSeconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,3)}
    $resultPath = Join-Path $output 'patch-receipt.json'
    [IO.File]::WriteAllText($resultPath,($result | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    [ordered]@{receipt=$resultPath;target=$Target;patchNumber=$PatchNumber;architectures=$artifacts.Count;elapsedSeconds=$result.elapsedSeconds;cloudCalls=$false;nativeBuild=$false} | ConvertTo-Json -Compress
} finally {
    $privateText = $null
    if ($null -ne $privateKey) { $privateKey.Dispose() }
    $publicKey.Dispose()
}
