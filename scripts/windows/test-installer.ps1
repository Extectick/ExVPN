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
$serviceAcl = 'D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWLORC;;;IU)'
Assert-ServiceControlAcl $serviceAcl
# Exact SCM readback from Windows Sandbox; the OS audit SACL is independent.
Assert-ServiceControlAcl 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLORC;;;IU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)'
foreach ($bad in @(
    'D:NO_ACCESS_CONTROL',
    'D:',
    'D:(A;;GA;;;SY)(A;;GA;;;BA)',
    'D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;IU)',
    'D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWLORC;;;IU)(A;;RP;;;WD)',
    'D:(A;;GA;;;SY)(A;;GA;;;SY)(A;;CCLCSWLORC;;;IU)',
    'D:(D;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWLORC;;;IU)',
    'D:(A;CI;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWLORC;;;IU)',
    'D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWRPLORC;;;IU)'
)) { Must-Reject { Assert-ServiceControlAcl $bad } 'unsafe service DACL' }
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
$buildPinTests = Join-Path $PSScriptRoot 'test-app-updater-build.ps1'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    & $buildPinTests
} else {
    # Keep the real installer's PS5.1 fixtures in this host. The build script is
    # PS7-only, so validate its pins in the fixed installed PS7 host as well.
    # An unavailable host or a failing child is a failure, never a skipped gate.
    $powerShell7 = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'PowerShell\7\pwsh.exe'
    if (!(Test-Path -LiteralPath $powerShell7 -PathType Leaf)) { throw 'PowerShell 7 is required for updater build-pin fixtures.' }
    & $powerShell7 -NoLogo -NoProfile -NonInteractive -File $buildPinTests
    if ($LASTEXITCODE -ne 0) { throw 'PowerShell 7 updater build-pin fixtures failed.' }
}
& (Join-Path $PSScriptRoot 'test-idle-maintenance.ps1')
& (Join-Path $PSScriptRoot 'test-package-recovery.ps1')
& (Join-Path $PSScriptRoot 'test-maintenance-lock.ps1')
