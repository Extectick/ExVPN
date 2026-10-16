# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._:-]{1,128}$')][string]$Serial,
    [Parameter(Mandatory)][string]$InputPath,
    [string]$AndroidSdkPath = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$adb = Join-Path $AndroidSdkPath 'platform-tools/adb.exe'
$result = [ordered]@{ status='host_input_invalid'; inputLength=0; inputSha256=$null; appliedSha256=$null; actionAccepted=$false }
$exitCode = 1
$staged = $false

function Invoke-QaAdb([string[]]$Arguments, [byte[]]$InputBytes = $null) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $adb
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-s', $Serial) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputBytes) {
            $write = $process.StandardInput.BaseStream.WriteAsync($InputBytes, 0, $InputBytes.Length)
            if (!$write.Wait(30000)) { throw 'adb_stdin_deadline' }
        }
        $process.StandardInput.Close()
        if (!$process.WaitForExit(30000)) { throw 'adb_deadline' }
        $output = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'adb_transport_failed' }
        $output
    } finally {
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

try {
    $privateRoot = [IO.Path]::GetFullPath((Join-Path $repository '.private'))
    $path = [IO.Path]::GetFullPath($InputPath)
    if (!$path.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'private_input_required' }
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or !(Test-Path -LiteralPath $adb -PathType Leaf)) { throw 'input_or_adb_missing' }
    # Reject file/parent links rather than reading outside the private root.
    $entry = Get-Item -LiteralPath $path
    while ($null -ne $entry -and $entry.FullName.Length -ge $privateRoot.Length) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'input_link_rejected' }
        $entry = if ($entry -is [IO.FileInfo]) { $entry.Directory } else { $entry.Parent }
    }
    $source = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(4096)
        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $count -gt 524288) { throw 'input_too_large' }
            $memory.Write($buffer, 0, $count)
        }
        $bytes = $memory.ToArray()
    } finally { $source.Dispose(); $memory.Dispose() }
    if (!$bytes.Length) { throw 'input_empty' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') { throw 'input_control_character' }
    $result.inputLength = $bytes.Length
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $result.inputSha256 = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $result.status = 'host_transport_failed'
    $staged = $true
    # The command is constant. Payload bytes travel through stdin, not a process
    # argument, shell interpolation, clipboard, shared storage or a printed log.
    $null = Invoke-QaAdb @('shell', '-T', "run-as ru.exvpn.netprobe sh -c 'umask 077; mkdir -p files && cat > files/qa-text-input.txt && chmod 600 files/qa-text-input.txt'") $bytes
    $output = Invoke-QaAdb @('shell', 'am', 'instrument', '-w', '-e', 'payloadFile', 'qa-text-input.txt', 'ru.exvpn.netprobe/ru.exvpn.netprobe.TextInputProbe')
    $result.status = 'invalid_instrumentation_response'
    $fields = @{}
    foreach ($match in [regex]::Matches($output, '(?m)^INSTRUMENTATION_RESULT: (status|inputLength|inputSha256|appliedSha256|actionAccepted)=([^\r\n]*)\r?$')) {
        $key = $match.Groups[1].Value
        if ($fields.ContainsKey($key)) { throw 'duplicate_result_field' }
        $fields[$key] = $match.Groups[2].Value
    }
    $allowedStatus = @('verified','accepted_unverified','invalid_payload_file','payload_empty','payload_too_large','payload_invalid_utf8','payload_control_character','window_unavailable','wrong_window_package','ambiguous_focus','tree_too_large','focused_editable_missing','target_not_editable','set_text_unsupported','action_rejected','input_or_accessibility_error','payload_cleanup_failed')
    if (!$fields.ContainsKey('status') -or $fields.status -notin $allowedStatus -or $output -notmatch '(?m)^INSTRUMENTATION_CODE: -1\r?$') { throw 'invalid_status' }
    if ($fields.ContainsKey('inputLength') -and $fields.inputLength -cne [string]$bytes.Length) { throw 'input_length_mismatch' }
    if ($fields.ContainsKey('inputSha256') -and $fields.inputSha256 -cne $result.inputSha256) { throw 'input_digest_mismatch' }
    if ($fields.ContainsKey('appliedSha256')) {
        if ($fields.appliedSha256 -notmatch '^[a-f0-9]{64}$') { throw 'invalid_applied_digest' }
        $result.appliedSha256 = $fields.appliedSha256
    }
    if (!$fields.ContainsKey('actionAccepted') -or $fields.actionAccepted -cnotin @('true','false')) { throw 'invalid_action_result' }
    $result.actionAccepted = $fields.actionAccepted -ceq 'true'
    $result.status = $fields.status
    if ($fields.status -eq 'verified') {
        if (!$fields.ContainsKey('inputLength') -or !$fields.ContainsKey('inputSha256') -or
            !$result.actionAccepted -or $result.appliedSha256 -cne $result.inputSha256) { throw 'unverified_readback' }
        $exitCode = 0
    }
} catch {
    # Never print exception messages, remote output, private paths or text.
    if ($result.status -eq 'verified') { $result.status = 'invalid_instrumentation_response' }
    $exitCode = 1
} finally {
    if ($staged) {
        try {
            # Exact QA-owned file only; also covers a killed/failed instrumentation.
            $null = Invoke-QaAdb @('shell', 'run-as', 'ru.exvpn.netprobe', 'rm', '-f', 'files/qa-text-input.txt')
        } catch { $result.status = 'payload_cleanup_failed'; $exitCode = 1 }
    }
    $result | ConvertTo-Json -Compress
}
exit $exitCode
