#requires -Version 7.0
[CmdletBinding()]
param([switch]$Offline)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'nsis-audit-lib.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pin = Get-Content (Join-Path $PSScriptRoot 'archive-inspector.lock.json') -Raw | ConvertFrom-Json
$downloads = Join-Path $repository '.tools/downloads'
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
Assert-AuditNoLinks $downloads
foreach ($item in @($pin.bootstrap, $pin.archive)) {
    $path = Join-Path $downloads $item.file
    if (!(Test-Path -LiteralPath $path)) {
        if ($Offline) { throw 'archive_inspector_download_missing' }
        Invoke-WebRequest -Uri $item.url -OutFile $path -TimeoutSec 60
    }
    Assert-AuditNoLinks $path
    if ((Get-AuditSha256 $path) -cne $item.sha256) { throw 'archive_inspector_download_mismatch' }
}
$destination = Join-Path $repository ".tools/7zip-$($pin.version)"
if (!(Test-Path -LiteralPath $destination)) {
    # Only these three root entries are extracted. No installer is executed.
    $arguments = @('e', (Join-Path $downloads $pin.archive.file), '7z.exe', '7z.dll', 'License.txt', "-o$destination", '-y', '-bso0', '-bsp0', '-bse0')
    [void](Invoke-AuditExtractor (Join-Path $downloads $pin.bootstrap.file) $arguments 65536 30)
}
[void](Get-AuditArchiveInspector $repository)
Write-Host "7-Zip $($pin.version) audit tools verified; no system installation."
