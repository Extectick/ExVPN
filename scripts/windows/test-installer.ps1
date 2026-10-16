# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
$root = Join-Path $repository ('artifacts/windows/package-test-' + [Guid]::NewGuid().ToString('N'))
if (!$root.StartsWith($repository + '\artifacts\windows\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture root escaped workspace.' }
New-Item -ItemType Directory -Path $root | Out-Null
function Must-Reject([scriptblock]$Operation, [string]$Name) {
    $rejected = $false
    try { & $Operation } catch { $rejected = $true }
    if (!$rejected) { throw "Expected rejection: $Name" }
}
$known = Join-Path $root 'owned.txt'; Set-Content -LiteralPath $known -Value 'fixture'
$records = @(Get-TreeManifest $root)
Assert-TreeManifest $root $records
foreach ($bad in @('../outside.txt','C:\outside.txt','nested/../../outside.txt','owned.txt:stream','\\server\share\file')) { Must-Reject { Get-OwnedPath $root $bad } 'escaping/ADS path' }
$backupName = 'c7880ae4-094d-4f3e-8ad0-48247f0df5a0'
if ((Assert-RollbackPath $root (Join-Path $root $backupName)) -ne (Join-Path $root $backupName)) { throw 'Valid rollback path rejected.' }
foreach ($bad in @($backupName,(Join-Path $root "nested/$backupName"),(Join-Path $root ('-'*36)),(Join-Path $root "../$backupName"))) { Must-Reject { Assert-RollbackPath $root $bad } 'unowned rollback path' }
Must-Reject { Assert-TreeManifest $root @($records[0],$records[0]) } 'duplicate target'
$unknown = Join-Path $root 'unknown.txt'; Set-Content -LiteralPath $unknown -Value 'keep'
Must-Reject { Remove-OwnedTree $root $records } 'unknown file cleanup'
if (!(Test-Path -LiteralPath $known) -or !(Test-Path -LiteralPath $unknown)) { throw 'Preflight deleted files before detecting unknown contents.' }
Remove-Item -LiteralPath $unknown
Set-Content -LiteralPath $known -Value 'modified'
Must-Reject { Remove-OwnedTree $root $records } 'changed file cleanup'
if (!(Test-Path -LiteralPath $known)) { throw 'Modified file was deleted.' }
Set-Content -LiteralPath $known -Value 'fixture'
Assert-TreeManifest $root $records
Remove-OwnedTree $root $records
if (Test-Path -LiteralPath $root) { throw 'Known-file cleanup failed.' }
foreach ($script in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse) {
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$null,[ref]$parseErrors)>$null
    if ($parseErrors.Count) { throw "$($script.Name): $parseErrors" }
}
Write-Host 'Installer manifest, traversal, duplicate, unknown/changed-file refusal and known-only cleanup passed. No system installation performed.'
& (Join-Path $PSScriptRoot 'test-package-recovery.ps1')
& (Join-Path $PSScriptRoot 'test-maintenance-lock.ps1')
