# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Small validation helpers; dot-sourcing never builds, signs or invokes a tool.
Set-StrictMode -Version Latest

function Get-DemoAndroidBuildArguments {
    @('build', 'apk', '--release', '--pub', '--target=lib/main.dart',
        '--target-platform=android-arm64,android-x64', '--build-name=0.1.0',
        '--build-number=18', '--dart-define=EXVPN_DEMO=false')
}

function Get-DemoAndroidJvmArguments {
    # AGP 9 enables unit tests only for testBuildType (debug by default).
    # Opt into the release unit-test component for this one test invocation;
    # this does not change the APK's build configuration or test expectations.
    @(':app:testReleaseUnitTest', '--rerun', '--no-daemon',
        '-Pandroid.onlyEnableUnitTestForTheTestedBuildType=false')
}

function Get-DemoAndroidGradleFailureCode([string]$Log) {
    # Return fixed classifications only. Gradle text can contain signing paths
    # or credentials and must never be echoed into CI logs or public reports.
    $Log = $Log.Replace("`r`r`n", "`n").Replace("`r`n", "`n")
    if ($Log -match "(?m)^Cannot locate tasks that match ':app:testReleaseUnitTest' as task 'testReleaseUnitTest' not found in project ':app'\.\r?$") {
        return 'demo_android_jvm_task_missing'
    }
    if ($Log -match "(?m)^Execution failed for task ':app:testReleaseUnitTest'\.\r?$" -and
        $Log -match '(?m)^> There were failing tests\.') { return 'demo_android_jvm_test_failures' }
    if ($Log -match '(?m)^> Task :app:verifyExVpnPackageInputs FAILED\r?$') { return 'demo_android_jvm_snapshot_failed' }
    if ($Log -match "(?m)^Execution failed for task ':app:compileReleaseJavaWithJavac'\.\r?$") { return 'demo_android_jvm_java_compile_failed' }
    return 'demo_android_jvm_failed'
}

function Assert-DemoAndroidVersion([string]$Version) {
    if ($Version -cne '0.1.0+18') { throw 'demo_android_source_version_mismatch' }
}

function Get-DemoAndroidSigningInput {
    $values = @{}
    foreach ($name in @('EXVPN_ANDROID_KEYSTORE', 'EXVPN_ANDROID_KEY_ALIAS',
        'EXVPN_ANDROID_STORE_PASSWORD', 'EXVPN_ANDROID_KEY_PASSWORD')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'demo_android_signing_environment_incomplete' }
        $values[$name] = $value
    }
    if (![IO.Path]::IsPathFullyQualified($values.EXVPN_ANDROID_KEYSTORE) -or
        !(Test-Path -LiteralPath $values.EXVPN_ANDROID_KEYSTORE -PathType Leaf)) {
        throw 'demo_android_keystore_unavailable'
    }
    Assert-AuditNoLinks $values.EXVPN_ANDROID_KEYSTORE
    if ($values.EXVPN_ANDROID_KEY_ALIAS -cnotmatch '^[A-Za-z0-9._-]{1,128}$') { throw 'demo_android_key_alias_invalid' }
    # Do not return passwords to callers or metadata serializers.
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($values.EXVPN_ANDROID_KEYSTORE);Alias=$values.EXVPN_ANDROID_KEY_ALIAS}
}

function Get-DemoAndroidCertificateSha256([string]$Path, [switch]$Pem) {
    Assert-AuditNoLinks $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 64KB) { throw 'demo_android_certificate_invalid' }
    $certificate = $null
    try {
        $certificateBytes = if ($Pem) {
            # CreateFromPemFile also looks for a private key; this pin must be
            # exactly one public certificate and must never need that key.
            $text = [IO.File]::ReadAllText($Path)
            $match = [regex]::Match($text, '\A-----BEGIN CERTIFICATE-----\r?\n(?<body>(?:[A-Za-z0-9+/=]+\r?\n)+)-----END CERTIFICATE-----\r?\n?\z')
            if (!$match.Success) { throw 'demo_android_certificate_invalid' }
            [Convert]::FromBase64String($match.Groups['body'].Value)
        } else { [IO.File]::ReadAllBytes($Path) }
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$certificateBytes)
        if ($certificate.HasPrivateKey) { throw 'demo_android_certificate_invalid' }
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($certificate.RawData)).ToLowerInvariant()
    } catch { throw 'demo_android_certificate_invalid' }
    finally { if ($certificate) { $certificate.Dispose() } }
}

