# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$go = Join-Path $repository '.tools/go/bin/go.exe'
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$output = Join-Path $repository ('artifacts/windows/bootstrap-qa-' + $stamp)
$inputRoot = Join-Path $output 'input'
$resultRoot = Join-Path $output 'output'
New-Item -ItemType Directory -Path $inputRoot,$resultRoot | Out-Null
# Compilation only. The tagged test must never execute on the host or in CI.
& $go -C (Join-Path $repository 'native/windows') test -c -tags exvpn_sandbox_qa -o (Join-Path $inputRoot 'qa-bootstrap.exe') .
if ($LASTEXITCODE -ne 0) { throw 'Guest test compilation failed.' }
& $go -C (Join-Path $repository 'native/windows') build -trimpath -o (Join-Path $inputRoot 'protected-probe.exe') ./cmd/qa-https
if ($LASTEXITCODE -ne 0) { throw 'Guest probe compilation failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer/package-common.ps1'),(Join-Path $PSScriptRoot 'sandbox/guest-bootstrap-qa.ps1') -Destination $inputRoot
$files = @('qa-bootstrap.exe','protected-probe.exe','package-common.ps1') | ForEach-Object {
    [ordered]@{file=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $inputRoot $_)).Hash.ToLowerInvariant()}
}
[ordered]@{format=1;forbiddenHost=$env:COMPUTERNAME;files=@($files)} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Encoding utf8
$inputXml = [Security.SecurityElement]::Escape($inputRoot)
$resultXml = [Security.SecurityElement]::Escape($resultRoot)
$xml = @"
<Configuration>
  <VGpu>Disable</VGpu><Networking>Enable</Networking>
  <AudioInput>Disable</AudioInput><VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection><ClipboardRedirection>Disable</ClipboardRedirection>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder><HostFolder>$inputXml</HostFolder><SandboxFolder>C:\ExVPN-Bootstrap-QA</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$resultXml</HostFolder><SandboxFolder>C:\ExVPN-Bootstrap-Results</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
</Configuration>
"@
[xml]$checked = $xml
if (@($checked.Configuration.MappedFolders.MappedFolder).Count -ne 2) { throw 'Invalid mappings.' }
Set-Content -LiteralPath (Join-Path $output 'bootstrap.wsb') -Value $xml -Encoding utf8
Write-Host "Prepared only, not started: $output"
