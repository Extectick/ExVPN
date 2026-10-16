# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest

function Get-AndroidJvmTaskGraph([string]$Text) {
    $tasks=@([regex]::Matches($Text,'(?m)^(:[A-Za-z0-9_.:-]+) SKIPPED\r?$') | ForEach-Object { $_.Groups[1].Value })
    if (@($tasks | Where-Object { $_ -ceq ':app:testDebugUnitTest' }).Count -ne 1) { throw 'android_jvm_unit_task_missing_or_ambiguous' }
    foreach ($task in $tasks) {
        $name=$task.Split(':')[-1]
        if ($name -ieq 'verifyExVpnPackageInputs') { throw 'android_jvm_package_snapshot_task_present' }
        # Resource packages and class JARs are prerequisites of the ordinary
        # JUnit graph, not an APK/AAB. All other packaging tasks are rejected.
        if ($name -imatch '^(assemble|package|bundle|install|uninstall|publish|sign)' -and
            $name -cnotmatch '^(packageDebugResources|bundleLib(?:Compile|Runtime)ToJarDebug|bundleDebugClassesTo(?:Compile|Runtime)Jar)$') {
            throw 'android_jvm_packaging_task_present'
        }
        if ($name -imatch '^(externalNativeBuild|configureCMake|buildCMake)') { throw 'android_jvm_native_build_task_present' }
    }
    return [pscustomobject]@{taskCount=$tasks.Count;tasks=$tasks;unitTask=':app:testDebugUnitTest';excludedTask=':app:verifyExVpnPackageInputs'}
}

function Get-AndroidJvmResult([string]$ReportDirectory) {
    $reports=@(Get-ChildItem -LiteralPath $ReportDirectory -File -Filter 'TEST-*.xml')
    if (!$reports.Count) { throw 'android_jvm_junit_report_missing' }
    $result=[ordered]@{reports=$reports.Count;tests=0;failures=0;errors=0;skipped=0}
    foreach ($report in $reports) {
        # Do not resolve external entities from a report; only counters and
        # testcase records from the ordinary Gradle JUnit output are needed.
        $settings=[Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver=$null
        $reader=[Xml.XmlReader]::Create($report.FullName,$settings)
        try {
            $xml=[Xml.XmlDocument]::new()
            $xml.XmlResolver=$null
            $xml.Load($reader)
        } finally { $reader.Dispose() }
        $suite=$xml.DocumentElement
        # PowerShell's XML adapter maps .Name to the suite's `name` attribute;
        # use the DOM method to inspect the actual element name.
        if ($suite.get_Name() -cne 'testsuite') { throw 'android_jvm_junit_report_invalid' }
        foreach ($counter in @('tests','failures','errors','skipped')) {
            $value=$suite.GetAttribute($counter)
            if ($value -cnotmatch '^\d{1,7}$') { throw 'android_jvm_junit_counter_invalid' }
            $result[$counter]+=[int]$value
        }
        if ($suite.SelectNodes('testcase').Count -ne [int]$suite.GetAttribute('tests') -or
            $suite.SelectNodes('testcase/failure|testcase/error|testcase/skipped').Count -ne 0) {
            throw 'android_jvm_junit_cases_invalid'
        }
    }
    if ($result.tests -lt 1 -or $result.failures -ne 0 -or $result.errors -ne 0 -or $result.skipped -ne 0) {
        throw 'android_jvm_tests_not_all_passed'
    }
    return [pscustomobject]$result
}
