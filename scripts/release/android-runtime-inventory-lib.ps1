# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest

function Get-AndroidInventoryHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-AndroidInventoryPath([string]$Path, [string[]]$Roots) {
    $full=[IO.Path]::GetFullPath($Path)
    $inside=$false
    foreach ($root in $Roots) {
        $prefix=[IO.Path]::GetFullPath($root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $inside=$true }
    }
    if (!$inside) { throw 'android_inventory_path_outside_allowed_roots' }
    $item=Get-Item -LiteralPath $full -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'android_inventory_link_not_allowed' }
        $item=if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
    $full
}

function Get-AndroidInventoryTree([string]$Root) {
    # Source inputs only. Generated outputs are never copied or called source.
    $ignored=@('.git','.gradle','.dart_tool','.cxx','.kotlin','build')
    $rootPath=[IO.Path]::GetFullPath($Root)
    $pending=[Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    $files=[Collections.Generic.List[object]]::new()
    [long]$total=0
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.PSIsContainer -and $item.Name -cin $ignored) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'android_inventory_link_not_allowed' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $total+=$item.Length
            if ($files.Count -ge 20000 -or $total -gt 256MB) { throw 'android_inventory_source_limit' }
            $relative=[IO.Path]::GetRelativePath($rootPath,$item.FullName).Replace('\','/')
            if ($relative -match '[\x00-\x1f]' -or $relative -match '(^|/)\.\.(/|$)') { throw 'android_inventory_source_path_invalid' }
            $files.Add([ordered]@{relative=$relative;file=$item.FullName;size=$item.Length;sha256=Get-AndroidInventoryHash $item.FullName})
        }
    }
    @($files | Sort-Object relative)
}

function Get-AndroidInventoryFingerprint($Files) {
    $lines=@($Files | Sort-Object identity | ForEach-Object { "$($_.identity)`t$($_.sha256)`n" }) -join ''
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($lines))).ToLowerInvariant()
}

function Get-AndroidInventoryTreeSnapshot([string]$Identity, [string]$Root, [string[]]$ExcludedRelativePaths=@()) {
    $files=@(Get-AndroidInventoryTree $Root | Where-Object { $_.relative -cnotin $ExcludedRelativePaths })
    $fingerprintFiles=@($files | ForEach-Object { @{identity=$_.relative;sha256=$_.sha256} })
    [ordered]@{identity=$Identity;root=[IO.Path]::GetFullPath($Root);excludedRelativePaths=@($ExcludedRelativePaths);
        fingerprint=Get-AndroidInventoryFingerprint $fingerprintFiles;files=$files}
}

function Assert-AndroidInventoryTreeUnchanged($Snapshot) {
    # Re-enumeration is essential: checking only the previously known files
    # cannot detect a newly introduced source or build-logic input.
    $current=Get-AndroidInventoryTreeSnapshot $Snapshot.identity $Snapshot.root $Snapshot.excludedRelativePaths
    if ($current.files.Count -ne $Snapshot.files.Count -or $current.fingerprint -cne $Snapshot.fingerprint) {
        throw 'android_inventory_tree_inputs_changed'
    }
}

function Assert-AndroidInventoryExactVersion($Value, [switch]$AllowEmpty) {
    if ($Value -isnot [string]) { throw 'android_inventory_version_type' }
    if ($AllowEmpty -and $Value -ceq '') { return }
    if ($Value -cnotmatch '^[A-Za-z0-9_.-]{1,200}$' -or $Value -imatch 'snapshot|^latest\.') { throw 'android_inventory_non_exact_version' }
}

