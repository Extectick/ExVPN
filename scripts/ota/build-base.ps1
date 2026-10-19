# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [string]$AndroidSdkPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'aot-inputs.ps1')
. (Join-Path $repository 'scripts/release/flutter-runtime-inputs.ps1')
. (Join-Path $repository 'scripts/release/shorebird-pipeline-lib.ps1')
$sourceCommit = Get-ShorebirdSourceCommit $repository
Assert-ExvpnOtaVersion $repository $ReleaseVersion
$protectedInputs = @(Get-ExvpnOtaProtectedInputs $repository)
$fingerprint = Get-ExvpnOtaInputsFingerprint $protectedInputs
$pin = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/shorebird.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$runtime = Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release
$sdk = $runtime.SdkRoot
function BaseTool([string]$Root,[string]$Relative) {
    $path = Resolve-ExvpnOtaPath $Root $Relative
    [ordered]@{path=$Relative;sha256=(Get-ExvpnOtaSha256 $path)}
}
$tools = [ordered]@{
    flutterSdkRoot=[IO.Path]::GetRelativePath($repository,$sdk).Replace('\','/')
    dart=(BaseTool $sdk 'bin/cache/dart-sdk/bin/dart.exe')
    flutter=(BaseTool $sdk 'bin/cache/flutter_tools.snapshot')
    frontend=(BaseTool $sdk 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot')
    dartAotRuntime=(BaseTool $sdk 'bin/cache/dart-sdk/bin/dartaotruntime.exe')
    platformDill=(BaseTool $sdk 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill')
    patch=(BaseTool $repository '.tools/shorebird-1.6.129/bin/cache/artifacts/patch/patch.exe')
    genSnapshot=[ordered]@{}
}
$plan = @(Get-ExvpnOtaAotPlan $Target)
foreach ($item in $plan) { $tools.genSnapshot[$item.key] = BaseTool $sdk $item.genSnapshot }
$publicKey = BaseTool $repository 'config/signing/shorebird-beta-public.pem'
$buildArguments = @{Target=$Target;ReleaseVersion=$ReleaseVersion;Independent=$true;IndependentBaseFingerprint=$fingerprint}
if ($AndroidSdkPath) { $buildArguments.AndroidSdkPath = $AndroidSdkPath }
# Reuse the existing audited native/signing/notices/SBOM/package pipeline.
# Independent selects direct pinned Flutter builds, never a cloud CLI action.
$outputs = @(& (Join-Path $repository 'scripts/release/shorebird-release.ps1') @buildArguments)
$results = @($outputs | Where-Object { $_ -and $_.PSObject.Properties['OutputDirectory'] })
if ($results.Count -ne 1) { throw 'ota_base_output_ambiguous' }
$directory = Resolve-ExvpnOtaPath $repository $results[0].OutputDirectory
$buildPath = Join-Path $directory 'build.json'
$build = Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json -AsHashtable
if ($build.delivery -cne 'independent' -or $build.published -ne $false -or $null -ne $build.releaseId -or
    $build.auditAccepted -ne $true -or $build.sourceCommit -cne $sourceCommit -or $build.compiledSourceCommit -cne $sourceCommit -or
    $build.version -cne $ReleaseVersion -or $build.target -cne $Target -or $build.packagedRuntime.engineBytesBound -ne $true) { throw 'ota_independent_base_receipt_invalid' }
$null = Assert-ExvpnOtaProtectedInputs $repository $protectedInputs
if ((Get-ShorebirdSourceCommit $repository) -cne $sourceCommit) { throw 'ota_base_sources_changed' }
foreach ($name in @('dart','flutter','frontend','dartAotRuntime','platformDill')) {
    if ((Get-ExvpnOtaSha256 (Resolve-ExvpnOtaPath $sdk $tools[$name].path)) -cne $tools[$name].sha256) { throw 'ota_base_compiler_changed' }
}
if ((Get-ExvpnOtaSha256 (Resolve-ExvpnOtaPath $repository $tools.patch.path)) -cne $tools.patch.sha256) { throw 'ota_base_diff_tool_changed' }
foreach ($item in $plan) {
    if ((Get-ExvpnOtaSha256 (Resolve-ExvpnOtaPath $sdk $tools.genSnapshot[$item.key].path)) -cne $tools.genSnapshot[$item.key].sha256) { throw 'ota_base_snapshot_tool_changed' }
}
$aotMap = [ordered]@{}
foreach ($item in $plan) {
    $relative = 'base-aot/' + $item.key + '/app.so'
    $destination = Join-Path $directory $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if ($Target -ceq 'Windows') {
        Copy-Item -LiteralPath (Join-Path $directory 'ui/data/app.so') -Destination $destination
    } else {
        $apkFiles = @(Get-ChildItem -LiteralPath $directory -File -Filter '*.apk')
        if ($apkFiles.Count -ne 1) { throw 'ota_base_apk_ambiguous' }
        $abi = if ($item.arch -ceq 'aarch64') { 'arm64-v8a' } else { 'x86_64' }
        $zip = [IO.Compression.ZipFile]::OpenRead($apkFiles[0].FullName)
        try {
            $entries = @($zip.Entries | Where-Object FullName -CEQ ('lib/' + $abi + '/libapp.so'))
            if ($entries.Count -ne 1 -or $entries[0].Length -lt 4096 -or $entries[0].Length -gt 134217728) { throw 'ota_base_aot_zip_entry_invalid' }
            $source = $entries[0].Open()
            $output = [IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $source.CopyTo($output) } finally { $source.Dispose(); $output.Dispose() }
        } finally { $zip.Dispose() }
    }
    Assert-ExvpnOtaElf $destination $item.arch
    $hash = Get-ExvpnOtaSha256 $destination
    $binding = @($build.baseAot | Where-Object arch -CEQ $item.arch)
    if ($binding.Count -ne 1 -or $binding[0].sha256 -cne $hash) { throw 'ota_base_aot_binding_mismatch' }
    $aotMap[$item.key] = [ordered]@{path=$relative;sha256=$hash;size=(Get-Item -LiteralPath $destination).Length}
}
$fingerprints = [ordered]@{}
foreach ($category in @('native','assets','plugins','dependencies')) {
    $selected = @($protectedInputs | Where-Object {
        $record=$_
        switch ($category) {
            native { $record.path -match '^(native/|apps/exvpn/(android|windows)/)' }
            assets { $record.path -match '^apps/exvpn/assets/' }
            plugins { $record.path -match '(generated_plugin|GeneratedPlugin|registrant|pubspec\.(yaml|lock)$)' }
            dependencies { $record.path -match '(pubspec\.(yaml|lock)$|go\.(mod|sum)$|\.lock\.json$)' }
        }
    })
    $fingerprints[$category] = Get-ExvpnOtaInputsFingerprint $selected
}
$receipt = [ordered]@{
    schemaVersion=1;delivery='independent';published=$false;version=$ReleaseVersion;target=$Target;sourceCommit=$sourceCommit
    flutterRevision=$pin.flutter.revision;engineRevision=$pin.flutter.engineRevision;appRoot='apps/exvpn';dartEntrypoint='lib/main.dart'
    dartDefines=@('EXVPN_DEMO=false','EXVPN_DART_UPDATE_TRACK=beta','EXVPN_OTA_PROVIDER=exvpn',('EXVPN_OTA_BASE_FINGERPRINT=' + $fingerprint))
    protectedInputs=$protectedInputs;protectedInputsSha256=$fingerprint;fingerprints=$fingerprints
    baseAot=$aotMap;tools=$tools;signingPublicKey=$publicKey;packageBuildReceiptSha256=(Get-ExvpnOtaSha256 $buildPath)
    sourceUpdaterPolicyUnchanged=$true;packagedUpdaterEndpoint='http://127.0.0.1:57791';autoUpdate=$false;patchVerification='strict'
}
$receiptPath = Join-Path $directory 'base-receipt.json'
$stream = [IO.File]::Open($receiptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 16))
    $stream.Write($bytes,0,$bytes.Length)
} finally { $stream.Dispose() }
[pscustomobject]@{OutputDirectory=$directory;BaseReceipt=$receiptPath;Version=$ReleaseVersion;Target=$Target;Published=$false;Delivery='independent';ProtectedInputsSha256=$fingerprint}
