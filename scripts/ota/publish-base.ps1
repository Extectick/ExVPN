# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
# Promote the exact independent APK/EXE only after both device OTA roundtrips.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$BaseSourceCommit,
    [Parameter(Mandatory)][string]$AndroidBaseReceipt,
    [Parameter(Mandatory)][string]$WindowsBaseReceipt,
    [Parameter(Mandatory)][string]$RuntimeEvidence,
    [string]$AndroidSdkPath='',
    [switch]$Publish,
    [switch]$DeferRuntimeVerification
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$arguments=@{ReleaseVersion=$ReleaseVersion;BaseSourceCommit=$BaseSourceCommit;AndroidBaseReceipt=$AndroidBaseReceipt;WindowsBaseReceipt=$WindowsBaseReceipt;RuntimeEvidence=$RuntimeEvidence;Independent=$true;PublishCloud=[bool]$Publish}
if ($DeferRuntimeVerification) { $arguments.DeferRuntimeVerification = $true }
if ($AndroidSdkPath) { $arguments.AndroidSdkPath=$AndroidSdkPath }
& (Join-Path $PSScriptRoot '../release/publish-shorebird-preview.ps1') @arguments
