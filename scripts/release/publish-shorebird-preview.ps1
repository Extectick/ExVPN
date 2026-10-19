# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Promotes the SAME audited bases after device patch+rollback QA. Never builds.
# Default validates/stages only; -PublishCloud explicitly writes GitHub+feeds.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$BaseSourceCommit,
    [Parameter(Mandatory)][string]$AndroidBaseReceipt,
    [Parameter(Mandatory)][string]$WindowsBaseReceipt,
    [Parameter(Mandatory)][string]$RuntimeEvidence,
    [string]$AndroidSdkPath='',
    [switch]$PublishCloud,
    [switch]$Independent
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'demo-release-lib.ps1')
. (Join-Path $PSScriptRoot 'demo-android-lib.ps1')
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
. (Join-Path $PSScriptRoot 'nsis-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-preview-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-publication-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-runtime-notices.ps1')
$repo='Extectick/ExVPN'
$head=Get-ShorebirdSourceCommit $repository
$null=Invoke-ShorebirdGit $repository @('merge-base','--is-ancestor',$BaseSourceCommit,$head)
$baseVersion=Get-NoticeAppVersion (Invoke-ShorebirdGit $repository @('show',"${BaseSourceCommit}:apps/exvpn/pubspec.yaml")) (Invoke-ShorebirdGit $repository @('show',"${BaseSourceCommit}:apps/exvpn/lib/build_identity.dart"))
if ($baseVersion -cne $ReleaseVersion) { throw 'shorebird_public_source_version_mismatch' }
if ($PublishCloud -and $env:GITHUB_ACTIONS -ceq 'true' -and
    ($env:GITHUB_REPOSITORY -cne $repo -or $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_SHA -cne $head)) { throw 'shorebird_public_requires_main_dispatch' }
