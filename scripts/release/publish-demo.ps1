# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([switch]$ValidateOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'demo-release-lib.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$repo = 'Extectick/ExVPN'
$tag = 'v0.1.0-demo'
$commit = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[a-f0-9]{40}$') { throw 'demo_source_missing' }
if (!$ValidateOnly -and ($env:GITHUB_REPOSITORY -cne $repo -or $env:GITHUB_REF -cne 'refs/heads/main' -or
    $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_SHA -cne $commit -or !$env:GH_TOKEN)) {
    throw 'demo_publication_requires_main_dispatch'
}
$root = Join-Path $repository 'artifacts/demo'
$expected = @(
    'android/ExVPN-0.1.0-demo-android.apk','android/android-build.json','android/android-audit.json',
    'android/android-sbom.cdx.json','android/android-notices.zip','android/android-maven-notices.zip','android/android-maven-notices.json',
    'windows/ExVPN-0.1.0-demo-windows-x64.exe','windows/windows-build.json','windows/windows-audit.json',
    'windows/windows-sbom.cdx.json','windows/windows-notices.zip'
)
$items = @(Get-ChildItem -LiteralPath $root -Recurse -Force)
if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'demo_asset_link' }
$actual = @($items | Where-Object { !$_.PSIsContainer } | ForEach-Object { [IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/') })
if ((($actual | Sort-Object) -join ',') -cne (($expected | Sort-Object) -join ',')) { throw 'demo_asset_set_mismatch' }
$assets = @($expected | ForEach-Object { Get-DemoAssetRecord (Join-Path $root $_) })
foreach ($platform in @('android','windows')) {
    $folder = Join-Path $root $platform
    $build = Get-Content -LiteralPath (Join-Path $folder "$platform-build.json") -Raw | ConvertFrom-Json
    $audit = Get-Content -LiteralPath (Join-Path $folder "$platform-audit.json") -Raw | ConvertFrom-Json
    $name = if ($platform -ceq 'android') { 'ExVPN-0.1.0-demo-android.apk' } else { 'ExVPN-0.1.0-demo-windows-x64.exe' }
    $binary = Join-Path $folder $name
    $hash = Get-DemoSha256 $binary
    if ($build.schema -ne 1 -or $build.version -cne '0.1.0+18' -or $build.sourceCommit -cne $commit -or
        $build.runtime -cne 'ordinary' -or $build.syntheticProfiles -or $build.stableReady -or $build.dartOtaAvailable -or
        $build.artifact.file -cne $name -or $build.artifact.sha256 -cne $hash -or
        $build.artifact.bytes -ne (Get-Item -LiteralPath $binary).Length) { throw 'demo_build_identity_failed' }
    Assert-DemoAudit $audit $(if ($platform -ceq 'android') {'Android'} else {'Windows'}) $hash
    $notices = Get-DemoAssetRecord (Join-Path $folder "$platform-notices.zip")
    if ($build.notices.file -cne $notices.file -or $build.notices.bytes -ne $notices.bytes -or
        $build.notices.sha256 -cne $notices.sha256) { throw 'demo_notices_binding_failed' }
    $sbom = Get-Content -LiteralPath (Join-Path $folder "$platform-sbom.cdx.json") -Raw | ConvertFrom-Json
    if ($sbom.bomFormat -cne 'CycloneDX' -or $sbom.metadata.component.version -cne '0.1.0+18' -or
        @($sbom.metadata.component.hashes | Where-Object { $_.alg -ceq 'SHA-256' -and $_.content -ceq $hash }).Count -ne 1 -or
        @($sbom.compositions | Where-Object aggregate -CEQ 'incomplete').Count -ne 1) { throw 'demo_sbom_binding_failed' }
}
# The runtime notices collector is independently version/hash bound; never
# publish the Android binary while this separate distribution bundle is absent.
$maven = Get-Content -LiteralPath (Join-Path $root 'android/android-maven-notices.json') -Raw | ConvertFrom-Json
if ($maven.status -cne 'PASS' -or $maven.appVersion -cne '0.1.0+18' -or
    $maven.apkSha256 -cne (Get-DemoSha256 (Join-Path $root 'android/ExVPN-0.1.0-demo-android.apk')) -or
    $maven.archiveSha256 -cne (Get-DemoSha256 (Join-Path $root 'android/android-maven-notices.zip'))) {
    throw 'demo_maven_notices_binding_failed'
}
if ($ValidateOnly) { Write-Host 'Demo deliverables validated; no GitHub changes.'; return }

function Invoke-DemoGh([string[]]$Arguments) {
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'demo_github_operation_failed' }
    return $result
}
# Fail before mutations if the immutable tag or release already exists. Recovery
# of a partially created draft is deliberate; no --clobber, delete, or tag move.
$refs = @(Invoke-DemoGh @('api',"repos/$repo/git/matching-refs/tags/$tag") | ConvertFrom-Json)
if (@($refs | Where-Object ref -CEQ "refs/tags/$tag").Count) { throw 'demo_tag_already_exists' }
$releases = @(Invoke-DemoGh @('release','list','--repo',$repo,'--limit','100','--json','tagName') | ConvertFrom-Json)
if (@($releases | Where-Object tagName -CEQ $tag).Count) { throw 'demo_release_already_exists' }
$delivery = Join-Path $repository ('artifacts/demo-delivery-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $delivery | Out-Null
foreach ($relative in $expected) { Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $delivery }
Copy-Item -LiteralPath (Join-Path $repository 'docs/releases/0.1.0-demo.md') -Destination (Join-Path $delivery 'DEMO.md')
$assets += Get-DemoAssetRecord (Join-Path $delivery 'DEMO.md')
$manifest = [ordered]@{
    schema=1;version='0.1.0';build=18;channel='demo';tag=$tag;sourceCommit=$commit
    workflowRun="https://github.com/$repo/actions/runs/$($env:GITHUB_RUN_ID)"
    prerelease=$true;stableReady=$false;runtime='ordinary';dartOtaAvailable=$false;assets=$assets
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $delivery 'release-manifest.json') -Encoding utf8
$hashAssets = @($assets) + @(Get-DemoAssetRecord (Join-Path $delivery 'release-manifest.json'))
$hashAssets | Sort-Object file | ForEach-Object { "$($_.sha256)  $($_.file)" } | Set-Content -LiteralPath (Join-Path $delivery 'SHA256SUMS.txt') -Encoding ascii
$publishAssets = @($hashAssets) + @(Get-DemoAssetRecord (Join-Path $delivery 'SHA256SUMS.txt'))
$null = Invoke-DemoGh @('release','create',$tag,'--repo',$repo,'--target',$commit,'--title','ExVPN 0.1.0 Demo',
    '--notes-file',(Join-Path $delivery 'DEMO.md'),'--draft','--prerelease','--latest=false')
$null = Invoke-DemoGh (@('release','upload',$tag,'--repo',$repo) + @($publishAssets | ForEach-Object { Join-Path $delivery $_.file }))
# REST lookup by tag only sees published releases. gh resolves the draft's
# pending tag through GraphQL; inspect that exact numeric release via REST.
$releaseId = [string](Invoke-DemoGh @('release','view',$tag,'--repo',$repo,'--json','databaseId','--jq','.databaseId'))
if ($releaseId -cnotmatch '^[1-9][0-9]*$') { throw 'demo_draft_identity_invalid' }
$release = (Invoke-DemoGh @('api',"repos/$repo/releases/$releaseId")) | ConvertFrom-Json
if (!$release.draft -or !$release.prerelease -or $release.tag_name -cne $tag -or
    $release.target_commitish -cne $commit -or $release.assets.Count -ne $publishAssets.Count) { throw 'demo_uploaded_release_invalid' }
foreach ($asset in $publishAssets) {
    $remote = @($release.assets | Where-Object name -CEQ $asset.file)
    if ($remote.Count -ne 1 -or $remote[0].size -ne $asset.bytes -or $remote[0].digest -cne ('sha256:' + $asset.sha256)) {
        throw 'demo_uploaded_asset_mismatch'
    }
}
$null = Invoke-DemoGh @('release','edit',$tag,'--repo',$repo,'--draft=false','--prerelease','--latest=false')
Write-Host "Published verified prerelease: https://github.com/$repo/releases/tag/$tag"
