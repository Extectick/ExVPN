#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputDirectory,
    [string]$ExpectedVersion = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'android-notice-inputs.ps1')
Assert-AndroidNoticeSeal $repository $InputDirectory $ExpectedVersion
Assert-AndroidNoticeNativeInfo $repository $InputDirectory
Write-Host 'Android native/notices snapshot verified against current app, native inputs and pinned dependencies.'
