# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'prepare-demo-maven-notices.ps1') -LibraryOnly
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path $repository ('artifacts/qa/demo-maven-fixture-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$script:checks=0
function Check([bool]$Condition,[string]$Label) {
    if (!$Condition) { throw "demo_maven_test_failed_$Label" }
    $script:checks++
}
function Reject([scriptblock]$Body,[string]$Code) {
    $failed=$false
    try { & $Body | Out-Null } catch {
        $failed=$true
        if ($_.Exception.Message -cne $Code) { throw "demo_maven_unexpected_failure_$($_.Exception.Message)_expected_$Code" }
    }
    Check $failed $Code
}
function Clone($Object) { $Object | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable }
function FixtureFile([string]$Name,[string]$Content) {
    $file=Join-Path $fixture $Name
    [IO.File]::WriteAllText($file,$Content,[Text.UTF8Encoding]::new($false))
    @{file=$file;name=$Name;size=(Get-Item $file).Length;sha256=Get-DemoMavenHash $file}
}
$realRoot=Join-Path $PSScriptRoot 'licenses/android-demo'
$realPolicy=Get-Content -LiteralPath (Join-Path $realRoot 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
Assert-DemoMavenTexts $realPolicy $realRoot
Check ($realPolicy.components.Count -eq 66) 'overinclusive_count'
Check ($realPolicy.files.Count -eq 61) 'fulltext_count'
Check (@($realPolicy.files | Where-Object title -Like '*Protocol Buffers*').Count -eq 1) 'shaded_protobuf_notice'
Check (@($realPolicy.files | Where-Object title -Like '*Checker Framework*').Count -eq 1) 'checker_notice'
$releaseFuture=@($realPolicy.components | Where-Object id -CEQ 'maven:com.google.guava:listenablefuture:1.0')
Check ($releaseFuture.Count -eq 1 -and $releaseFuture[0].pom.sha256 -ceq '53873caf26bc1ed8a567ea6c939ab2aaa3f47a5e32d5cade95ddf5080d23238a' -and
    $releaseFuture[0].artifacts[0].sha256 -ceq 'e4ad7607e5c0477c6f890ef26a49cb8d1bb4dffb650bab4502afee64644e3069') 'actual_release_future_exact_bytes'
Check (@($realPolicy.components | Where-Object id -CEQ 'maven:com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava').Count -eq 1) 'empty_conflict_variant_retained_separately'
$futureText=(@($releaseFuture[0].texts | ForEach-Object { [IO.File]::ReadAllText((Join-Path $realRoot $_)) }) -join "`n")
Check ($futureText.Contains('Copyright (C) 2007 The Guava Authors') -and $futureText.Contains('TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION')) 'release_future_copyright_and_full_apache_text'
$pom=FixtureFile 'library-1.0.pom' '<project><artifactId>library</artifactId><version>1.0</version></project>'
$jar=FixtureFile 'library-1.0.jar' 'synthetic artifact bytes'
$engine='deb287481e3ce9468f3434937ced4240a70539ca'
$pin=@{id='maven:example:library:1.0';pom=@{size=$pom.size;sha256=$pom.sha256};
    artifacts=@(@{name=$jar.name;size=$jar.size;sha256=$jar.sha256});texts=@()}
$policy=@{schema=1;status='PINNED_OVERINCLUSIVE_LICENSE_TEXTS';appVersion='0.1.0+18';engineRevision=$engine;components=@($pin);files=@()}
$components=@(@{id=$pin.id;pom=$pom;artifacts=@($jar)})
foreach($name in @('flutter_embedding_release','arm64_v8a_release','x86_64_release')) {
    $components+=@{id="maven:io.flutter:${name}:1.0.0-$engine";
        pom=(FixtureFile "$name-1.0.0-$engine.pom" '<project>synthetic</project>');
        artifacts=@((FixtureFile "$name-1.0.0-$engine.jar" 'synthetic engine artifact'))}
}
$graph=@{schema=1;status='RESOLVED_DEMO_RELEASE_INPUTS';variant='release';configuration='releaseRuntimeClasspath';
    gradleVersion='9.3.1';projectComponentCount=2;components=$components;postR8InventoryComplete=$false}
$result=Get-DemoMavenVerifiedGraph $graph $policy
Check ($result.components.Count -eq 4) 'graph_count'
Check (!$result.postR8InventoryComplete) 'no_final_link_claim'
$json=$result | ConvertTo-Json -Depth 30
Check (!$json.Contains($fixture)) 'absolute_paths_redacted'
Check (@($result.components | Where-Object coverage -CEQ 'pinned-full-text-supplements').Count -eq 1) 'separate_flutter_coverage'

$ordinaryPolicy = Get-DemoMavenRuntimePolicy $policy $repository 'ordinary'
Check ($ordinaryPolicy.engineRevision -ceq $engine) 'ordinary_engine_unchanged'
$shorebirdPolicy = Get-DemoMavenRuntimePolicy $policy $repository 'shorebird'
Check ($shorebirdPolicy.engineRevision -ceq '4b936a0c03e13389ddfb1ac48823f187964975c2') 'shorebird_exact_engine'
Check ($policy.engineRevision -ceq $engine) 'source_policy_not_mutated'
$shorebirdGraph = Clone $graph
foreach ($component in $shorebirdGraph.components) {
    if (!$component.id.StartsWith('maven:io.flutter:')) { continue }
    $component.id = $component.id.Replace($engine, $shorebirdPolicy.engineRevision)
    $component.pom = FixtureFile ($component.pom.name.Replace($engine, $shorebirdPolicy.engineRevision)) '<project>synthetic Shorebird</project>'
    $component.artifacts = @((FixtureFile ($component.artifacts[0].name.Replace($engine, $shorebirdPolicy.engineRevision)) 'synthetic Shorebird engine'))
}
$shorebirdResult = Get-DemoMavenVerifiedGraph $shorebirdGraph $shorebirdPolicy
Check ($shorebirdResult.components.Count -eq 4 -and !$shorebirdResult.postR8InventoryComplete) 'shorebird_no_final_link_claim'
Reject { Get-DemoMavenVerifiedGraph $shorebirdGraph $ordinaryPolicy } 'demo_maven_flutter_component_invalid'
Reject { Get-DemoMavenVerifiedGraph $graph $shorebirdPolicy } 'demo_maven_flutter_component_invalid'
Reject { Get-DemoMavenRuntimePolicy $policy $repository 'future' } 'demo_maven_runtime_invalid'
$badShorebirdGraph = Clone $shorebirdGraph
$badShorebirdGraph.components[0].id = 'maven:uncovered:library:1.0'
Reject { Get-DemoMavenVerifiedGraph $badShorebirdGraph $shorebirdPolicy } 'demo_maven_component_not_covered'
$fakeRepository = Join-Path $fixture 'wrong-sdk-pin'
[IO.Directory]::CreateDirectory((Join-Path $fakeRepository 'scripts/bootstrap')) | Out-Null
[IO.File]::WriteAllText((Join-Path $fakeRepository 'scripts/bootstrap/shorebird.lock.json'), '{"schemaVersion":1,"cli":{"version":"1.6.129"},"flutter":{"revision":"5bef02a16146a0effc07da4acccaafe90a2739ce","engineRevision":"0000000000000000000000000000000000000000"}}')
Reject { Get-DemoMavenRuntimePolicy $policy $fakeRepository 'shorebird' } 'demo_maven_shorebird_pin_invalid'

$bad=Clone $graph; $bad.variant='debug'
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_graph_invalid'
$bad=Clone $graph; $bad.postR8InventoryComplete=$true
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_graph_invalid'
$bad=Clone $graph; $bad.gradleVersion='9.4'
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_graph_invalid'
$bad=Clone $graph; $bad.components+=Clone $bad.components[0]
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_component_invalid'
$bad=Clone $graph; $bad.components[0].id='maven:uncovered:library:1.0'
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_component_not_covered'
$bad=Clone $graph; $bad.components[0].id='maven:example:library:1.+'
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_component_invalid'
$bad=Clone $graph; $bad.components[0].artifacts=@()
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_binary_missing'
$bad=Clone $graph; $bad.components[0].artifacts+=Clone $bad.components[0].artifacts[0]
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_artifact_invalid'
$bad=Clone $graph; $bad.components[0].artifacts[0].file=Join-Path $fixture 'missing.jar'
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_input_missing'
$bad=Clone $graph; $bad.components[0].pom.name='other.pom'
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_pom_name_invalid'
$bad=Clone $graph; $bad.components=@($bad.components | Select-Object -SkipLast 1)
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_flutter_component_missing'
$bad=Clone $graph; $bad.components[1].id=$bad.components[1].id.Replace('flutter_embedding_release','flutter_embedding_debug')
$bad.components[1].pom.name=$bad.components[1].pom.name.Replace('flutter_embedding_release','flutter_embedding_debug')
# POM filename/path must match before any runtime exception is considered.
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_input_changed'
$original=[IO.File]::ReadAllBytes($jar.file)
[IO.File]::WriteAllText($jar.file,'tampered artifact')
Reject { Get-DemoMavenVerifiedGraph $graph $policy } 'demo_maven_input_changed'
$bad=Clone $graph; $bad.components[0].artifacts[0].size=(Get-Item $jar.file).Length
$bad.components[0].artifacts[0].sha256=Get-DemoMavenHash $jar.file
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_artifact_not_pinned'
[IO.File]::WriteAllBytes($jar.file,$original)
$original=[IO.File]::ReadAllBytes($pom.file)
[IO.File]::WriteAllText($pom.file,'<project>changed</project>')
Reject { Get-DemoMavenVerifiedGraph $graph $policy } 'demo_maven_input_changed'
$bad=Clone $graph; $bad.components[0].pom.size=(Get-Item $pom.file).Length
$bad.components[0].pom.sha256=Get-DemoMavenHash $pom.file
Reject { Get-DemoMavenVerifiedGraph $bad $policy } 'demo_maven_pom_not_pinned'
[IO.File]::WriteAllBytes($pom.file,$original)

$textRoot=Join-Path $fixture 'licenses'; [IO.Directory]::CreateDirectory((Join-Path $textRoot 'texts')) | Out-Null
$textBytes=[Text.Encoding]::UTF8.GetBytes('synthetic full license text')
$textHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($textBytes)).ToLowerInvariant()
$textPath="texts/$textHash.txt"
[IO.File]::WriteAllBytes((Join-Path $textRoot $textPath),$textBytes)
$policy.components[0].texts=@($textPath)
$policy.files=@(@{path=$textPath;sha256=$textHash;size=$textBytes.Length})
Assert-DemoMavenTexts $policy $textRoot; $script:checks++
$bad=Clone $policy; $bad.components[0].texts=@('texts/missing.txt')
Reject { Assert-DemoMavenTexts $bad $textRoot } 'demo_maven_license_missing'
$bad=Clone $policy; $bad.files[0].path='../escape.txt'
Reject { Assert-DemoMavenTexts $bad $textRoot } 'demo_maven_text_path_invalid'
[IO.File]::WriteAllText((Join-Path $textRoot $textPath),'tampered license')
Reject { Assert-DemoMavenTexts $policy $textRoot } 'demo_maven_input_changed'
Remove-Item -LiteralPath (Join-Path $textRoot $textPath)
Reject { Assert-DemoMavenTexts $policy $textRoot } 'demo_maven_input_missing'
Write-Host ("Demo Maven notices: $script:checks focused checks passed.")
