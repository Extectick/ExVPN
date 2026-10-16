# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([Parameter(Mandatory)][ValidateSet('Corrupt','Restart','Restore')][string]$Action,[switch]$ConfirmDisposableGuest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$inputRoot='C:\ExVPN-App-QA'
$outputRoot='C:\ExVPN-App-QA-Results'
$controlRoot='C:\Program Files\ExVPN UI QA Control'
$serviceExe='C:\Program Files\ExVPN Service\exvpn-service.exe'
$backupFile=Join-Path $controlRoot 'policy-backup.bin'
$backupState=Join-Path $controlRoot 'policy-backup.json'
if (!$ConfirmDisposableGuest -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable System runner required.' }
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or $marker.policyRecovery -notin @('reset','reopen') -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'Policy recovery guest marker required.' }
trap {
    if (Test-Path -LiteralPath $outputRoot -PathType Container) {
        [ordered]@{action=$Action;failed=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'policy-control-error.json') -Encoding utf8
    }
    exit 1
}
$common=@($marker.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'Helper checksum mismatch.' }
. (Join-Path $inputRoot 'package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
Assert-ProtectedPackage $controlRoot
$state=Get-Content -LiteralPath (Join-Path $controlRoot 'state.json') -Raw | ConvertFrom-Json
$service=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
if ($state.ownerSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $state.build -ne $marker.build -or $service.StartName -ne 'LocalSystem' -or $service.PathName -cne $state.qaCommand -or (Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant() -cne $state.serviceSha256) { throw 'Owned service identity differs.' }
if (Get-Process -Name exvpn -ErrorAction SilentlyContinue) { throw 'Close the owned application before controlling its storage.' }
function Assert-Idle {
    if (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) { throw 'Active tunnel refused.' }
    $json=& (Join-Path $inputRoot 'ui\qa-guard.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Guard inspection failed.' }
    $guard=$json | ConvertFrom-Json
    if ($guard.readFailed -or $guard.guardArmed) { throw 'Protected traffic must be explicitly disconnected first.' }
}
function Stop-Maintenance {
    Assert-Idle
    $current=Get-Service ExVPNService
    if ($current.Status -eq 'Running') {
        & "$env:SystemRoot\System32\sc.exe" control ExVPNService 128 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Maintenance refused.' }
        $current.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))
    } elseif ($current.Status -ne 'Stopped') { throw 'Service transitioning.' }
    $current=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    if ($current.ExitCode -ne 0 -or $current.ServiceSpecificExitCode -ne 0) { throw 'Maintenance failed.' }
    Assert-Idle
}
Assert-Idle
$hive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
$key=$null
try {
    $key=$hive.OpenSubKey(('SOFTWARE\ExVPN.ServicePolicy.v1\'+$state.ownerSid),$true)
    if (!$key) { throw 'Installed policy is absent.' }
    $acl=$key.GetAccessControl()
    if (!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Policy ACL differs.' }
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { throw 'Policy ACL differs.' }
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule=@($rules | Where-Object { $_.IdentityReference.Value -ceq $sid })
        if ($rule.Count -ne 1 -or $rule[0].IsInherited -or $rule[0].AccessControlType -ne 'Allow' -or $rule[0].RegistryRights -ne 'FullControl') { throw 'Policy ACL differs.' }
    }
    if ($Action -eq 'Corrupt') {
        if ($marker.policyRecovery -ne 'reset' -or (Test-Path -LiteralPath $backupFile) -or (Test-Path -LiteralPath $backupState)) { throw 'Another recovery session exists.' }
        Stop-Maintenance
        if ($key.GetValueKind('policy') -ne [Microsoft.Win32.RegistryValueKind]::Binary) { throw 'Expected existing encrypted policy.' }
        [byte[]]$bytes=$key.GetValue('policy')
        if ($bytes.Length -lt 1 -or $bytes.Length -gt 266240) { throw 'Policy backup size refused.' }
        [IO.File]::WriteAllBytes($backupFile,$bytes)
        Set-ProtectedPackageACL $backupFile
        [ordered]@{runId=$marker.runId;ownerSid=$state.ownerSid;sha256=(Get-FileHash -LiteralPath $backupFile).Hash.ToLowerInvariant()} | ConvertTo-Json | Set-Content -LiteralPath $backupState -Encoding utf8
        Set-ProtectedPackageACL $backupState
        # Fixed invalid ciphertext, never attacker-supplied paths or preferences.
        $key.SetValue('policy',[byte[]](0x45,0x58,0x56,0x50,0x4e),[Microsoft.Win32.RegistryValueKind]::Binary)
        $key.Flush()
    } else {
        $backup=Get-Content -LiteralPath $backupState -Raw | ConvertFrom-Json
        if ($backup.runId -cne $marker.runId -or $backup.ownerSid -cne $state.ownerSid -or (Get-FileHash -LiteralPath $backupFile).Hash.ToLowerInvariant() -cne $backup.sha256) { throw 'Owned backup verification failed.' }
        Stop-Maintenance
        if ($Action -eq 'Restore') {
            $key.SetValue('policy',[IO.File]::ReadAllBytes($backupFile),[Microsoft.Win32.RegistryValueKind]::Binary)
            $key.Flush()
        }
    }
    Start-Service ExVPNService
    (Get-Service ExVPNService).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    Assert-Idle
    if ($Action -eq 'Restore') {
        # Exact files owned by this verified session, no recursive deletion.
        Remove-Item -LiteralPath $backupFile,$backupState
    }
    [ordered]@{runId=$marker.runId;action=$Action;serviceRunning=$true;guardArmed=$false;tunnelAbsent=$true;hostNetworkChanged=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot ('policy-'+$Action+'.json')) -Encoding utf8
} finally {
    if ($key) { $key.Dispose() }
    $hive.Dispose()
}
