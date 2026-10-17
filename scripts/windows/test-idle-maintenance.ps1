# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# The real Get-Service cmdlet loads this assembly in Windows PowerShell 5.1.
# Its fixture double must supply the enum without querying the host SCM.
Add-Type -AssemblyName System.ServiceProcess
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'installer/package.ps1'),[ref]$null,[ref]$errors)
if ($errors.Count) { throw 'Package source failed syntax validation.' }
foreach ($name in @('Get-PackageMaintenanceControl','Stop-OwnedService')) {
    $definitions=@($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name },$false))
    if ($definitions.Count -ne 1) { throw 'Missing actual idle-maintenance function.' }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$RequireDisconnected=$true
$roots=@{service='Z:\forbidden-real-guard-recovery'}
function Assert-OwnedService($State) {
    if ($script:currentState -eq 'absent') { return $null }
    [pscustomobject]@{State=$script:currentState;ExitCode=0;ServiceSpecificExitCode=0}
}
function Request-OwnedServiceStop([int]$Control) {
    $script:requested++
    if ($Control -ne 129) { throw 'Automatic update invoked a disconnecting SCM control.' }
}
function Get-Service([string]$Name) {
    if ($Name -cne 'ExVPNService') { throw 'Unexpected service query.' }
    $mock=[pscustomobject]@{}
    $mock | Add-Member ScriptMethod WaitForStatus {
        param($Status,$Timeout)
        if ($script:reject) { throw 'Synthetic SCM129 refusal or unsupported old service.' }
        $script:currentState='Stopped'
    }
    return $mock
}
function Get-NetAdapter {
    [CmdletBinding()]param([string]$Name)
    if ($Name -cne 'ExVPN-Tunnel') { throw 'Unexpected adapter query.' }
    if ($script:adapter) { return [pscustomobject]@{Name=$Name} }
}
$checks=0
foreach ($scenario in @('absent','stopped','transition','active-refused','old-service','idle','adapter-remains')) {
    $script:currentState=switch ($scenario) { 'absent' {'absent'}; 'stopped' {'Stopped'}; 'transition' {'Stop Pending'}; default {'Running'} }
    $script:requested=0
    $script:reject=$scenario -in @('active-refused','old-service')
    $script:adapter=$scenario -eq 'adapter-remains'
    $refused=$false
    try { Stop-OwnedService ([pscustomobject]@{}) } catch { $refused=$true }
    if ($scenario -eq 'idle') {
        if ($refused -or $script:currentState -ne 'Stopped' -or $script:requested -ne 1) { throw 'Confirmed idle service did not stop without guard recovery.' }
    } elseif (!$refused) { throw 'Unsafe automatic maintenance was accepted.' }
    if ($scenario -in @('absent','stopped','transition') -and $script:requested -ne 0) { throw 'Unconfirmed service received an automatic stop.' }
    if ($scenario -in @('active-refused','old-service') -and $script:currentState -ne 'Running') { throw 'Refused automatic maintenance changed a running service.' }
    $checks++
}
Write-Host "$checks idle-maintenance installer fixtures passed. SCM and adapter queries were mocked; no service or guard changed."