function Assert-AndroidInventoryFile($Record, [string[]]$Roots, [switch]$VerifyBytes) {
    if ($Record -isnot [Collections.IDictionary] -or $Record.sha256 -isnot [string] -or
        $Record.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Record.size -isnot [long] -and $Record.size -isnot [int] -or
        $Record.size -lt 0 -or $Record.size -gt 2GB -or
        $Record.name -isnot [string] -or $Record.name -match '[/\\\x00-\x1f]' -or !$Record.name) {
        throw 'android_inventory_file_record_invalid'
    }
    if ($VerifyBytes) {
        $path=Assert-AndroidInventoryPath $Record.file $Roots
        $file=Get-Item -LiteralPath $path
        if ($file.PSIsContainer -or $file.Name -cne $Record.name -or $file.Length -ne $Record.size -or
            (Get-AndroidInventoryHash $path) -cne $Record.sha256) { throw 'android_inventory_artifact_changed' }
    }
}

function Assert-AndroidInventoryGraph($Report, [string]$Variant, [string]$EngineRevision, [string[]]$ArtifactRoots=@(), [switch]$VerifyBytes) {
    if ($Variant -cnotin @('debug','release') -or $EngineRevision -cnotmatch '^[a-f0-9]{40}$') { throw 'android_inventory_expected_identity_invalid' }
    if ($Report -isnot [Collections.IDictionary] -or $Report.schema -ne 1 -or
        $Report.status -cne 'RESOLVED_INPUT_GRAPH' -or $Report.gradleVersion -cne '9.3.1' -or
        $Report.variant -cne $Variant -or $Report.configuration -cne ($Variant+'RuntimeClasspath') -or
        $Report.engineRevision -cne $EngineRevision -or $Report.offline -isnot [bool] -or !$Report.offline -or
        @($Report.taskGraph).Count -ne 1 -or $Report.taskGraph[0] -cne ':app:exvpnRuntimeInventory') {
        throw 'android_inventory_graph_identity_invalid'
    }
    foreach ($boundary in @('apkBindingVerified','licensesReviewed','projectBinariesVerified','exactLinkedCodeInventory','metadataSourceSelectionVerified')) {
        if ($Report.boundaries[$boundary] -isnot [bool] -or $Report.boundaries[$boundary]) { throw 'android_inventory_false_completeness_claim' }
    }
    $nodes=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if (@($Report.components).Count -lt 2 -or @($Report.components).Count -gt 3000 -or @($Report.edges).Count -gt 30000) {
        throw 'android_inventory_graph_limit'
    }
    $engineFound=$false
    foreach ($node in $Report.components) {
        if ($node.id -isnot [string] -or !$nodes.TryAdd($node.id,$node) -or @($node.variants).Count -lt 1) { throw 'android_inventory_node_invalid' }
        if ($node.kind -ceq 'maven') {
            foreach ($part in @($node.group,$node.name)) { if ($part -isnot [string] -or $part -cnotmatch '^[A-Za-z0-9_.-]{1,200}$') { throw 'android_inventory_coordinate_invalid' } }
            Assert-AndroidInventoryExactVersion $node.version
            if ($node.id -cne "maven:$($node.group):$($node.name):$($node.version)") { throw 'android_inventory_node_id_mismatch' }
            if ($node.group -ceq 'io.flutter') {
                if ($node.version -cne ('1.0.0-'+$EngineRevision) -or !$node.name.EndsWith('_'+$Variant,[StringComparison]::Ordinal)) { throw 'android_inventory_engine_mismatch' }
                if ($node.name -ceq ('flutter_embedding_'+$Variant)) { $engineFound=$true }
            }
            if (@($node.metadata | Where-Object { $_.role -ceq 'selected-component-pom' }).Count -ne 1) { throw 'android_inventory_pom_missing_or_ambiguous' }
            if (@($node.metadata | Where-Object { $_.role -ceq 'selected-component-module-candidate' }).Count -gt 1) { throw 'android_inventory_module_ambiguous' }
            foreach ($record in $node.metadata) {
                $extension=switch -CaseSensitive ($record.role) {
                    'selected-component-pom' { '.pom' }
                    'selected-component-module-candidate' { '.module' }
                    default { throw 'android_inventory_metadata_role_invalid' }
                }
                if ($record.name -cne ($node.name+'-'+$node.version+$extension)) { throw 'android_inventory_metadata_name_mismatch' }
                Assert-AndroidInventoryFile $record $ArtifactRoots -VerifyBytes:$VerifyBytes
            }
            foreach ($record in $node.artifacts) {
                if ($record.role -cne 'resolved-runtime-artifact' -or $record.name -cnotmatch '\.(aar|jar)$') { throw 'android_inventory_runtime_artifact_invalid' }
                Assert-AndroidInventoryFile $record $ArtifactRoots -VerifyBytes:$VerifyBytes
            }
        } elseif ($node.kind -ceq 'project') {
            if ($node.id -cnotmatch '^project::[A-Za-z0-9_:.-]+$' -or $node.binaryArtifactsInspected -isnot [bool] -or
                $node.binaryArtifactsInspected -or @($node.artifacts).Count -ne 0) { throw 'android_inventory_project_invalid' }
            Assert-AndroidInventoryFile $node.buildFile $ArtifactRoots -VerifyBytes:$VerifyBytes
        } else { throw 'android_inventory_unknown_component' }
    }
    if (!$engineFound -or !$nodes.ContainsKey($Report.rootComponent) -or $nodes[$Report.rootComponent].kind -cne 'project') { throw 'android_inventory_root_or_engine_missing' }
    foreach ($edge in $Report.edges) {
        if (!$nodes.ContainsKey($edge.from) -or !$nodes.ContainsKey($edge.to) -or $edge.constraint -isnot [bool]) { throw 'android_inventory_edge_invalid' }
        if ($edge.requested.kind -ceq 'maven') {
            foreach ($field in @('required','strict','preferred')) { Assert-AndroidInventoryExactVersion $edge.requested[$field] -AllowEmpty }
            foreach ($rejected in $edge.requested.rejected) { Assert-AndroidInventoryExactVersion $rejected }
        } elseif ($edge.requested.kind -cne 'project') { throw 'android_inventory_unknown_selector' }
    }
    $reachable=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$reachable.Add($Report.rootComponent)
    do {
        $changed=$false
        foreach ($edge in $Report.edges) { if ($reachable.Contains($edge.from) -and $reachable.Add($edge.to)) { $changed=$true } }
    } while ($changed)
    if ($reachable.Count -ne $nodes.Count) { throw 'android_inventory_orphan_component' }
    [pscustomobject]@{components=$nodes.Count;maven=@($Report.components | Where-Object kind -CEQ 'maven').Count;projects=@($Report.components | Where-Object kind -CEQ 'project').Count;edges=@($Report.edges).Count}
}

