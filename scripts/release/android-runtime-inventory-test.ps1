# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([switch]$WithGradleFixture,[switch]$WithMetadataFixture)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'android-runtime-inventory-lib.ps1')
. (Join-Path $PSScriptRoot 'android-runtime-inventory-preparation.ps1')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=Join-Path $repository ('artifacts/qa/android-runtime-inventory-fixture-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$checks=0
$engine='a'*40
function Check([bool]$Condition) { if (!$Condition) { throw 'android_inventory_fixture_assertion_failed' }; $script:checks++ }
function Reject([scriptblock]$Action) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Check $failed
}
function RejectCode([scriptblock]$Action,[string]$Expected) {
    $actual=$null
    try { & $Action | Out-Null } catch { $actual=$_.Exception.Message }
    Check ($actual -ceq $Expected)
}
function Clone($Value) { $Value | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable }
function FixtureFile([string]$Relative,[string]$Role) {
    $path=Join-Path $root $Relative
    [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
    [IO.File]::WriteAllText($path,'synthetic fixture only',[Text.UTF8Encoding]::new($false))
    [ordered]@{file=$path;name=[IO.Path]::GetFileName($path);role=$Role;size=(Get-Item -LiteralPath $path).Length;sha256=Get-AndroidInventoryHash $path}
}
$variant=[ordered]@{name='runtime';attributes=@{'org.gradle.usage'='java-runtime'};capabilities=@()}
$rootNode=[ordered]@{id='project::app';kind='project';variants=@($variant);artifacts=@();metadata=@();binaryArtifactsInspected=$false;buildFile=FixtureFile 'app/build.gradle' 'project-build-script'}
$engineNode=[ordered]@{id="maven:io.flutter:flutter_embedding_debug:1.0.0-$engine";kind='maven';group='io.flutter';name='flutter_embedding_debug';version="1.0.0-$engine";variants=@($variant);artifacts=@(FixtureFile "repo/flutter_embedding_debug-1.0.0-$engine.jar" 'resolved-runtime-artifact');metadata=@(FixtureFile "repo/flutter_embedding_debug-1.0.0-$engine.pom" 'selected-component-pom')}
$report=[ordered]@{schema=1;status='RESOLVED_INPUT_GRAPH';gradleVersion='9.3.1';variant='debug';configuration='debugRuntimeClasspath';engineRevision=$engine;offline=$true;taskGraph=@(':app:exvpnRuntimeInventory');rootComponent=$rootNode.id;components=@($rootNode,$engineNode);edges=@([ordered]@{from=$rootNode.id;to=$engineNode.id;constraint=$false;requested=@{kind='maven';required="1.0.0-$engine";strict='';preferred='';rejected=@()}});boundaries=@{apkBindingVerified=$false;licensesReviewed=$false;projectBinariesVerified=$false;exactLinkedCodeInventory=$false;metadataSourceSelectionVerified=$false}}
$count=Assert-AndroidInventoryGraph $report 'debug' $engine -ArtifactRoots @($root) -VerifyBytes
Check ($count.components -eq 2 -and $count.maven -eq 1)
foreach ($mutation in @(
    {param($x) $x.schema=2},
    {param($x) $x.status='PASS'},
    {param($x) $x.gradleVersion='9.3.2'},
    {param($x) $x.variant='release'},
    {param($x) $x.configuration='testDebugRuntimeClasspath'},
    {param($x) $x.offline=$false},
    {param($x) $x.offline='true'},
    {param($x) $x.taskGraph+= ':app:assembleDebug'},
    {param($x) $x.engineRevision='b'*40},
    {param($x) $x.components+= $x.components[0]},
    {param($x) $x.components[1].kind='file'},
    {param($x) $x.components[1].version='1.+'},
    {param($x) $x.components[1].version='1.0-SNAPSHOT'},
    {param($x) $x.components[1].metadata=@()},
    {param($x) $x.components[1].metadata+= $x.components[1].metadata[0]},
    {param($x) $x.components[1].metadata[0].name='another.pom'},
    {param($x) $x.components[1].artifacts[0].name='unknown.exe'},
    {param($x) $x.components[1].artifacts[0].role='metadata-only'},
    {param($x) $x.components[1].artifacts[0].sha256='b'*64},
    {param($x) $x.components[1].artifacts[0].size='22'},
    {param($x) $x.components[0].binaryArtifactsInspected=$true},
    {param($x) $x.edges[0].to='maven:missing:unknown:1.0'},
    {param($x) $x.edges[0].requested.kind='file'},
    {param($x) $x.edges[0].requested.required='[1.0,2.0)'},
    {param($x) $x.edges[0].requested.preferred='latest.release'},
    {param($x) $x.edges[0].requested.strict='1.+'},
    {param($x) $x.edges[0].requested.rejected=@('2.+')},
    {param($x) $x.edges=@()},
    {param($x) $x.rootComponent='maven:no:root:1.0'}
)) {
    $copy=Clone $report
    & $mutation $copy
    Reject { Assert-AndroidInventoryGraph $copy 'debug' $engine -ArtifactRoots @($root) -VerifyBytes }
}
foreach ($boundary in $report.boundaries.Keys) {
    $copy=Clone $report
    $copy.boundaries[$boundary]=$true
    Reject { Assert-AndroidInventoryGraph $copy 'debug' $engine }
}
foreach ($bad in @('','+','1.+','[1.0,2.0)','latest.release','1.0-SNAPSHOT','../1.0',3,$null)) { Reject { Assert-AndroidInventoryExactVersion $bad } }
Assert-AndroidInventoryExactVersion '' -AllowEmpty
Check $true
$before=Get-AndroidInventoryFingerprint @(@{identity='b';sha256='a'*64},@{identity='a';sha256='b'*64})
Check ($before -ceq (Get-AndroidInventoryFingerprint @(@{identity='a';sha256='b'*64},@{identity='b';sha256='a'*64})))
Check ($before -cne (Get-AndroidInventoryFingerprint @(@{identity='a';sha256='a'*64},@{identity='b';sha256='a'*64})))
$membershipFile=FixtureFile 'membership/source/main.kt' 'source'
$membershipRoot=Split-Path $membershipFile.file
$membership=Get-AndroidInventoryTreeSnapshot 'membership' $membershipRoot
Assert-AndroidInventoryTreeUnchanged $membership
Check $true
[void](FixtureFile 'membership/source/build/generated.tmp' 'generated-output')
Assert-AndroidInventoryTreeUnchanged $membership
Check $true
[void](FixtureFile 'membership/source/new-build-logic.gradle.kts' 'source')
Reject { Assert-AndroidInventoryTreeUnchanged $membership }
Reject { Assert-AndroidInventoryPath $report.components[1].artifacts[0].file @((Join-Path $root 'other')) }
function ModuleCacheFile([string]$CacheName,[string]$Content,[string]$DirectoryKey='') {
    $bytes=[Text.Encoding]::UTF8.GetBytes($Content)
    $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
    if (!$DirectoryKey) { $DirectoryKey=$sha1.TrimStart('0') }
    $file=FixtureFile "$CacheName/modules-2/files-2.1/io.flutter/flutter_embedding_debug/1.0.0-$engine/$DirectoryKey/flutter_embedding_debug-1.0.0-$engine.module" 'unused'
    [IO.File]::WriteAllBytes($file.file,$bytes)
    @{file=$file.file;sha1=$sha1;key=$DirectoryKey;cache=Join-Path $root $CacheName}
}
$module=ModuleCacheFile 'cache' 'synthetic module metadata ordinary'
Check ($module.sha1.Length -eq 40 -and !$module.sha1.StartsWith('0'))
$cache=$module.cache
$copy=Clone $report
Add-AndroidInventoryModuleMetadata $copy @($cache)
Check (@($copy.components[1].metadata).Count -eq 2)
[void](Assert-AndroidInventoryGraph $copy 'debug' $engine -ArtifactRoots @($root) -VerifyBytes)
Check $true
# Actual SHA1 starts with two zeroes; Gradle 9.3.1 strips both from the directory.
$short=ModuleCacheFile 'short-key-cache' 'synthetic module metadata 34'
Check ($short.sha1 -ceq '0071bf34724589bdbb8cc2996a6ca993e3b9cf0d' -and $short.key.Length -eq 38)
$copy=Clone $report
Add-AndroidInventoryModuleMetadata $copy @($short.cache)
Check (@($copy.components[1].metadata).Count -eq 2)
[void](Assert-AndroidInventoryGraph $copy 'debug' $engine -ArtifactRoots @($root) -VerifyBytes)
Check $true
[IO.File]::WriteAllText($short.file,'changed bytes under the old cache key')
RejectCode { Add-AndroidInventoryModuleMetadata (Clone $report) @($short.cache) } 'android_inventory_cache_key_mismatch'
foreach ($badKey in @('0',('0'*40),'not-hex',$module.key.ToUpperInvariant(),$short.sha1)) {
    $bad=ModuleCacheFile ('invalid-key-'+[guid]::NewGuid().ToString('N')) 'synthetic module metadata 34' $badKey
    RejectCode { Add-AndroidInventoryModuleMetadata (Clone $report) @($bad.cache) } 'android_inventory_cache_layout_invalid'
}
foreach ($wrongKey in @(('c'*40),'c')) {
    $bad=ModuleCacheFile ('mismatch-key-'+[guid]::NewGuid().ToString('N')) 'synthetic module metadata ordinary' $wrongKey
    RejectCode { Add-AndroidInventoryModuleMetadata (Clone $report) @($bad.cache) } 'android_inventory_cache_key_mismatch'
}
$duplicate=ModuleCacheFile 'duplicate-cache' 'synthetic module metadata ordinary'
$copy=Clone $report
Add-AndroidInventoryModuleMetadata $copy @($cache,$duplicate.cache)
Check (@($copy.components[1].metadata).Count -eq 2)
[void](ModuleCacheFile 'cache' 'different candidate')
RejectCode { Add-AndroidInventoryModuleMetadata (Clone $report) @($cache) } 'android_inventory_module_ambiguous'

# Prepared metadata never discovers new versions online. The signed-release
# and publisher-provenance boundaries remain false even for exact local bytes.
function PomFixture([string]$Id,[string]$Body) {
    $parts=$Id.Split(':'); $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
    $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant().TrimStart('0')
    $path=Join-Path $root ('prepared-cache/modules-2/files-2.1/'+($parts[1..3] -join '/')+'/'+$sha1+'/'+$parts[2]+'-'+$parts[3]+'.pom')
    [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
    [IO.File]::WriteAllBytes($path,$bytes)
    @{file=$path;name=[IO.Path]::GetFileName($path);size=$bytes.Length;sha256=Get-AndroidInventoryHash $path;role='selected-component-pom'}
}
$runtimeId=$engineNode.id
$runtimePom=PomFixture $runtimeId '<project><parent><groupId>fixture</groupId><artifactId>parent</artifactId><version>1.0</version></parent></project>'
$parentPom=PomFixture 'maven:fixture:parent:1.0' '<project><dependencyManagement><dependencies><dependency><groupId>fixture</groupId><artifactId>bom</artifactId><version>1.0</version><type>pom</type><scope>import</scope></dependency></dependencies></dependencyManagement></project>'
$bomPom=PomFixture 'maven:fixture:bom:1.0' '<project/>'
$preparedGraph=Clone $report
$preparedGraph.components[1].metadata=@($runtimePom)
$source=@{count=6;sha256='d'*64}; $flutterRevision='f'*40
$selectionRecords=@('app/pubspec.yaml','app/pubspec.lock','toolchain.lock.json','flutter/bin/cache/engine.stamp',
    'flutter/bin/internal/engine.version','flutter/bin/cache/engine.realm') | ForEach-Object { @{identity=$_;sha256='c'*64} }
$selectionA=Get-AndroidInventorySelectionSource $selectionRecords
$reverse=@($selectionRecords); [Array]::Reverse($reverse)
Check ($selectionA.sha256 -ceq (Get-AndroidInventorySelectionSource $reverse).sha256)
RejectCode { Get-AndroidInventorySelectionSource (@($selectionRecords)+@($selectionRecords[0])) } 'android_inventory_selection_source_missing'
$seed=@{schema=1;status='PINNED_PREPARED_INPUTS';origin='locally_observed_gradle_inputs';variant='debug';gradleVersion='9.3.1';
    flutterRevision=$flutterRevision;engineRevision=$engine;selectionSource=$source;semanticGraphAlgorithm='exvpn-input-graph-v1';
    semanticGraphSha256=Get-AndroidInventorySemanticHash $preparedGraph;repositoryPolicy='google-mavenCentral-flutter-public-v1';
    runtimeComponents=@(@{id=$runtimeId;pom=@{size=$runtimePom.size;sha256=$runtimePom.sha256};
        artifacts=@($preparedGraph.components[1].artifacts | ForEach-Object { @{name=$_.name;size=$_.size;sha256=$_.sha256} })});
    metadataOnlyComponents=@(@{id='maven:fixture:parent:1.0';pom=@{size=$parentPom.size;sha256=$parentPom.sha256}},
        @{id='maven:fixture:bom:1.0';pom=@{size=$bomPom.size;sha256=$bomPom.sha256}});
    metadataEdges=@(@{from=$runtimeId;to='maven:fixture:parent:1.0';kind='parent'},
        @{from='maven:fixture:parent:1.0';to='maven:fixture:bom:1.0';kind='bom-import'});
    boundaries=@{independentPublisherVerification=$false;apkBindingVerified=$false;licensesReviewed=$false}}
Assert-AndroidInventorySeed $seed debug $engine $flutterRevision $source
Assert-AndroidInventorySeedGraph $seed $preparedGraph
Check $true
$plan=Get-AndroidInventoryPreparedPlan $seed @((Join-Path $root 'prepared-cache'))
Check ($plan.runtimeCount -eq 1 -and $plan.metadataOnlyCount -eq 2 -and $plan.nodes.Count -eq 3 -and $plan.edges.Count -eq 2)
$reordered=Clone $preparedGraph
$reordered.components=@($reordered.components[1],$reordered.components[0])
Check ((Get-AndroidInventorySemanticHash $reordered) -ceq $seed.semanticGraphSha256)
foreach ($mutation in @(
    {param($x) $x.schema='1'}, {param($x) $x.engineRevision=@($x.engineRevision)},
    {param($x) $x.variant='release'}, {param($x) $x.engineRevision='b'*40}, {param($x) $x.flutterRevision='b'*40},
    {param($x) $x.selectionSource.sha256='e'*64}, {param($x) $x.selectionSource.count++},
    {param($x) $x.origin='trusted_publisher'}, {param($x) $x.repositoryPolicy='https://example.invalid'},
    {param($x) $x.extra='unknown'}, {param($x) $x.boundaries.licensesReviewed=$true},
    {param($x) $x.runtimeComponents[0].id='maven:fixture:dynamic:1.+'},
    {param($x) $x.runtimeComponents[0].id='maven:fixture:dynamic:latest'},
    {param($x) $x.runtimeComponents[0].id='maven:io.flutter:flutter_embedding_release:1.0.0-'+('a'*40)},
    {param($x) $x.runtimeComponents[0].artifacts=$null},
    {param($x) $x.runtimeComponents[0].artifacts=@{}},
    {param($x) $x.metadataOnlyComponents=@{}},
    {param($x) $x.metadataOnlyComponents+=$x.metadataOnlyComponents[0]},
    {param($x) $x.metadataOnlyComponents[0].pom.size=8MB+1},
    {param($x) $x.metadataEdges+=@{from='maven:fixture:bom:1.0';to='maven:fixture:parent:1.0';kind='parent'}},
    {param($x) $x.metadataEdges=@()}
)) { $copy=Clone $seed; & $mutation $copy; Reject { Assert-AndroidInventorySeed $copy debug $engine $flutterRevision $source } }
$depthIds=@(0..9 | ForEach-Object { 'maven:fixture:depth:'+$_ })
$depthEdges=@(0..8 | ForEach-Object { @{from=$depthIds[$_];to=$depthIds[$_+1];kind='parent'} })
RejectCode { Assert-AndroidInventoryMetadataEdges $depthIds @($depthIds[0]) $depthEdges } 'android_inventory_metadata_depth_limit'
$copy=Clone $seed; $copy.metadataEdges[0].kind='bom-import'
RejectCode { Get-AndroidInventoryPreparedPlan $copy @((Join-Path $root 'prepared-cache')) } 'android_inventory_metadata_closure_changed'
$copy=Clone $seed; $copy.runtimeComponents[0].pom.sha256='a'*64
RejectCode { Get-AndroidInventoryPreparedPlan $copy @((Join-Path $root 'prepared-cache')) } 'android_inventory_metadata_seed_bytes_mismatch'
foreach ($badXml in @(
    '<project>', '<other/>',
    '<!DOCTYPE project [<!ENTITY ext SYSTEM "file:///must-not-be-read">]><project>&ext;</project>',
    '<project><parent><groupId>fixture</groupId><artifactId>parent</artifactId><version>${parent.version}</version></parent></project>',
    '<project><parent><groupId>fixture</groupId><groupId>second</groupId><artifactId>parent</artifactId><version>1.0</version></parent></project>',
    '<project><profiles><profile><dependencyManagement><dependencies><dependency><scope>import</scope><type>pom</type><groupId>fixture</groupId><artifactId>bom</artifactId><version>1.0</version></dependency></dependencies></dependencyManagement></profile></profiles></project>'
)) { Reject { Get-AndroidInventoryPomEdges ([Text.Encoding]::UTF8.GetBytes($badXml)) $runtimeId } }
foreach ($mutation in @(
    {param($x) $x.components[1].artifacts[0].sha256='e'*64},
    {param($x) $x.components[1].metadata[0].sha256='e'*64},
    {param($x) $x.edges[0].requested.required='9.0'},
    {param($x) $x.components[0].buildFile.sha256='e'*64},
    {param($x) $x.components+=@{kind='maven';id='maven:fixture:extra:1.0'}}
)) { $copy=Clone $preparedGraph; & $mutation $copy; Reject { Assert-AndroidInventorySeedGraph $seed $copy } }
$seedFile=Join-Path $root 'prepared-seed.json'
$seed | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $seedFile -Encoding utf8NoBOM
Assert-AndroidInventorySeed (Read-AndroidInventorySeed $seedFile @($root)) debug $engine $flutterRevision $source
Check $true
[IO.File]::WriteAllText($seedFile,'{"schema":1,"schema":2}')
RejectCode { Read-AndroidInventorySeed $seedFile @($root) } 'android_inventory_seed_duplicate_key'
[IO.File]::WriteAllText($seedFile,'{')
RejectCode { Read-AndroidInventorySeed $seedFile @($root) } 'android_inventory_seed_json_invalid'
$private=Join-Path $root 'prepared-private'
[IO.Directory]::CreateDirectory($private) | Out-Null
$preparedRecords=@(foreach ($node in $plan.nodes) {
    $file=Join-Path $private ([IO.Path]::GetFileName($node.sourceFile))
    Copy-Item -LiteralPath $node.sourceFile -Destination $file
    @{id=$node.id;runtimeSelected=$node.runtimeSelected;resultType='RESOLVED_ARTIFACT_RESULT';file=$file;
        name=[IO.Path]::GetFileName($file);size=$node.pom.size;sha256=$node.pom.sha256}
})
$preparedResult=@{schema=1;status='PREPARED_METADATA_ONLY';success=$true;planSha256='b'*64;runtimeCount=1;metadataOnlyCount=2;
    repositories=@('https://dl.google.com/dl/android/maven2/','https://repo.maven.apache.org/maven2/','https://storage.googleapis.com/download.flutter.io');
    taskGraph=@(':prepareExactPoms');runtimeDependencyGraphCreated=$false;apkBindingVerified=$false;licensesReviewed=$false;records=$preparedRecords}
Assert-AndroidInventoryPreparedResult $preparedResult $plan ('b'*64) $private
Check $true
foreach ($mutation in @(
    {param($x) $x.repositories[0]='https://example.invalid'}, {param($x) $x.records[0].sha256='a'*64},
    {param($x) $x.records[0].id='maven:fixture:extra:1.0'}, {param($x) $x.records[0]=$x.records[1]},
    {param($x) $x.records[0].file=$runtimePom.file}, {param($x) $x.runtimeDependencyGraphCreated=$true},
    {param($x) $x.taskGraph+= ':app:assembleDebug'}
)) { $copy=Clone $preparedResult; & $mutation $copy; Reject { Assert-AndroidInventoryPreparedResult $copy $plan ('b'*64) $private } }
$processArgs=@{GradleDirectory=$root;JavaPath=$root;AndroidSdkPath=$root;PrivateHome=$private;ReadOnlyCache=(Join-Path $root 'prepared-cache');Project=$root;Arguments=@(':app:exvpnRuntimeInventory')}
$offlineStart=New-AndroidInventoryGradleStartInfo @processArgs -Phase offline
Check ($offlineStart.ArgumentList.Contains('--offline') -and $offlineStart.Environment['GRADLE_USER_HOME'] -ceq $private)
RejectCode { New-AndroidInventoryGradleStartInfo @processArgs -Phase preparation } 'android_inventory_metadata_network_not_enabled'
$networkStart=New-AndroidInventoryGradleStartInfo @processArgs -Phase preparation -AllowMetadataNetwork
Check (!$networkStart.ArgumentList.Contains('--offline') -and !$networkStart.Environment.ContainsKey('GRADLE_RO_DEP_CACHE'))
foreach ($key in @('JAVA_OPTS','JDK_JAVA_OPTIONS','GRADLE_OPTS','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS')) { Check (!$offlineStart.Environment.ContainsKey($key)) }
$sleepStart=[Diagnostics.ProcessStartInfo]::new()
$sleepStart.FileName=(Get-Process -Id $PID).Path
$sleepStart.UseShellExecute=$false; $sleepStart.CreateNoWindow=$true
$sleepStart.RedirectStandardOutput=$true; $sleepStart.RedirectStandardError=$true
foreach ($arg in @('-NoProfile','-Command','Start-Sleep -Seconds 30')) { $sleepStart.ArgumentList.Add($arg) }
$bounded=Invoke-AndroidInventoryGradle $sleepStart 'synthetic-timeout' $root -MaximumSeconds 1
Check ($bounded.terminationReason -ceq 'time_limit' -and $bounded.elapsedSeconds -lt 15 -and $bounded.exitCode -ne 0)
$publicSeedPath=Join-Path $PSScriptRoot 'android-runtime-inventory-seed.json'
$publicSeed=Read-AndroidInventorySeed $publicSeedPath @($repository)
Assert-AndroidInventorySeed $publicSeed $publicSeed.variant $publicSeed.engineRevision $publicSeed.flutterRevision $publicSeed.selectionSource
Check ($publicSeed.runtimeComponents.Count -eq 68 -and $publicSeed.metadataOnlyComponents.Count -eq 9)
Check ([IO.File]::ReadAllText($publicSeedPath) -notmatch '[A-Z]:\\|https?://|sourceFile|exceptionMessage|stackTrace')

$gradleCases=@()
if ($WithGradleFixture -or $WithMetadataFixture) {
    $fixtureGradle=@(Get-ChildItem -LiteralPath (Join-Path $repository '.tools/cache/gradle/wrapper/dists/gradle-9.3.1-all') -Directory |
        ForEach-Object { Join-Path $_.FullName 'gradle-9.3.1' } | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'bin/gradle.bat') })
    if ($fixtureGradle.Count -ne 1) { throw 'android_inventory_fixture_gradle_missing' }
    $fixtureJava=if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:/Program Files/Android/Android Studio/jbr' }
    foreach ($case in @('empty-metadata-project','metadata-child','metadata-repository','metadata-configuration')) {
        $caseRoot=Join-Path $root $case
        $metadataProject=Join-Path $caseRoot 'project'
        [IO.Directory]::CreateDirectory($metadataProject) | Out-Null
        $settings="rootProject.name='metadata-fixture'`n"
        $build=''
        $expectedCode=switch ($case) {
            'metadata-child' {
                [IO.Directory]::CreateDirectory((Join-Path $metadataProject 'child')) | Out-Null
                $settings+="include 'child'`n"
                'exvpn_metadata_child_projects_present'
            }
            'metadata-repository' { $build='repositories { mavenCentral() }'; 'exvpn_metadata_repositories_present' }
            'metadata-configuration' { $build='configurations { runtime }'; 'exvpn_metadata_configurations_present' }
            default { 'exvpn_metadata_unexpected_task_graph' }
        }
        [IO.File]::WriteAllText((Join-Path $metadataProject 'settings.gradle'),$settings)
        [IO.File]::WriteAllText((Join-Path $metadataProject 'build.gradle'),$build)
        $planPath=Join-Path $caseRoot 'plan.json'
        $plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $planPath -Encoding utf8NoBOM
        $fixtureHome=Join-Path $root 'metadata-gradle-home'
        $fixtureArguments=@('--project-dir',$metadataProject,'--project-cache-dir',(Join-Path $caseRoot 'project-cache'),
            '--init-script',(Join-Path $PSScriptRoot 'android-runtime-inventory-metadata.init.gradle'),
            '-PexvpnMetadataNetwork=approved-public-poms',"-PexvpnMetadataHome=$fixtureHome","-PexvpnMetadataProject=$metadataProject",
            "-PexvpnMetadataPlan=$planPath",('-PexvpnMetadataPlanSha256='+(Get-AndroidInventoryHash $planPath)),
            ('-PexvpnMetadataOutput='+(Join-Path $caseRoot 'never-query.json')),':help')
        # :help is forbidden by the task-graph guard. This exercises the exact
        # metadata init's project checks without ever executing a network query.
        $start=New-AndroidInventoryGradleStartInfo -Phase preparation -GradleDirectory $fixtureGradle[0] -JavaPath $fixtureJava `
            -AndroidSdkPath $root -PrivateHome $fixtureHome -ReadOnlyCache $root -Project $metadataProject -Arguments $fixtureArguments -AllowMetadataNetwork
        $result=Invoke-AndroidInventoryGradle $start 'metadata-guard' $caseRoot
        $log=[IO.File]::ReadAllText((Join-Path $caseRoot 'metadata-guard-stderr.log'))
        Check ($result.exitCode -ne 0 -and !$result.terminationReason -and $log.Contains($expectedCode,[StringComparison]::Ordinal))
        Check (!(Test-Path -LiteralPath (Join-Path $caseRoot 'never-query.json')))
        $gradleCases+=@{case=$case;exitCode=$result.exitCode;expected=$true;artifactQueryExecuted=$false}
    }
}
if ($WithGradleFixture) {
    $fixture=Join-Path $root 'gradle-fixture'
    $repo=Join-Path $fixture 'repo'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'settings.gradle'),"rootProject.name='inventory-fixture'`ninclude 'app','plugin','integration_test'`nincludeBuild('tooling')`n")
    [IO.File]::WriteAllText((Join-Path $fixture 'build.gradle'),@'
allprojects { repositories { maven { url = uri(rootProject.file('repo')) } } }
if (providers.gradleProperty('fixtureCase').get().startsWith('pin-')) {
    apply from: providers.gradleProperty('exvpnFixturePinScript').get()
}
'@)
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'app')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'plugin')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'integration_test')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'tooling')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'tooling/settings.gradle'),"rootProject.name='inventory-tooling-fixture'`n")
    [IO.File]::WriteAllText((Join-Path $fixture 'tooling/build.gradle'),@'
plugins { id 'java-library' }
group = 'fixture.tooling'
version = '1.0'
gradle.projectsEvaluated {
    file('evaluated.txt').text = 'Composite configured; no build task requested.'
}
'@)
    [IO.File]::WriteAllText((Join-Path $fixture 'app/build.gradle'),@'
configurations {
    implementation { canBeResolved=false; canBeConsumed=false }
    debugRuntimeClasspath { canBeResolved=true; canBeConsumed=false; extendsFrom implementation }
}
def testCase = providers.gradleProperty('fixtureCase').get()
def expected = providers.gradleProperty('exvpnInventoryEngine').get()
dependencies {
    debugRuntimeClasspath project(path: ':plugin', configuration: 'runtimeElements')
    debugRuntimeClasspath "io.flutter:flutter_embedding_debug:1.0.0-${testCase == 'wrong-engine' ? 'b' * 40 : expected}"
    if (testCase == 'dynamic') debugRuntimeClasspath 'fixture:runtime:1.+'
    if (testCase == 'changing') debugRuntimeClasspath('fixture:runtime:1.0') { changing = true }
    if (testCase == 'unresolved') debugRuntimeClasspath 'fixture:missing:1.0'
    if (testCase == 'file') debugRuntimeClasspath files('unknown.jar')
    if (testCase.startsWith('pin-') && testCase != 'pin-absent') debugRuntimeClasspath project(path: ':integration_test', configuration: 'runtimeElements')
    if (testCase == 'pin-conflict') debugRuntimeClasspath('androidx.test:runner:1.4.0') { version { strictly('1.4.0') } }
}
'@)
    [IO.File]::WriteAllText((Join-Path $fixture 'plugin/build.gradle'),"plugins { id 'java-library' }`ndependencies { api 'fixture:runtime:1.0' }`n")
    [IO.File]::WriteAllText((Join-Path $fixture 'integration_test/build.gradle'),@'
plugins { id 'java-library' }
def testCase = providers.gradleProperty('fixtureCase').get()
if (testCase.startsWith('pin-')) {
    dependencies {
        api "androidx.test:runner:${testCase == 'pin-unknown-selector' ? '1.3+' : '1.2+'}"
        api 'androidx.test:rules:1.2+'
        api 'androidx.test.espresso:espresso-core:3.3+'
        api "fixture:runtime:${testCase == 'pin-foreign-module' ? '1.+' : '1.0'}"
    }
}
'@)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($coordinate in @(@('fixture','runtime','1.0'),@('io.flutter','flutter_embedding_debug',"1.0.0-$engine"),@('io.flutter','flutter_embedding_debug',('1.0.0-'+('b'*40))),@('androidx.test','runner','1.3.0'),@('androidx.test','runner','1.4.0'),@('androidx.test','rules','1.2.0'),@('androidx.test.espresso','espresso-core','3.3.0'))) {
        $dir=Join-Path $repo ($coordinate[0].Replace('.','/')+'/'+$coordinate[1]+'/'+$coordinate[2])
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $base=$coordinate[1]+'-'+$coordinate[2]
        [IO.File]::WriteAllText((Join-Path $dir ($base+'.pom')),"<project><modelVersion>4.0.0</modelVersion><groupId>$($coordinate[0])</groupId><artifactId>$($coordinate[1])</artifactId><version>$($coordinate[2])</version></project>")
        $archive=[IO.Compression.ZipFile]::Open((Join-Path $dir ($base+'.jar')),[IO.Compression.ZipArchiveMode]::Create)
        try { [void]$archive.CreateEntry('synthetic-fixture.txt') } finally { $archive.Dispose() }
    }
    [IO.File]::WriteAllText((Join-Path $repo 'fixture/runtime/maven-metadata.xml'),'<metadata><groupId>fixture</groupId><artifactId>runtime</artifactId><versioning><latest>1.0</latest><release>1.0</release><versions><version>1.0</version></versions></versioning></metadata>')
    $gradle=@(Get-ChildItem -LiteralPath (Join-Path $repository '.tools/cache/gradle/wrapper/dists/gradle-9.3.1-all') -Directory | ForEach-Object { Join-Path $_.FullName 'gradle-9.3.1/bin/gradle.bat' } | Where-Object { Test-Path -LiteralPath $_ })
    if ($gradle.Count -ne 1) { throw 'android_inventory_fixture_gradle_missing' }
    $saved=@{}
    foreach ($key in @('JAVA_HOME','GRADLE_USER_HOME','GRADLE_RO_DEP_CACHE','JAVA_OPTS','JDK_JAVA_OPTIONS','GRADLE_OPTS','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
    try {
        if (!$env:JAVA_HOME) { $env:JAVA_HOME='C:/Program Files/Android/Android Studio/jbr' }
        $env:GRADLE_USER_HOME=Join-Path $root 'gradle-home'
        [Environment]::SetEnvironmentVariable('GRADLE_RO_DEP_CACHE',$null,'Process')
        foreach ($key in @('JAVA_OPTS','JDK_JAVA_OPTIONS','GRADLE_OPTS','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS')) { [Environment]::SetEnvironmentVariable($key,$null,'Process') }
        foreach ($case in @('valid','dynamic','changing','unresolved','file','wrong-engine','pin-valid','pin-conflict','pin-unknown-selector','pin-foreign-module','pin-absent','home-mismatch')) {
            $output=Join-Path $root ($case+'.json')
            $expectedHome=if ($case -ceq 'home-mismatch') { Join-Path $root 'incorrect-home' } else { $env:GRADLE_USER_HOME }
            & $gradle[0] '--offline' '--no-daemon' '--no-build-cache' '--no-configuration-cache' '--console=plain' '--max-workers=2' '-Dorg.gradle.jvmargs=-Xmx512m' '--project-dir' $fixture '--project-cache-dir' (Join-Path $root 'project-cache') '--gradle-user-home' $env:GRADLE_USER_HOME '--init-script' (Join-Path $PSScriptRoot 'android-runtime-inventory.init.gradle') "-PfixtureCase=$case" "-PexvpnFixturePinScript=$(Join-Path $repository 'apps/exvpn/android/exvpn-integration-test-pins.gradle.kts')" '-PexvpnInventoryVariant=debug' "-PexvpnInventoryEngine=$engine" "-PexvpnInventoryGradleUserHome=$expectedHome" "-PexvpnInventoryOutput=$output" "-PexvpnInventoryRoot=$root" "-PexvpnInventoryProject=$fixture" ':app:exvpnRuntimeInventory' *> (Join-Path $root ($case+'.log'))
            $exit=$LASTEXITCODE
            if ($case -cin @('valid','pin-valid','pin-absent')) {
                Check ($exit -eq 0)
                $real=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -AsHashtable
                $counts=Assert-AndroidInventoryGraph $real 'debug' $engine -ArtifactRoots @($root) -VerifyBytes
                if ($case -cin @('valid','pin-absent')) {
                    Check ($counts.maven -eq 2 -and $counts.projects -eq 2 -and $counts.edges -ge 3)
                    if ($case -ceq 'pin-absent') { Check (@($real.components | Where-Object { $_.kind -ceq 'maven' -and $_.group -clike 'androidx.test*' }).Count -eq 0) }
                }
                else {
                    foreach ($pin in @(@('androidx.test','runner','1.3.0'),@('androidx.test','rules','1.2.0'),@('androidx.test.espresso','espresso-core','3.3.0'))) {
                        $pinned=@($real.edges | Where-Object { $_.from -ceq 'project::integration_test' -and $_.requested.kind -ceq 'maven' -and $_.requested.group -ceq $pin[0] -and $_.requested.name -ceq $pin[1] })
                        Check ($pinned.Count -eq 1 -and $pinned[0].requested.required -ceq $pin[2] -and $pinned[0].requested.strict -ceq $pin[2] -and $pinned[0].to -ceq ('maven:'+($pin -join ':')))
                    }
                    $untouched=@($real.edges | Where-Object { $_.from -ceq 'project::integration_test' -and $_.requested.kind -ceq 'maven' -and $_.requested.group -ceq 'fixture' -and $_.requested.name -ceq 'runtime' })
                    Check ($untouched.Count -eq 1 -and $untouched[0].requested.required -ceq '1.0' -and $untouched[0].requested.strict -ceq '')
                }
                Check (Test-Path -LiteralPath (Join-Path $fixture 'tooling/evaluated.txt'))
            } else {
                Check ($exit -ne 0)
                if ($case -cin @('home-mismatch','pin-unknown-selector')) {
                    $log=Get-Content -LiteralPath (Join-Path $root ($case+'.log')) -Raw
                    $expectedFailure=if ($case -ceq 'home-mismatch') { 'exvpn_inventory_gradle_user_home_mismatch' } else { 'exvpn_integration_test_dependency_selector_changed' }
                    Check ($log.Contains($expectedFailure,[StringComparison]::Ordinal))
                    $gradleCases+=@{case=$case;exitCode=$exit;expected=$true}
                    continue
                }
                $failedGraph=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -AsHashtable
                $expectedCode=switch ($case) {
                    'file' { 'exvpn_inventory_file_dependency' }
                    'wrong-engine' { 'exvpn_inventory_engine_mismatch' }
                    default { 'exvpn_inventory_unresolved_dependency' }
                }
                Check ($failedGraph.status -ceq 'FAILED' -and $failedGraph.code -ceq $expectedCode)
                if ($case -ceq 'unresolved') {
                    $diagnosticText=Get-Content -LiteralPath ($output+'.unresolved.json') -Raw
                    $diagnostic=$diagnosticText | ConvertFrom-Json -AsHashtable
                    Check ($diagnostic.status -ceq 'FAILED_UNRESOLVED_DEPENDENCIES' -and $diagnostic.offline -eq $true)
                    $missing=@($diagnostic.dependencies | Where-Object { $_.group -ceq 'fixture' -and $_.name -ceq 'missing' })
                    Check ($missing.Count -eq 1 -and $missing[0].selectorType -ceq 'MODULE' -and $missing[0].required -ceq '1.0')
                    Check ($missing[0].failureClass -ceq 'MODULE_NOT_FOUND')
                    Check ($diagnostic.exceptionMessagesIncluded -eq $false -and $diagnostic.repositoryUrlsIncluded -eq $false)
                    Check ($diagnosticText -notmatch 'https?://|file:|stackTrace|exceptionMessage"|repositoryUrl"' -and
                        !$diagnosticText.Contains($root,[StringComparison]::OrdinalIgnoreCase))
                }
                if ($case -ceq 'pin-foreign-module') {
                    $diagnostic=Get-Content -LiteralPath ($output+'.unresolved.json') -Raw | ConvertFrom-Json -AsHashtable
                    $foreign=@($diagnostic.dependencies | Where-Object { $_.group -ceq 'fixture' -and $_.name -ceq 'runtime' -and $_.required -ceq '1.+' })
                    Check ($foreign.Count -eq 1)
                }
            }
            $gradleCases+=@{case=$case;exitCode=$exit;expected=$true}
        }
        # Compile the exact preparation init on Gradle 9.3.1. Default offline
        # mode must reject it before repository creation or artifact queries.
        $metadataStart=New-AndroidInventoryGradleStartInfo -Phase offline -GradleDirectory (Split-Path (Split-Path $gradle[0])) `
            -JavaPath $env:JAVA_HOME -AndroidSdkPath $root -PrivateHome $env:GRADLE_USER_HOME -ReadOnlyCache (Join-Path $root 'unused-ro-cache') `
            -Project $fixture -Arguments @('--project-dir',$fixture,'--project-cache-dir',(Join-Path $root 'project-cache'),
                '--init-script',(Join-Path $PSScriptRoot 'android-runtime-inventory-metadata.init.gradle'),':prepareExactPoms')
        $metadataResult=Invoke-AndroidInventoryGradle $metadataStart 'metadata-offline-rejection' $root
        $metadataLog=[IO.File]::ReadAllText((Join-Path $root 'metadata-offline-rejection-stderr.log'))
        Check ($metadataResult.exitCode -ne 0 -and !$metadataResult.terminationReason -and $metadataLog.Contains('exvpn_metadata_invocation_invalid',[StringComparison]::Ordinal))
        $gradleCases+=@{case='metadata-offline-rejection';exitCode=$metadataResult.exitCode;expected=$true}
        Check (@(Get-ChildItem -LiteralPath $fixture -File -Recurse | Where-Object { $_.Extension -in @('.apk','.aab','.so') -or $_.FullName -like '*\build\libs\*' }).Count -eq 0)
    } finally { foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') } }
}
[ordered]@{schema=1;status='PASS';checks=$checks;gradleCases=$gradleCases;noApplicationBuild=$true} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding utf8NoBOM
Write-Host "Android runtime inventory fixtures: $checks checks passed."
Write-Host "Fixture evidence: $root"
