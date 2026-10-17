# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('debug','release')][string]$Variant='debug',
    [string]$Repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')),
    [string]$OutputDirectory='',
    [string]$PrepareMetadataFrom='',
    [string]$AndroidSdkPath=$(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }),
    [string]$JavaPath=$(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:/Program Files/Android/Android Studio/jbr' })
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'android-runtime-inventory-lib.ps1')
. (Join-Path $PSScriptRoot 'android-runtime-inventory-preparation.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
$Repository=[IO.Path]::GetFullPath($Repository)
$qaRoot=Join-Path $Repository 'artifacts/qa'
if (!$OutputDirectory) { $OutputDirectory=Join-Path $qaRoot ('android-runtime-inventory-'+[guid]::NewGuid().ToString('N')) }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if (!$OutputDirectory.StartsWith($qaRoot.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $OutputDirectory)) { throw 'android_inventory_output_not_fresh_or_outside_qa' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
[void](Assert-AndroidInventoryPath $OutputDirectory @($qaRoot))
$sourceInputs=[Collections.Generic.List[object]]::new()
$snapshotInputs=[Collections.Generic.List[object]]::new()
$sourceTrees=[Collections.Generic.List[object]]::new()
$snapshotTreeDefinitions=[Collections.Generic.List[object]]::new()
$relocations=[Collections.Generic.List[object]]::new()
$pluginInputs=[Collections.Generic.List[object]]::new()
$prepared=$null; $preparationRun=$null; $seed=$null; $seedHash=$null
$phase='snapshot'
$watch=[Diagnostics.Stopwatch]::StartNew()

function Add-SourceInput([string]$Identity,[string]$Path) {
    $path=Assert-AndroidInventoryPath $Path @($Repository)
    $record=[ordered]@{identity=$Identity;file=$path;sha256=Get-AndroidInventoryHash $path;size=(Get-Item -LiteralPath $path).Length}
    $sourceInputs.Add($record)
    $record
}
function Copy-SourceFile([string]$Identity,[string]$Source,[string]$Destination) {
    $record=Add-SourceInput $Identity $Source
    [IO.Directory]::CreateDirectory((Split-Path $Destination)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination
    if ((Get-AndroidInventoryHash $Destination) -cne $record.sha256) { throw 'android_inventory_snapshot_copy_changed' }
    $snapshotInputs.Add([ordered]@{identity=$Identity;file=$Destination;sha256=$record.sha256})
}
function Copy-SourceTree([string]$Identity,[string]$Source,[string]$Destination) {
    [void](Assert-AndroidInventoryPath (Join-Path $Source 'pubspec.yaml') @($Repository))
    foreach ($file in Record-SourceTree $Identity $Source $Destination) {
        Copy-SourceFile "$Identity/$($file.relative)" $file.file (Join-Path $Destination $file.relative)
    }
}
function Record-SourceTree([string]$Identity,[string]$Source,[string]$Destination,[string[]]$ExcludedRelativePaths=@()) {
    $tree=Get-AndroidInventoryTreeSnapshot $Identity $Source $ExcludedRelativePaths
    $sourceTrees.Add($tree)
    $snapshotTreeDefinitions.Add(@{identity=$Identity;root=$Destination;excludedRelativePaths=@($ExcludedRelativePaths)})
    @($tree.files)
}
function Assert-InputsUnchanged($Records) {
    foreach ($record in $Records) {
        if (!(Test-Path -LiteralPath $record.file -PathType Leaf) -or
            (Get-AndroidInventoryHash $record.file) -cne $record.sha256) { throw 'android_inventory_inputs_changed' }
    }
}

try {
    $app=Join-Path $Repository 'apps/exvpn'
    $flutter=Join-Path $Repository '.tools/flutter'
    $pinsPath=Join-Path $Repository 'scripts/bootstrap/toolchain.lock.json'
    $pins=Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json -AsHashtable
    [void](Add-SourceInput 'toolchain.lock.json' $pinsPath)
    $flutterCommit=(& git -C $flutter rev-parse HEAD) -join ''
    if ($LASTEXITCODE -ne 0 -or $flutterCommit -cne $pins.flutter.revision) { throw 'android_inventory_flutter_revision_mismatch' }
    $enginePath=Join-Path $flutter 'bin/cache/engine.stamp'
    $engine=[IO.File]::ReadAllText($enginePath).Trim()
    if ($engine -cnotmatch '^[a-f0-9]{40}$' -or
        [IO.File]::ReadAllText((Join-Path $flutter 'bin/internal/engine.version')).Trim() -cne $engine) { throw 'android_inventory_engine_stamp_mismatch' }
    foreach ($relative in @('bin/cache/engine.stamp','bin/internal/engine.version','bin/cache/engine.realm')) {
        [void](Add-SourceInput "flutter/$relative" (Join-Path $flutter $relative))
    }
    if ([IO.File]::ReadAllText((Join-Path $flutter 'bin/cache/engine.realm')).Trim()) { throw 'android_inventory_custom_engine_realm' }
    foreach ($name in @('android-runtime-inventory.ps1','android-runtime-inventory-lib.ps1','android-runtime-inventory.init.gradle',
        'android-runtime-inventory-preparation.ps1','android-runtime-inventory-metadata.init.gradle','notice-inputs.ps1')) {
        [void](Add-SourceInput "collector/$name" (Join-Path $PSScriptRoot $name))
    }
    $wrapperProperties=Join-Path $app 'android/gradle/wrapper/gradle-wrapper.properties'
    $wrapperText=[IO.File]::ReadAllText($wrapperProperties)
    if (@([regex]::Matches($wrapperText,'(?m)^distributionUrl=https\\://services\.gradle\.org/distributions/gradle-9\.3\.1-all\.zip\r?$')).Count -ne 1) {
        throw 'android_inventory_gradle_pin_mismatch'
    }
    $distributions=@(Get-ChildItem -LiteralPath (Join-Path $Repository '.tools/cache/gradle/wrapper/dists/gradle-9.3.1-all') -Directory |
        ForEach-Object { Join-Path $_.FullName 'gradle-9.3.1/bin/gradle.bat' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($distributions.Count -ne 1) { throw 'android_inventory_gradle_distribution_ambiguous' }
    $gradle=$distributions[0]
    $gradleDirectory=Split-Path (Split-Path $gradle)
    [void](Add-SourceInput 'tooling/gradle.bat' $gradle)
    [void](Add-SourceInput 'tooling/gradle-launcher.jar' (Join-Path (Split-Path (Split-Path $gradle)) 'lib/gradle-launcher-9.3.1.jar'))
    foreach ($name in @('gradle-gradle-cli-main-9.3.1.jar','agents/gradle-instrumentation-agent-9.3.1.jar')) {
        [void](Add-SourceInput ('tooling/'+$name) (Join-Path $gradleDirectory ('lib/'+$name)))
    }
    if (!(Test-Path -LiteralPath (Join-Path $JavaPath 'bin/java.exe') -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $AndroidSdkPath 'platforms/android-36/android.jar') -PathType Leaf)) {
        throw 'android_inventory_required_sdk_missing'
    }
    $appSnapshot=Join-Path $OutputDirectory 'snapshot/apps/exvpn'
    $android=Join-Path $appSnapshot 'android'
    # Copy current bytes, including uncommitted inputs, not a different Git ref.
    foreach ($file in Record-SourceTree 'app/android' (Join-Path $app 'android') $android @('local.properties','gradlew','gradlew.bat','gradle/wrapper/gradle-wrapper.jar')) {
        Copy-SourceFile "app/android/$($file.relative)" $file.file (Join-Path $android $file.relative)
    }
    foreach ($relative in @('pubspec.yaml','pubspec.lock','.flutter-plugins-dependencies','.dart_tool/package_config.json')) {
        Copy-SourceFile "app/$relative" (Join-Path $app $relative) (Join-Path $appSnapshot $relative)
    }
    $lock=[IO.File]::ReadAllText((Join-Path $app 'pubspec.lock'))
    $resolved=@(Get-NoticeDartInputs $Repository $lock (Join-Path $app '.dart_tool/package_config.json'))
    $plugins=Get-Content -LiteralPath (Join-Path $app '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json -AsHashtable
    $pluginNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($plugin in $plugins.plugins.android) {
        if ($plugin.name -cnotmatch '^[a-z][a-z0-9_]{0,99}$' -or !$pluginNames.Add($plugin.name)) { throw 'android_inventory_plugin_invalid' }
        $pluginSource=[IO.Path]::GetFullPath($plugin.path).TrimEnd('\','/')
        $hosted=@($resolved | Where-Object { $_.name -ceq $plugin.name })
        if ($hosted.Count -eq 1 -and $pluginSource -ieq $hosted[0].root) {
            $pin=[ordered]@{kind='pub';version=$hosted[0].version;archiveSha256=$hosted[0].archiveSha256}
        } elseif ($plugin.name -ceq 'integration_test' -and $pluginSource -ieq (Join-Path $flutter 'packages/integration_test')) {
            $pin=[ordered]@{kind='flutter-sdk';revision=$flutterCommit}
        } else { throw 'android_inventory_plugin_source_unpinned' }
        $destination=Join-Path $OutputDirectory ('snapshot/plugins/'+$plugin.name)
        Copy-SourceTree ('plugin/'+$plugin.name) $pluginSource $destination
        $pluginInputs.Add([ordered]@{name=$plugin.name;sourcePin=$pin;developmentDependency=$plugin.dev_dependency;nativeBuild=$plugin.native_build})
        $plugin.path=$destination.Replace('\','/')+'/'
        $relocations.Add([ordered]@{kind='plugin-root';name=$plugin.name;meaning='same source bytes, isolated project/cache/build paths'})
    }
    $plugins | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $appSnapshot '.flutter-plugins-dependencies') -Encoding utf8NoBOM
    # Rebase relative package URIs without running pub or changing a lockfile.
    $packageConfig=Get-Content -LiteralPath (Join-Path $app '.dart_tool/package_config.json') -Raw | ConvertFrom-Json -AsHashtable
    $configUri=[Uri]::new((Join-Path $app '.dart_tool/package_config.json'))
    foreach ($package in $packageConfig.packages) { $package.rootUri=([Uri]::new($configUri,$package.rootUri)).AbsoluteUri }
    $packageConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $appSnapshot '.dart_tool/package_config.json') -Encoding utf8NoBOM
    $relocations.Add([ordered]@{kind='package-uris';meaning='relative URIs rebased to the same original files; no Dart compilation'})
    # The included build compiles Flutter's Gradle plugin even for resolution.
    # Isolate those tool outputs too; never write into the shared Flutter SDK.
    $gradlePluginSource=Join-Path $flutter 'packages/flutter_tools/gradle'
    $gradlePluginSnapshot=Join-Path $OutputDirectory 'snapshot/flutter-gradle-plugin'
    foreach ($file in Record-SourceTree 'flutter-gradle' $gradlePluginSource $gradlePluginSnapshot) {
        Copy-SourceFile "flutter-gradle/$($file.relative)" $file.file (Join-Path $gradlePluginSnapshot $file.relative)
    }
    $settings=Join-Path $android 'settings.gradle.kts'
    $settingsText=[IO.File]::ReadAllText($settings)
    $include='includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")'
    if (($settingsText.Split(@($include),[StringSplitOptions]::None)).Length -ne 2) { throw 'android_inventory_flutter_include_unsupported' }
    $replacement='includeBuild("'+$gradlePluginSnapshot.Replace('\','/')+'")'
    [IO.File]::WriteAllText($settings,$settingsText.Replace($include,$replacement),[Text.UTF8Encoding]::new($false))
    $relocations.Add([ordered]@{kind='flutter-gradle-included-build';meaning='exact pinned plugin sources copied; include path only changed'})
    $appVersion=[regex]::Match([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml')),'(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (!$appVersion.Success) { throw 'android_inventory_app_version_invalid' }
    [IO.File]::WriteAllLines((Join-Path $android 'local.properties'),@(
        ('sdk.dir='+[IO.Path]::GetFullPath($AndroidSdkPath).Replace('\','/')),
        ('flutter.sdk='+$flutter.Replace('\','/')),
        ('flutter.buildMode='+$Variant),
        ('flutter.versionName='+$appVersion.Groups[1].Value),
        ('flutter.versionCode='+$appVersion.Groups[2].Value)
    ),[Text.UTF8Encoding]::new($false))
    # Record the explicit relocation outputs separately from original source.
    foreach ($record in $snapshotInputs) { $record.sha256=Get-AndroidInventoryHash $record.file }
    $snapshotInputs.Add([ordered]@{identity='generated/local.properties';file=(Join-Path $android 'local.properties');sha256=Get-AndroidInventoryHash (Join-Path $android 'local.properties')})
    $selectionSource=Get-AndroidInventorySelectionSource $sourceInputs
    $readOnlyCache=Join-Path $Repository '.tools/cache/gradle/caches'
    $privateHome=Join-Path $OutputDirectory 'gradle-user-home'
    if (Test-Path -LiteralPath $privateHome) { throw 'android_inventory_private_cache_not_empty' }
    if ($PrepareMetadataFrom) {
        $phase='metadata-plan'
        $seedPath=Assert-AndroidInventoryPath $PrepareMetadataFrom @($Repository)
        $seedHash=(Add-SourceInput 'preparation/seed' $seedPath).sha256
        $seed=Read-AndroidInventorySeed $seedPath @($Repository)
        Assert-AndroidInventorySeed $seed $Variant $engine $flutterCommit $selectionSource
        $plan=Get-AndroidInventoryPreparedPlan $seed @($readOnlyCache)
        foreach ($node in $plan.nodes) { [void](Add-SourceInput ('preparation/'+$node.id) $node.sourceFile) }
        $planPath=Join-Path $OutputDirectory 'metadata-plan.json'
        $plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $planPath -Encoding utf8NoBOM
        $planHash=Get-AndroidInventoryHash $planPath
        $snapshotInputs.Add(@{identity='generated/metadata-plan';file=$planPath;sha256=$planHash})
        $metadataProject=Join-Path $OutputDirectory 'metadata-project'
        [IO.Directory]::CreateDirectory($metadataProject) | Out-Null
        [IO.File]::WriteAllText((Join-Path $metadataProject 'settings.gradle'),"rootProject.name = 'exvpn-metadata-only'`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $metadataProject 'build.gradle'),"// No plugins, dependencies or application build tasks.`n",[Text.UTF8Encoding]::new($false))
        $snapshotTreeDefinitions.Add(@{identity='generated/metadata-project';root=$metadataProject;excludedRelativePaths=@()})
    }
    $inputFingerprint=Get-AndroidInventoryFingerprint $sourceInputs
    $snapshotFingerprint=Get-AndroidInventoryFingerprint $snapshotInputs
    $snapshotTrees=@(foreach ($tree in $snapshotTreeDefinitions) {
        Get-AndroidInventoryTreeSnapshot $tree.identity $tree.root $tree.excludedRelativePaths
    })
    $sourceInputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'source-inputs.json') -Encoding utf8NoBOM
    $snapshotInputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'snapshot-inputs.json') -Encoding utf8NoBOM
    $sourceTrees | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'source-trees.json') -Encoding utf8NoBOM
    $snapshotTrees | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'snapshot-trees.json') -Encoding utf8NoBOM
    function Assert-AllInputsUnchanged {
        Assert-InputsUnchanged $sourceInputs
        Assert-InputsUnchanged $snapshotInputs
        foreach ($tree in @($sourceTrees)+@($snapshotTrees)) { Assert-AndroidInventoryTreeUnchanged $tree }
    }
    Assert-AllInputsUnchanged
    $baseProcess=@{GradleDirectory=$gradleDirectory;JavaPath=[IO.Path]::GetFullPath($JavaPath);
        AndroidSdkPath=[IO.Path]::GetFullPath($AndroidSdkPath);PrivateHome=$privateHome;ReadOnlyCache=$readOnlyCache}
    if ($PrepareMetadataFrom) {
        $phase='preparation'
        $preparedPath=Join-Path $OutputDirectory 'prepared-poms.json'
        $prepareArgs=@('--project-dir',$metadataProject,'--project-cache-dir',(Join-Path $OutputDirectory 'metadata-project-cache'),
            '--init-script',(Join-Path $PSScriptRoot 'android-runtime-inventory-metadata.init.gradle'),
            '-Dorg.gradle.internal.http.connectionTimeout=15000','-Dorg.gradle.internal.http.socketTimeout=15000',
            '-PexvpnMetadataNetwork=approved-public-poms',"-PexvpnMetadataHome=$privateHome","-PexvpnMetadataProject=$metadataProject",
            "-PexvpnMetadataPlan=$planPath","-PexvpnMetadataPlanSha256=$planHash","-PexvpnMetadataOutput=$preparedPath",':prepareExactPoms')
        $start=New-AndroidInventoryGradleStartInfo @baseProcess -Phase preparation -Project $metadataProject -Arguments $prepareArgs -AllowMetadataNetwork
        Write-Host 'Preparing pinned public POM metadata in a fresh private cache (maximum 180 seconds).'
        $preparationRun=Invoke-AndroidInventoryGradle $start preparation $OutputDirectory
        Assert-AllInputsUnchanged
        if ($preparationRun.exitCode -ne 0 -or $preparationRun.terminationReason -or !(Test-Path -LiteralPath $preparedPath)) {
            throw 'android_inventory_metadata_preparation_failed'
        }
        $prepared=Get-Content -LiteralPath $preparedPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-AndroidInventoryPreparedResult $prepared $plan $planHash $privateHome
    }
    $phase='offline'
    $rawOutput=Join-Path $OutputDirectory 'resolved-graph.json'
    $init=Join-Path $PSScriptRoot 'android-runtime-inventory.init.gradle'
    $arguments=@('--project-cache-dir',(Join-Path $OutputDirectory 'project-cache'),
        '--project-dir',$android,'--init-script',$init,
        '-Ptarget-platform=android-arm64,android-x64',
        "-PexvpnInventoryVariant=$Variant","-PexvpnInventoryEngine=$engine",
        "-PexvpnInventoryGradleUserHome=$privateHome",
        "-PexvpnInventoryRoot=$OutputDirectory","-PexvpnInventoryProject=$android","-PexvpnInventoryOutput=$rawOutput",
        ':app:exvpnRuntimeInventory')
    $start=New-AndroidInventoryGradleStartInfo @baseProcess -Phase offline -Project $android -Arguments $arguments
    Write-Host 'Running independent strict offline input graph verification (maximum 180 seconds).'
    $offlineRun=Invoke-AndroidInventoryGradle $start offline $OutputDirectory
    Assert-AllInputsUnchanged
    if ($offlineRun.exitCode -ne 0 -or $offlineRun.terminationReason -or !(Test-Path -LiteralPath $rawOutput)) { throw 'android_inventory_gradle_resolution_failed' }
    $graph=Get-Content -LiteralPath $rawOutput -Raw | ConvertFrom-Json -AsHashtable
    $roots=@((Join-Path $Repository '.tools/cache/gradle/caches'),$OutputDirectory)
    [void](Assert-AndroidInventoryGraph $graph $Variant $engine -ArtifactRoots $roots -VerifyBytes)
    Add-AndroidInventoryModuleMetadata $graph @($roots[0],(Join-Path $privateHome 'caches'))
    $counts=Assert-AndroidInventoryGraph $graph $Variant $engine -ArtifactRoots $roots -VerifyBytes
    if ($seed) { Assert-AndroidInventorySeedGraph $seed $graph }
    $dependencyFiles=@(foreach ($node in $graph.components) {
        foreach ($file in @($node.artifacts)+@($node.metadata)) { [ordered]@{identity=$node.id+'/'+$file.role+'/'+$file.name;sha256=$file.sha256} }
        if ($node.kind -ceq 'project') { [ordered]@{identity=$node.id+'/build-script';sha256=$node.buildFile.sha256} }
    })
    $result=[ordered]@{schema=1;status='COLLECTED_INCOMPLETE';variant=$Variant;
        appVersion=($appVersion.Groups[1].Value+'+'+$appVersion.Groups[2].Value);
        sourceFingerprint=$inputFingerprint;snapshotFingerprint=$snapshotFingerprint;sourceInputsUnchanged=$true;
        sourceTreeMembershipUnchanged=$true;snapshotTreeMembershipUnchanged=$true;
        selectionSource=$selectionSource;preparedInputWorkflow=[bool]$PrepareMetadataFrom;seedSha256=$seedHash;
        privateCacheInitiallyEmpty=$true;preparation=$preparationRun;offline=$offlineRun;
        semanticGraphSha256=Get-AndroidInventorySemanticHash $graph;
        dependencyFingerprint=Get-AndroidInventoryFingerprint $dependencyFiles;
        flutter=[ordered]@{version=$pins.flutter.version;revision=$flutterCommit;engineRevision=$engine};
        plugins=@($pluginInputs);relocations=@($relocations);counts=$counts;graph=$graph;
        elapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);observedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');
        limitations=@('Resolved runtime inputs are not an exact linked-code inventory.',
            'No APK, JNI, project plugin AAR, or application code was built.',
            'POM/module descriptors are not reviewed licenses; module cache availability does not prove internal metadata selection.',
            'Artifact hashes identify bytes observed locally, not independent publisher verification.',
            'APK binding, complete license obligations, release signing, and runtime acceptance remain open.')}
    $result | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'inventory.json') -Encoding utf8NoBOM
    Write-Host "Android runtime inputs: $($counts.maven) Maven components, $($counts.projects) projects, $($counts.edges) edges. APK/license checks remain incomplete."
    Write-Host "Inventory evidence: $OutputDirectory"
} catch {
    $code=if ($_.Exception.Message -cmatch '^(android_inventory_[a-z_]+)$') { $Matches[1] } else { 'android_inventory_collection_failed' }
    [ordered]@{schema=1;status='FAILED';code=$code;phase=$phase;variant=$Variant;apkBindingVerified=$false;licensesReviewed=$false} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'failure.json') -Encoding utf8NoBOM
    throw $code
} finally {
    $watch.Stop()
}