function Add-AndroidInventoryModuleMetadata($Report, [string[]]$CacheDirectories) {
    # Only exact coordinates already selected by Gradle are visited. A .module
    # cached beside that coordinate is a candidate descriptor, not proof that
    # Gradle selected it instead of the POM. Preserve that explicit boundary.
    foreach ($node in $Report.components | Where-Object kind -CEQ 'maven') {
        $found=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($cache in $CacheDirectories) {
            $versionPath=Join-Path $cache "modules-2/files-2.1/$($node.group)/$($node.name)/$($node.version)"
            if (!(Test-Path -LiteralPath $versionPath -PathType Container)) { continue }
            foreach ($hashDirectory in Get-ChildItem -LiteralPath $versionPath -Directory) {
                if ($hashDirectory.Name -cnotmatch '^[a-f0-9]{40}$') { throw 'android_inventory_cache_layout_invalid' }
                $path=Join-Path $hashDirectory.FullName ($node.name+'-'+$node.version+'.module')
                if (!(Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $path=Assert-AndroidInventoryPath $path @($cache)
                $file=Get-Item -LiteralPath $path
                if ($file.Length -gt 8MB) { throw 'android_inventory_metadata_too_large' }
                $hash=Get-AndroidInventoryHash $path
                if (!$found.ContainsKey($hash)) {
                    $found.Add($hash,[ordered]@{file=$path;name=$file.Name;role='selected-component-module-candidate';size=$file.Length;sha256=$hash})
                }
            }
        }
        if ($found.Count -gt 1) { throw 'android_inventory_module_ambiguous' }
        $node.metadata=@($node.metadata)+@($found.Values)
    }
}