if ($PublishCloud -and (!$env:EXVPN_WINDOWS_UPDATE_SEED_BASE64 -or !$env:GH_TOKEN)) { throw 'shorebird_public_dual_feed_signing_required' }
$bases=@{
    Android=(Get-ShorebirdPublicBase $repository $AndroidBaseReceipt $ReleaseVersion $BaseSourceCommit Android -Independent:$Independent)
    Windows=(Get-ShorebirdPublicBase $repository $WindowsBaseReceipt $ReleaseVersion $BaseSourceCommit Windows -Independent:$Independent)
}
if (!$Independent -and $bases.Android.base.releaseId -ne $bases.Windows.base.releaseId) { throw 'shorebird_public_cloud_release_ids_differ' }
Assert-AuditNoLinks $RuntimeEvidence
if ((Get-Item -LiteralPath $RuntimeEvidence).Length -gt 1MB) { throw 'shorebird_runtime_gate_oversized' }
$proof=Get-Content -LiteralPath $RuntimeEvidence -Raw | ConvertFrom-Json -AsHashtable
$receiptHashes=@{Android=$bases.Android.receiptSha256;Windows=$bases.Windows.receiptSha256}
$artifactHashes=@{Android=$bases.Android.binary.asset.sha256;Windows=$bases.Windows.binary.asset.sha256}
$safeProof=if ($Independent) { Assert-IndependentRuntimeGate $proof $ReleaseVersion $BaseSourceCommit $receiptHashes $artifactHashes } else { Assert-ShorebirdRuntimeGate $proof $ReleaseVersion $BaseSourceCommit $receiptHashes $artifactHashes }
$privateRun=New-ShorebirdPrivateDirectory $repository 'public-preview'
$stage=Join-Path $privateRun 'public'
New-Item -ItemType Directory -Path $stage | Out-Null
$phase='actual_package_inspection'
try {
    $public=Get-ShorebirdPublicKey $repository
    $sdk=Get-ReleaseAndroidSdkPath $AndroidSdkPath
    $java=if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/java.exe' } else { 'C:/Program Files/Android/Android Studio/jbr/bin/java.exe' }
    $expectedSigner=Get-DemoAndroidCertificateSha256 (Join-Path $repository 'config/signing/android-release-cert.pem') -Pem
    $apk=$bases.Android.binary.path
    $signature=ConvertFrom-DemoAndroidSignature (Invoke-AuditTool $java @('-jar',(Join-Path $sdk 'build-tools/36.0.0/lib/apksigner.jar'),'verify','--verbose','--print-certs',$apk)) $expectedSigner
    $identity=ConvertFrom-DemoAndroidIdentity (Invoke-AuditTool (Join-Path $sdk 'build-tools/36.0.0/aapt2.exe') @('dump','badging',$apk)) $ReleaseVersion
    if (($signature | ConvertTo-Json -Compress) -cne ($bases.Android.base.signature | ConvertTo-Json -Compress) -or
        ($identity | ConvertTo-Json -Compress) -cne ($bases.Android.base.android | ConvertTo-Json -Compress)) { throw 'shorebird_public_android_identity_changed' }
    $androidPolicy=[Text.UTF8Encoding]::new($false,$true).GetString((Read-AuditZipBytes $apk 'assets/flutter_assets/shorebird.yaml' 16KB))
    if ($Independent) { Assert-IndependentCompiledPolicy $androidPolicy $public.encoded }
    else { Assert-ShorebirdCompiledPolicy $androidPolicy $public.encoded }
    $apkFiles=Get-AuditZipFiles $apk -Apk
    $androidNoticeRoot=Join-Path $privateRun 'android-notices'
    $actualAndroidNotices=Expand-ShorebirdNoticeZip $apk 'assets/exvpn_notices/' $androidNoticeRoot $apkFiles
    Assert-ShorebirdNoticeMap $actualAndroidNotices $bases.Android.audit
    Assert-ShorebirdFileMaps (Get-AuditZipFiles $bases.Android.notices.path) $actualAndroidNotices
    $inventory=Get-Content -LiteralPath (Join-Path $androidNoticeRoot 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-ShorebirdRuntimeNotices $inventory (Get-ShorebirdRuntimeNotices $repository @{Identity=$bases.Android.base.runtime.identity}) $androidNoticeRoot

    # Read the actual installer with the pinned archive inspector; never launch
    # it or its uninstaller. Its whole-file hash was verified against both proofs.
    $inspector=Get-AuditArchiveInspector $repository
    $installer=$bases.Windows.binary.path
    $listing=ConvertFrom-AuditNsisListing ([Text.UTF8Encoding]::new($false,$true).GetString((Invoke-AuditExtractor $inspector.executable @('l','-slt','-sccUTF-8','-bse0',$installer))))
    $unpacked=Join-Path $privateRun 'windows-installer'
    $null=Expand-AuditNsis $inspector.executable $installer $unpacked $listing
    $payload=Join-Path $unpacked $listing.prefix
    $windowsPolicy=[IO.File]::ReadAllText((Join-Path $payload 'ui/data/flutter_assets/shorebird.yaml'))
    if ($Independent) { Assert-IndependentCompiledPolicy $windowsPolicy $public.encoded }
    else { Assert-ShorebirdCompiledPolicy $windowsPolicy $public.encoded }
    foreach ($path in @('data/app.so','flutter_windows.dll')) {
        if ((Get-AuditSha256 (Join-Path $payload "ui/$path")) -cne (Get-AuditSha256 (Join-Path $bases.Windows.root "ui/$path"))) { throw 'shorebird_public_windows_runtime_changed' }
    }
    $windowsNoticeRoot=Join-Path $payload 'control/notices'
    $actualWindowsNotices=Get-AuditTreeFiles $windowsNoticeRoot
    Assert-ShorebirdNoticeMap $actualWindowsNotices $bases.Windows.audit
    Assert-ShorebirdFileMaps (Get-AuditZipFiles $bases.Windows.notices.path) (Get-AuditTreeFiles (Join-Path $payload 'control'))
    $inventory=Get-Content -LiteralPath (Join-Path $windowsNoticeRoot 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-ShorebirdRuntimeNotices $inventory (Get-ShorebirdRuntimeNotices $repository @{Identity=$bases.Windows.base.runtime.identity}) $windowsNoticeRoot
    $phase='stage'
    $proofPath=Join-Path $stage 'shorebird-runtime-qa.json'
    $safeProof | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $proofPath -Encoding utf8NoBOM
    $qaHash=Get-AuditSha256 $proofPath
    foreach ($target in @('Android','Windows')) {
        $base=$bases[$target];$stem=$target.ToLowerInvariant()
        $folder=Join-Path $stage $stem
        New-Item -ItemType Directory -Path $folder | Out-Null
        foreach ($file in @($base.binary,$base.auditFile,$base.sbomFile,$base.notices)) {
            Copy-Item -LiteralPath $file.path -Destination (Join-Path $folder $file.asset.file)
        }
        # Full original base receipt has only bounded relative file names and
        # public SDK evidence, and its exact hash is covered by the runtime gate.
        Copy-Item -LiteralPath $base.receiptPath -Destination (Join-Path $stage "$stem-shorebird-base.json")
        if ($target -ceq 'Android') {
            foreach ($name in @('android-maven-notices.zip','android-maven-notices.json')) {
                $file=Get-ShorebirdBasePublicFile $base.root $base.base $name
                Copy-Item -LiteralPath $file.path -Destination (Join-Path $folder $name)
            }
            $maven=Get-Content -LiteralPath (Join-Path $folder 'android-maven-notices.json') -Raw | ConvertFrom-Json -AsHashtable
            if ($maven.status -cne 'PASS' -or $maven.appVersion -cne $ReleaseVersion -or $maven.apkSha256 -cne $base.binary.asset.sha256 -or
                $maven.archiveSha256 -cne (Get-AuditSha256 (Join-Path $folder 'android-maven-notices.zip'))) { throw 'shorebird_public_maven_binding_failed' }
        }
        $build=[ordered]@{
            schema=1;version=$ReleaseVersion;sourceCommit=$BaseSourceCommit;runtime='shorebird';syntheticProfiles=$false
            stableReady=$false;dartOtaAvailable=$true;artifact=$base.binary.asset;baseReceiptSha256=$base.receiptSha256
            runtimeQaSha256=$qaHash;notices=$base.notices.asset;flutterRuntime=$base.base.packagedRuntime
            signature=$(if ($target -ceq 'Android') {$signature} else {$null})
        }
        if ($Independent) { $build['otaProvider']='exvpn' }
        $build | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $folder "$stem-build.json") -Encoding utf8NoBOM
        Assert-ShorebirdPublicBuild $build $ReleaseVersion $BaseSourceCommit $base.binary.asset.file $base.binary.asset.sha256 $base.binary.asset.bytes
    }
    foreach ($target in @('Android','Windows')) { Assert-ShorebirdReceiptFiles $bases[$target].receiptPath $bases[$target].base }
    $output=Join-Path $repository ('artifacts/shorebird-preview/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($output)) -Force | Out-Null
    Assert-AuditNoLinks ([IO.Path]::GetDirectoryName($output))
    Move-Item -LiteralPath $stage -Destination $output
} catch {
    ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $privateRun 'failure.log') -Encoding utf8NoBOM
    throw "shorebird_public_validation_failed phase=$phase; private diagnostics retained"
}
if (!$PublishCloud) { [pscustomobject]@{DeliveryDirectory=$output;Published=$false};return }

$parts=$ReleaseVersion.Split('+');$tag="v$($parts[0])"
if ((Invoke-ShorebirdGit $repository @('rev-parse',"$tag^{}")) -cne $BaseSourceCommit) { throw 'shorebird_public_tag_must_match_base' }
function Invoke-ShorebirdGh([string[]]$Arguments) {
    $result=& gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'shorebird_public_github_failed' }
    $result
}
$tagRef=Invoke-ShorebirdGh @('api',"repos/$repo/git/ref/tags/$tag") | ConvertFrom-Json
$object=$tagRef.object
for ($depth=0;$depth -lt 5 -and $object.type -ceq 'tag';$depth++) {
    if ($object.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'shorebird_public_remote_tag_invalid' }
    $annotated=Invoke-ShorebirdGh @('api',"repos/$repo/git/tags/$($object.sha)") | ConvertFrom-Json
    $object=$annotated.object
}
if ($object.type -cne 'commit' -or $object.sha -cne $BaseSourceCommit) { throw 'shorebird_public_remote_tag_mismatch' }
$delivery=Join-Path $output 'delivery'
New-Item -ItemType Directory -Path $delivery | Out-Null
$files=@(Get-ChildItem -LiteralPath $output -File -Recurse)
foreach ($file in $files) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $delivery $file.Name) }
$notes=Invoke-ShorebirdGit $repository @('show',"${BaseSourceCommit}:docs/releases/$($parts[0]).md")
[IO.File]::WriteAllText((Join-Path $delivery 'RELEASE.md'),$notes + "`n",[Text.UTF8Encoding]::new($false))
$assets=@(Get-ChildItem -LiteralPath $delivery -File | ForEach-Object { Get-DemoAssetRecord $_.FullName })
$manifest=[ordered]@{schema=1;version=$parts[0];build=[int]$parts[1];channel='beta';tag=$tag;sourceCommit=$BaseSourceCommit;prerelease=$true;stableReady=$false;runtime='shorebird';dartOtaAvailable=$true;runtimeQaSha256=$qaHash;assets=$assets}
if ($Independent) { $manifest['otaProvider']='exvpn' }
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $delivery 'release-manifest.json') -Encoding utf8NoBOM
$assets+=Get-DemoAssetRecord (Join-Path $delivery 'release-manifest.json')
$assets | Sort-Object file | ForEach-Object { "$($_.sha256)  $($_.file)" } | Set-Content -LiteralPath (Join-Path $delivery 'SHA256SUMS.txt') -Encoding ascii
$assets+=Get-DemoAssetRecord (Join-Path $delivery 'SHA256SUMS.txt')
$releases=@(Invoke-ShorebirdGh @('release','list','--repo',$repo,'--limit','100','--json','tagName') | ConvertFrom-Json)
$uploaded=@();$existing=@($releases | Where-Object tagName -CEQ $tag).Count -eq 1
if ($existing) {
    $id=[string](Invoke-ShorebirdGh @('release','view',$tag,'--repo',$repo,'--json','databaseId','--jq','.databaseId'))
    if ($id -cnotmatch '^[1-9][0-9]*$') { throw 'shorebird_public_release_id_invalid' }
    $remote=Invoke-ShorebirdGh @('api',"repos/$repo/releases/$id") | ConvertFrom-Json
    if (!$remote.prerelease -or $remote.tag_name -cne $tag -or $remote.target_commitish -cne $BaseSourceCommit) { throw 'shorebird_public_release_identity_mismatch' }
    foreach ($asset in $remote.assets) {
        $local=@($assets | Where-Object file -CEQ $asset.name)
        if ($local.Count -ne 1 -or $local[0].bytes -ne $asset.size -or $asset.digest -cne ('sha256:'+$local[0].sha256)) { throw 'shorebird_public_existing_asset_changed' }
        $uploaded+=$asset.name
    }
    if (!$remote.draft -and $uploaded.Count -ne $assets.Count) { throw 'shorebird_public_published_asset_set_incomplete' }
} else {
    $null=Invoke-ShorebirdGh @('release','create',$tag,'--repo',$repo,'--target',$BaseSourceCommit,'--verify-tag','--title',"ExVPN $($parts[0]) Preview",'--notes-file',(Join-Path $delivery 'RELEASE.md'),'--draft','--prerelease','--latest=false')
}
$missing=@($assets | Where-Object file -CNotIn $uploaded)
if ($missing.Count) { $null=Invoke-ShorebirdGh (@('release','upload',$tag,'--repo',$repo) + @($missing | ForEach-Object { Join-Path $delivery $_.file })) }
$id=[string](Invoke-ShorebirdGh @('release','view',$tag,'--repo',$repo,'--json','databaseId','--jq','.databaseId'))
if ($id -cnotmatch '^[1-9][0-9]*$') { throw 'shorebird_public_release_id_invalid' }
$remote=Invoke-ShorebirdGh @('api',"repos/$repo/releases/$id") | ConvertFrom-Json
if (!$remote.prerelease -or $remote.target_commitish -cne $BaseSourceCommit -or $remote.tag_name -cne $tag -or $remote.assets.Count -ne $assets.Count) { throw 'shorebird_public_uploaded_identity_failed' }
foreach ($asset in $assets) {
    $match=@($remote.assets | Where-Object name -CEQ $asset.file)
    if ($match.Count -ne 1 -or $match[0].size -ne $asset.bytes -or $match[0].digest -cne ('sha256:'+$asset.sha256)) { throw 'shorebird_public_uploaded_asset_mismatch' }
}
if ($remote.draft) { $null=Invoke-ShorebirdGh @('release','edit',$tag,'--repo',$repo,'--draft=false','--prerelease','--latest=false') }
$seed=$env:EXVPN_WINDOWS_UPDATE_SEED_BASE64
try {
    foreach ($target in @('Windows','Android')) {
        $env:EXVPN_WINDOWS_UPDATE_SEED_BASE64=$seed
        & (Join-Path $PSScriptRoot 'publish-windows-feed.ps1') -ReleaseVersion $ReleaseVersion -Target $target -ShorebirdPreview -ShorebirdDeliveryDirectory $output -BaseSourceCommit $BaseSourceCommit
    }
} finally { $env:EXVPN_WINDOWS_UPDATE_SEED_BASE64=$null;$seed=$null }
[pscustomobject]@{DeliveryDirectory=$output;Published=$true;Url="https://github.com/$repo/releases/tag/$tag"}
