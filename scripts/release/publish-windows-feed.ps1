# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$')][string]$ReleaseVersion)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'demo-release-lib.ps1')
function Get-FeedResumeAsset($Feed,[string]$Commit,[string]$Title,[string]$Notes) {
    if ($Feed.draft -or !$Feed.prerelease -or $Feed.tag_name -cne 'windows-beta' -or
        $Feed.name -cne $Title -or $Feed.body -cne $Notes) { throw 'preview_feed_existing_identity_mismatch' }
    $assets = @($Feed.assets)
    if ($assets.Count -eq 0) {
        # The first create succeeded but its upload failed. An empty feed from
        # another commit/account is not authority to seed a new update channel.
        if ($Feed.target_commitish -cne $Commit -or $Feed.author.login -cne 'github-actions[bot]') {
            throw 'preview_feed_empty_release_not_owned'
        }
        return $null
    }
    if ($assets.Count -ne 1 -or $assets[0].name -cne 'windows-x64.json' -or
        $assets[0].size -le 0 -or $assets[0].size -gt 32768 -or
        $assets[0].digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'preview_feed_foreign_assets' }
    return $assets[0]
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$repo = 'Extectick/ExVPN'
$feedTitle = 'ExVPN Windows beta updates'
$feedNotes = 'Signed Windows beta update feed. Installers are published in immutable version releases. Windows publisher signing and stable acceptance remain pending.'
$commit = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $env:GITHUB_REPOSITORY -cne $repo -or
    $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
    $env:GITHUB_SHA -cne $commit -or !$env:GH_TOKEN -or !$env:EXVPN_WINDOWS_UPDATE_SEED_BASE64) {
    throw 'preview_feed_requires_authorized_release_dispatch'
}
$parts = $ReleaseVersion.Split('+')
$tag = "v$($parts[0])"
$folder = Join-Path $repository 'artifacts/preview/windows'
$build = Get-Content -LiteralPath (Join-Path $folder 'windows-build.json') -Raw | ConvertFrom-Json
if ($build.version -cne $ReleaseVersion -or $build.sourceCommit -cne $commit -or $build.stableReady -or
    $build.artifact.file -cne "ExVPN-$($parts[0])-$($parts[1])-windows-x64-development.exe") {
    throw 'preview_feed_build_identity_failed'
}
$binary = Join-Path $folder $build.artifact.file
$asset = Get-DemoAssetRecord $binary
if ($asset.sha256 -cne $build.artifact.sha256 -or $asset.bytes -ne $build.artifact.bytes) {
    throw 'preview_feed_local_asset_changed'
}
function Invoke-FeedGh([string[]]$Arguments) {
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'preview_feed_github_failed' }
    return $result
}
# Only advertise bytes already published in the immutable version release.
$release = Invoke-FeedGh @('api',"repos/$repo/releases/tags/$tag") | ConvertFrom-Json
$published = @($release.assets | Where-Object name -CEQ $asset.file)
if ($release.draft -or !$release.prerelease -or $release.target_commitish -cne $commit -or
    $published.Count -ne 1 -or $published[0].size -ne $asset.bytes -or
    $published[0].digest -cne "sha256:$($asset.sha256)") { throw 'preview_feed_remote_asset_mismatch' }
$work = Join-Path $repository ('.private/windows-feed-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$seedFile = Join-Path $work 'signing.seed'
try {
    try { $seed = [Convert]::FromBase64String($env:EXVPN_WINDOWS_UPDATE_SEED_BASE64) }
    catch { throw 'preview_feed_signing_input_invalid' }
    if ($seed.Length -ne 32) { throw 'preview_feed_signing_input_invalid' }
    [IO.File]::WriteAllBytes($seedFile, $seed)
    [Array]::Clear($seed)
    $env:EXVPN_WINDOWS_UPDATE_SEED_BASE64 = ''
    # The offline signer requires the original, byte-bound package identity.
    $stagedBinary = Join-Path $work $asset.file
    Copy-Item -LiteralPath $binary -Destination $stagedBinary
    [ordered]@{file=$asset.file;version=$parts[0];build=[int]$parts[1];sha256=$asset.sha256} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $work 'artifact.json') -Encoding utf8
    $feeds = @(Invoke-FeedGh @('release','list','--repo',$repo,'--limit','100','--json','tagName') | ConvertFrom-Json)
    $exists = @($feeds | Where-Object tagName -CEQ 'windows-beta').Count -eq 1
    $arguments = @((Join-Path $PSScriptRoot 'sign-windows-update.py'), '--artifact', $stagedBinary,
        '--url', "https://github.com/$repo/releases/download/$tag/$($asset.file)",
        '--seed-file', $seedFile, '--output', (Join-Path $work 'windows-x64.json'))
    if ($exists) {
        $existingFeed = Invoke-FeedGh @('api',"repos/$repo/releases/tags/windows-beta") | ConvertFrom-Json
        $existingAsset = Get-FeedResumeAsset $existingFeed $commit $feedTitle $feedNotes
        if ($null -ne $existingAsset) {
            $previous = Join-Path $work 'previous'
            New-Item -ItemType Directory -Path $previous | Out-Null
            $null = Invoke-FeedGh @('release','download','windows-beta','--repo',$repo,'--pattern','windows-x64.json','--dir',$previous)
            $previousPath = Join-Path $previous 'windows-x64.json'
            $previousHash = Get-DemoSha256 $previousPath
            if ($existingAsset.size -ne (Get-Item -LiteralPath $previousPath).Length -or
                $existingAsset.digest -cne "sha256:$previousHash") { throw 'preview_feed_previous_asset_changed' }
            $arguments += @('--previous', $previousPath, '--resume-identical')
        }
    }
    & python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'preview_feed_signing_refused' }
    $hash = Get-DemoSha256 (Join-Path $work 'windows-x64.json')
    if ($exists -and $arguments -ccontains '--previous' -and $hash -ceq $previousHash) {
        # The signer authenticated every field and copied the exact unexpired
        # prior envelope. Do not delete/reupload it or extend its validity.
        Write-Host "Signed Windows beta feed already advertises identical $ReleaseVersion; no upload needed."
        return
    }
    if (!$exists) {
        $notes = Join-Path $work 'feed-notes.md'
        [IO.File]::WriteAllText($notes, $feedNotes)
        $null = Invoke-FeedGh @('release','create','windows-beta','--repo',$repo,'--target',$commit,
            '--title',$feedTitle,'--notes-file',$notes,'--prerelease','--latest=false')
    }
    # This single signed pointer is intentionally mutable. Version artifacts
    # and their tags are never replaced; concurrency is serialized in workflow.
    $null = Invoke-FeedGh @('release','upload','windows-beta',(Join-Path $work 'windows-x64.json'),'--repo',$repo,'--clobber')
    $feed = Invoke-FeedGh @('api',"repos/$repo/releases/tags/windows-beta") | ConvertFrom-Json
    $manifestAsset = @($feed.assets | Where-Object name -CEQ 'windows-x64.json')
    if ($manifestAsset.Count -ne 1 -or $manifestAsset[0].digest -cne "sha256:$hash") { throw 'preview_feed_published_hash_failed' }
    Write-Host "Signed Windows beta feed now advertises $ReleaseVersion; stable acceptance remains open."
} finally {
    if (Test-Path -LiteralPath $seedFile) { Remove-Item -LiteralPath $seedFile }
    $env:EXVPN_WINDOWS_UPDATE_SEED_BASE64 = ''
}
