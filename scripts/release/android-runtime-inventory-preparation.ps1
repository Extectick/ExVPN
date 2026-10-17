# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Prepared inputs are a reviewed local baseline, not publisher authentication.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')

function Get-AndroidInventoryStorageOrigin([string]$FlutterRuntime='ordinary') {
    switch -CaseSensitive ($FlutterRuntime) {
        ordinary { 'https://storage.googleapis.com' }
        shorebird { 'https://download.shorebird.dev' }
        default { throw 'android_inventory_runtime_selector_invalid' }
    }
}

function Assert-AndroidInventoryRuntimeRequest([string]$FlutterRuntime,[string]$Variant,[switch]$PrepareMetadata) {
    [void](Get-AndroidInventoryStorageOrigin $FlutterRuntime)
    if ($Variant -cnotin @('debug','release')) { throw 'android_inventory_runtime_variant_invalid' }
    if ($FlutterRuntime -ceq 'shorebird') {
        # The existing prepared-POM policy is ordinary-only. Fail before any
        # output/cache creation or process; never query the wrong repository.
        if ($PrepareMetadata) { throw 'android_inventory_shorebird_prepared_metadata_unsupported' }
        if ($Variant -cne 'release') { throw 'android_inventory_shorebird_release_required' }
    }
}

function Get-AndroidInventoryFlutterRuntime([string]$Repository,[string]$FlutterRuntime='ordinary',[string]$Variant='debug') {
    Assert-AndroidInventoryRuntimeRequest $FlutterRuntime $Variant
    $runtime=Get-ReleaseFlutterRuntime -Repository $Repository -Target Android -FlutterRuntime $FlutterRuntime -FlutterBuildMode $Variant
    $realmPath=Join-Path $runtime.SdkRoot 'bin/cache/engine.realm'
    Assert-AuditNoLinks $realmPath
    if ([IO.File]::ReadAllText($realmPath).Trim()) { throw 'android_inventory_custom_engine_realm' }
    $runtime
}

function ConvertTo-AndroidInventoryCanonicalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [Collections.IDictionary]) {
        $keys=[string[]]@($Value.Keys)
        [Array]::Sort($keys,[StringComparer]::Ordinal)
        $parts=@(foreach ($key in $keys) { (ConvertTo-Json $key -Compress)+':'+(ConvertTo-AndroidInventoryCanonicalJson $Value[$key]) })
        return '{'+($parts -join ',')+'}'
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return '['+(@(foreach ($item in $Value) { ConvertTo-AndroidInventoryCanonicalJson $item }) -join ',')+']'
    }
    ConvertTo-Json $Value -Compress -Depth 5
}

function Sort-AndroidInventoryCanonical($Items) {
    $strings=[string[]]@(foreach ($item in $Items) { ConvertTo-AndroidInventoryCanonicalJson $item })
    [Array]::Sort($strings,[StringComparer]::Ordinal)
    foreach ($text in $strings) { ConvertFrom-Json $text -AsHashtable -Depth 64 }
}

