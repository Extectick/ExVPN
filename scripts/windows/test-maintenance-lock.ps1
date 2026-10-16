# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
$script:held=$false; $script:requestedNames=@(); $script:reportedAcl=$null; $script:waitCalls=0
function New-MachineMaintenanceMutex([string]$Name,[Security.AccessControl.MutexSecurity]$Security) {
    $script:requestedNames += $Name
    if (!$script:reportedAcl) { $script:reportedAcl=$Security }
    $mock=[pscustomobject]@{owns=$false;disposed=$false}
    $mock | Add-Member ScriptMethod GetAccessControl { $script:reportedAcl }
    $mock | Add-Member ScriptMethod WaitOne {
        param($Timeout)
        if ($Timeout -ne 0) { throw 'Maintenance lock must be nonblocking.' }
        $script:waitCalls++
        if ($script:held) { return $false }
        $script:held=$true; $this.owns=$true; return $true
    }
    $mock | Add-Member ScriptMethod ReleaseMutex { if (!$this.owns) { throw 'Released an unowned mutex.' }; $script:held=$false; $this.owns=$false }
    $mock | Add-Member ScriptMethod Dispose { $this.disposed=$true }
    $mock
}
function Must-Reject([scriptblock]$Action,[string]$Reason) {
    $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }
    if (!$failed) { throw "Expected rejection: $Reason" }
}
# Structurally simulate two elevated setup processes with different IPC owners.
# Both MUST request the same machine object; the UI-owner mutex is separate.
$OwnerSid='S-1-5-21-100-200-300-1001'
$first=Enter-MachineMaintenanceLock
$OwnerSid='S-1-5-21-100-200-300-1002'
Must-Reject { Enter-MachineMaintenanceLock } 'cross-owner contention'
if (!$script:held -or !$first.owns) { throw 'Contending caller released the active operation.' }
$first.ReleaseMutex(); $first.Dispose()
$second=Enter-MachineMaintenanceLock
$second.ReleaseMutex(); $second.Dispose()
if (@($script:requestedNames | Sort-Object -Unique).Count -ne 1 -or $script:requestedNames[0] -cne 'Global\ExVPN.PackageMaintenance.v1') { throw 'Machine lock varied with IPC owner.' }
$trusted=$script:reportedAcl
$malicious=[Security.AccessControl.MutexSecurity]::new()
$malicious.SetSecurityDescriptorSddlForm($trusted.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
$malicious.SetOwner([Security.Principal.SecurityIdentifier]::new($OwnerSid))
$script:reportedAcl=$malicious; $calls=$script:waitCalls
Must-Reject { Enter-MachineMaintenanceLock } 'precreated user-owned mutex'
if ($script:waitCalls -ne $calls) { throw 'Untrusted mutex was acquired before ACL inspection.' }
$malicious.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
$malicious.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new($OwnerSid),[Security.AccessControl.MutexRights]::Synchronize,[Security.AccessControl.AccessControlType]::Allow))
Must-Reject { Enter-MachineMaintenanceLock } 'unexpected user ACE'
$script:reportedAcl=$trusted
# Keep the placement invariant: no installed-state inspection may precede the
# global lease. This parses the actual entry point without executing it.
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer/package.ps1') -Raw
if ($source.IndexOf('$maintenanceLock = Enter-MachineMaintenanceLock') -gt $source.IndexOf('$current = Read-InstalledState')) { throw 'Installed state read occurs before machine lock.' }
Write-Host 'Machine maintenance mutex cross-owner contention, nonblocking lifetime, owner/ACL hijack refusal and preflight ordering passed (mock handles; no elevation/system objects).'
