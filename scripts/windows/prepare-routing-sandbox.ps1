# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HarnessExecutable,
    [Parameter(Mandatory)][string]$ProbeExecutable,
    [string]$ServiceExecutable = '',
    [string]$WintunLibrary = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
$artifactPrefix = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts/windows')).TrimEnd('\') + '\'
$go = Join-Path $repository '.tools/go/bin/go.exe'
if ((& $go version) -cne 'go version go1.27.2 windows/amd64' -or $LASTEXITCODE -ne 0) { throw 'Pinned Go 1.27.2 is required for binary metadata inspection.' }
if (!$ServiceExecutable) { $ServiceExecutable = Join-Path $repository 'artifacts/windows/exvpn-service.exe' }
if (!$WintunLibrary) { $WintunLibrary = Join-Path $repository 'artifacts/windows/wintun.dll' }
function Resolve-QAInput([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (!$resolved.StartsWith($artifactPrefix,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'Existing local Windows artifact required.' }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact links are forbidden.' }
    $resolved
}
function Assert-GoArtifact([string]$Path,[string]$MainPath) {
    # Read metadata only; this never executes a supplied test/service binary.
    $raw = & $go version -m -json $Path
    if ($LASTEXITCODE -ne 0) { throw 'Go build metadata unavailable.' }
    $info = $raw | ConvertFrom-Json
    if ($info.GoVersion -cne 'go1.27.2' -or $info.Path -cne $MainPath -or $info.Main.Path -cne 'github.com/Extectick/ExVPN/native/windows') { throw 'Unexpected QA executable toolchain/module.' }
    foreach ($pin in @{GOOS='windows';GOARCH='amd64'}.GetEnumerator()) {
        $found = @($info.Settings | Where-Object Key -CEQ $pin.Key)
        if ($found.Count -ne 1 -or $found[0].Value -cne $pin.Value) { throw 'QA executable platform mismatch.' }
    }
}
$harness = Resolve-QAInput $HarnessExecutable
$probe = Resolve-QAInput $ProbeExecutable
$service = Resolve-QAInput $ServiceExecutable
$wintun = Resolve-QAInput $WintunLibrary
Assert-GoArtifact $harness 'github.com/Extectick/ExVPN/native/windows/cmd/qa-system'
Assert-GoArtifact $probe 'github.com/Extectick/ExVPN/native/windows/cmd/qa-https'
Assert-GoArtifact $service 'github.com/Extectick/ExVPN/native/windows/cmd/exvpn-service'
$wintunPin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wintun.lock.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $wintun -Algorithm SHA256).Hash.ToLowerInvariant() -cne $wintunPin.dllSha256 -or (Get-AuthenticodeSignature -LiteralPath $wintun).Status -ne 'Valid') { throw 'Pinned, signed Wintun is required.' }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$output = Join-Path $repository ('artifacts/windows/routing-modes-' + $stamp)
$inputRoot = Join-Path $output 'input'
$resultRoot = Join-Path $output 'output'
New-Item -ItemType Directory -Path $inputRoot,$resultRoot | Out-Null
Copy-Item -LiteralPath $harness -Destination (Join-Path $inputRoot 'qa-system.exe')
Copy-Item -LiteralPath $probe -Destination (Join-Path $inputRoot 'protected-probe.exe')
Copy-Item -LiteralPath $probe -Destination (Join-Path $inputRoot 'excluded-probe.exe')
Copy-Item -LiteralPath $service -Destination (Join-Path $inputRoot 'exvpn-service.exe')
Copy-Item -LiteralPath $wintun -Destination (Join-Path $inputRoot 'wintun.dll')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer/package-common.ps1'),(Join-Path $PSScriptRoot 'sandbox/guest-system-qa.ps1') -Destination $inputRoot
$files = @('qa-system.exe','protected-probe.exe','excluded-probe.exe','exvpn-service.exe','wintun.dll','package-common.ps1') | ForEach-Object {
    [ordered]@{file=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $inputRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant()}
}
[ordered]@{format=1;files=@($files)} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $inputRoot 'qa-manifest.json') -Encoding utf8NoBOM
$runId = [Guid]::NewGuid().ToString()
$allFiles = @(Get-TreeManifest $inputRoot | ForEach-Object { [ordered]@{file=$_.path;sha256=$_.sha256} })
[ordered]@{format=1;forbiddenHost=$env:COMPUTERNAME;runId=$runId;routingModes=@('disabled','exclude','include');controllerHarness=$true;installedServiceIpcTested=$false;files=$allFiles} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Encoding utf8NoBOM
# This sole mutable input accepts only the two fixed test controls. It is not
# executable and is deliberately omitted from the immutable file manifest.
[IO.File]::WriteAllText((Join-Path $inputRoot 'command.txt'),'')
$inputXml = [Security.SecurityElement]::Escape($inputRoot)
$resultXml = [Security.SecurityElement]::Escape($resultRoot)
$xml = @"
<Configuration>
  <VGpu>Disable</VGpu><Networking>Enable</Networking>
  <AudioInput>Disable</AudioInput><VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection><ClipboardRedirection>Disable</ClipboardRedirection>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder><HostFolder>$inputXml</HostFolder><SandboxFolder>C:\ExVPN-Package</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$inputXml</HostFolder><SandboxFolder>C:\ExVPN-System-QA</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$resultXml</HostFolder><SandboxFolder>C:\ExVPN-QA</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
</Configuration>
"@
[xml]$checked = $xml
if (@($checked.Configuration.MappedFolders.MappedFolder).Count -ne 3) { throw 'Invalid isolated mappings.' }
$xml | Set-Content -LiteralPath (Join-Path $output 'routing-modes.wsb') -Encoding utf8
@"
Prepared only. No compiler, Sandbox, service or VPN was run by this script.
The coordinator requires the ID of this exact fresh Sandbox after its owner
starts routing-modes.wsb. Run scripts/windows/run-routing-modes-sandbox.ps1
-SandboxId <id> -BundleDirectory <this directory>. The coordinator installs
only protected QA files, not a service. Real TUN/WFP routes exist only inside
the explicitly confirmed disposable SYSTEM guest. Desktop probes run as the
existing WDAGUtilityAccount login; their administrator status is recorded.
The local VLESS fixture shares the guest egress: matching external IP hashes
are expected and do not prove a route. Per-destination fixture counters and
the outage matrix establish routing. DNS stays protected in all three modes.
SCM/production IPC, remote VPN egress, IPv6, physical Android, and crash
persistence are separate acceptance gates. The result is a controller harness.
No repository/private/key mappings, host firewall/routes/DNS mutation or UI
automation are included. Never execute guest-produced output on the host.
"@ | Set-Content -LiteralPath (Join-Path $output 'README.txt') -Encoding utf8
Write-Host "Prepared only, not started: $output"
