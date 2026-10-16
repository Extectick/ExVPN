# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# ADB-only QA helpers. Dot-sourcing is inert; all raw output stays in .private.
Set-StrictMode -Version Latest

function Initialize-AndroidLifecycleQa {
    param(
        [Parameter(Mandatory)][ValidatePattern('^emulator-[0-9]{4,5}$')][string]$Serial,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$AndroidSdkPath = $env:ANDROID_HOME
    )
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $privateRoot = [IO.Path]::GetFullPath((Join-Path $repository '.private'))
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    if (!$output.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'qa_private_output_required' }
    $entryPath = $output
    while ($entryPath.Length -ge $privateRoot.Length) {
        if (Test-Path -LiteralPath $entryPath) {
            if ((Get-Item -LiteralPath $entryPath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'qa_output_link_rejected' }
        }
        $entryPath = [IO.Path]::GetDirectoryName($entryPath)
    }
    $adb = Join-Path $AndroidSdkPath 'platform-tools/adb.exe'
    if (!(Test-Path -LiteralPath $adb -PathType Leaf)) { throw 'qa_adb_unavailable' }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $script:AndroidLifecycleContext = @{ Serial=$Serial; Output=$output; Adb=$adb }
}

function Invoke-AndroidLifecycleAdb {
    param(
        [Parameter(Mandatory)][string[]]$AdbArguments,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,80}$')][string]$Step,
        [ValidateRange(1,60)][int]$TimeoutSeconds=30
    )
    $context = $script:AndroidLifecycleContext
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $context.Adb
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-s', $context.Serial) + $AdbArguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { throw 'qa_adb_deadline' }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $context.Output "$Step.stdout.txt"), $output)
        [IO.File]::WriteAllText((Join-Path $context.Output "$Step.stderr.txt"), $errorOutput)
        if ($process.ExitCode -ne 0) { throw 'qa_adb_failed' }
        return $output
    } finally {
        if (!$process.HasExited) { $process.Kill(); $null = $process.WaitForExit(1000) }
        $process.Dispose()
    }
}

function ConvertFrom-AndroidLifecycleProbe {
    param([Parameter(Mandatory)][string]$Output)
    $numbers = @('durationMs','uid','uidRxBytes','uidTxBytes','httpStatus','responseBytes','publicIpFamily','ipv4Answers','ipv6Answers')
    $booleans = @('vpnTransport','success')
    $digests = @('bodySha256','publicIpSha256')
    $errors = @('deadline','network','unsupported_mode','http_status','too_large','invalid_ip_response')
    $result = [ordered]@{}
    foreach ($match in [regex]::Matches($Output, '(?m)^INSTRUMENTATION_RESULT: ([a-zA-Z0-9]+)=([^\r\n]*)\r?$')) {
        $key=$match.Groups[1].Value; $value=$match.Groups[2].Value
        if ($result.Contains($key)) { throw 'qa_duplicate_probe_field' }
        if ($key -in $numbers -and $value -match '^-?\d{1,18}$') {
            $number = [long]$value
            if ($number -lt 0 -and !($number -eq -1 -and $key -in @('uidRxBytes','uidTxBytes'))) { throw 'qa_invalid_probe_number' }
            $result[$key] = $number
        } elseif ($key -in $booleans -and $value -cin @('true','false')) { $result[$key] = $value -ceq 'true' }
        elseif ($key -in $digests -and $value -cmatch '^[a-f0-9]{64}$') { $result[$key] = $value }
        elseif ($key -eq 'error' -and $value -cin $errors) { $result[$key] = $value }
        else { throw 'qa_invalid_probe_field' }
    }
    if ([regex]::Matches($Output, '(?m)^INSTRUMENTATION_CODE: -1\r?$').Count -ne 1 -or
        !$result.Contains('uid') -or !$result.Contains('vpnTransport') -or !$result.Contains('durationMs')) { throw 'qa_incomplete_probe' }
    if ($result.Contains('error')) {
        if ($result.Contains('success') -and $result.success) { throw 'qa_contradictory_probe' }
        $result.success=$false
    } elseif (!$result.Contains('success')) { throw 'qa_incomplete_probe' }
    return $result
}

function Invoke-AndroidLifecycleProbe {
    param(
        [Parameter(Mandatory)][ValidateSet('health','trace4','ip4','ip6','numeric','dns')][string]$Mode,
        [Parameter(Mandatory)][string]$Step
    )
    # One synchronous invocation at a time; never run this package's text-input
    # instrumentation concurrently. A completed process alone is not success.
    $output = Invoke-AndroidLifecycleAdb -Step $Step -AdbArguments @('shell','am','instrument','-w','-e','mode',$Mode,'ru.exvpn.netprobe/ru.exvpn.netprobe.HttpsProbe')
    ConvertFrom-AndroidLifecycleProbe $output
}

function Read-AndroidLifecycleUi {
    param([Parameter(Mandatory)][string]$Step)
    $output = Invoke-AndroidLifecycleAdb -Step $Step -AdbArguments @('exec-out','uiautomator','dump','/dev/tty')
    $start = $output.IndexOf('<?xml', [StringComparison]::Ordinal)
    $end = $output.LastIndexOf('</hierarchy>', [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw 'qa_ui_xml_unavailable' }
    $xml = [Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.LoadXml($output.Substring($start, $end + '</hierarchy>'.Length - $start))
    return $xml
}

function Find-AndroidLifecycleLabel {
    param([Parameter(Mandatory)][xml]$Tree, [Parameter(Mandatory)][string]$Label)
    $nodes = @($Tree.SelectNodes('//node') | Where-Object { $_.GetAttribute('content-desc') -ceq $Label -or $_.GetAttribute('text') -ceq $Label })
    if ($nodes.Count -ne 1) { throw 'qa_unique_ui_target_required' }
    return $nodes[0]
}

function Invoke-AndroidLifecycleTap {
    param([Parameter(Mandatory)][Xml.XmlElement]$Node, [Parameter(Mandatory)][string]$Step)
    if ($Node.GetAttribute('package') -cne 'ru.exvpn.exvpn') { throw 'qa_wrong_ui_package' }
    $bounds = [regex]::Match($Node.GetAttribute('bounds'), '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (!$bounds.Success) { throw 'qa_invalid_ui_bounds' }
    $x1=[int]$bounds.Groups[1].Value; $y1=[int]$bounds.Groups[2].Value
    $x2=[int]$bounds.Groups[3].Value; $y2=[int]$bounds.Groups[4].Value
    if ($x2 -le $x1 -or $y2 -le $y1) { throw 'qa_empty_ui_bounds' }
    $x=[int](($x1+$x2)/2); $y=[int](($y1+$y2)/2)
    $null = Invoke-AndroidLifecycleAdb -Step $Step -AdbArguments @('shell','input','tap',[string]$x,[string]$y)
}
