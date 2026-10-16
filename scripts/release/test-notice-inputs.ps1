# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$checks = 0
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Invalid notice input was accepted.' }
    $script:checks++
}
$identity = "const appVersion = '1.2.3';`nconst appBuild = 42;"
if ((Get-NoticeAppVersion 'version: 1.2.3+42' $identity) -cne '1.2.3+42') { throw 'Application identity mismatch.' }
$checks++
Assert-Rejected { Get-NoticeAppVersion 'version: 1.2.3+41' $identity }
Assert-Rejected { Get-NoticeAppVersion "version: 1.2.3+42`nversion: 1.2.3+42" $identity }
Assert-Rejected { Get-NoticeAppVersion 'version: 1.2.3+42' ("// " + $identity) }
Assert-Rejected { Get-NoticeAppVersion 'version: 1.2.3+42' ($identity + "`nconst appBuild = 41;") }

# Own disposable source/cache fixture. No native runtime, downloads or service
# installation. Keep evidence instead of recursively deleting directories.
$fixture = Join-Path $repository ('artifacts/qa/notice-fixture-' + [Guid]::NewGuid().ToString('N'))
$app = Join-Path $fixture 'apps/exvpn'
$configPath = Join-Path $app '.dart_tool/package_config.json'
$package = Join-Path $fixture '.tools/cache/pub/hosted/pub.dev/sample-1.0.0'
$hashFile = Join-Path $fixture '.tools/cache/pub/hosted-hashes/pub.dev/sample-1.0.0.sha256'
New-Item -ItemType Directory -Path (Split-Path $configPath),$package,(Split-Path $hashFile) -Force | Out-Null
$hash = 'a' * 64
Set-Content -LiteralPath (Join-Path $package 'pubspec.yaml') -Value "name: sample`nversion: 1.0.0 # pinned source comment"
Set-Content -LiteralPath $hashFile -Value $hash
$lock = @"
packages:
  sample:
    dependency: transitive
    description:
      name: sample
      sha256: "$hash"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
sdks:
  dart: ">=3.13.0 <4.0.0"
"@
$config = [ordered]@{configVersion=2;packages=@(@{name='sample';rootUri=([Uri]::new($package)).AbsoluteUri},@{name='exvpn';rootUri='../'})}
function Save-Config { $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath }
Save-Config
$resolved = @(Get-NoticeDartInputs $fixture $lock $configPath)
if ($resolved.Count -ne 1 -or $resolved[0].archiveSha256 -cne $hash) { throw 'Valid locked package was lost.' }
$checks++
Assert-Rejected { Get-NoticeDartInputs $fixture ($lock.Replace('version: "1.0.0"','version: "1.0.1"')) $configPath }
Assert-Rejected { Get-NoticeDartInputs $fixture ($lock.Replace('https://pub.dev','https://untrusted.invalid')) $configPath }
Assert-Rejected { Get-NoticeDartInputs $fixture ($lock.Replace('source: hosted',"source: hosted`n    source: hosted")) $configPath }
Set-Content -LiteralPath $hashFile -Value ('b' * 64)
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }
Set-Content -LiteralPath $hashFile -Value $hash
Set-Content -LiteralPath (Join-Path $package 'pubspec.yaml') -Value "name: sample`nversion: 1.0.1"
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }
Set-Content -LiteralPath (Join-Path $package 'pubspec.yaml') -Value "name: sample`nversion: 1.0.0"
$config.packages = @($config.packages[1]); Save-Config
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }
$config.packages = @(@{name='sample';rootUri=([Uri]::new($package)).AbsoluteUri},@{name='sample';rootUri=([Uri]::new($package)).AbsoluteUri},@{name='exvpn';rootUri='../'}); Save-Config
Assert-Rejected { Get-NoticeDartInputs $fixture $lock $configPath }

$info = @{GoVersion='go1.27.2';Settings=@(@{Key='GOOS';Value='windows'},@{Key='GOARCH';Value='amd64'},@{Key='-buildmode';Value='exe'})}
if ((Get-NoticeBinaryName 'Windows' $info '1.27.2') -cne 'service/exvpn-service.exe') { throw 'Wrong Windows binary identity.' }
$checks++
Assert-Rejected { Get-NoticeBinaryName 'Android' $info '1.27.2' }
Assert-Rejected { Get-NoticeBinaryName 'Windows' $info '1.27.1' }
$info.Settings = @(@{Key='GOOS';Value='android'},@{Key='GOARCH';Value='arm64'},@{Key='-buildmode';Value='c-shared'})
if ((Get-NoticeBinaryName 'Android' $info '1.27.2') -cne 'lib/arm64-v8a/libexvpn.so') { throw 'Wrong Android ABI identity.' }
$checks++
$info.Settings[1].Value = 'amd64'
if ((Get-NoticeBinaryName 'Android' $info '1.27.2') -cne 'lib/x86_64/libexvpn.so') { throw 'Wrong x86_64 ABI identity.' }
$checks++

$inventory = [pscustomobject]@{schema=1;app=@{version='1.2.3+42'};dartLockSha256=$hash;nativeBinaries=@(@{name='service/exvpn-service.exe';sha256=$hash});components=@(@{name='ExVPN';version='1.2.3+42'},@{name='ExVPN copyright';version='1.2.3+42'})}
Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash}
$checks++
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+43' $hash @{'service/exvpn-service.exe'=$hash} }
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' ('b' * 64) @{'service/exvpn-service.exe'=$hash} }
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=('b' * 64)} }
$inventory.components[0].version='1.2.3+1'
Assert-Rejected { Assert-NoticePackageBinding $inventory '1.2.3+42' $hash @{'service/exvpn-service.exe'=$hash} }
Write-Host "Notice input validation: $checks checks passed."
