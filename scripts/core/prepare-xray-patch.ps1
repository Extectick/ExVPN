# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$LockPath = '',
    [string]$UpstreamZipPath = '',
    [string]$OutputRoot = '',
    [switch]$Offline
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'xray-patch-lib.ps1')
if (!$LockPath) { $LockPath = Join-Path $repository 'native/patches/xray-lifecycle.lock.json' }
$LockPath = [IO.Path]::GetFullPath($LockPath)
$pin = Get-XrayPatchLock $LockPath
$lock = $pin.Value
$patchPath = Join-Path ([IO.Path]::GetDirectoryName($LockPath)) $lock.patch.path
Assert-AuditNoLinks $patchPath
if ((Get-AuditSha256 $patchPath) -cne $lock.patch.sha256) { throw 'xray_patch_sha256_mismatch' }
[void](Assert-XrayPatchText $patchPath)
if (!$OutputRoot) { $OutputRoot = Join-Path $repository '.tools/go-proxy/xray' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$allowed = @('.tools','artifacts') | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $repository $_)) + [IO.Path]::DirectorySeparatorChar }
if (!@($allowed | Where-Object { $OutputRoot.StartsWith($_,[StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'xray_patch_output_outside_workspace_cache' }
$ancestor = $OutputRoot
while (!(Test-Path -LiteralPath $ancestor)) { $ancestor=[IO.Path]::GetDirectoryName($ancestor) }
Assert-AuditNoLinks $ancestor
$versionRoot = Join-Path $OutputRoot $lock.patched.version
$destination = Join-Path $versionRoot $pin.Sha256
if (Test-Path -LiteralPath $destination) { return Assert-XrayProxy $destination $lock $pin.Sha256 }

[IO.Directory]::CreateDirectory($versionRoot) | Out-Null
Assert-AuditNoLinks $versionRoot
$staging = Join-Path $versionRoot ('staging-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($staging) | Out-Null
$sourceZip = Join-Path $staging 'upstream.zip'
if (!$UpstreamZipPath) {
    $candidate = Join-Path $repository ".tools/cache/go/pkg/mod/cache/download/$($lock.module)/@v/$($lock.upstream.version).zip"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $UpstreamZipPath=$candidate }
}
if ($UpstreamZipPath) {
    Assert-AuditNoLinks $UpstreamZipPath
    Copy-Item -LiteralPath $UpstreamZipPath -Destination $sourceZip
} else {
    if ($Offline) { throw 'xray_patch_verified_upstream_zip_unavailable_offline' }
    # A single pinned official archive; no SDK, latest lookup, module cache write,
    # package source execution or global Go configuration change.
    $url = "https://proxy.golang.org/$($lock.module)/@v/$($lock.upstream.version).zip"
    & curl.exe --fail --location --connect-timeout 15 --max-time 120 --silent --show-error --output $sourceZip $url
    if ($LASTEXITCODE -ne 0) { throw 'xray_patch_upstream_download_failed' }
}
if ((Get-AuditSha256 $sourceZip) -cne $lock.upstream.zipSha256) { throw 'xray_patch_upstream_sha256_mismatch' }
[void](Assert-XrayModuleZip $sourceZip $lock.module $lock.upstream.version $lock.upstream.sum $lock.upstream.goModSum)
$extract = Join-Path $staging 'source'
[IO.Compression.ZipFile]::ExtractToDirectory($sourceZip,$extract)
$tree = Join-Path $extract "$($lock.module)@$($lock.upstream.version)"
Assert-AuditNoLinks $tree
$patchCopy = Join-Path $staging 'verified.patch'
Copy-Item -LiteralPath $patchPath -Destination $patchCopy
if ((Get-AuditSha256 $patchCopy) -cne $lock.patch.sha256) { throw 'xray_patch_sha256_mismatch' }
$template = Join-Path $staging 'empty-git-template'
[IO.Directory]::CreateDirectory($template) | Out-Null
Invoke-XrayGit $tree @('init','--quiet',"--template=$template")
Invoke-XrayGit $tree @('apply','--check','--whitespace=nowarn',$patchCopy)
Invoke-XrayGit $tree @('apply','--whitespace=nowarn',$patchCopy)

$proxy = Join-Path $staging 'proxy'
$versions = Join-Path $proxy "$($lock.module)/@v"
[IO.Directory]::CreateDirectory($versions) | Out-Null
$zip = Join-Path $versions "$($lock.patched.version).zip"
New-XrayModuleZip $tree $zip $lock.module $lock.patched.version
[void](Assert-XrayModuleZip $zip $lock.module $lock.patched.version $lock.patched.sum $lock.patched.goModSum)
$mod = Read-AuditZipBytes $zip "$($lock.module)@$($lock.patched.version)/go.mod" 1MB
[IO.File]::WriteAllBytes((Join-Path $versions "$($lock.patched.version).mod"),$mod)
Write-AuditJson (Join-Path $versions "$($lock.patched.version).info") ([ordered]@{Version=$lock.patched.version;Time=$lock.patched.time})
[IO.File]::WriteAllText((Join-Path $versions 'list'),"$($lock.patched.version)`n",[Text.UTF8Encoding]::new($false))
Write-AuditJson (Join-Path $proxy 'provenance.json') (Get-XrayProxyProvenance $lock $pin.Sha256 (Get-AuditSha256 $zip))
[void](Assert-XrayProxy $proxy $lock $pin.Sha256)
if ((Get-AuditSha256 $LockPath) -cne $pin.Sha256 -or (Get-AuditSha256 $patchPath) -cne $lock.patch.sha256) { throw 'xray_patch_inputs_changed_during_preparation' }
try { [IO.Directory]::Move($proxy,$destination) }
catch {
    # Another native lane may have published the same verified immutable proxy.
    # Never replace it. The full content checks below decide whether it is valid.
    if (!(Test-Path -LiteralPath $destination -PathType Container)) { throw }
}
$result = Assert-XrayProxy $destination $lock $pin.Sha256
# Staging is retained for inspection; no recursive deletion or overwriting of
# an earlier source tree/proxy is performed by this preparation step.
return $result
