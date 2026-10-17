# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([switch]$DownloadMirror)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root = Join-Path $repository ('artifacts/qa/nsis-download-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$checks = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Label) { if (!$Condition) { throw "NSIS fixture failed: $Label" }; $checks.Add($Label) }
function Reject([scriptblock]$Action, [string]$Code, [string]$Label) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Check ($message.Contains($Code)) $Label
}
function RejectType([scriptblock]$Action, [type]$Type, [string]$Label) {
    $matched = $false
    try { & $Action | Out-Null } catch {
        $exception = $_.Exception
        while ($null -ne $exception) { if ($Type.IsInstanceOfType($exception)) { $matched = $true }; $exception = $exception.InnerException }
    }
    Check $matched $Label
}
$scriptPath = Join-Path $PSScriptRoot 'prepare-nsis.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
Check ($errors.Count -eq 0) 'production script parses'
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $definition.Extent.Text
}
$originalReceive = (Get-Item Function:Receive-NsisArchive).ScriptBlock
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'nsis.lock.json') -Raw | ConvertFrom-Json
Check ($pin.version -ceq '3.13' -and $pin.sha256 -ceq 'ba63dffc4410ee89193e1cb5a41989991bd77c61068da17e3156d136b7b0b3d8' -and
    $pin.compilerSha256 -ceq '4ec390d0f96f9728507fbc2f4e91311dd90bfc6c8ddfe2159357b3651ae151c0') 'original archive and compiler pins unchanged'
$sources = @(Get-NsisDownloadSources $pin)
Check ($sources.Count -eq 3) 'one original URL plus two official mirrors'
Assert-NsisDownloadUri ([uri]($pin.mirrors[0] + '?viasf=1&fid=synthetic')) $pin.version
$checks.Add('official same-file HTTPS redirect query allowed')
foreach ($uri in @(
    $pin.url.Replace('https:', 'http:'),
    $pin.url.Replace('downloads.sourceforge.net', 'downloads.sourceforge.net.evil.invalid'),
    $pin.url.Replace('downloads.sourceforge.net', 'other.invalid'),
    $pin.url.Replace('downloads.sourceforge.net', 'user@downloads.sourceforge.net'),
    $pin.url.Replace('downloads.sourceforge.net', 'downloads.sourceforge.net:444'),
    $pin.url.Replace('nsis-3.13.zip', 'nsis-3.13-src.tar.bz2'),
    ($pin.url + '#fragment'))) {
    Reject { Assert-NsisDownloadUri ([uri]$uri) $pin.version } 'nsis_download_uri_rejected' 'redirect origin/path/downgrade rejected'
}
$invalidPin = $pin | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$invalidPin.mirrors[0] = $invalidPin.url
Reject { Get-NsisDownloadSources $invalidPin } 'nsis_download_source_invalid' 'duplicate source rejected'
$invalidPin.mirrors[0] = $pin.mirrors[0] + '?not-pinned=1'
Reject { Get-NsisDownloadSources $invalidPin } 'nsis_download_source_invalid' 'unpinned source query rejected'

