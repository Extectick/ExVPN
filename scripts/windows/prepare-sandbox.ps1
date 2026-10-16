# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstallerDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$source = [IO.Path]::GetFullPath($InstallerDirectory)
$metadata = Get-Content -LiteralPath (Join-Path $source 'artifact.json') -Raw | ConvertFrom-Json
if ($metadata.file -notmatch '^ExVPN-\d+\.\d+\.\d+-\d+-windows-x64-development\.exe$' -or $metadata.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid installer artifact metadata.' }
$installer = Join-Path $source $metadata.file
if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.sha256) { throw 'Installer checksum mismatch.' }
$output = Join-Path $repository ('artifacts/windows/sandbox-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$inputFolder = Join-Path $output 'input'; $qaFolder = Join-Path $output 'qa-output'
New-Item -ItemType Directory -Path $inputFolder,$qaFolder | Out-Null
Copy-Item -LiteralPath $installer,(Join-Path $source 'artifact.json'),(Join-Path $PSScriptRoot 'sandbox/guest-qa.ps1'),(Join-Path $repository 'native/windows/INSTALLER.md') -Destination $inputFolder
$files = @(Get-TreeManifest $inputFolder | ForEach-Object { [ordered]@{file=$_.path;sha256=$_.sha256} })
[ordered]@{format=1;forbiddenHost=$env:COMPUTERNAME;installerFile=$metadata.file;installerSha256=$metadata.sha256;files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $inputFolder 'sandbox-bundle.json') -Encoding utf8
function Escape-Xml([string]$Text) { [Security.SecurityElement]::Escape($Text) }
$xml = @"
<Configuration>
  <vGPU>Disable</vGPU>
  <Networking>Enable</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MemoryInMB>8192</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(Escape-Xml $inputFolder)</HostFolder>
      <SandboxFolder>C:\ExVPN-Package</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(Escape-Xml $qaFolder)</HostFolder>
      <SandboxFolder>C:\ExVPN-QA</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ExVPN-Package\guest-qa.ps1 -ConfirmDisposableGuest</Command>
  </LogonCommand>
</Configuration>
"@
[xml]$checked = $xml
if (@($checked.Configuration.MappedFolders.MappedFolder).Count -ne 2) { throw 'Unexpected mapping count.' }
$wsb = Join-Path $output 'ExVPN-installer-qa.wsb'
$xml | Set-Content -LiteralPath $wsb -Encoding utf8
@"
Prepared, not executed. Opening ExVPN-installer-qa.wsb starts a disposable guest
and automatically tests installation, ACLs, service recovery/restart and uninstall.
VPN network testing is OFF. UI, tunnel, crash protection and upgrade are NOT tested.
Input is read-only; only the fresh qa-output folder is writable from the guest.
There are no repository/private/key/clipboard mappings. Guest output is untrusted
evidence and must never be executed by the host. No host install/network commands
are included. The host Sandbox feature and any reboot require separate coordination.
After execution, inspect qa-output/result.json. Failure retains the guest state for
diagnosis. Closing Sandbox discards its files. Do not reuse this output directory.
Installer SHA256: $($metadata.sha256)
"@ | Set-Content -LiteralPath (Join-Path $output 'README.txt') -Encoding utf8
Write-Host "Prepared without launching Windows Sandbox: $wsb"
