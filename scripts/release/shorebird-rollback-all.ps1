# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Explicit two-platform orchestration; every actual patch ID is checked before
# the first mutation. Distinct numbers are both rolled back, never guessed.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$AndroidPatchNumber,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$WindowsPatchNumber,
    [Parameter(Mandatory)][string[]]$BaseReceipts,
    [switch]$PublishCloud
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
$groups=@(Get-ShorebirdRollbackGroups $AndroidPatchNumber $WindowsPatchNumber)
$plans=@()
foreach ($group in $groups) {
    $result=& (Join-Path $PSScriptRoot 'shorebird-rollback.ps1') -ReleaseVersion $ReleaseVersion -PatchNumber $group.number -BaseReceipts $BaseReceipts -ExpectedPlatforms $group.targets
    $plan=Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'rollback.json') -Raw | ConvertFrom-Json -AsHashtable
    $plans+=@{group=$group;plan=$plan}
}
$receipts=@()
foreach ($entry in $plans) {
    if ($PublishCloud) {
        $result=& (Join-Path $PSScriptRoot 'shorebird-rollback.ps1') -ReleaseVersion $ReleaseVersion -PatchNumber $entry.group.number -BaseReceipts $BaseReceipts -ExpectedPlatforms $entry.group.targets -ExpectedPatchId $entry.plan.patchId -PublishCloud
        $receipt=Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'rollback.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($receipt.patchId -ne $entry.plan.patchId -or !$receipt.cloudReadbackVerified) { throw 'shorebird_rollback_all_identity_changed' }
        $receipts+=$receipt
    } else { $receipts+=$entry.plan }
}
$output=Join-Path $repository ('artifacts/shorebird/rollback-all-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output | Out-Null
[ordered]@{schemaVersion=1;action='rollback-all';version=$ReleaseVersion;androidPatchNumber=$AndroidPatchNumber;windowsPatchNumber=$WindowsPatchNumber;published=[bool]$PublishCloud;platformCoverage=@('android','windows');receipts=$receipts;deviceRollbackVerified=$false} |
    ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'rollback-all.json') -Encoding utf8NoBOM
[pscustomobject]@{OutputDirectory=$output;Published=[bool]$PublishCloud}
