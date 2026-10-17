[CmdletBinding()]
param([switch]$Offline)
$ErrorActionPreference = 'Stop'

function Assert-NsisDownloadUri([uri]$Uri, [string]$Version) {
    $expectedPath = "/project/nsis/NSIS%203/$Version/nsis-$Version.zip"
    if (!$Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or
        $Uri.UserInfo -or $Uri.Fragment -or
        ($Uri.Host -cne 'downloads.sourceforge.net' -and $Uri.Host -cnotmatch '^[a-z0-9-]+\.dl\.sourceforge\.net$') -or
        $Uri.AbsolutePath -cne $expectedPath) { throw 'nsis_download_uri_rejected' }
}

function Get-NsisDownloadSources($Pin) {
    if ($Pin.version -cnotmatch '^[0-9]+\.[0-9]+(?:\.[0-9]+)?$' -or
        $Pin.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Pin.compilerSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'nsis_pin_invalid' }
    $sources = @($Pin.url)
    if ($Pin.PSObject.Properties.Name -contains 'mirrors') { $sources += @($Pin.mirrors) }
    if ($sources.Count -gt 3) { throw 'nsis_download_source_limit' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($source in $sources) {
        $uri = [uri]$source
        Assert-NsisDownloadUri $uri $Pin.version
        if ($uri.Query -or !$seen.Add($uri.AbsoluteUri)) { throw 'nsis_download_source_invalid' }
        $uri
    }
}

function Copy-NsisDownloadStream([IO.Stream]$Source, [IO.Stream]$Destination, [Threading.CancellationToken]$Token) {
    # A fixed bound also covers chunked responses without a Content-Length.
    $buffer = [byte[]]::new(65536)
    [long]$total = 0
    while (($read = $Source.ReadAsync($buffer, 0, $buffer.Length, $Token).GetAwaiter().GetResult()) -gt 0) {
        $Token.ThrowIfCancellationRequested()
        $total += $read
        if ($total -gt 16MB) { throw 'nsis_download_size' }
        $Destination.Write($buffer, 0, $read)
    }
    if ($total -eq 0) { throw 'nsis_download_empty' }
}

function Receive-NsisArchive([uri]$Uri, [string]$Path, [string]$Version) {
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $cancel = [Threading.CancellationTokenSource]::new(30000)
    $response = $null; $source = $null; $destination = $null
    try {
        # SourceForge may redirect between its official mirrors. Never follow a
        # downgrade, another project/path, credentials, or an unbounded chain.
        for ($redirect = 0; $redirect -le 4; $redirect++) {
            Assert-NsisDownloadUri $Uri $Version
            $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                if ($redirect -eq 4 -or !$response.Headers.Location) { throw 'nsis_download_redirect_limit' }
                $Uri = [uri]::new($Uri, $response.Headers.Location)
                $response.Dispose(); $response = $null
                continue
            }
            if ([int]$response.StatusCode -ne 200) { throw 'nsis_download_status' }
            if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt 16MB) { throw 'nsis_download_size' }
            $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $destination = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            Copy-NsisDownloadStream $source $destination $cancel.Token
            return
        }
    } finally {
        if ($destination) { $destination.Dispose() }
        if ($source) { $source.Dispose() }
        if ($response) { $response.Dispose() }
        $cancel.Dispose(); $client.Dispose(); $handler.Dispose()
    }
}

function Save-NsisArchive([string]$Path, $Pin, [bool]$Offline) {
    $sources = @(Get-NsisDownloadSources $Pin)
    if (Test-Path -LiteralPath $Path) {
        # Preserve existing evidence/cache. A bad cache is never overwritten or
        # treated as permission to download different bytes.
        if (!(Test-Path -LiteralPath $Path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pin.sha256) { throw 'NSIS archive checksum mismatch.' }
        return
    }
    if ($Offline) { throw 'Pinned NSIS archive is missing in offline mode.' }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    $failures = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $sources.Count; $index++) {
        $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.partial'
        $verified = $false
        try {
            try {
                Receive-NsisArchive $sources[$index] $temporary $Pin.version
                if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pin.sha256) { throw 'nsis_download_hash_mismatch' }
                $verified = $true
            } catch {
                $code = if ($_.Exception.Message -cmatch '^nsis_download_[a-z_]+$') { $_.Exception.Message } else { 'nsis_download_transport' }
                $failures.Add(('source' + ($index + 1) + ':' + $code))
            }
            if ($verified) {
                # Same-directory atomic publication; File.Move refuses to
                # replace a cache concurrently created by another invocation.
                [IO.File]::Move($temporary, $Path)
                return
            }
        } finally {
            # Only this invocation's uniquely named temporary file is removed.
            if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary }
        }
    }
    throw ('NSIS archive unavailable from pinned HTTPS sources: ' + ($failures -join ', '))
}

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'nsis.lock.json') -Raw | ConvertFrom-Json
$archive = Join-Path $repository ".cache/nsis-$($pin.version).zip"
$tool = Join-Path $repository ".tools/nsis-$($pin.version)"
Save-NsisArchive $archive $pin ([bool]$Offline)
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.sha256) { throw 'NSIS archive checksum mismatch.' }
if (!(Test-Path -LiteralPath (Join-Path $tool 'makensis.exe'))) { Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $repository '.tools') }
if ((Get-FileHash -LiteralPath (Join-Path $tool 'makensis.exe') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.compilerSha256) { throw 'NSIS compiler checksum mismatch.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        if (!$entry.Name) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path (Join-Path $repository '.tools') $entry.FullName))
        if (!$target.StartsWith($tool + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'NSIS archive escaped the pinned tool directory.' }
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
        if (!(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Expanded NSIS SDK differs from its pinned archive.' }
    }
} finally { $zip.Dispose() }
Write-Host "NSIS $($pin.version) verified. No system installation performed."
