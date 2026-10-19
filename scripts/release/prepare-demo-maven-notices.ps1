# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ResolvedGraph,
    [string]$ArtifactPath,
    [string]$OutputDirectory,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$')][string]$AppVersion = '0.1.0+18',
    [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary',
    [switch]$LibraryOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DemoMavenHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-DemoMavenFile($Record) {
    if ($Record.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Record.size -le 0 -or
        !(Test-Path -LiteralPath $Record.file -PathType Leaf)) { throw 'demo_maven_input_missing' }
    $file = Get-Item -LiteralPath $Record.file
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Name -cne $Record.name -or
        $file.Length -ne $Record.size -or (Get-DemoMavenHash $file.FullName) -cne $Record.sha256) {
        throw 'demo_maven_input_changed'
    }
}
function Assert-DemoMavenTexts($Policy, [string]$LicenseRoot) {
    if ($Policy.schema -ne 1 -or $Policy.status -cne 'PINNED_OVERINCLUSIVE_LICENSE_TEXTS' -or
        $Policy.appVersion -cne '0.1.0+18') { throw 'demo_maven_policy_invalid' }
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Policy.files) {
        if ($entry.path -cnotmatch '^texts/[a-f0-9]{64}\.txt$' -or !$known.Add($entry.path)) {
            throw 'demo_maven_text_path_invalid'
        }
        $path = Join-Path $LicenseRoot $entry.path
        Assert-DemoMavenFile @{file=$path;name=[IO.Path]::GetFileName($path);size=$entry.size;sha256=$entry.sha256}
    }
    foreach ($component in $Policy.components) {
        if (@($component.texts).Count -lt 1) { throw 'demo_maven_license_missing' }
        foreach ($path in $component.texts) {
            if (!$known.Contains($path)) { throw 'demo_maven_license_missing' }
        }
    }
}
function Get-DemoMavenRuntimePolicy($Policy, [string]$Repository, [string]$Runtime) {
    if ($Runtime -ceq 'ordinary') { return $Policy }
    if ($Runtime -cne 'shorebird') { throw 'demo_maven_runtime_invalid' }
    $path = Join-Path $Repository 'scripts/bootstrap/shorebird.lock.json'
    $pin = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($pin.schemaVersion -ne 1 -or $pin.cli.version -cne '1.6.129' -or
        $pin.flutter.revision -cne '5bef02a16146a0effc07da4acccaafe90a2739ce' -or
        $pin.flutter.engineRevision -cne '4b936a0c03e13389ddfb1ac48823f187964975c2') {
        throw 'demo_maven_shorebird_pin_invalid'
    }
    # Reuse only the immutable non-Flutter POM/artifact/license supplement.
    # The separately verified Shorebird engine bundle covers its own runtime.
    $selected = @{} + $Policy
    $selected.engineRevision = $pin.flutter.engineRevision
    return $selected
}
function Get-DemoMavenVerifiedGraph($Graph, $Policy) {
    if ($Graph.schema -ne 1 -or $Graph.status -cne 'RESOLVED_DEMO_RELEASE_INPUTS' -or
        $Graph.variant -cne 'release' -or $Graph.configuration -cne 'releaseRuntimeClasspath' -or
        $Graph.gradleVersion -cne '9.3.1' -or $Graph.postR8InventoryComplete -or
        $Graph.projectComponentCount -lt 1 -or @($Graph.components).Count -lt 1 -or
        @($Graph.components).Count -gt 3000) { throw 'demo_maven_graph_invalid' }
    $policyById = @{}
    foreach ($pin in $Policy.components) {
        if ($policyById.ContainsKey($pin.id)) { throw 'demo_maven_duplicate_policy_component' }
        $policyById[$pin.id] = $pin
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($component in $Graph.components) {
        if ($component.id -cnotmatch '^maven:[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$' -or
            !$seen.Add($component.id)) { throw 'demo_maven_component_invalid' }
        $parts = $component.id.Split(':')
        if ($component.pom.name -cne ($parts[2]+'-'+$parts[3]+'.pom')) { throw 'demo_maven_pom_name_invalid' }
        Assert-DemoMavenFile $component.pom
        $flutter = $parts[1] -ceq 'io.flutter'
        if ($flutter) {
            if ($parts[2] -cnotin @('flutter_embedding_release','arm64_v8a_release','x86_64_release') -or
                $parts[3] -cne ('1.0.0-'+$Policy.engineRevision) -or @($component.artifacts).Count -ne 1) {
                throw 'demo_maven_flutter_component_invalid'
            }
            $coverage = 'separate-verified-flutter-engine-notice-bundle'
        } else {
            if (!$policyById.ContainsKey($component.id)) { throw 'demo_maven_component_not_covered' }
            $pin = $policyById[$component.id]
            if ($component.pom.sha256 -cne $pin.pom.sha256 -or $component.pom.size -ne $pin.pom.size) {
                throw 'demo_maven_pom_not_pinned'
            }
            $coverage = 'pinned-full-text-supplements'
            if (@($pin.artifacts).Count -gt 0 -and @($component.artifacts).Count -eq 0) {
                throw 'demo_maven_binary_missing'
            }
        }
        $artifacts = [Collections.Generic.List[object]]::new()
        $artifactNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($artifact in $component.artifacts) {
            if ($artifact.name -cnotmatch '^[A-Za-z0-9_.-]+\.(aar|jar)$' -or !$artifactNames.Add($artifact.name)) {
                throw 'demo_maven_artifact_invalid'
            }
            Assert-DemoMavenFile $artifact
            if (!$flutter -and !@($pin.artifacts | Where-Object {
                $_.name -ceq $artifact.name -and $_.sha256 -ceq $artifact.sha256 -and $_.size -eq $artifact.size
            }).Count) { throw 'demo_maven_artifact_not_pinned' }
            $artifacts.Add([ordered]@{name=$artifact.name;size=$artifact.size;sha256=$artifact.sha256})
        }
        $result.Add([ordered]@{id=$component.id;coverage=$coverage;
            pom=[ordered]@{name=$component.pom.name;size=$component.pom.size;sha256=$component.pom.sha256};
            artifacts=@($artifacts | Sort-Object name)})
    }
    foreach ($name in @('flutter_embedding_release','arm64_v8a_release','x86_64_release')) {
        if (!$seen.Contains('maven:io.flutter:'+$name+':1.0.0-'+$Policy.engineRevision)) {
            throw 'demo_maven_flutter_component_missing'
        }
    }
    [ordered]@{schema=1;status='VERIFIED_DEMO_RELEASE_INPUTS';variant='release';configuration=$Graph.configuration;
        gradleVersion=$Graph.gradleVersion;projectComponentCount=$Graph.projectComponentCount;
        components=@($result | Sort-Object id);postR8InventoryComplete=$false}
}
function Write-DemoMavenJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 50)+"`n"), [Text.UTF8Encoding]::new($false))
}

