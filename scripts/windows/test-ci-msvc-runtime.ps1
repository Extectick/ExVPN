# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([string]$RuntimeDirectory = '', [string]$DumpbinPath = '', [string]$ArchivePath = '')
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root = Join-Path $repository ('artifacts/qa/msvc-runtime-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$checks = [Collections.Generic.List[string]]::new()
function Check([bool]$Value, [string]$Name) { if (!$Value) { throw "Fixture failed: $Name" }; $checks.Add($Name) }
function Reject([scriptblock]$Action, [string]$Expected, [string]$Label) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Check ($message.Contains($Expected)) $Label
}
# Load only real function definitions; preparation/download/install never runs in pure fixtures.
foreach ($name in @('prepare-ci-msvc-runtime.ps1','prepare-msvc-runtime.ps1')) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$null, [ref]$errors)
    Check ($errors.Count -eq 0) ($name + ' parses')
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { Invoke-Expression $definition.Extent.Text }
}
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'msvc-runtime.lock.json') -Raw | ConvertFrom-Json
$sourcePin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'msvc-runtime-ci.lock.json') -Raw | ConvertFrom-Json
Check ($sourcePin.runtimeFileVersion -ceq $pin.fileVersion -and $sourcePin.entryPrefix -ceq ('Contents/' + $pin.sourceRelativePath + '/')) 'source and unchanged runtime pin agree'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Make-Zip([object[]]$Entries) {
    $path = Join-Path $root ([Guid]::NewGuid().ToString('N') + '.zip')
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in $Entries) {
            $entry = $zip.CreateEntry($item.name)
            $stream = $entry.Open()
            try { $bytes = [Text.Encoding]::UTF8.GetBytes($item.text); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}
function Text-Sha([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
$fixturePin = [pscustomobject]@{ files = @(
    foreach ($record in $pin.files) { [pscustomobject]@{ file = $record.file; sha256 = (Text-Sha $record.file) } }
) }
$entries = @(foreach ($record in $fixturePin.files) { @{ name = $sourcePin.entryPrefix + $record.file; text = $record.file } })
$archive = Make-Zip ($entries + @(@{ name = 'debug_nonredist/never.dll'; text = 'not distributable' }))
$destination = Join-Path $root 'exact'
Expand-CiMsvcArchive $archive $destination $fixturePin $sourcePin.entryPrefix
Check (@(Get-ChildItem -LiteralPath $destination -Force).Count -eq 3) 'extract only three pinned release entries'
foreach ($record in $fixturePin.files) { Check ((Get-FileHash -LiteralPath (Join-Path $destination $record.file) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $record.sha256) ('extracted bytes ' + $record.file) }
Reject { Expand-CiMsvcArchive $archive $destination $fixturePin $sourcePin.entryPrefix } 'msvc_ci_output_exists' 'never overwrite existing output'
$archivePin = [pscustomobject]@{ bytes = (Get-Item -LiteralPath $archive).Length; sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() }
Save-CiMsvcArchive $archive $archivePin $true
$checks.Add('offline cache verifies actual archive bytes')
Reject { Save-CiMsvcArchive (Join-Path $root 'missing.vsix') $archivePin $true } 'msvc_ci_archive_missing_offline' 'offline missing archive refuses without fallback'
$badSize = [pscustomobject]@{ bytes = $archivePin.bytes + 1; sha256 = $archivePin.sha256 }
Reject { Assert-CiMsvcArchive $archive $badSize } 'msvc_ci_archive_mismatch' 'archive size mismatch'
$badHash = [pscustomobject]@{ bytes = $archivePin.bytes; sha256 = ('0' * 64) }
Reject { Save-CiMsvcArchive $archive $badHash $false } 'msvc_ci_archive_mismatch' 'bad cache is refused without redownload'
foreach ($bad in @('../outside.dll','C:/outside.dll','/outside.dll','nested/../outside.dll','nested\outside.dll','nested/./outside.dll','name:stream')) {
    $badZip = Make-Zip ($entries + @(@{name=$bad;text='x'}))
    $out = Join-Path $root ([Guid]::NewGuid().ToString('N'))
    Reject { Expand-CiMsvcArchive $badZip $out $fixturePin $sourcePin.entryPrefix } 'msvc_ci_archive_path_or_duplicate' ('unsafe archive path ' + $bad)
    Check (!(Test-Path -LiteralPath $out)) 'reject archive paths before any extraction'
}
foreach ($duplicate in @($entries[0].name, $entries[0].name.ToUpperInvariant())) {
    $badZip = Make-Zip ($entries + @(@{name=$duplicate;text='x'}))
    Reject { Expand-CiMsvcArchive $badZip (Join-Path $root ([Guid]::NewGuid().ToString('N'))) $fixturePin $sourcePin.entryPrefix } 'msvc_ci_archive_path_or_duplicate' 'duplicate case-insensitive entry'
}
$missingZip = Make-Zip @($entries[0],$entries[1])
Reject { Expand-CiMsvcArchive $missingZip (Join-Path $root 'missing-entry') $fixturePin $sourcePin.entryPrefix } 'msvc_ci_runtime_entry_missing' 'missing third DLL'
$wrongCaseZip = Make-Zip @(@{name=$entries[0].name.ToUpperInvariant();text=$entries[0].text}, $entries[1], $entries[2])
Reject { Expand-CiMsvcArchive $wrongCaseZip (Join-Path $root 'wrong-case') $fixturePin $sourcePin.entryPrefix } 'msvc_ci_runtime_entry_missing' 'exact archive path case required'
$tamperedZip = Make-Zip @(@{name=$entries[0].name;text='modified'}, $entries[1], $entries[2])
Reject { Expand-CiMsvcArchive $tamperedZip (Join-Path $root 'tampered-entry') $fixturePin $sourcePin.entryPrefix } 'msvc_ci_extracted_hash_mismatch' 'extracted DLL hash mismatch'
$unsigned = Join-Path $root 'dumpbin.exe'; [IO.File]::WriteAllText($unsigned, 'not a tool')
Reject { Get-CiMsvcDumpbin $unsigned $pin } 'msvc_ci_dumpbin_identity' 'unsigned inspector rejected before execution'
Assert-MsvcRuntimeImports @('    MSVCP140.dll', '    VCRUNTIME140.dll', '    VCRUNTIME140_1.dll', '    KERNEL32.dll', '    api-ms-win-crt-runtime-l1-1-0.dll') $pin
$checks.Add('pinned CRT and OS imports accepted')
foreach ($name in @('MSVCP140_2.dll','CONCRT140.dll','VCCORLIB140.dll','VCRUNTIME140D.dll','MSVCP140_ATOMIC_WAIT.dll')) {
    Reject { Assert-MsvcRuntimeImports @('    ' + $name) $pin } 'unpinned C++ runtime dependency' ('unpinned import ' + $name)
}
$linkTarget = Join-Path $root 'link-target'; New-Item -ItemType Directory -Path $linkTarget | Out-Null
$linkPath = Join-Path $root 'junction'; New-Item -ItemType Junction -Path $linkPath -Target $linkTarget | Out-Null
Reject { Assert-CiMsvcNoLinks (Join-Path $linkPath 'new-file.dll') } 'msvc_ci_reparse_path' 'reparse ancestor rejected before create'
Reject { Assert-MsvcNoLinks $linkPath } 'reparse point' 'packager reparse source rejected'
Reject { & (Join-Path $PSScriptRoot 'prepare-msvc-runtime.ps1') -UiDirectory $root -RuntimeDirectory $destination } 'both RuntimeDirectory and DumpbinPath' 'explicit runtime cannot bypass inspector'

$actual = [bool]$RuntimeDirectory -or [bool]$DumpbinPath -or [bool]$ArchivePath
if ($actual) {
    if (!$RuntimeDirectory -or !$DumpbinPath -or !$ArchivePath) { throw 'Actual fixtures require all three explicit inputs.' }
    Assert-CiMsvcRuntime $RuntimeDirectory $pin
    $checks.Add('actual pinned DLL hash/version/Microsoft signatures')
    $result = & (Join-Path $PSScriptRoot 'prepare-ci-msvc-runtime.ps1') -Offline -ArchivePath $ArchivePath -OutputDirectory (Join-Path $root 'actual-prepared') -DumpbinPath $DumpbinPath
    Check ($result.RuntimeDirectory -eq (Join-Path $root 'actual-prepared') -and $result.ArchiveSha256 -ceq $sourcePin.sha256) 'actual offline preparation publishes exact runtime'
    $again = & (Join-Path $PSScriptRoot 'prepare-ci-msvc-runtime.ps1') -Offline -ArchivePath $ArchivePath -OutputDirectory $result.RuntimeDirectory -DumpbinPath $DumpbinPath
    Check ($again.RuntimeDirectory -eq $result.RuntimeDirectory) 'cache reuse rechecks all bytes and signatures'
    $ui = Join-Path $root 'actual-ui'; New-Item -ItemType Directory -Path $ui | Out-Null
    & (Join-Path $PSScriptRoot 'prepare-msvc-runtime.ps1') -UiDirectory $ui -RuntimeDirectory $result.RuntimeDirectory -DumpbinPath $DumpbinPath
    Check (@(Get-ChildItem -LiteralPath $ui -File).Count -eq 3) 'actual explicit runtime copies and inspects PE imports'
    $occupied = Join-Path $root 'occupied-ui'; New-Item -ItemType Directory -Path $occupied | Out-Null
    [IO.File]::WriteAllText((Join-Path $occupied 'vcruntime140_1.dll'), 'keep')
    Reject { & (Join-Path $PSScriptRoot 'prepare-msvc-runtime.ps1') -UiDirectory $occupied -RuntimeDirectory $result.RuntimeDirectory -DumpbinPath $DumpbinPath } 'already contains a runtime DLL' 'existing third DLL prevents all copies'
    Check (@(Get-ChildItem -LiteralPath $occupied -File).Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $occupied 'vcruntime140_1.dll')) -ceq 'keep') 'preexisting UI bytes retained'
    $wrongVersion = $pin | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $wrongVersion.fileVersion = '0.0.0.0'
    Reject { Assert-CiMsvcRuntime $result.RuntimeDirectory $wrongVersion } 'msvc_ci_runtime_mismatch' 'actual version mismatch'
    & {
        function Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        Reject { Assert-CiMsvcRuntime $result.RuntimeDirectory $pin } 'msvc_ci_runtime_signature' 'signature failure cannot be bypassed by exact hashes'
    }
    [IO.File]::WriteAllText((Join-Path $result.RuntimeDirectory 'unexpected.dll'), 'extra')
    Reject { & (Join-Path $PSScriptRoot 'prepare-ci-msvc-runtime.ps1') -Offline -ArchivePath $ArchivePath -OutputDirectory $result.RuntimeDirectory -DumpbinPath $DumpbinPath } 'msvc_ci_runtime_membership' 'cached output extra file refuses'
    $changed = Join-Path $root 'changed-runtime'; Copy-Item -LiteralPath $RuntimeDirectory -Destination $changed -Recurse
    [IO.File]::AppendAllText((Join-Path $changed 'msvcp140.dll'), 'modified')
    Reject { Assert-CiMsvcRuntime $changed $pin } 'msvc_ci_runtime_mismatch' 'changed cached DLL refuses'
    $invalidUi = Join-Path $root 'invalid-pe'; New-Item -ItemType Directory -Path $invalidUi | Out-Null
    [IO.File]::WriteAllText((Join-Path $invalidUi 'invalid.exe'), 'not a PE')
    Reject { & (Join-Path $PSScriptRoot 'prepare-msvc-runtime.ps1') -UiDirectory $invalidUi -RuntimeDirectory $RuntimeDirectory -DumpbinPath $DumpbinPath } 'PE runtime import inspection failed' 'failed inspector cannot become packaging success'
}
$evidence = [ordered]@{
    status = 'PASS'; checks = $checks.Count; actualMicrosoftInputs = $actual
    powershell = $PSVersionTable.PSVersion.ToString(); cases = @($checks)
    sources = @(foreach ($name in @('prepare-ci-msvc-runtime.ps1','prepare-msvc-runtime.ps1','msvc-runtime-ci.lock.json','msvc-runtime.lock.json','test-ci-msvc-runtime.ps1')) {
        [ordered]@{file=$name; sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
}
$evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding utf8
Write-Host "MSVC CI preparation: $($checks.Count) checks PASS. Actual Microsoft inputs: $actual. No system installation."
Write-Host (Join-Path $root 'result.json')
