# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AabPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$CacheRoot = '',
    [string]$JavaPath = 'C:/Program Files/Android/Android Studio/jbr/bin/java.exe'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-aab-dependencies-lib.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$CacheRoot) { $CacheRoot = Join-Path $repository '.tools/cache/gradle/caches/modules-2/files-2.1' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$allowed = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts/qa')) + [IO.Path]::DirectorySeparatorChar
if (!$output.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) { throw 'aab_output_must_be_fresh_qa_directory' }
$parent = Split-Path $output
while (!(Test-Path -LiteralPath $parent)) { $parent = Split-Path $parent }
Assert-AuditNoLinks $parent
$pinPath = Join-Path $PSScriptRoot 'android-aab-dependencies.lock.json'
$sourcePath = Join-Path $PSScriptRoot 'AndroidAabDependencies.java'
$watch = [Diagnostics.Stopwatch]::StartNew()
$tools = Get-AabPinnedTools $CacheRoot $pinPath
$embedded = Get-AabEmbeddedDependencies $AabPath $ExpectedSha256
$inputs = [Collections.Generic.List[object]]::new()
foreach ($path in @($AabPath,$pinPath,$sourcePath,$JavaPath,(Join-Path $PSScriptRoot 'android-aab-dependencies-lib.ps1'),$PSCommandPath) + @($tools.files.path)) {
    $inputs.Add([ordered]@{path=[IO.Path]::GetFullPath($path);sha256=Get-AuditSha256 $path})
}
[IO.Directory]::CreateDirectory($output) | Out-Null
try {
    $metadataPath = Join-Path $output 'dependencies.pb'
    $decodedPath = Join-Path $output 'decoded.json'
    [IO.File]::WriteAllBytes($metadataPath,$embedded.bytes)
    $message = Invoke-AabParser $JavaPath @($tools.files.path) $sourcePath @($metadataPath,$decodedPath)
    if ($message -cne 'AAB_PROTOBUF_DECODED') { throw 'aab_parser_result_missing' }
    $decoded = Get-Content -LiteralPath $decodedPath -Raw | ConvertFrom-Json -AsHashtable
    $binding = Get-AabMavenBindings $decoded $CacheRoot $embedded.metadataSha256
    foreach ($inputFile in $binding.inputs) { $inputs.Add($inputFile) }
    foreach ($inputFile in $inputs) {
        Assert-AuditNoLinks $inputFile.path
        if ((Get-AuditSha256 $inputFile.path) -cne $inputFile.sha256) { throw 'aab_input_changed' }
    }
    if ((Get-AuditSha256 $AabPath) -cne $ExpectedSha256) { throw 'aab_input_changed' }
    $report = [ordered]@{
        schema=1; status='AAB_REPORTED_INPUTS_BOUND_LICENSE_COVERAGE_INCOMPLETE'; bindingKind='aab_embedded_agp_dependencies';
        artifact=[ordered]@{file=[IO.Path]::GetFileName($AabPath);sha256=$ExpectedSha256};
        metadata=[ordered]@{entry=$embedded.entry;sha256=$embedded.metadataSha256;producerSha256=$embedded.producerSha256;agpVersion=$tools.pin.agpVersion;schemaSha256=$tools.pin.schemaSha256};
        parserTools=@($tools.files | ForEach-Object { [ordered]@{file=$_.name;sha256=$_.sha256} });
        counts=[ordered]@{libraries=@($decoded.libraries).Count;boundBinaries=$binding.bound.Count;withoutDigest=$binding.unbound.Count;edges=$decoded.edgeCount};
        bound=$binding.bound;unbound=$binding.unbound;
        scope=[ordered]@{exactLinkedCodeInventory=$false;separateApkBinding=$false;licensesReviewed=$false;signatureVerified=$false};
        elapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);
        limitations=@('AGP reports pre-R8 Maven input artifacts, not exact linked classes.',
            'Missing producer digests remain explicitly unbound; local POM availability cannot supply a historical digest.',
            'This result applies only to this AAB, not a separately built APK.',
            'Project plugins, Dart/Flutter/native inputs, full notices and signatures require separate checks.')
    }
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $output 'binding.json') -Encoding utf8NoBOM
    $inputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'inputs-local.json') -Encoding utf8NoBOM
    Write-Host "AAB: $($binding.bound.Count) reported binary hashes matched; $($binding.unbound.Count) records have no producer digest. License/APK gates remain open."
} catch {
    $code = if ($_.Exception.Message -cmatch '^aab_[a-z_]+$') { $_.Exception.Message } else { 'aab_inspection_failed' }
    [ordered]@{status='FAILED';code=$code} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'failure.json') -Encoding utf8NoBOM
    throw $code
}