function Get-AndroidInventorySemanticHash($Graph) {
    # Paths, timestamps and candidate .module descriptors do not describe the
    # selected runtime graph. Variants, requested selectors and bytes do.
    $nodes=@(foreach ($node in $Graph.components) {
        $item=[ordered]@{id=$node.id;kind=$node.kind;variants=@($node.variants)}
        if ($node.kind -ceq 'maven') {
            $item.artifacts=@(foreach ($file in $node.artifacts) {
                [ordered]@{name=$file.name;size=$file.size;sha256=$file.sha256;variant=$file['variant']}
            })
            $pom=@($node.metadata | Where-Object role -CEQ 'selected-component-pom')
            if ($pom.Count -ne 1) { throw 'android_inventory_pom_missing_or_ambiguous' }
            $item.pom=[ordered]@{size=$pom[0].size;sha256=$pom[0].sha256}
        } else { $item.buildScriptSha256=$node.buildFile.sha256 }
        # Gradle may enumerate sets differently on a new resolution.
        $item.variants=@(Sort-AndroidInventoryCanonical $item.variants)
        if ($node.kind -ceq 'maven') { $item.artifacts=@(Sort-AndroidInventoryCanonical $item.artifacts) }
        $item
    })
    $projection=[ordered]@{algorithm='exvpn-input-graph-v1';variant=$Graph.variant;configuration=$Graph.configuration;
        engineRevision=$Graph.engineRevision;rootComponent=$Graph.rootComponent;
        components=@(Sort-AndroidInventoryCanonical $nodes);edges=@(Sort-AndroidInventoryCanonical $Graph.edges)}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-AndroidInventoryCanonicalJson $projection))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-AndroidInventorySelectionSource($Records,[string]$FlutterRuntime='ordinary') {
    [void](Get-AndroidInventoryStorageOrigin $FlutterRuntime)
    $pinIdentity=if ($FlutterRuntime -ceq 'ordinary') { 'toolchain.lock.json' } else { 'shorebird.lock.json' }
    $otherPin=if ($FlutterRuntime -ceq 'ordinary') { 'shorebird.lock.json' } else { 'toolchain.lock.json' }
    if (@($Records | Where-Object identity -CEQ $otherPin).Count) { throw 'android_inventory_selection_runtime_mismatch' }
    # Portable identities from the original source seal; neither relocated
    # absolute paths nor collector implementation bytes are dependency inputs.
    $selected=@($Records | Where-Object {
        $_.identity -cmatch '^(app/android/|plugin/|flutter-gradle/|flutter/)' -or
        $_.identity -cin @('app/pubspec.yaml','app/pubspec.lock',$pinIdentity)
    })
    foreach ($required in @('app/pubspec.yaml','app/pubspec.lock',$pinIdentity,
        'flutter/bin/cache/engine.stamp','flutter/bin/internal/engine.version','flutter/bin/cache/engine.realm')) {
        if (@($selected | Where-Object identity -CEQ $required).Count -ne 1) { throw 'android_inventory_selection_source_missing' }
    }
    $identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $lines=[string[]]@(foreach ($record in $selected) {
        if (!$identities.Add($record.identity)) { throw 'android_inventory_selection_source_duplicate' }
        "$($record.identity)`t$($record.sha256)`n"
    })
    [Array]::Sort($lines,[StringComparer]::Ordinal)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join '')))).ToLowerInvariant()
    [ordered]@{count=$selected.Count;sha256=$hash}
}

function Assert-AndroidInventoryFields($Object,[string[]]$Fields) {
    if ($Object -isnot [Collections.IDictionary] -or @($Object.Keys).Count -ne $Fields.Count -or
        @($Object.Keys | Where-Object { $_ -cnotin $Fields }).Count) { throw 'android_inventory_seed_fields_invalid' }
}

function Assert-AndroidInventoryCoordinate([string]$Id) {
    if ($Id -cnotmatch '^maven:([A-Za-z0-9_.-]{1,200}):([A-Za-z0-9_.-]{1,200}):([A-Za-z0-9_.-]{1,200})$') {
        throw 'android_inventory_coordinate_invalid'
    }
    Assert-AndroidInventoryExactVersion $Matches[3]
    if ($Matches[3] -imatch '^(latest|release)$') { throw 'android_inventory_non_exact_version' }
}

function Assert-AndroidInventoryDigestRecord($Record,[switch]$Artifact) {
    Assert-AndroidInventoryFields $Record $(if ($Artifact) { @('name','size','sha256') } else { @('size','sha256') })
    if ($Record.sha256 -isnot [string] -or $Record.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $Record.size -isnot [int] -and $Record.size -isnot [long] -or $Record.size -lt 1 -or
        $Record.size -gt $(if ($Artifact) { 2GB } else { 8MB })) { throw 'android_inventory_seed_digest_invalid' }
    if ($Artifact -and ($Record.name -isnot [string] -or $Record.name -cnotmatch '^[A-Za-z0-9_.-]{1,240}\.(aar|jar)$')) {
        throw 'android_inventory_seed_artifact_invalid'
    }
}

