# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$')][string]$ReleaseVersion,
    [switch]$ValidateOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'demo-release-lib.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$repo = 'Extectick/ExVPN'
$parts = $ReleaseVersion.Split('+')
$version = $parts[0]
$buildNumber = [int]$parts[1]
$tag = "v$version"
$androidName = "ExVPN-$version-$buildNumber-android.apk"
$windowsName = "ExVPN-$version-$buildNumber-windows-x64-development.exe"
$commit = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[a-f0-9]{40}$') { throw 'demo_source_missing' }
if (!$ValidateOnly -and ($env:GITHUB_REPOSITORY -cne $repo -or $env:GITHUB_REF -cne 'refs/heads/main' -or
    $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_SHA -cne $commit -or !$env:GH_TOKEN)) {
    throw 'demo_publication_requires_main_dispatch'
}
$root = Join-Path $repository 'artifacts/preview'
$expected = @(
    "android/$androidName",'android/android-build.json','android/android-audit.json',
    'android/android-sbom.cdx.json','android/android-notices.zip','android/android-maven-notices.zip','android/android-maven-notices.json',
    "windows/$windowsName",'windows/windows-build.json','windows/windows-audit.json',
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
    $name = if ($platform -ceq 'android') { $androidName } else { $windowsName }
    $binary = Join-Path $folder $name
    $hash = Get-DemoSha256 $binary
    if ($build.schema -ne 1 -or $build.version -cne $ReleaseVersion -or $build.sourceCommit -cne $commit -or
        $build.runtime -cne 'ordinary' -or $build.syntheticProfiles -or $build.stableReady -or $build.dartOtaAvailable -or
        $build.artifact.file -cne $name -or $build.artifact.sha256 -cne $hash -or
        $build.artifact.bytes -ne (Get-Item -LiteralPath $binary).Length) { throw 'demo_build_identity_failed' }
    Assert-DemoAudit $audit $(if ($platform -ceq 'android') {'Android'} else {'Windows'}) $hash $ReleaseVersion
    $notices = Get-DemoAssetRecord (Join-Path $folder "$platform-notices.zip")
    if ($build.notices.file -cne $notices.file -or $build.notices.bytes -ne $notices.bytes -or
        $build.notices.sha256 -cne $notices.sha256) { throw 'demo_notices_binding_failed' }
    $sbom = Get-Content -LiteralPath (Join-Path $folder "$platform-sbom.cdx.json") -Raw | ConvertFrom-Json
    if ($sbom.bomFormat -cne 'CycloneDX' -or $sbom.metadata.component.version -cne $ReleaseVersion -or
        @($sbom.metadata.component.hashes | Where-Object { $_.alg -ceq 'SHA-256' -and $_.content -ceq $hash }).Count -ne 1 -or
        @($sbom.compositions | Where-Object aggregate -CEQ 'incomplete').Count -ne 1) { throw 'demo_sbom_binding_failed' }
}
# The runtime notices collector is independently version/hash bound; never
# publish the Android binary while this separate distribution bundle is absent.
$maven = Get-Content -LiteralPath (Join-Path $root 'android/android-maven-notices.json') -Raw | ConvertFrom-Json
if ($maven.status -cne 'PASS' -or $maven.appVersion -cne $ReleaseVersion -or
    $maven.apkSha256 -cne (Get-DemoSha256 (Join-Path $root "android/$androidName")) -or
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
if (@($refs | Where-Object ref -CEQ "refs/tags/$tag").Count -ne 1) { throw 'preview_source_tag_missing' }
$tagCommit = (& git -C $repository rev-parse "$tag^{}").Trim()
if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $commit) { throw 'preview_source_tag_mismatch' }
$releases = @(Invoke-DemoGh @('release','list','--repo',$repo,'--limit','100','--json','tagName') | ConvertFrom-Json)
$existingRelease = @($releases | Where-Object tagName -CEQ $tag).Count -eq 1
$delivery = Join-Path $repository ('artifacts/preview-delivery-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $delivery | Out-Null
foreach ($relative in $expected) { Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $delivery }
Copy-Item -LiteralPath (Join-Path $repository "docs/releases/$version.md") -Destination (Join-Path $delivery 'RELEASE.md')
$assets += Get-DemoAssetRecord (Join-Path $delivery 'RELEASE.md')
$manifest = [ordered]@{
    schema=1;version=$version;build=$buildNumber;channel='beta';tag=$tag;sourceCommit=$commit
    workflowRun="https://github.com/$repo/actions/runs/$($env:GITHUB_RUN_ID)"
    prerelease=$true;stableReady=$false;runtime='ordinary';dartOtaAvailable=$false;assets=$assets
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $delivery 'release-manifest.json') -Encoding utf8
$hashAssets = @($assets) + @(Get-DemoAssetRecord (Join-Path $delivery 'release-manifest.json'))
$hashAssets | Sort-Object file | ForEach-Object { "$($_.sha256)  $($_.file)" } | Set-Content -LiteralPath (Join-Path $delivery 'SHA256SUMS.txt') -Encoding ascii
$publishAssets = @($hashAssets) + @(Get-DemoAssetRecord (Join-Path $delivery 'SHA256SUMS.txt'))
$alreadyUploaded = @()
if ($existingRelease) {
    $existingId = [string](Invoke-DemoGh @('release','view',$tag,'--repo',$repo,'--json','databaseId','--jq','.databaseId'))
    if ($existingId -cnotmatch '^[1-9][0-9]*$') { throw 'preview_existing_release_identity_invalid' }
    $previous = Invoke-DemoGh @('api',"repos/$repo/releases/$existingId") | ConvertFrom-Json
    if (!$previous.prerelease -or $previous.target_commitish -cne $commit -or $previous.tag_name -cne $tag) {
        throw 'preview_existing_release_source_mismatch'
    }
    foreach ($remote in $previous.assets) {
        $expectedAsset = @($publishAssets | Where-Object file -CEQ $remote.name)
        if ($expectedAsset.Count -ne 1 -or $remote.size -ne $expectedAsset[0].bytes -or
            $remote.digest -cne ('sha256:' + $expectedAsset[0].sha256)) { throw 'preview_existing_asset_changed' }
        $alreadyUploaded += $remote.name
    }
    if (!$previous.draft) {
        if ($alreadyUploaded.Count -ne $publishAssets.Count) { throw 'preview_published_release_incomplete' }
        Write-Host 'Immutable preview already matches these artifacts; continuing with the signed feed.'
        return
    }
} else {
    $null = Invoke-DemoGh @('release','create',$tag,'--repo',$repo,'--target',$commit,'--verify-tag','--title',"ExVPN $version Preview",
        '--notes-file',(Join-Path $delivery 'RELEASE.md'),'--draft','--prerelease','--latest=false')
}
$missing = @($publishAssets | Where-Object file -CNotIn $alreadyUploaded)
if ($missing.Count) {
    $null = Invoke-DemoGh (@('release','upload',$tag,'--repo',$repo) + @($missing | ForEach-Object { Join-Path $delivery $_.file }))
}
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