function ConvertFrom-DemoAndroidIdentity([string]$Badging) {
    $packages = [regex]::Matches($Badging, "(?m)^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'")
    $minimum = [regex]::Matches($Badging, "(?m)^sdkVersion:'([0-9]+)'\r?$")
    $target = [regex]::Matches($Badging, "(?m)^targetSdkVersion:'([0-9]+)'\r?$")
    if ($packages.Count -ne 1 -or $minimum.Count -ne 1 -or $target.Count -ne 1 -or
        $packages[0].Groups[1].Value -cne 'ru.exvpn.exvpn' -or
        $packages[0].Groups[2].Value -cne '18' -or $packages[0].Groups[3].Value -cne '0.1.0' -or
        $minimum[0].Groups[1].Value -cne '30' -or $target[0].Groups[1].Value -cne '36' -or
        $Badging -match '(?m)^application-debuggable(?:\s|$)') { throw 'demo_android_packaged_identity_invalid' }
    [ordered]@{package='ru.exvpn.exvpn';version='0.1.0+18';minimumSdk=30;targetSdk=36;debuggable=$false}
}

function ConvertFrom-DemoAndroidSignature([string]$Output, [string]$ExpectedSha256) {
    $signers = [regex]::Matches($Output, '(?m)^Number of signers: ([0-9]+)\r?$')
    $certificates = [regex]::Matches($Output, '(?im)^Signer #([0-9]+) certificate SHA-256 digest: ([a-f0-9]{64})\r?$')
    $v2 = [regex]::Matches($Output, '(?m)^Verified using v2 scheme \(APK Signature Scheme v2\): (true|false)\r?$')
    if ($ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$' -or $signers.Count -ne 1 -or
        $signers[0].Groups[1].Value -cne '1' -or $certificates.Count -ne 1 -or
        $certificates[0].Groups[1].Value -cne '1' -or
        $certificates[0].Groups[2].Value.ToLowerInvariant() -cne $ExpectedSha256 -or
        $v2.Count -ne 1 -or $v2[0].Groups[1].Value -cne 'true' -or
        $Output -match '(?im)^Signer #\d+ certificate DN:.*(?:CN=Android Debug|CN=AndroidDebug)') {
        throw 'demo_android_signature_mismatch'
    }
    # Caller must separately require apksigner exit 0. Text is not verification.
    [ordered]@{verified=$true;trustedSignerMatched=$true;v2Verified=$true;debug=$false;certificateSha256=$ExpectedSha256}
}

function Get-DemoAndroidJvmSummary([string]$Directory, [datetime]$StartedAtUtc) {
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter 'TEST-*.xml' -ErrorAction Stop)
    if (!$files.Count) { throw 'demo_android_jvm_reports_missing' }
    $tests = 0
    foreach ($file in $files) {
        Assert-AuditNoLinks $file.FullName
        if ($file.Length -gt 2MB -or $file.LastWriteTimeUtc -lt $StartedAtUtc) { throw 'demo_android_jvm_report_stale' }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($file.FullName, $settings)
        try { $document = [Xml.XmlDocument]::new(); $document.XmlResolver=$null; $document.Load($reader) }
        finally { $reader.Dispose() }
        $suite = $document.DocumentElement
        if ($suite.get_Name() -cne 'testsuite' -or $suite.GetAttribute('tests') -cnotmatch '^[1-9][0-9]*$' -or
            $suite.GetAttribute('failures') -cne '0' -or $suite.GetAttribute('errors') -cne '0' -or
            $suite.GetAttribute('skipped') -cne '0' -or
            @($suite.SelectNodes('./testcase')).Count -ne [int]$suite.GetAttribute('tests') -or
            @($suite.SelectNodes('.//failure|.//error|.//skipped')).Count -ne 0) { throw 'demo_android_jvm_results_invalid' }
        $tests += [int]$suite.GetAttribute('tests')
    }
    [ordered]@{task=':app:testReleaseUnitTest';freshReports=$true;tests=$tests;suites=$files.Count;failures=0;errors=0;skipped=0}
}