$payload = Join-Path $root 'verified-payload.zip'
[IO.File]::WriteAllText($payload, 'synthetic pinned bytes, not an executable')
$fixturePin = $pin | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$fixturePin.sha256 = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
$script:receives = 0; $script:behavior = 'html-then-valid'; $script:cachePath = ''
function Receive-NsisArchive([uri]$Uri, [string]$Path, [string]$Version) {
    $script:receives++
    if ($script:behavior -eq 'transport-then-valid' -and $script:receives -eq 1) { throw 'synthetic transport detail must not escape' }
    if ($script:behavior -eq 'all-html' -or ($script:behavior -eq 'html-then-valid' -and $script:receives -eq 1)) {
        [IO.File]::WriteAllText($Path, '<html>temporary mirror error, not an archive</html>')
    } else {
        [IO.File]::Copy($payload, $Path, $false)
        if ($script:behavior -eq 'concurrent-cache') { [IO.File]::WriteAllText($script:cachePath, 'concurrent cache must survive') }
    }
}
$cache = Join-Path $root 'cache.zip'
Save-NsisArchive $cache $fixturePin $false
Check ($script:receives -eq 2 -and (Get-FileHash $cache -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $fixturePin.sha256) 'HTML response rejected before mirror bytes are published'
Check (@(Get-ChildItem -LiteralPath $root -Filter '*.partial').Count -eq 0) 'owned temporary files cleaned after rejection and success'
$script:receives = 0
Save-NsisArchive $cache $fixturePin $true
Save-NsisArchive $cache $fixturePin $false
Check ($script:receives -eq 0) 'verified cache never redownloaded'
Reject { Save-NsisArchive (Join-Path $root 'offline.zip') $fixturePin $true } 'missing in offline mode' 'offline cache miss never downloads'
Check ($script:receives -eq 0) 'offline miss made zero requests'
$badCache = Join-Path $root 'bad-cache.zip'
[IO.File]::WriteAllText($badCache, 'preserve prior failure')
$badHash = (Get-FileHash $badCache -Algorithm SHA256).Hash
Reject { Save-NsisArchive $badCache $fixturePin $false } 'checksum mismatch' 'existing corrupt cache fails closed'
Check ($script:receives -eq 0 -and (Get-FileHash $badCache -Algorithm SHA256).Hash -ceq $badHash) 'bad cache retained byte-for-byte without request'
$script:behavior = 'all-html'; $script:receives = 0
$allBad = Join-Path $root 'all-bad.zip'
Reject { Save-NsisArchive $allBad $fixturePin $false } 'source3:nsis_download_hash_mismatch' 'all three hash failures are bounded and diagnosed'
Check ($script:receives -eq 3 -and !(Test-Path -LiteralPath $allBad)) 'no cache publication when every source fails'
Check (@(Get-ChildItem -LiteralPath $root -Filter '*.partial').Count -eq 0) 'all-failure temporary files cleaned'
$script:behavior = 'transport-then-valid'; $script:receives = 0
Save-NsisArchive (Join-Path $root 'transport.zip') $fixturePin $false
Check ($script:receives -eq 2) 'transport failure uses next pinned mirror'
$script:behavior = 'concurrent-cache'; $script:receives = 0
$script:cachePath = Join-Path $root 'concurrent.zip'
RejectType { Save-NsisArchive $script:cachePath $fixturePin $false } ([IO.IOException]) 'atomic publication cannot overwrite another cache'
Check ([IO.File]::ReadAllText($script:cachePath) -ceq 'concurrent cache must survive') 'concurrent cache preserved'
Check ($script:receives -eq 1) 'publication error does not retry network'

$sourceStream = [IO.MemoryStream]::new([byte[]]::new(16MB + 1))
$destinationStream = [IO.MemoryStream]::new()
try {
    Reject { Copy-NsisDownloadStream $sourceStream $destinationStream ([Threading.CancellationToken]::None) } 'nsis_download_size' 'chunked body larger than bound rejected'
    Check ($destinationStream.Length -le 16MB) 'oversized stream never writes beyond bound'
} finally { $sourceStream.Dispose(); $destinationStream.Dispose() }
$sourceStream = [IO.MemoryStream]::new(); $destinationStream = [IO.MemoryStream]::new()
try { Reject { Copy-NsisDownloadStream $sourceStream $destinationStream ([Threading.CancellationToken]::None) } 'nsis_download_empty' 'empty response rejected' }
finally { $sourceStream.Dispose(); $destinationStream.Dispose() }
$cancel = [Threading.CancellationTokenSource]::new(); $cancel.Cancel()
$sourceStream = [IO.MemoryStream]::new([byte[]]@(1)); $destinationStream = [IO.MemoryStream]::new()
try { RejectType { Copy-NsisDownloadStream $sourceStream $destinationStream $cancel.Token } ([OperationCanceledException]) 'expired total deadline stops stream read' }
finally { $sourceStream.Dispose(); $destinationStream.Dispose(); $cancel.Dispose() }
Set-Item Function:Receive-NsisArchive -Value $originalReceive

$download = $null
if ($DownloadMirror) {
    $actual = Join-Path $root 'actual-nsis-3.13.zip'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Receive-NsisArchive ([uri]$pin.mirrors[0]) $actual $pin.version
    Check ((Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $pin.sha256) 'actual official mirror download matches original archive SHA'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($actual)
    try {
        $entry = $zip.GetEntry('nsis-3.13/makensis.exe')
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $compiler = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        Check ($compiler -ceq $pin.compilerSha256) 'actual mirror compiler matches original compiler SHA without execution'
    } finally { $zip.Dispose() }
    $download = [ordered]@{source=$pin.mirrors[0];bytes=(Get-Item -LiteralPath $actual).Length;sha256=$pin.sha256;compilerSha256=$compiler;seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3)}
}
$proof = [ordered]@{status='PASS';checks=$checks.Count;labels=@($checks);powerShell=$PSVersionTable.PSVersion.ToString();download=$download;files=@()}
foreach ($name in @('prepare-nsis.ps1','nsis.lock.json','test-prepare-nsis.ps1')) {
    $proof.files += [ordered]@{path=('scripts/windows/'+$name);sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$proof | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'proof.json') -Encoding UTF8
Write-Host "NSIS download fixtures: $($checks.Count) PASS; no installation or compiler execution."
Write-Host ('Proof: '+(Join-Path $root 'proof.json').Substring($repository.Length + 1))
