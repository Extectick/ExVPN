# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'demo-android-lib.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $repository ('artifacts/qa/demo-android-helpers-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$checks = 0
function Assert-True([bool]$Condition) {
    if (!$Condition) { throw 'demo_android_fixture_assertion_failed' }
    $script:checks++
}
function Assert-Refused([scriptblock]$Action) {
    $refused = $false
    try { $null = & $Action } catch { $refused = $true }
    Assert-True $refused
}

foreach ($name in @('demo-android-lib.ps1','build-demo-android.ps1')) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0)
}
Assert-DemoAndroidVersion '0.1.0+18'; $checks++
foreach ($value in @('0.1.0+17','0.1.0+19','0.1.1+18','0.1.0+018','')) {
    Assert-Refused { Assert-DemoAndroidVersion $value }
}
$arguments = @(Get-DemoAndroidBuildArguments)
Assert-True ($arguments -ccontains '--dart-define=EXVPN_DEMO=false' -and $arguments -cnotcontains '--dart-define=EXVPN_DEMO=true')
Assert-True ($arguments -ccontains '--release' -and $arguments -ccontains '--pub' -and $arguments -ccontains '--target=lib/main.dart')
Assert-True ($arguments -ccontains '--target-platform=android-arm64,android-x64' -and $arguments -ccontains '--build-number=18')
$jvmArguments = @(Get-DemoAndroidJvmArguments)
Assert-True ($jvmArguments[0] -ceq ':app:testReleaseUnitTest' -and $jvmArguments -cnotcontains ':app:testDebugUnitTest')
Assert-True ($jvmArguments -ccontains '-Pandroid.onlyEnableUnitTestForTheTestedBuildType=false' -and $jvmArguments -ccontains '--rerun')
Assert-True ($jvmArguments -cnotcontains '-x' -and $jvmArguments -cnotcontains '--rerun-tasks')
$missingTask = "Cannot locate tasks that match ':app:testReleaseUnitTest' as task 'testReleaseUnitTest' not found in project ':app'."
Assert-True ((Get-DemoAndroidGradleFailureCode $missingTask) -ceq 'demo_android_jvm_task_missing')
Assert-True ((Get-DemoAndroidGradleFailureCode ($missingTask + "`r`n")) -ceq 'demo_android_jvm_task_missing')
Assert-True ((Get-DemoAndroidGradleFailureCode ($missingTask + "`r`r`n")) -ceq 'demo_android_jvm_task_missing')
Assert-True ((Get-DemoAndroidGradleFailureCode ($missingTask.Replace('testReleaseUnitTest','testDebugUnitTest'))) -ceq 'demo_android_jvm_failed')
Assert-True ((Get-DemoAndroidGradleFailureCode "Execution failed for task ':app:testReleaseUnitTest'.`n> There were failing tests. See report") -ceq 'demo_android_jvm_test_failures')
Assert-True ((Get-DemoAndroidGradleFailureCode '> Task :app:verifyExVpnPackageInputs FAILED') -ceq 'demo_android_jvm_snapshot_failed')
Assert-True ((Get-DemoAndroidGradleFailureCode "Execution failed for task ':app:compileReleaseJavaWithJavac'.") -ceq 'demo_android_jvm_java_compile_failed')
Assert-True ((Get-DemoAndroidGradleFailureCode 'unknown error with synthetic SECRET credentials') -ceq 'demo_android_jvm_failed')

$fingerprint = 'a' * 64
$validSignature = "Verifies`nVerified using v1 scheme (JAR signing): false`nVerified using v2 scheme (APK Signature Scheme v2): true`nNumber of signers: 1`nSigner #1 certificate DN: CN=ExVPN`nSigner #1 certificate SHA-256 digest: $fingerprint`n"
$signed = ConvertFrom-DemoAndroidSignature $validSignature $fingerprint
Assert-True ($signed.verified -and $signed.trustedSignerMatched -and !$signed.debug -and $signed.certificateSha256 -ceq $fingerprint)
$signedCrLf = ConvertFrom-DemoAndroidSignature ($validSignature.Replace("`n","`r`n")) $fingerprint
Assert-True $signedCrLf.v2Verified
foreach ($text in @(
    $validSignature.Replace('v2): true','v2): false'),
    $validSignature.Replace('Number of signers: 1','Number of signers: 2'),
    $validSignature.Replace($fingerprint,('b' * 64)),
    $validSignature.Replace('CN=ExVPN','CN=Android Debug'),
    ($validSignature + 'Signer #2 certificate SHA-256 digest: ' + $fingerprint),
    ($validSignature + "Number of signers: 1`n"),
    ($validSignature + "Verified using v2 scheme (APK Signature Scheme v2): true`n"),
    '')) { Assert-Refused { ConvertFrom-DemoAndroidSignature $text $fingerprint } }
Assert-Refused { ConvertFrom-DemoAndroidSignature $validSignature 'not-a-digest' }

