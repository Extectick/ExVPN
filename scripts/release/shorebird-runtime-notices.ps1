# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Offline, source-pinned notice superset. Never resolves dependencies or builds.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')

function Get-ShorebirdNoticeFiles([string]$Root, [switch]$AllowRootSourceMetadata) {
    $entries = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    if ($entries.Count -gt 1000 -or @($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        throw 'shorebird_runtime_notices_file_set_invalid'
    }
    $files = @($entries | Where-Object { !$_.PSIsContainer } | Select-Object -ExpandProperty FullName)
    if ($AllowRootSourceMetadata) {
        # This exact source-only Git file preserves pinned upstream raw bytes.
        # It is not a license and Android asset merging excludes dotfiles. Do
        # not ignore other dotfiles or any unexpected file in delivered copies.
        $metadataPath = [IO.Path]::GetFullPath((Join-Path $Root '.gitattributes'))
        if (!(Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'shorebird_runtime_source_metadata_invalid' }
        $metadata = Get-ReleaseRuntimeFile $Root '.gitattributes'
        if ($metadata.size -ne 20 -or $metadata.sha256 -cne 'e97602ab9cac70102245345c5ab0fc9830df8b17f1072b188265a662a3a547ae') {
            throw 'shorebird_runtime_source_metadata_invalid'
        }
        $files = @($files | Where-Object { $_ -cne $metadataPath })
    }
    $files
}

function Get-ShorebirdRuntimeNotices([string]$Repository, $Runtime) {
    $identity = Get-ReleaseRuntimeField $Runtime 'Identity'
    if ((Get-ReleaseRuntimeField $identity 'kind') -ceq 'ordinary') { return $null }
    if ((Get-ReleaseRuntimeField $identity 'kind') -cne 'shorebird' -or
        $identity.buildMode -cne 'release' -or $identity.target -cnotin @('Android','Windows')) {
        throw 'shorebird_runtime_notices_selection_invalid'
    }
    $pinPath = 'scripts/release/shorebird-runtime-notices.lock.json'
    $pinFile = Get-ReleaseRuntimeFile $Repository $pinPath
    if ($pinFile.size -gt 16KB) { throw 'shorebird_runtime_notices_pin_invalid' }
    $pin = Get-Content -LiteralPath (Join-Path $Repository $pinPath) -Raw | ConvertFrom-Json -AsHashtable
    $expectedDirectory = 'scripts/release/licenses/shorebird-runtime-4b936a0c03e13389ddfb1ac48823f187964975c2'
    if ($pin.schema -ne 1 -or $pin.directory -cne $expectedDirectory -or
        $pin.flutterRevision -cne '5bef02a16146a0effc07da4acccaafe90a2739ce' -or
        $pin.engineRevision -cne '4b936a0c03e13389ddfb1ac48823f187964975c2' -or
        $pin.updaterRevision -cne '70ff1e336798474e39586d3f5ac2ca386ef32d9e' -or
        $pin.rustSourceRevision -cne 'b940084d7eb6a299eb4bfeb8e34901bc051e7ac4' -or
        $pin.inventorySha256 -cnotmatch '^[a-f0-9]{64}$' -or $pin.inventorySha256.Length -ne 64 -or
        $pin.inventorySize -le 0 -or $pin.inventorySize -gt 1MB) { throw 'shorebird_runtime_notices_pin_invalid' }
    if ($identity.flutterRevision -cne $pin.flutterRevision -or $identity.engineRevision -cne $pin.engineRevision) {
        throw 'shorebird_runtime_notices_selection_mismatch'
    }
    $root = Join-Path $Repository $pin.directory
    $inventoryFile = Get-ReleaseRuntimeFile $root 'inventory.json'
    if ($inventoryFile.sha256 -cne $pin.inventorySha256 -or $inventoryFile.size -ne $pin.inventorySize) {
        throw 'shorebird_runtime_notices_inventory_mismatch'
    }
    $inventory = Get-Content -LiteralPath (Join-Path $root 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
    $cratePin = Get-ReleaseRuntimeFile $Repository 'scripts/release/shorebird-updater-notices-crates.lock.json'
    if ($inventory.schema -ne 1 -or $inventory.status -cne 'PINNED_SOURCE_NOTICE_SUPERSET' -or
        $inventory.flutterRevision -cne $pin.flutterRevision -or $inventory.engineRevision -cne $pin.engineRevision -or
        $inventory.updaterRevision -cne $pin.updaterRevision -or $inventory.rustSourceRevision -cne $pin.rustSourceRevision -or
        $inventory.sourceCratePinSha256 -cne $cratePin.sha256 -or
        @($inventory.sourceCrates).Count -ne 282 -or @($inventory.files).Count -ne 198 -or
        $inventory.claims.exactLinkedMembership -or $inventory.claims.completePostLinkSbom -or $inventory.claims.stableReleaseReady) {
        throw 'shorebird_runtime_notices_inventory_invalid'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$seen.Add('inventory.json')
    foreach ($entry in $inventory.files) {
        $relative = ConvertTo-AuditPath $entry.path
        if (!$seen.Add($relative) -or $entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $entry.sha256.Length -ne 64 -or
            $entry.size -le 0 -or $entry.size -gt 2MB) { throw 'shorebird_runtime_notices_file_invalid' }
        $actual = Get-ReleaseRuntimeFile $root $relative
        if ($actual.sha256 -cne $entry.sha256 -or $actual.size -ne $entry.size) {
            throw 'shorebird_runtime_notices_file_mismatch'
        }
    }
    $actualFiles = @(Get-ShorebirdNoticeFiles $root -AllowRootSourceMetadata)
    if ($actualFiles.Count -ne $seen.Count) { throw 'shorebird_runtime_notices_file_set_mismatch' }
    foreach ($file in $actualFiles) {
        if (!$seen.Contains([IO.Path]::GetRelativePath($root, $file).Replace('\','/'))) {
            throw 'shorebird_runtime_notices_file_set_mismatch'
        }
    }
    [pscustomobject]@{
        Name = 'Shorebird updater and Rust source notices'
        Version = $pin.engineRevision
        SourceRoot = $root
        Files = @($inventory.files) + @($inventoryFile)
        Evidence = [ordered]@{
            scope = 'conservative-source-notice-superset'; pin = $pinFile
            inventorySha256 = $pin.inventorySha256; inventorySize = $pin.inventorySize
            updaterRevision = $pin.updaterRevision; rustSourceRevision = $pin.rustSourceRevision
            sourceCrates = 282; files = $seen.Count
            exactLinkedMembership = $false; completePostLinkSbom = $false; stableReleaseReady = $false
        }
    }
}

function Copy-ShorebirdRuntimeNotices($Expected, [string]$OutputDirectory) {
    if (!$Expected) { return $null }
    $destination = Join-Path $OutputDirectory 'shorebird-runtime'
    if (Test-Path -LiteralPath $destination) { throw 'shorebird_runtime_notices_destination_exists' }
    $notices = @()
    foreach ($entry in $Expected.Files) {
        $target = Join-Path $destination $entry.path
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath (Join-Path $Expected.SourceRoot $entry.path) -Destination $target
        $actual = Get-ReleaseRuntimeFile $destination $entry.path
        if ($actual.sha256 -cne $entry.sha256 -or $actual.size -ne $entry.size) {
            throw 'shorebird_runtime_notices_copy_mismatch'
        }
        $notices += [ordered]@{path=('shorebird-runtime/'+$entry.path);sha256=$entry.sha256}
    }
    [ordered]@{
        name = $Expected.Name; version = $Expected.Version; scope = 'conservative-source-notice-superset'
        source = 'https://github.com/shorebirdtech/updater/tree/'+$Expected.Evidence.updaterRevision
        notices = $notices
    }
}

function Assert-ShorebirdRuntimeNotices($Inventory, $Expected, [string]$Directory) {
    $components = @($Inventory.components | Where-Object name -CEQ 'Shorebird updater and Rust source notices')
    if (!$Expected) {
        if ($components.Count -or $null -ne (Get-ReleaseRuntimeField $Inventory 'shorebirdRuntimeSupplement')) {
            throw 'shorebird_runtime_notices_unexpected'
        }
        return
    }
    if ($components.Count -ne 1 -or $components[0].version -cne $Expected.Version -or
        @($components[0].notices).Count -ne $Expected.Files.Count -or
        (($Inventory.shorebirdRuntimeSupplement | ConvertTo-Json -Depth 10 -Compress) -cne
        ($Expected.Evidence | ConvertTo-Json -Depth 10 -Compress))) { throw 'shorebird_runtime_notices_binding_mismatch' }
    foreach ($entry in $Expected.Files) {
        $path = 'shorebird-runtime/'+$entry.path
        $declared = @($components[0].notices | Where-Object path -CEQ $path)
        $actual = Get-ReleaseRuntimeFile $Directory $path
        if ($declared.Count -ne 1 -or $declared[0].sha256 -cne $entry.sha256 -or
            $actual.sha256 -cne $entry.sha256 -or $actual.size -ne $entry.size) {
            throw 'shorebird_runtime_notices_copy_mismatch'
        }
    }
    $files = @(Get-ShorebirdNoticeFiles (Join-Path $Directory 'shorebird-runtime'))
    if ($files.Count -ne $Expected.Files.Count) { throw 'shorebird_runtime_notices_file_set_mismatch' }
}
