# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
# Explicit cold-cache preparation only; the actual AOT builder remains offline.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseReceipt,
    [switch]$OnlineDependencies,
    [string]$Repository=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'source-driver.ps1')
$root=[IO.Path]::GetFullPath($Repository)
. (Join-Path $root 'scripts/release/flutter-runtime-inputs.ps1')
. (Join-Path $root 'scripts/release/shorebird-pipeline-lib.ps1')
$receiptPath=Resolve-ExvpnOtaPath $root $BaseReceipt
if((Get-Item -LiteralPath $receiptPath).Length -gt 16MB){throw 'ota_driver_base_receipt_oversized'}
$receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json -AsHashtable
if($receipt.schemaVersion -ne 1 -or $receipt.delivery -cne 'independent' -or $receipt.target -cnotin @('Windows','Android') -or
    $receipt.flutterRevision -cne (Get-ExvpnOtaDriverPolicy).flutterRevision -or $receipt.engineRevision -cne '4b936a0c03e13389ddfb1ac48823f187964975c2' -or
    $receipt.tools.dart.path -cne 'bin/cache/dart-sdk/bin/dart.exe' -or $receipt.tools.dart.sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'ota_driver_base_receipt_invalid'}
$runtime=Get-ReleaseFlutterRuntime -Repository $root -Target $receipt.target -FlutterRuntime shorebird -FlutterBuildMode release
$dart=Resolve-ExvpnOtaPath $runtime.SdkRoot $receipt.tools.dart.path
if((Get-ExvpnOtaSha256 $dart) -cne $receipt.tools.dart.sha256){throw 'ota_driver_dart_pin_mismatch'}
$private=New-ShorebirdPrivateDirectory $root 'ota-driver-prepare'
$driver=Initialize-ExvpnOtaSourceDriver $root $runtime.SdkRoot $dart $private -OnlineDependencies:$OnlineDependencies
Assert-ExvpnOtaSourceDriver $runtime.SdkRoot $driver
[ordered]@{prepared=$true;onlineDependencies=[bool]$OnlineDependencies;sdkCommit=$driver.sdkCommit;dependencyLockSha256=$driver.dependencyLockSha256}|ConvertTo-Json -Compress