$validBadging = "package: name='ru.exvpn.exvpn' versionCode='18' versionName='0.1.0' platformBuildVersionName='16'`nsdkVersion:'30'`ntargetSdkVersion:'36'`napplication-label:'ExVPN'`n"
$identity = ConvertFrom-DemoAndroidIdentity $validBadging
Assert-True ($identity.version -ceq '0.1.0+18' -and !$identity.debuggable -and $identity.minimumSdk -eq 30)
foreach ($text in @(
    $validBadging.Replace('ru.exvpn.exvpn','ru.other.app'),
    $validBadging.Replace("versionCode='18'","versionCode='17'"),
    $validBadging.Replace("versionName='0.1.0'","versionName='0.2.0'"),
    $validBadging.Replace("sdkVersion:'30'","sdkVersion:'29'"),
    $validBadging.Replace("targetSdkVersion:'36'","targetSdkVersion:'35'"),
    ($validBadging + "application-debuggable`n"),
    ($validBadging + "sdkVersion:'30'`n"),
    ($validBadging + "package: name='ru.exvpn.exvpn' versionCode='18' versionName='0.1.0'`n"))) {
    Assert-Refused { ConvertFrom-DemoAndroidIdentity $text }
}

# Public certificate only. No keystore, password or private certificate is read.
$publicCertificate = Join-Path $repository 'config/signing/android-release-cert.pem'
$publicHash = Get-DemoAndroidCertificateSha256 $publicCertificate -Pem
Assert-True ($publicHash -ceq '2a43b65b5261da825b1793e8d9a2196b868fa0887b2e87c5908298b4ccbc7093')
$badCertificate = Join-Path $fixture 'invalid-cert.pem'
[IO.File]::WriteAllText($badCertificate, 'not a certificate')
Assert-Refused { Get-DemoAndroidCertificateSha256 $badCertificate -Pem }
[IO.File]::WriteAllText($badCertificate, ([IO.File]::ReadAllText($publicCertificate) * 2))
Assert-Refused { Get-DemoAndroidCertificateSha256 $badCertificate -Pem }

$jvmDirectory = Join-Path $fixture 'jvm'
New-Item -ItemType Directory -Path $jvmDirectory | Out-Null
$jvmPath = Join-Path $jvmDirectory 'TEST-synthetic.xml'
$jvmStart = [datetime]::UtcNow.AddSeconds(-2)
# Attribute name collisions must not replace XmlElement.Name/SelectNodes.
$validSuite = '<testsuite name="synthetic" tests="2" failures="0" errors="0" skipped="0"><testcase name="one"/><testcase name="two"/></testsuite>'
[IO.File]::WriteAllText($jvmPath, $validSuite)
$jvm = Get-DemoAndroidJvmSummary $jvmDirectory $jvmStart
Assert-True ($jvm.tests -eq 2 -and $jvm.suites -eq 1 -and $jvm.freshReports)
foreach ($xml in @(
    $validSuite.Replace('failures="0"','failures="1"'),
    $validSuite.Replace('errors="0"','errors="1"'),
    $validSuite.Replace('skipped="0"','skipped="1"'),
    $validSuite.Replace('tests="2"','tests="1"'),
    $validSuite.Replace('tests="2"','tests="0"'),
    $validSuite.Replace('<testcase name="two"/>','<testcase name="two"><failure/></testcase>'),
    $validSuite.Replace('<testcase name="two"/>','<testcase name="two"><skipped/></testcase>'),
    ('<!DOCTYPE testsuite [<!ENTITY external SYSTEM "file:///unread">]>' + $validSuite),
    $validSuite.Replace('testsuite','testsuites'))) {
    [IO.File]::WriteAllText($jvmPath, $xml)
    Assert-Refused { Get-DemoAndroidJvmSummary $jvmDirectory $jvmStart }
}
[IO.File]::WriteAllText($jvmPath, $validSuite)
[IO.File]::SetLastWriteTimeUtc($jvmPath, $jvmStart.AddMinutes(-1))
Assert-Refused { Get-DemoAndroidJvmSummary $jvmDirectory $jvmStart }
$emptyJvm = Join-Path $fixture 'empty-jvm'
New-Item -ItemType Directory -Path $emptyJvm | Out-Null
Assert-Refused { Get-DemoAndroidJvmSummary $emptyJvm $jvmStart }

