# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Read-only policy helpers. Dot-sourcing never executes SDK, cloud or app code.
Set-StrictMode -Version Latest

function Assert-ShorebirdRuntimeGate($Evidence,[string]$Version,[string]$BaseCommit,$Receipts,$Artifacts) {
    if ($Evidence.schemaVersion -ne 1 -or $Evidence.version -cne $Version -or $Evidence.baseSourceCommit -cne $BaseCommit -or
        @($Evidence.platforms).Count -ne 2) { throw 'shorebird_runtime_gate_identity_failed' }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $safe=@()
    foreach ($record in $Evidence.platforms) {
        $target=$record.target
        if ($target -cnotin @('Android','Windows') -or !$seen.Add($target) -or
            $Evidence.baseReceipts[$target] -cne $Receipts[$target] -or $record.artifactSha256 -cne $Artifacts[$target] -or
            $record.patchNumber -le 0 -or $record.patchId -le 0 -or $record.applyVerified -ne $true -or
            $record.rollbackVerified -ne $true -or $record.appliedCurrentPatch -ne $record.patchNumber -or
            $record.rollbackCurrentPatch -ne 0 -or $record.dataPreserved -ne $true -or $record.updaterAvailable -ne $true -or
            $record.baseUiRevision -lt 0 -or $record.appliedUiRevision -le $record.baseUiRevision -or
            $record.rollbackUiRevision -ne $record.baseUiRevision) { throw 'shorebird_runtime_gate_platform_failed' }
        # Export known safe fields, never arbitrary raw QA diagnostics or paths.
        $safe+= [ordered]@{target=$target;artifactSha256=$record.artifactSha256;patchNumber=$record.patchNumber;patchId=$record.patchId;applyVerified=$true;rollbackVerified=$true;appliedCurrentPatch=$record.patchNumber;rollbackCurrentPatch=0;dataPreserved=$true;updaterAvailable=$true;baseUiRevision=$record.baseUiRevision;appliedUiRevision=$record.appliedUiRevision;rollbackUiRevision=$record.baseUiRevision}
    }
    [ordered]@{schemaVersion=1;version=$Version;baseSourceCommit=$BaseCommit;baseReceipts=$Receipts;platforms=$safe}
}

function Assert-ShorebirdNoticeMap($Files,$Audit) {
    $list=@($Files.Keys | Sort-Object -CaseSensitive -Culture en-US | ForEach-Object {
        [ordered]@{path=$_;sha256=$Files[$_].sha256;size=$Files[$_].size}
    })
    if (!$Files.ContainsKey('inventory.json') -or $Files.Count -ne $Audit.noticeEvidence.fileCount -or
        $Files['inventory.json'].sha256 -cne $Audit.noticeEvidence.inventorySha256 -or
        (Get-AuditTextHash ($list | ConvertTo-Json -Depth 5 -Compress)) -cne $Audit.noticeEvidence.fileSetSha256) {
        throw 'shorebird_public_notice_audit_binding_failed'
    }
}

function Assert-ShorebirdCompiledPolicy([string]$Text,[string]$EncodedKey) {
    $values=@{}
    foreach ($line in $Text -split '\r?\n') {
        if ($line -match '^\s*(#.*)?$') { continue }
        $field=[regex]::Match($line,'^([a-z_]+): *([^\r\n]+)$')
        if (!$field.Success -or $field.Groups[1].Value -cnotin @('app_id','auto_update','patch_verification','patch_public_key') -or $values.ContainsKey($field.Groups[1].Value)) { throw 'shorebird_public_updater_policy_failed' }
        $value=$field.Groups[2].Value.Trim()
        if ($field.Groups[1].Value -ceq 'patch_public_key') {
            $scalar=[regex]::Match($value,'^(?:"(?<key>[A-Za-z0-9+/]+={0,2})"|''(?<key>[A-Za-z0-9+/]+={0,2})''|(?<key>[A-Za-z0-9+/]+={0,2}))$')
            if (!$scalar.Success) { throw 'shorebird_public_updater_policy_failed' }
            $value=$scalar.Groups['key'].Value
        }
        $values[$field.Groups[1].Value]=$value
    }
    if ($values.Count -ne 4 -or $values.app_id -cne (Get-ShorebirdPolicy).appId -or $values.auto_update -cne 'false' -or
        $values.patch_verification -cne 'strict' -or $values.patch_public_key -cne $EncodedKey) { throw 'shorebird_public_updater_policy_failed' }
}

function Get-ShorebirdBasePublicFile([string]$Root,$Base,[string]$Name) {
    $records=@($Base.files | Where-Object path -CEQ $Name)
    if ($records.Count -ne 1) { throw 'shorebird_public_required_file_missing' }
    $path=Join-Path $Root $Name
    $asset=Get-DemoAssetRecord $path
    if ($asset.sha256 -cne $records[0].sha256) { throw 'shorebird_public_file_changed' }
    [ordered]@{path=$path;asset=$asset}
}