function Assert-AndroidInventoryMetadataEdges($Ids,[string[]]$Roots,$Edges) {
    if (@($Edges).Count -gt 10000) { throw 'android_inventory_metadata_edge_limit' }
    $adj=@{}; $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $Ids) { $adj[$id]=[Collections.Generic.List[string]]::new() }
    foreach ($edge in $Edges) {
        Assert-AndroidInventoryFields $edge @('from','to','kind')
        if ($edge.kind -cnotin @('parent','bom-import') -or !$adj.ContainsKey($edge.from) -or !$adj.ContainsKey($edge.to) -or
            !$unique.Add((ConvertTo-AndroidInventoryCanonicalJson $edge))) { throw 'android_inventory_metadata_edge_invalid' }
        $adj[$edge.from].Add($edge.to)
    }
    $active=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $depths=@{}; $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    function Visit-AndroidInventoryMetadata([string]$Id) {
        [void]$seen.Add($Id)
        if ($active.Contains($Id)) { throw 'android_inventory_metadata_cycle' }
        if ($depths.ContainsKey($Id)) { return $depths[$Id] }
        if ($active.Count -ge 9) { throw 'android_inventory_metadata_depth_limit' }
        [void]$active.Add($Id)
        $depth=0
        try { foreach ($next in $adj[$Id]) { $depth=[Math]::Max($depth,1+(Visit-AndroidInventoryMetadata $next)) } }
        finally { [void]$active.Remove($Id) }
        if ($depth -gt 8) { throw 'android_inventory_metadata_depth_limit' }
        $depths[$Id]=$depth
        $depth
    }
    foreach ($id in $Roots) { [void](Visit-AndroidInventoryMetadata $id) }
    if ($seen.Count -ne @($Ids).Count) { throw 'android_inventory_metadata_orphan' }
}