function Get-DemoAndroidSourceInputs([string]$Repository) {
    # Ignore docs/Windows changes, but include every tracked Android/Dart/native
    # and build-policy input. The CI checkout must not contain untracked inputs.
    $scopes = @('apps/exvpn/lib', 'apps/exvpn/assets', 'apps/exvpn/android',
        'apps/exvpn/pubspec.yaml', 'apps/exvpn/pubspec.lock', 'apps/exvpn/shorebird.yaml',
        'packages', 'native/core', 'native/android', 'native/patches', 'scripts/bootstrap', 'scripts/core',
        'scripts/release', 'config/signing', 'LICENSE', 'NOTICE')
    $statusArguments = @('-C', $Repository, 'status', '--porcelain=v1', '--untracked-files=all', '--') + $scopes
    $status = @(& git @statusArguments)
    if ($LASTEXITCODE -ne 0 -or $status.Count) { throw 'demo_android_source_not_clean' }
    $arguments = @('-C', $Repository, 'ls-files', '--') + $scopes
    $paths = @(& git @arguments)
    if ($LASTEXITCODE -ne 0 -or !$paths.Count) { throw 'demo_android_source_inventory_failed' }
    @($paths | Sort-Object -Unique -CaseSensitive | ForEach-Object {
        $path = ConvertTo-AuditPath $_
        $full = Join-Path $Repository $path
        Assert-AuditNoLinks $full
        [ordered]@{path=$path;sha256=Get-AuditSha256 $full}
    })
}

function Assert-DemoAndroidSourceUnchanged($Before, $After) {
    if (!$Before -or ($Before | ConvertTo-Json -Depth 5 -Compress) -cne ($After | ConvertTo-Json -Depth 5 -Compress)) {
        throw 'demo_android_source_changed'
    }
}

function Remove-DemoAndroidOwnedHook([string]$Path, [string]$ExpectedSha256) {
    # Only a byte-identical file created by this invocation may be removed.
    Assert-AuditNoLinks $Path
    if ($ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-AuditSha256 $Path) -cne $ExpectedSha256) {
        throw 'demo_android_maven_hook_changed'
    }
    Remove-Item -LiteralPath $Path -ErrorAction Stop
}

function Assert-DemoAndroidPublicFiles([string]$Directory) {
    $expected = @('ExVPN-0.1.0-demo-android.apk', 'android-build.json', 'android-audit.json',
        'android-sbom.cdx.json', 'android-notices.zip', 'android-maven-notices.zip', 'android-maven-notices.json')
    $files = Get-AuditTreeFiles $Directory
    if (@(Get-ChildItem -LiteralPath $Directory -Directory -Force).Count) { throw 'demo_android_public_files_invalid' }
    if ($files.Count -ne $expected.Count) { throw 'demo_android_public_files_invalid' }
    foreach ($name in $expected) {
        if (!$files.ContainsKey($name) -or $files[$name].path -cne $name -or $files[$name].size -le 0) {
            throw 'demo_android_public_files_invalid'
        }
    }
}

function Restore-DemoAndroidEnvironment([Collections.IDictionary]$Saved) {
    foreach ($name in $Saved.Keys) {
        if ($null -eq $Saved[$name]) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $Saved[$name], 'Process') }
    }
}

function Get-DemoAndroidFailureDiagnostic($Failure, [string]$Repository) {
    $message = $Failure.Exception.Message
    $code = if ($message -cmatch '^(?:demo_|flutter_|android_|xray_|audit_|notice_)[a-z0-9_]{1,110}$') { $message } else { 'unexpected_error' }
    $type = $Failure.Exception.GetType().Name
    if ($type -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,79}$') { $type = 'Exception' }
    $locations = [Collections.Generic.List[string]]::new()
    foreach ($line in ([string]$Failure.ScriptStackTrace).Split("`n")) {
        $match = [regex]::Match($line.Trim(), '^at [^,]+, (.+): line ([0-9]{1,6})$')
        if (!$match.Success) { continue }
        try {
            $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Repository), [IO.Path]::GetFullPath($match.Groups[1].Value)).Replace('\','/')
            # Source filenames/lines only, never stack text, arguments, local
            # absolute paths or private diagnostic/input filenames.
            if ($relative -cmatch '^scripts/[A-Za-z0-9_./-]+\.ps1$' -and $relative -notmatch '(?:^|/)\.\.(?:/|$)') {
                $locations.Add($relative + ':' + $match.Groups[2].Value)
            }
        } catch { continue }
        if ($locations.Count -ge 8) { break }
    }
    [ordered]@{code=$code;exceptionType=$type;locations=$locations.ToArray()}
}
