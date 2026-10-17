#requires -Version 7.0
[CmdletBinding()]
param([string]$AndroidSdkPath = (Join-Path $env:LOCALAPPDATA 'Android/Sdk'))
$ErrorActionPreference = 'Stop'
$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $workspacePath 'scripts/bootstrap/enter-environment.ps1') -AndroidSdkPath $AndroidSdkPath
$androidJar = Join-Path $AndroidSdkPath 'platforms/android-36/android.jar'
$classes = Join-Path $workspacePath 'artifacts/android-network-probe-tests/classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null
& (Join-Path $env:JAVA_HOME 'bin/javac.exe') -source 8 -target 8 -classpath $androidJar -d $classes (Join-Path $PSScriptRoot 'HttpsProbe.java') (Join-Path $PSScriptRoot 'TraceIpv4Test.java') (Join-Path $PSScriptRoot 'DnsNonceTest.java') (Join-Path $PSScriptRoot 'TextInputPayload.java') (Join-Path $PSScriptRoot 'TextInputPayloadTest.java') (Join-Path $PSScriptRoot 'VpnUiSemantics.java') (Join-Path $PSScriptRoot 'VpnUiSemanticsTest.java')
if ($LASTEXITCODE -ne 0) { throw 'QA parser compilation failed.' }
& (Join-Path $env:JAVA_HOME 'bin/java.exe') -classpath $classes ru.exvpn.netprobe.TraceIpv4Test
if ($LASTEXITCODE -ne 0) { throw 'QA parser fixtures failed.' }
& (Join-Path $env:JAVA_HOME 'bin/java.exe') -classpath $classes ru.exvpn.netprobe.DnsNonceTest
if ($LASTEXITCODE -ne 0) { throw 'QA DNS nonce fixtures failed.' }
& (Join-Path $env:JAVA_HOME 'bin/java.exe') -classpath $classes ru.exvpn.netprobe.TextInputPayloadTest
if ($LASTEXITCODE -ne 0) { throw 'QA text input fixtures failed.' }
& (Join-Path $env:JAVA_HOME 'bin/java.exe') -classpath $classes ru.exvpn.netprobe.VpnUiSemanticsTest
if ($LASTEXITCODE -ne 0) { throw 'QA VPN UI fixtures failed.' }
