# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Rollback is release-wide, never a per-platform operation. Without -PublishCloud
# this command only verifies the target and writes a plan; it never mutates cloud.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$PatchNumber,
    [Parameter(Mandatory)][string[]]$BaseReceipts,
    [Parameter(Mandatory)][ValidateSet('Android','Windows')][string[]]$ExpectedPlatforms,
    [ValidateRange(0,2147483647)][long]$ExpectedPatchId=0,
    [switch]$PublishCloud
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
$policy = Get-ShorebirdPolicy
$public = Get-ShorebirdPublicKey $repository
$cli = Get-ShorebirdCli $repository
$privateRun = New-ShorebirdPrivateDirectory $repository 'rollback'
$oldCI = $env:CI; $phase = 'readback'
try {
    $env:CI = 'true'
    $releaseId = $null; $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $BaseReceipts) {
        Assert-AuditNoLinks $path
        if ((Get-Item -LiteralPath $path).Length -gt 4MB) { throw 'shorebird_base_receipt_oversized' }
        $base = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        Assert-ShorebirdBaseReceipt $base $ReleaseVersion $base.target
        if ($base.publicKeySha256 -cne $public.sha256) { throw 'shorebird_rollback_key_mismatch' }
        if (!$targets.Add($base.target) -or ($releaseId -and $base.releaseId -ne $releaseId)) { throw 'shorebird_rollback_base_mismatch' }
        $releaseId = $base.releaseId
        $release = Invoke-ShorebirdJson $cli @('releases','info',"--app-id=$($policy.appId)","--release-version=$ReleaseVersion") 'releases info' $privateRun ('release-' + $base.target)
        Assert-ShorebirdCloudRelease $release.release $ReleaseVersion $base.target $releaseId
    }
    if (!$targets.Contains('Android') -or !$targets.Contains('Windows') -or $targets.Count -ne 2) { throw 'shorebird_rollback_both_base_receipts_required' }
    $patchArguments = @(Get-ShorebirdPatchLookupArguments $ReleaseVersion $PatchNumber)
    $before = Invoke-ShorebirdJson $cli (@('patches','info') + $patchArguments) 'patches info' $privateRun 'before'
    if ($before.patch.number -ne $PatchNumber -or $before.patch.channel -cne 'beta' -or $before.patch.id -le 0) { throw 'shorebird_rollback_patch_mismatch' }
    if ($ExpectedPatchId -gt 0 -and $before.patch.id -ne $ExpectedPatchId) { throw 'shorebird_rollback_patch_id_changed' }
    $platforms = @($before.patch.artifacts | ForEach-Object platform | Sort-Object -Unique)
    if (!$platforms.Count -or @($platforms | Where-Object { $_ -cnotin @('android','windows') }).Count) { throw 'shorebird_rollback_platform_mismatch' }
    $expected = @($ExpectedPlatforms | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if (($platforms -join ',') -cne ($expected -join ',')) { throw 'shorebird_rollback_platform_coverage_mismatch' }
    $changed = $false
    if ($PublishCloud) {
        $phase = 'rollback'
        $mutation = Invoke-ShorebirdJson $cli (@('patches','rollback') + $patchArguments) 'patches rollback' $privateRun 'rollback'
        if ($mutation.app_id -cne $policy.appId -or $mutation.release_version -cne $ReleaseVersion -or
            $mutation.patch_number -ne $PatchNumber -or $mutation.action -cne 'rollback' -or !$mutation.patch.is_rolled_back) { throw 'shorebird_rollback_response_invalid' }
        $changed = $mutation.changed
        $after = Invoke-ShorebirdJson $cli (@('patches','info') + $patchArguments) 'patches info' $privateRun 'after'
        if ($after.patch.id -ne $before.patch.id -or $after.patch.number -ne $PatchNumber -or !$after.patch.is_rolled_back) { throw 'shorebird_rollback_readback_failed' }
        if ((@($after.patch.artifacts | ForEach-Object platform | Sort-Object -Unique) -join ',') -cne ($platforms -join ',')) { throw 'shorebird_rollback_platform_coverage_changed' }
    }
    $output = Join-Path $repository ('artifacts/shorebird/rollback-' + $ReleaseVersion + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    [ordered]@{
        schemaVersion=1;action='rollback';version=$ReleaseVersion;appId=$policy.appId;releaseId=$releaseId
        track='beta';patchNumber=$PatchNumber;patchId=$before.patch.id;platforms=$platforms
        published=[bool]$PublishCloud;changed=[bool]$changed;cloudReadbackVerified=[bool]$PublishCloud
        deviceRollbackVerified=$false;activation='next cold launch after explicit client check'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'rollback.json') -Encoding utf8NoBOM
} catch {
    ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $privateRun 'failure.log') -Encoding utf8NoBOM
    throw "shorebird_rollback_failed phase=$phase; private diagnostics retained"
} finally { $env:CI = $oldCI }
[pscustomobject]@{OutputDirectory=$output;Published=[bool]$PublishCloud;Version=$ReleaseVersion;PatchNumber=$PatchNumber}
