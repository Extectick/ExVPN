# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([string]$Repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'build-impact-lib.ps1')
$decision=Get-BuildImpactEventDecision -Repository $Repository
$skip=if ($decision.skipNativeBuild) { 'true' } else { 'false' }
if ($env:GITHUB_OUTPUT) {
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT,"skip_native_build=$skip`nreason=$($decision.reason)`n",[Text.UTF8Encoding]::new($false))
}
Write-Host "Native build decision: $($decision.reason); skip_native_build=$skip. All check suites remain required."
if ($decision.skipNativeBuild) { Write-Host 'QA-only push: this run provides no new APK/EXE build proof and uploads no native build artifacts.' }
$decision | ConvertTo-Json -Compress