if ($LibraryOnly) { return }
if (!$ResolvedGraph -or !$ArtifactPath -or !$OutputDirectory) { throw 'demo_maven_required_argument_missing' }
$licenseRoot = Join-Path $PSScriptRoot 'licenses/android-demo'
$policyPath = Join-Path $licenseRoot 'inventory.json'
# This immutable snapshot is deliberately independent of stable audit policy.
if ((Get-DemoMavenHash $policyPath) -cne 'e2564888a8b905a8cab6ac1b2ec3f58b9fc0367c6c20154ce3046e67e7393983') {
    throw 'demo_maven_license_policy_changed'
}
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -AsHashtable
Assert-DemoMavenTexts $policy $licenseRoot
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$verificationPolicy = Get-DemoMavenRuntimePolicy $policy $repository $FlutterRuntime
$runtimePinHash = if ($FlutterRuntime -ceq 'shorebird') {
    Get-DemoMavenHash (Join-Path $repository 'scripts/bootstrap/shorebird.lock.json')
} else { $null }
$graph = Get-Content -LiteralPath $ResolvedGraph -Raw | ConvertFrom-Json -AsHashtable
$safeGraph = Get-DemoMavenVerifiedGraph $graph $verificationPolicy
if ($FlutterRuntime -ceq 'shorebird') {
    $safeGraph.flutterRuntime = [ordered]@{
        kind = 'shorebird'; engineRevision = $verificationPolicy.engineRevision
        sourcePinSha256 = $runtimePinHash
    }
}
$apk = Get-Item -LiteralPath $ArtifactPath
if ($apk.Extension -cne '.apk' -or $apk.Length -le 0 -or ($apk.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'demo_maven_apk_invalid'
}
$apkHash = Get-DemoMavenHash $apk.FullName
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$zipPath = Join-Path $OutputDirectory 'android-maven-notices.zip'
$jsonPath = Join-Path $OutputDirectory 'android-maven-notices.json'
if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $jsonPath)) { throw 'demo_maven_output_not_fresh' }
$stage = Join-Path $OutputDirectory ('.maven-notices-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    Copy-Item -LiteralPath $policyPath -Destination (Join-Path $stage 'license-inventory.json')
    Copy-Item -LiteralPath (Join-Path $licenseRoot 'README.txt') -Destination (Join-Path $stage 'README.txt')
    foreach ($file in $policy.files) {
        $target = Join-Path $stage $file.path
        [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $licenseRoot $file.path) -Destination $target
        if ((Get-DemoMavenHash $target) -cne $file.sha256) { throw 'demo_maven_copy_changed' }
    }
    foreach ($component in $graph.components) {
        $parts = $component.id.Split(':')
        $target = Join-Path $stage ('poms/'+$parts[1]+'/'+$parts[2]+'/'+$component.pom.name)
        [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
        Copy-Item -LiteralPath $component.pom.file -Destination $target
        if ((Get-DemoMavenHash $target) -cne $component.pom.sha256) { throw 'demo_maven_copy_changed' }
    }
    $graphPath = Join-Path $stage 'android-maven-inputs.json'
    Write-DemoMavenJson $graphPath $safeGraph
    $graphHash = Get-DemoMavenHash $graphPath
    Write-DemoMavenJson (Join-Path $stage 'apk-binding.json') ([ordered]@{
        appVersion=$AppVersion;apkSha256=$apkHash;inputGraphSha256=$graphHash;
        licenseInventorySha256=(Get-DemoMavenHash $policyPath);postR8InventoryComplete=$false;stableReleaseReady=$false
    })
    if ($FlutterRuntime -ceq 'shorebird') {
        Write-DemoMavenJson (Join-Path $stage 'flutter-runtime-selection.json') $safeGraph.flutterRuntime
    }
    # Validate source inputs again after copy; no successful report can bind a
    # changed artifact, POM, license text or APK.
    [void](Get-DemoMavenVerifiedGraph $graph $verificationPolicy)
    $runtimeAfter = Get-DemoMavenRuntimePolicy $policy $repository $FlutterRuntime
    if ($runtimeAfter.engineRevision -cne $verificationPolicy.engineRevision -or
        ($FlutterRuntime -ceq 'shorebird' -and
        (Get-DemoMavenHash (Join-Path $repository 'scripts/bootstrap/shorebird.lock.json')) -cne $runtimePinHash)) {
        throw 'demo_maven_runtime_changed'
    }
    Assert-DemoMavenTexts $policy $licenseRoot
    if ((Get-DemoMavenHash $apk.FullName) -cne $apkHash) { throw 'demo_maven_apk_changed' }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zipPath,[IO.Compression.CompressionLevel]::Optimal,$false)
    $report = [ordered]@{
        schema=1;status='PASS';appVersion=$AppVersion;apkSha256=$apkHash;archiveSha256=(Get-DemoMavenHash $zipPath);
        archive='android-maven-notices.zip';inputGraphSha256=$graphHash;licenseInventorySha256=(Get-DemoMavenHash $policyPath);
        runtimeMavenComponents=@($safeGraph.components).Count;
        runtimeComponentsCoveredBySupplement=@($safeGraph.components | Where-Object coverage -CEQ 'pinned-full-text-supplements').Count;
        flutterComponentsCoveredSeparately=@($safeGraph.components | Where-Object coverage -CEQ 'separate-verified-flutter-engine-notice-bundle').Count;
        overinclusiveInventoryComponents=@($policy.components).Count;fullTextFiles=@($policy.files).Count;
        scope='Exact same-build releaseRuntimeClasspath inputs, plus an overinclusive pinned source/binary license-text supplement.';
        sourceArchiveBodiesIncluded=$false;postR8InventoryComplete=$false;stableReleaseReady=$false;
        exclusions=@('Flutter engine and own/Dart/Go/plugin notices use the separately verified embedded notice bundle.',
            'No claim to identify final linked classes after R8, the complete SBOM, or stable release acceptance.')
    }
    if ($FlutterRuntime -ceq 'shorebird') { $report.flutterRuntime = $safeGraph.flutterRuntime }
    Write-DemoMavenJson $jsonPath $report
    Write-Host ('Demo Maven notice supplement verified: '+$report.runtimeComponentsCoveredBySupplement+' selected components; '+$report.fullTextFiles+' full text files.')
} finally {
    # Only the exact fresh staging directory created above is removed.
    $resolved = [IO.Path]::GetFullPath($stage)
    if (!$resolved.StartsWith($OutputDirectory.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'demo_maven_cleanup_boundary'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