function Get-ShorebirdPublicBase([string]$Repository,[string]$ReceiptPath,[string]$Version,[string]$BaseCommit,[string]$Target) {
    Assert-AuditNoLinks $ReceiptPath
    if ((Get-Item -LiteralPath $ReceiptPath).Length -gt 4MB) { throw 'shorebird_base_receipt_oversized' }
    $base=Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-ShorebirdBaseReceipt $base $Version $Target
    Assert-ShorebirdReceiptFiles $ReceiptPath $base
    if ($base.sourceCommit -cne $BaseCommit -or !$base.sourceLockUnchanged -or !$base.updaterPolicyVerified -or $base.stableReady -ne $false -or
        $base.publicKeySha256 -cne (Get-ShorebirdPublicKey $Repository).sha256) { throw 'shorebird_public_base_identity_failed' }
    $root=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReceiptPath))
    $parts=$Version.Split('+');$stem=$Target.ToLowerInvariant()
    $name=if ($Target -ceq 'Android') { "ExVPN-$($parts[0])-$($parts[1])-android.apk" } else { "ExVPN-$($parts[0])-$($parts[1])-windows-x64-development.exe" }
    $binary=Get-ShorebirdBasePublicFile $root $base $name
    $auditFile=Get-ShorebirdBasePublicFile $root $base "$stem-audit.json"
    $audit=Get-Content -LiteralPath $auditFile.path -Raw | ConvertFrom-Json -AsHashtable
    Assert-ShorebirdPreviewAudit $audit $Target $binary.asset.sha256 $Version
    if (($audit.flutterRuntime.identity | ConvertTo-Json -Depth 12 -Compress) -cne ($base.runtime.identity | ConvertTo-Json -Depth 12 -Compress)) { throw 'shorebird_public_audit_runtime_mismatch' }
    $sbomFile=Get-ShorebirdBasePublicFile $root $base "$stem-sbom.cdx.json"
    $sbom=Get-Content -LiteralPath $sbomFile.path -Raw | ConvertFrom-Json -AsHashtable
    if ($sbom.bomFormat -cne 'CycloneDX' -or $sbom.metadata.component.version -cne $Version -or
        @($sbom.metadata.component.hashes | Where-Object { $_.alg -ceq 'SHA-256' -and $_.content -ceq $binary.asset.sha256 }).Count -ne 1 -or
        @($sbom.compositions | Where-Object aggregate -CEQ 'incomplete').Count -ne 1) { throw 'shorebird_public_sbom_binding_failed' }
    [ordered]@{target=$Target;root=$root;base=$base;receiptPath=[IO.Path]::GetFullPath($ReceiptPath);receiptSha256=Get-AuditSha256 $ReceiptPath;binary=$binary;audit=$audit;auditFile=$auditFile;sbomFile=$sbomFile;notices=(Get-ShorebirdBasePublicFile $root $base "$stem-notices.zip")}
}

function Assert-ShorebirdFileMaps($Actual,$Expected) {
    if ($Actual.Count -ne $Expected.Count) { throw 'shorebird_public_archive_set_mismatch' }
    foreach ($key in $Expected.Keys) {
        if (!$Actual.ContainsKey($key) -or $Actual[$key].sha256 -cne $Expected[$key].sha256 -or $Actual[$key].size -ne $Expected[$key].size) { throw 'shorebird_public_archive_bytes_mismatch' }
    }
}

function Expand-ShorebirdNoticeZip([string]$Archive,[string]$Prefix,[string]$Destination,$Files) {
    New-Item -ItemType Directory -Path $Destination | Out-Null
    $selected=New-AuditFileMap -CaseSensitive
    foreach ($file in $Files.Values) {
        if (!$file.path.StartsWith($Prefix,[StringComparison]::Ordinal)) { continue }
        $relative=ConvertTo-AuditPath $file.path.Substring($Prefix.Length)
        $path=Join-Path $Destination $relative
        $parent=[IO.Path]::GetDirectoryName($path)
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Assert-AuditNoLinks $parent
        [IO.File]::WriteAllBytes($path,(Read-AuditZipBytes $Archive $file.path 256MB))
        $selected.Add($relative,@{path=$relative;sha256=$file.sha256;size=$file.size})
    }
    ,$selected
}

function Assert-ShorebirdPublicBuild($Build,[string]$Version,[string]$BaseCommit,[string]$Name,[string]$Hash,[long]$Bytes) {
    if ($Build.schema -ne 1 -or $Build.version -cne $Version -or $Build.sourceCommit -cne $BaseCommit -or
        $Build.runtime -cne 'shorebird' -or $Build.dartOtaAvailable -ne $true -or $Build.stableReady -ne $false -or
        $Build.syntheticProfiles -ne $false -or $Build.artifact.file -cne $Name -or $Build.artifact.sha256 -cne $Hash -or
        $Build.artifact.bytes -ne $Bytes -or $Build.baseReceiptSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $Build.runtimeQaSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'shorebird_public_build_identity_failed' }
}
