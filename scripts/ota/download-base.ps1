# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
# Restore accepted local/CI bases from their permanent immutable release assets.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$BaseSourceCommit,
    [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Repository=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'base-capsule.ps1')
$repositoryRoot=[IO.Path]::GetFullPath($Repository)
. (Join-Path $repositoryRoot 'scripts/release/shorebird-pipeline-lib.ps1')
. (Join-Path $repositoryRoot 'scripts/release/shorebird-publication-lib.ps1')
function Invoke-OtaBaseGh([string[]]$Arguments) {
    $result=& gh @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'ota_base_github_read_failed' }
    $result
}
$repo='Extectick/ExVPN'
$tag='v'+$ReleaseVersion.Split('+')[0]
$reference=Invoke-OtaBaseGh @('api',"repos/$repo/git/ref/tags/$tag") | ConvertFrom-Json
$object=$reference.object
for ($depth=0;$depth -lt 5 -and $object.type -ceq 'tag';$depth++) {
    if ($object.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'ota_base_release_tag_invalid' }
    $object=(Invoke-OtaBaseGh @('api',"repos/$repo/git/tags/$($object.sha)") | ConvertFrom-Json).object
}
if ($object.type -cne 'commit' -or $object.sha -cne $BaseSourceCommit) { throw 'ota_base_release_tag_mismatch' }
$release=Invoke-OtaBaseGh @('api',"repos/$repo/releases/tags/$tag") | ConvertFrom-Json
if ($release.draft -or !$release.prerelease -or $release.tag_name -cne $tag -or $release.target_commitish -cne $BaseSourceCommit) { throw 'ota_base_release_identity_mismatch' }
$stem=$Target.ToLowerInvariant()
$capsule='ExVPN-'+$ReleaseVersion.Replace('+','-')+'-'+$stem+'-ota-inputs.zip'
$packageReceipt=$stem+'-shorebird-base.json'
$downloads=Resolve-ExvpnOtaPath $repositoryRoot ('artifacts/ota-input-downloads/'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
$downloaded=@{}
foreach ($name in @($capsule,$packageReceipt)) {
    $asset=@($release.assets | Where-Object name -CEQ $name)
    $maximum=if($name -ceq $capsule){288MB}else{4MB}
    if ($asset.Count -ne 1 -or $asset[0].size -le 0 -or $asset[0].size -gt $maximum -or $asset[0].digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'ota_base_release_asset_invalid' }
    $null=Invoke-OtaBaseGh @('release','download',$tag,'--repo',$repo,'--pattern',$name,'--dir',$downloads)
    $path=Resolve-ExvpnOtaPath $downloads $name
    if ((Get-Item -LiteralPath $path).Length -ne $asset[0].size -or ('sha256:'+(Get-ExvpnOtaSha256 $path)) -cne $asset[0].digest) { throw 'ota_base_download_hash_mismatch' }
    $downloaded[$name]=$path
}
$package=Get-Content -LiteralPath $downloaded[$packageReceipt] -Raw | ConvertFrom-Json -AsHashtable
Assert-IndependentBaseReceipt $package $ReleaseVersion $Target
if ($package.sourceCommit -cne $BaseSourceCommit) { throw 'ota_base_package_source_mismatch' }
$receiptPath=Expand-ExvpnOtaBaseCapsule -Archive $downloaded[$capsule] -Version $ReleaseVersion -SourceCommit $BaseSourceCommit -Target $Target `
    -PackageReceiptSha256 (Get-ExvpnOtaSha256 $downloaded[$packageReceipt]) -OutputDirectory (Resolve-ExvpnOtaPath $repositoryRoot $OutputDirectory)
$receipt=Read-ExvpnOtaCapsuleReceipt $receiptPath
if ($receipt.signingPublicKey.sha256 -cne $package.publicKeySha256) { throw 'ota_base_capsule_public_key_mismatch' }
foreach ($item in @(Get-ExvpnOtaCapsulePlan $receipt $ReleaseVersion $BaseSourceCommit $Target)) {
    $bound=@($package.baseAot | Where-Object arch -CEQ $item.arch)
    if ($bound.Count -ne 1 -or $bound[0].sha256 -cne $item.sha256 -or $bound[0].bytes -ne $item.size) { throw 'ota_base_capsule_package_aot_mismatch' }
}
[ordered]@{receipt=$receiptPath;version=$ReleaseVersion;target=$Target;sourceCommit=$BaseSourceCommit;fromImmutableRelease=$tag} | ConvertTo-Json -Compress