function Assert-AndroidInventorySeed($Seed,[string]$Variant,[string]$Engine,[string]$FlutterRevision,$Source) {
    Assert-AndroidInventoryFields $Seed @('schema','status','origin','variant','gradleVersion','flutterRevision','engineRevision',
        'selectionSource','semanticGraphAlgorithm','semanticGraphSha256','repositoryPolicy','runtimeComponents','metadataOnlyComponents','metadataEdges','boundaries')
    foreach ($field in @('status','origin','variant','gradleVersion','flutterRevision','engineRevision','semanticGraphAlgorithm','semanticGraphSha256','repositoryPolicy')) {
        if ($Seed[$field] -isnot [string]) { throw 'android_inventory_seed_type_invalid' }
    }
    if ($Seed.schema -isnot [int] -and $Seed.schema -isnot [long] -or $Seed.schema -ne 1 -or
        $Seed.status -cne 'PINNED_PREPARED_INPUTS' -or $Seed.origin -cne 'locally_observed_gradle_inputs' -or
        $Seed.gradleVersion -cne '9.3.1' -or $Seed.variant -cne $Variant -or $Seed.engineRevision -cne $Engine -or
        $Seed.flutterRevision -cne $FlutterRevision -or $Seed.semanticGraphAlgorithm -cne 'exvpn-input-graph-v1' -or
        $Seed.semanticGraphSha256 -cnotmatch '^[a-f0-9]{64}$' -or $Seed.repositoryPolicy -cne 'google-mavenCentral-flutter-public-v1') {
        throw 'android_inventory_seed_identity_mismatch'
    }
    Assert-AndroidInventoryFields $Seed.selectionSource @('count','sha256')
    if ($Seed.selectionSource.count -isnot [int] -and $Seed.selectionSource.count -isnot [long] -or
        $Seed.selectionSource.count -lt 1 -or $Seed.selectionSource.count -gt 20000 -or
        $Seed.selectionSource.sha256 -isnot [string] -or $Seed.selectionSource.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'android_inventory_seed_type_invalid' }
    if ($Seed.selectionSource.count -ne $Source.count -or $Seed.selectionSource.sha256 -cne $Source.sha256) { throw 'android_inventory_seed_source_mismatch' }
    Assert-AndroidInventoryFields $Seed.boundaries @('independentPublisherVerification','apkBindingVerified','licensesReviewed')
    foreach ($value in $Seed.boundaries.Values) { if ($value -isnot [bool] -or $value) { throw 'android_inventory_false_completeness_claim' } }
    foreach ($field in @('runtimeComponents','metadataOnlyComponents','metadataEdges')) {
        if ($Seed[$field] -isnot [Collections.IList]) { throw 'android_inventory_seed_type_invalid' }
    }
    if (@($Seed.runtimeComponents).Count -lt 1 -or @($Seed.runtimeComponents).Count -gt 3000 -or @($Seed.metadataOnlyComponents).Count -gt 64) {
        throw 'android_inventory_metadata_component_limit'
    }
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $roots=[Collections.Generic.List[string]]::new()
    foreach ($node in @($Seed.runtimeComponents)+@($Seed.metadataOnlyComponents)) {
        $runtime=$node.Contains('artifacts')
        Assert-AndroidInventoryFields $node $(if ($runtime) { @('id','pom','artifacts') } else { @('id','pom') })
        Assert-AndroidInventoryCoordinate $node.id
        if (!$ids.Add($node.id)) { throw 'android_inventory_metadata_duplicate' }
        Assert-AndroidInventoryDigestRecord $node.pom
        if ($runtime) {
            if ($node.id.StartsWith('maven:io.flutter:',[StringComparison]::Ordinal) -and
                (!$node.id.EndsWith(':1.0.0-'+$Engine,[StringComparison]::Ordinal) -or
                 !$node.id.Split(':')[2].EndsWith('_'+$Variant,[StringComparison]::Ordinal))) { throw 'android_inventory_engine_mismatch' }
            $roots.Add($node.id)
            if ($node.artifacts -isnot [Collections.IList]) { throw 'android_inventory_seed_type_invalid' }
            if (@($node.artifacts).Count -gt 64) { throw 'android_inventory_seed_artifact_limit' }
            foreach ($artifact in $node.artifacts) { Assert-AndroidInventoryDigestRecord $artifact -Artifact }
        }
    }
    if ($roots.Count -ne @($Seed.runtimeComponents).Count -or
        @($Seed.metadataOnlyComponents | Where-Object { $_.Contains('artifacts') }).Count) { throw 'android_inventory_seed_roles_invalid' }
    if (!$roots.Contains('maven:io.flutter:flutter_embedding_'+$Variant+':1.0.0-'+$Engine)) { throw 'android_inventory_root_or_engine_missing' }
    Assert-AndroidInventoryMetadataEdges @($ids) @($roots) $Seed.metadataEdges
}

function Read-AndroidInventorySeed([string]$Path,[string[]]$Roots) {
    $bytes=Read-AndroidInventoryMetadataBytes $Path $Roots
    try {
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document=[Text.Json.JsonDocument]::Parse($text,[Text.Json.JsonDocumentOptions]@{MaxDepth=32})
        try {
            function Assert-AndroidInventoryJsonKeys([Text.Json.JsonElement]$Node) {
                if ($Node.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    foreach ($property in $Node.EnumerateObject()) {
                        if (!$names.Add($property.Name)) { throw 'android_inventory_seed_duplicate_key' }
                        Assert-AndroidInventoryJsonKeys $property.Value
                    }
                } elseif ($Node.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                    foreach ($child in $Node.EnumerateArray()) { Assert-AndroidInventoryJsonKeys $child }
                }
            }
            Assert-AndroidInventoryJsonKeys $document.RootElement
        } finally { $document.Dispose() }
        ConvertFrom-Json $text -AsHashtable -Depth 32
    } catch {
        if ($_.Exception.Message -ceq 'android_inventory_seed_duplicate_key') { throw }
        throw 'android_inventory_seed_json_invalid'
    }
}

