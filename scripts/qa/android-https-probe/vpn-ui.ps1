# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^emulator-[0-9]{4,5}$')][string]$Serial,
    [Parameter(Mandatory)][ValidateSet('observe','connect','disconnect')][string]$Command,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$AndroidSdkPath = (Join-Path $env:LOCALAPPDATA 'Android/Sdk')
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../android-lifecycle-tools.ps1')
try {
    Initialize-AndroidLifecycleQa -Serial $Serial -OutputDirectory $OutputDirectory -AndroidSdkPath $AndroidSdkPath
    $result=Invoke-AndroidLifecycleVpnUi -Command $Command -Step ('vpn-ui-'+[guid]::NewGuid().ToString('N'))
    $result | ConvertTo-Json -Compress
    if ($result.status -cin @('observed','completed')) { exit 0 }
    exit 1
} catch {
    # Raw ADB errors and UI data are never echoed by this public wrapper.
    [ordered]@{mechanism='instrumentation_semantics_v1';command=$Command;status='host_refused'} | ConvertTo-Json -Compress
    exit 1
}