$saved = @{}
$signingNames = @('EXVPN_ANDROID_KEYSTORE','EXVPN_ANDROID_KEY_ALIAS','EXVPN_ANDROID_STORE_PASSWORD','EXVPN_ANDROID_KEY_PASSWORD')
foreach ($name in $signingNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    foreach ($name in $signingNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    Assert-Refused { Get-DemoAndroidSigningInput }
    $fakeKeystore = Join-Path $fixture 'synthetic.p12'
    [IO.File]::WriteAllText($fakeKeystore, 'synthetic-not-a-keystore')
    $env:EXVPN_ANDROID_KEYSTORE = $fakeKeystore
    $env:EXVPN_ANDROID_KEY_ALIAS = 'exvpn'
    $env:EXVPN_ANDROID_STORE_PASSWORD = 'fixture-password'
    Assert-Refused { Get-DemoAndroidSigningInput }
    $env:EXVPN_ANDROID_KEY_PASSWORD = 'fixture-password'
    $inputRecord = Get-DemoAndroidSigningInput
    Assert-True ($inputRecord.Alias -ceq 'exvpn' -and $inputRecord.Path -ceq $fakeKeystore -and @($inputRecord.PSObject.Properties).Count -eq 2)
    $env:EXVPN_ANDROID_KEY_ALIAS = '../other'
    Assert-Refused { Get-DemoAndroidSigningInput }
    $env:EXVPN_ANDROID_KEY_ALIAS = 'exvpn'
    $env:EXVPN_ANDROID_KEYSTORE = 'relative.p12'
    Assert-Refused { Get-DemoAndroidSigningInput }
} finally { Restore-DemoAndroidEnvironment $saved }
foreach ($name in $signingNames) { Assert-True ([Environment]::GetEnvironmentVariable($name,'Process') -ceq $saved[$name]) }

$first = @([ordered]@{path='apps/exvpn/lib/main.dart';sha256=('a'*64)})
Assert-DemoAndroidSourceUnchanged $first $first; $checks++
Assert-Refused { Assert-DemoAndroidSourceUnchanged $first @([ordered]@{path='apps/exvpn/lib/main.dart';sha256=('b'*64)}) }
Assert-Refused { Assert-DemoAndroidSourceUnchanged $first @() }
$hookPath = Join-Path $fixture 'owned.gradle'
[IO.File]::WriteAllText($hookPath,'synthetic owned hook')
$hookHash = Get-AuditSha256 $hookPath
[IO.File]::AppendAllText($hookPath,' changed')
Assert-Refused { Remove-DemoAndroidOwnedHook $hookPath $hookHash }
Assert-True (Test-Path -LiteralPath $hookPath)
Remove-DemoAndroidOwnedHook $hookPath (Get-AuditSha256 $hookPath)
Assert-True (!(Test-Path -LiteralPath $hookPath))

$public = Join-Path $fixture 'public'
New-Item -ItemType Directory -Path $public | Out-Null
foreach ($name in @('ExVPN-0.1.0-demo-android.apk','android-build.json','android-audit.json','android-sbom.cdx.json',
    'android-notices.zip','android-maven-notices.zip','android-maven-notices.json')) {
    [IO.File]::WriteAllText((Join-Path $public $name),'synthetic fixture, not an artifact')
}
Assert-DemoAndroidPublicFiles $public; $checks++
$raw = Join-Path $public 'raw-maven-inputs.json'
[IO.File]::WriteAllText($raw,'synthetic raw graph must not be public')
Assert-Refused { Assert-DemoAndroidPublicFiles $public }
Remove-Item -LiteralPath $raw
New-Item -ItemType Directory -Path (Join-Path $public 'unexpected') | Out-Null
Assert-Refused { Assert-DemoAndroidPublicFiles $public }

$failure = [pscustomobject]@{
    Exception=[InvalidOperationException]::new('synthetic SECRET and absolute path must not appear')
    ScriptStackTrace=("at Function(argument-secret), " + (Join-Path $repository 'scripts/release/build-demo-android.ps1') + ": line 42`n" +
        'at unknown, C:\other\secret.ps1: line 13' + "`n" + 'at unknown, ' + (Join-Path $repository '.private/secret.ps1') + ': line 2')
}
$safe = Get-DemoAndroidFailureDiagnostic $failure $repository
Assert-True ($safe.code -ceq 'unexpected_error' -and $safe.exceptionType -ceq 'InvalidOperationException')
Assert-True ($safe.locations.Count -eq 1 -and $safe.locations[0] -ceq 'scripts/release/build-demo-android.ps1:42')
Assert-True (($safe | ConvertTo-Json -Compress) -notmatch 'SECRET|argument-secret|C:|\.private')
$failure.Exception = [InvalidOperationException]::new('demo_maven_component_not_covered')
$safe = Get-DemoAndroidFailureDiagnostic $failure $repository
Assert-True ($safe.code -ceq 'demo_maven_component_not_covered')

$proof = [ordered]@{
    schema=1;status='PASS';checks=$checks;buildRun=$false;signingToolRun=$false;guestActions=0;cloudActions=0
    files=@(@('demo-android-lib.ps1','build-demo-android.ps1','test-build-demo-android.ps1') | ForEach-Object {
        [ordered]@{path=('scripts/release/'+$_);sha256=(Get-AuditSha256 (Join-Path $PSScriptRoot $_))}
    })
}
Write-AuditJson (Join-Path $fixture 'proof.json') $proof
Write-Host "Android demo build helpers: $checks checks PASS; no build, signing, device or cloud action."
Write-Host ('Proof: ' + [IO.Path]::GetRelativePath($repository, (Join-Path $fixture 'proof.json')))