function Assert-AndroidInventoryPreparedResult($Result,$Plan,[string]$PlanHash,[string]$PrivateHome) {
    if ($Result.schema -ne 1 -or $Result.status -cne 'PREPARED_METADATA_ONLY' -or $Result.success -isnot [bool] -or !$Result.success -or
        $Result.planSha256 -cne $PlanHash -or $Result.runtimeCount -ne $Plan.runtimeCount -or
        $Result.metadataOnlyCount -ne $Plan.metadataOnlyCount -or @($Result.records).Count -ne @($Plan.nodes).Count -or
        @($Result.taskGraph).Count -ne 1 -or $Result.taskGraph[0] -cne ':prepareExactPoms' -or
        ($Result.repositories -join '|') -cne 'https://dl.google.com/dl/android/maven2/|https://repo.maven.apache.org/maven2/|https://storage.googleapis.com/download.flutter.io') {
        throw 'android_inventory_preparation_result_invalid'
    }
    foreach ($flag in @('runtimeDependencyGraphCreated','apkBindingVerified','licensesReviewed')) {
        if ($Result[$flag] -isnot [bool] -or $Result[$flag]) { throw 'android_inventory_false_completeness_claim' }
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $Result.records) {
        $pin=@($Plan.nodes | Where-Object id -CEQ $record.id)
        if ($pin.Count -ne 1 -or !$seen.Add($record.id) -or $record.resultType -cne 'RESOLVED_ARTIFACT_RESULT' -or
            $record.runtimeSelected -isnot [bool] -or $record.runtimeSelected -ne $pin[0].runtimeSelected -or
            $record.sha256 -cne $pin[0].pom.sha256 -or $record.size -ne $pin[0].pom.size) { throw 'android_inventory_prepared_pom_changed' }
        $parts=$record.id.Split(':')
        if ($record.name -cne ($parts[2]+'-'+$parts[3]+'.pom')) { throw 'android_inventory_metadata_name_mismatch' }
        Assert-AndroidInventoryFile $record @($PrivateHome) -VerifyBytes
    }
}

function Read-AndroidInventoryMetadataBytes([string]$Path,[string[]]$Roots) {
    $path=Assert-AndroidInventoryPath $Path $Roots
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt 8MB) { throw 'android_inventory_metadata_size_limit' }
        $bytes=[byte[]]::new([int]$stream.Length)
        $offset=0
        while ($offset -lt $bytes.Length) {
            $n=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($n -eq 0) { throw 'android_inventory_artifact_changed' }
            $offset+=$n
        }
        if ($stream.ReadByte() -ne -1) { throw 'android_inventory_artifact_changed' }
    } finally { $stream.Dispose() }
    ,$bytes
}

function Get-AndroidInventoryPomEdges([byte[]]$Bytes,[string]$Id) {
    $settings=[Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $settings.MaxCharactersInDocument=8MB
    $xmlStream=[IO.MemoryStream]::new($Bytes,$false)
    $reader=[Xml.XmlReader]::Create($xmlStream,$settings)
    $xml=[Xml.XmlDocument]::new(); $xml.XmlResolver=$null
    try { $xml.Load($reader) } catch { throw 'android_inventory_metadata_xml_invalid' }
    finally { $reader.Dispose(); $xmlStream.Dispose() }
    if ($xml.DocumentElement.LocalName -cne 'project') { throw 'android_inventory_metadata_xml_invalid' }
    function Read-AndroidInventoryPomField($Node,[string]$Name,[switch]$Optional) {
        $found=@($Node.SelectNodes('./*[local-name()="'+$Name+'"]'))
        if ($found.Count -eq 0 -and $Optional) { return '' }
        if ($found.Count -ne 1 -or @($found[0].ChildNodes | Where-Object NodeType -EQ ([Xml.XmlNodeType]::Element)).Count) {
            throw 'android_inventory_metadata_field_invalid'
        }
        $found[0].InnerText.Trim()
    }
    function Get-AndroidInventoryPomCoordinate($Node) {
        $values=@(foreach ($name in @('groupId','artifactId','version')) { Read-AndroidInventoryPomField $Node $name })
        $id='maven:'+($values -join ':')
        Assert-AndroidInventoryCoordinate $id
        $id
    }
    $edges=[Collections.Generic.List[object]]::new()
    $parents=@($xml.SelectNodes('/*[local-name()="project"]/*[local-name()="parent"]'))
    if ($parents.Count -gt 1) { throw 'android_inventory_metadata_parent_ambiguous' }
    if ($parents.Count -eq 1) { $edges.Add([ordered]@{from=$Id;to=Get-AndroidInventoryPomCoordinate $parents[0];kind='parent'}) }
    foreach ($dependency in $xml.SelectNodes('//*[local-name()="dependencyManagement"]/*[local-name()="dependencies"]/*[local-name()="dependency"]')) {
        $scope=Read-AndroidInventoryPomField $dependency 'scope' -Optional
        if ($scope.Contains('${',[StringComparison]::Ordinal)) { throw 'android_inventory_metadata_nonliteral' }
        if ($scope -cne 'import') { continue }
        if ($null -ne $dependency.SelectSingleNode('ancestor::*[local-name()="profile"]')) { throw 'android_inventory_metadata_profile_import_unsupported' }
        if ((Read-AndroidInventoryPomField $dependency 'type') -cne 'pom') { throw 'android_inventory_metadata_import_type_invalid' }
        $edges.Add([ordered]@{from=$Id;to=Get-AndroidInventoryPomCoordinate $dependency;kind='bom-import'})
    }
    @($edges)
}

function Get-AndroidInventoryPreparedPlan($Seed,[string[]]$CacheDirectories) {
    $nodes=[Collections.Generic.List[object]]::new(); $edges=[Collections.Generic.List[object]]::new()
    foreach ($node in @($Seed.runtimeComponents)+@($Seed.metadataOnlyComponents)) {
        $parts=$node.id.Split(':'); $name=$parts[2]+'-'+$parts[3]+'.pom'
        $found=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($cache in $CacheDirectories) {
            $dir=Join-Path $cache ('modules-2/files-2.1/'+($parts[1..3] -join '/'))
            if (!(Test-Path -LiteralPath $dir -PathType Container)) { continue }
            $hashDirs=@(Get-ChildItem -LiteralPath $dir -Directory)
            if ($hashDirs.Count -gt 128) { throw 'android_inventory_metadata_cache_limit' }
            foreach ($hashDir in $hashDirs) {
                $path=Join-Path $hashDir.FullName $name
                if (!(Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $bytes=Read-AndroidInventoryMetadataBytes $path @($cache)
                $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
                if ($hashDir.Name -cnotmatch '^[1-9a-f][a-f0-9]{0,39}$' -or $sha1.TrimStart('0') -cne $hashDir.Name) { throw 'android_inventory_cache_key_mismatch' }
                $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                if ($hash -cne $node.pom.sha256 -or $bytes.Length -ne $node.pom.size) { throw 'android_inventory_metadata_seed_bytes_mismatch' }
                if (!$found.ContainsKey($hash)) { $found.Add($hash,@{file=$path;bytes=$bytes}) }
            }
        }
        if ($found.Count -ne 1) { throw 'android_inventory_metadata_missing_or_ambiguous' }
        $source=@($found.Values)[0]
        foreach ($edge in Get-AndroidInventoryPomEdges $source.bytes $node.id) { $edges.Add($edge) }
        $nodes.Add([ordered]@{id=$node.id;runtimeSelected=$node.Contains('artifacts');pom=$node.pom;sourceFile=$source.file})
    }
    $actual=@(Sort-AndroidInventoryCanonical $edges); $expected=@(Sort-AndroidInventoryCanonical $Seed.metadataEdges)
    if ((ConvertTo-AndroidInventoryCanonicalJson $actual) -cne (ConvertTo-AndroidInventoryCanonicalJson $expected)) { throw 'android_inventory_metadata_closure_changed' }
    Assert-AndroidInventoryMetadataEdges @($nodes | ForEach-Object id) @($Seed.runtimeComponents | ForEach-Object id) $actual
    [ordered]@{schema=1;status='EXACT_METADATA_PREPARATION_PLAN';repositoryPolicy=$Seed.repositoryPolicy;
        runtimeCount=@($Seed.runtimeComponents).Count;metadataOnlyCount=@($Seed.metadataOnlyComponents).Count;
        maximumDepth=8;maximumExtra=64;nodes=@($nodes | Sort-Object id);edges=$actual}
}

function Assert-AndroidInventorySeedGraph($Seed,$Graph) {
    $expected=@($Seed.runtimeComponents | ForEach-Object id | Sort-Object)
    $actual=@($Graph.components | Where-Object kind -CEQ 'maven' | ForEach-Object id | Sort-Object)
    if (($expected -join "`n") -cne ($actual -join "`n")) { throw 'android_inventory_prepared_selection_changed' }
    if ((Get-AndroidInventorySemanticHash $Graph) -cne $Seed.semanticGraphSha256) { throw 'android_inventory_prepared_graph_changed' }
    foreach ($node in $Graph.components | Where-Object kind -CEQ 'maven') {
        $pin=@($Seed.runtimeComponents | Where-Object id -CEQ $node.id)[0]
        $pom=@($node.metadata | Where-Object role -CEQ 'selected-component-pom')[0]
        if ($pom.sha256 -cne $pin.pom.sha256 -or $pom.size -ne $pin.pom.size) { throw 'android_inventory_prepared_pom_changed' }
        $actual=@(Sort-AndroidInventoryCanonical @($node.artifacts | ForEach-Object { [ordered]@{name=$_.name;size=$_.size;sha256=$_.sha256} }))
        $expected=@(Sort-AndroidInventoryCanonical $pin.artifacts)
        if ((ConvertTo-AndroidInventoryCanonicalJson $actual) -cne (ConvertTo-AndroidInventoryCanonicalJson $expected)) { throw 'android_inventory_prepared_artifact_changed' }
    }
}

function New-AndroidInventoryGradleStartInfo {
    param([ValidateSet('offline','preparation')][string]$Phase,[string]$GradleDirectory,[string]$JavaPath,
        [string]$AndroidSdkPath,[string]$PrivateHome,[string]$ReadOnlyCache,[string]$Project,
        [string[]]$Arguments,[switch]$AllowMetadataNetwork,[string]$FlutterRuntime='ordinary')
    $storageOrigin=Get-AndroidInventoryStorageOrigin $FlutterRuntime
    if ($Phase -ceq 'preparation' -and $FlutterRuntime -ceq 'shorebird') { throw 'android_inventory_shorebird_prepared_metadata_unsupported' }
    if ($Phase -ceq 'preparation' -and !$AllowMetadataNetwork) { throw 'android_inventory_metadata_network_not_enabled' }
    if ($Arguments -ccontains '--offline' -or $Arguments -ccontains '--refresh-dependencies') { throw 'android_inventory_gradle_arguments_invalid' }
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $JavaPath 'bin/java.exe'
    $info.WorkingDirectory=$Project
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $base=@('-Xmx64m','-Xms64m',('-javaagent:'+(Join-Path $GradleDirectory 'lib/agents/gradle-instrumentation-agent-9.3.1.jar')),
        '-Dorg.gradle.appname=gradle','-jar',(Join-Path $GradleDirectory 'lib/gradle-gradle-cli-main-9.3.1.jar'),
        '--no-daemon','--no-build-cache','--no-configuration-cache','--console=plain','--max-workers=2',
        '-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=1g','--gradle-user-home',$PrivateHome)
    if ($Phase -ceq 'offline') { $base+='--offline' }
    foreach ($arg in @($base)+@($Arguments)) { $info.ArgumentList.Add($arg) }
    foreach ($key in @('JAVA_OPTS','JDK_JAVA_OPTIONS','GRADLE_OPTS','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS',
        'EXVPN_ANDROID_PACKAGE_INPUTS','FLUTTER_STORAGE_BASE_URL','GRADLE_RO_DEP_CACHE')) { [void]$info.Environment.Remove($key) }
    $info.Environment['JAVA_HOME']=$JavaPath
    $info.Environment['ANDROID_HOME']=$AndroidSdkPath
    $info.Environment['ANDROID_SDK_ROOT']=$AndroidSdkPath
    $info.Environment['GRADLE_USER_HOME']=$PrivateHome
    # Ordinary retains Gradle's standard default after inherited overrides are
    # removed. Shorebird uses only the reviewed origin, never a caller URL.
    if ($FlutterRuntime -ceq 'shorebird') { $info.Environment['FLUTTER_STORAGE_BASE_URL']=$storageOrigin }
    if ($Phase -ceq 'offline') { $info.Environment['GRADLE_RO_DEP_CACHE']=$ReadOnlyCache }
    $info
}

function Invoke-AndroidInventoryGradle {
    param([Diagnostics.ProcessStartInfo]$StartInfo,[string]$Phase,[string]$OutputDirectory,
        [ValidateRange(1,180)][int]$MaximumSeconds=180)
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$StartInfo
    $stdoutPath=Join-Path $OutputDirectory ($Phase+'-stdout.log')
    $stderrPath=Join-Path $OutputDirectory ($Phase+'-stderr.log')
    $stdout=[IO.File]::Open($stdoutPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $stderr=[IO.File]::Open($stderrPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $watch=[Diagnostics.Stopwatch]::StartNew(); $reason=$null; $started=$false
    try {
        if (!$process.Start()) { throw 'android_inventory_gradle_start_failed' }
        $started=$true
        $copies=[Threading.Tasks.Task[]]@($process.StandardOutput.BaseStream.CopyToAsync($stdout),$process.StandardError.BaseStream.CopyToAsync($stderr))
        while (!$process.WaitForExit(200)) {
            if ($watch.Elapsed.TotalSeconds -ge $MaximumSeconds) { $reason='time_limit' }
            if ($stdout.Length -gt 32MB -or $stderr.Length -gt 32MB) { $reason='log_limit' }
            if ($reason) { $process.Kill($true); if (!$process.WaitForExit(10000)) { throw 'android_inventory_gradle_stop_failed' }; break }
        }
        if (![Threading.Tasks.Task]::WaitAll($copies,10000)) { throw 'android_inventory_gradle_output_timeout' }
        if ($stdout.Length -gt 32MB -or $stderr.Length -gt 32MB) { $reason='log_limit' }
        $result=[ordered]@{phase=$Phase;exitCode=$process.ExitCode;elapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);
            maximumSeconds=$MaximumSeconds;terminationReason=$reason;offline=$StartInfo.ArgumentList.Contains('--offline')}
        $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory ($Phase+'-result.json')) -Encoding utf8NoBOM
        $result
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(10000) }
        $stdout.Dispose(); $stderr.Dispose(); $process.Dispose(); $watch.Stop()
    }
}
