#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $repository ('artifacts/release-audit/fixtures-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$checks = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (!$Condition) { throw "FAIL: $Name" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Code) {
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($caught -ceq $Code) $Code
}
function New-Findings { ,([Collections.Generic.List[object]]::new()) }
function Has-Code($Findings, [string]$Code) { @($Findings | Where-Object code -CEQ $Code).Count -gt 0 }
function New-FixtureZip([string]$Name, [object[]]$Entries) {
    $path = Join-Path $fixture $Name
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in $Entries) {
            $entry = $zip.CreateEntry($item.path)
            if ($item.Contains('attributes')) { $entry.ExternalAttributes = $item.attributes }
            $stream = $entry.Open()
            try { $bytes = [Text.Encoding]::UTF8.GetBytes($item.text); $stream.Write($bytes, 0, $bytes.Length) }
            finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $path
}

Assert-True ((ConvertTo-AuditPath 'control\notices\LICENSE') -ceq 'control/notices/LICENSE') 'Windows path normalization'
foreach ($path in @('../escape', 'a/../escape', '/absolute', 'C:\escape', 'a:stream', 'a//b', 'a/./b', 'a/b.', 'a/b ', 'CON.txt', "a/line`nb")) {
    Assert-Rejected { ConvertTo-AuditPath $path } 'unsafe_relative_path'
}
$tree = Join-Path $fixture 'payload'
foreach ($dir in @('ui', 'service', 'control')) { New-Item -ItemType Directory -Path (Join-Path $tree $dir) | Out-Null }
[IO.File]::WriteAllText((Join-Path $tree 'ui/app.exe'), 'synthetic executable bytes')
[IO.File]::WriteAllText((Join-Path $tree 'package.json'), '{}')
$files = Get-AuditTreeFiles $tree
$manifest = @{ format = 1; trees = @{ ui = @(@{ path = 'app.exe'; sha256 = $files['ui/app.exe'].sha256 }); service = @(); control = @() } }
$f = New-Findings
Test-AuditManifest $manifest $files $f
Assert-True ($f.Count -eq 0) 'exact manifest/tree'
[IO.File]::AppendAllText((Join-Path $tree 'ui/app.exe'), 'tampered')
[IO.File]::WriteAllText((Join-Path $tree 'ui/extra.dll'), 'not in manifest')
$f = New-Findings
Test-AuditManifest $manifest (Get-AuditTreeFiles $tree) $f
Assert-True ((Has-Code $f 'packaged_file_hash_mismatch') -and (Has-Code $f 'unmanifested_payload_file')) 'tampered and added files rejected'
$manifest.trees.service = @(@{ path = 'missing.exe'; sha256 = ('0' * 64) })
$f = New-Findings
Test-AuditManifest $manifest $files $f
Assert-True (Has-Code $f 'packaged_file_missing') 'missing file rejected'
$manifest.trees.service += @{ path = 'MISSING.exe'; sha256 = ('0' * 64) }
Assert-Rejected { Test-AuditManifest $manifest $files (New-Findings) } 'invalid_package_file_record'
$manifest.trees.service = @(@{ path = '../escape'; sha256 = ('0' * 64) })
Assert-Rejected { Test-AuditManifest $manifest $files (New-Findings) } 'unsafe_relative_path'

$validZip = New-FixtureZip 'valid.zip' @(@{ path = 'lib/x86_64/libexvpn.so'; text = 'native' }, @{ path = 'LICENSE'; text = 'license' })
$zipFiles = Get-AuditZipFiles $validZip
Assert-True ($zipFiles.Count -eq 2 -and $zipFiles['LICENSE'].sha256 -ceq (Get-AuditTextHash 'license')) 'ZIP hashes exact entries'
Assert-Rejected { Read-AuditZipBytes $validZip 'LICENSE' 3 } 'archive_entry_missing_or_too_large'
$badZip = New-FixtureZip 'traversal.zip' @(@{ path = '../../escape'; text = 'no' })
Assert-Rejected { Get-AuditZipFiles $badZip } 'unsafe_relative_path'
$duplicateZip = New-FixtureZip 'duplicate.zip' @(@{ path = 'file'; text = 'one' }, @{ path = 'FILE'; text = 'two' })
Assert-Rejected { Get-AuditZipFiles $duplicateZip } 'duplicate_archive_path'
$linkZip = New-FixtureZip 'link.zip' @(@{ path = 'link'; text = 'target'; attributes = [int]-1610612736 })
Assert-Rejected { Get-AuditZipFiles $linkZip } 'archive_link_not_allowed'
$smallStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('too long'))
try { Assert-Rejected { Get-AuditStreamHash $smallStream 3 } 'archive_entry_length_mismatch' } finally { $smallStream.Dispose() }
$emptyZip = New-FixtureZip 'empty.zip' @()
Assert-True ((Get-AuditGoZipSum $emptyZip) -ceq 'h1:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=') 'Go empty-zip h1 vector'
$zipReverse = New-FixtureZip 'reverse.zip' @(@{ path = 'LICENSE'; text = 'license' }, @{ path = 'lib/x86_64/libexvpn.so'; text = 'native' })
Assert-True ((Get-AuditGoZipSum $validZip) -ceq (Get-AuditGoZipSum $zipReverse)) 'Go h1 independent of ZIP entry order'
$zipTampered = New-FixtureZip 'tampered.zip' @(@{ path = 'LICENSE'; text = 'license changed' }, @{ path = 'lib/x86_64/libexvpn.so'; text = 'native' })
Assert-True ((Get-AuditGoZipSum $validZip) -cne (Get-AuditGoZipSum $zipTampered)) 'Go source content tamper rejected'
$prefixZip = New-FixtureZip 'prefix.zip' @(@{ path = 'LICENSE.md'; text = 'B' }, @{ path = 'LICENSE'; text = 'A' })
Assert-True ((Get-AuditGoZipSum $prefixZip) -ceq 'h1:nY/RJ6yENsnpGpKjYpGuXCT/Z/8L4cFjEyWMk/r73cM=') 'Go prefix-name h1 vector'
$collisionZip = New-FixtureZip 'collision.zip' @(@{ path = 'parent'; text = 'file' }, @{ path = 'parent/child'; text = 'child' })
Assert-Rejected { Get-AuditZipFiles $collisionZip } 'archive_file_directory_collision'
$shell = Join-Path $PSHOME 'pwsh.exe'
Assert-Rejected { Invoke-AuditTool $shell @('-NoProfile', '-Command', 'exit 7') } 'audit_tool_failed'
Assert-Rejected { Invoke-AuditTool $shell @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') 1 } 'audit_tool_timeout'

$pins = @{ 'example.org/dep' = @{ version = 'v1.2.3'; sum = 'h1:synthetic' } }
$info = @{ GoVersion = 'go1.27.2'; Settings = @(@{ Key = 'GOOS'; Value = 'windows' }, @{ Key = 'GOARCH'; Value = 'amd64' }); Deps = @(@{ Path = 'example.org/dep'; Version = 'v1.2.3'; Sum = 'h1:synthetic' }) }
$f = New-Findings
$nativeEvidence = Test-AuditGoBinary $info 'service/exvpn-service.exe' ('a' * 64) $pins '1.27.2' $f
Assert-True ($f.Count -eq 0 -and $nativeEvidence.modules.Count -eq 1) 'matching embedded module pin'
$info.Deps[0].Version = 'v9.9.9'
$info.Deps[0].Replace = @{ Path = 'example.org/other'; Version = 'v1.2.3' }
$info.Settings[0].Value = 'android'
$info.GoVersion = 'go1.0.0'
$f = New-Findings
Test-AuditGoBinary $info 'service/exvpn-service.exe' ('a' * 64) $pins '1.27.2' $f | Out-Null
Assert-True ((Has-Code $f 'native_module_pin_mismatch') -and (Has-Code $f 'external_go_module_replacement') -and (Has-Code $f 'native_platform_mismatch') -and (Has-Code $f 'native_go_version_mismatch')) 'wrong pin/toolchain/platform/replacement rejected'

$noticeFiles = New-AuditFileMap
$noticeFiles.Add('license.txt', @{ path = 'license.txt'; sha256 = ('b' * 64); size = 5 })
$notice = @{ path = 'license.txt'; sha256 = ('b' * 64) }
$inventory = @{ schema = 1; target = 'Windows'; app = @{ version = '0.1.0+9' }; dartLockSha256 = ('c' * 64); nativeBinaries = @(@{
    name = 'service/exvpn-service.exe'; sha256 = ('a' * 64); go = 'go1.27.2'; modules = @(@{ Path = 'example.org/dep'; Version = 'v1.2.3'; Sum = 'h1:synthetic' })
}); components = @(
    @{ name = 'ExVPN'; version = '0.1.0+9'; scope = 'runtime-or-asset'; notices = @($notice) },
    @{ name = 'ExVPN copyright'; version = '0.1.0+9'; scope = 'runtime-or-asset'; notices = @($notice) },
    @{ name = 'example.org/dep'; version = 'v1.2.3'; scope = 'linked-go-module'; moduleSum = 'h1:synthetic'; notices = @($notice) }
) }
$f = New-Findings
Test-AuditNotices $inventory $noticeFiles @($nativeEvidence) 'Windows' '0.1.0+9' ('c' * 64) $f
Assert-True ($f.Count -eq 0) 'exact notice/native/version binding'
$inventory.components[0].version = '0.1.0+1'
$inventory.nativeBinaries[0].name = 'artifacts/windows/exvpn-service.exe'
$inventory.dartLockSha256 = 'outdated'
$noticeFiles['license.txt'].sha256 = ('d' * 64)
$f = New-Findings
Test-AuditNotices $inventory $noticeFiles @($nativeEvidence) 'Windows' '0.1.0+9' ('c' * 64) $f
Assert-True ((Has-Code $f 'notice_component_version_stale') -and (Has-Code $f 'notice_native_path_not_bound') -and (Has-Code $f 'notice_dart_lock_missing_or_mismatch') -and (Has-Code $f 'notice_file_hash_mismatch')) 'stale inventory/wrong binary path/tampered notice rejected'
$inventory.nativeBinaries[0].sha256 = ('e' * 64)
$f = New-Findings
Test-AuditNotices $inventory $noticeFiles @($nativeEvidence) 'Windows' '0.1.0+9' ('c' * 64) $f
Assert-True ((Has-Code $f 'notice_native_hash_not_bound') -and (Has-Code $f 'notice_native_binary_not_in_artifact')) 'global unshipped binary cannot bind artifact'
$inventory.nativeBinaries[0].sha256 = ('a' * 64)
$inventory.nativeBinaries[0].modules[0].Sum = 'h1:forged'
$f = New-Findings
Test-AuditNotices $inventory $noticeFiles @($nativeEvidence) 'Windows' '0.1.0+9' ('c' * 64) $f
Assert-True (Has-Code $f 'notice_native_module_mismatch') 'forged embedded module sum rejected'
$missing = New-AuditFileMap
$f = New-Findings
Test-AuditNotices $inventory $missing @($nativeEvidence) 'Windows' '0.1.0+9' ('c' * 64) $f
Assert-True (Has-Code $f 'notice_file_missing') 'missing full license text rejected'
$inventory.components += $inventory.components[0]
Assert-Rejected { Test-AuditNotices $inventory $noticeFiles @($nativeEvidence) 'Windows' '0.1.0+9' ('c' * 64) (New-Findings) } 'duplicate_notice_component'
$inventory.components = $inventory.components[0..2]

$bom1 = New-AuditSbom 'Windows' '0.1.0+9' ('f' * 64) $files @($nativeEvidence) $inventory
$reverseFiles = New-AuditFileMap
foreach ($key in @($files.Keys | Sort-Object -Descending)) { $reverseFiles.Add($key, $files[$key]) }
$inventory.components = @($inventory.components | Sort-Object { $_.name } -Descending)
$bom2 = New-AuditSbom 'Windows' '0.1.0+9' ('f' * 64) $reverseFiles @($nativeEvidence) $inventory
Write-AuditJson (Join-Path $fixture 'first.cdx.json') $bom1
Write-AuditJson (Join-Path $fixture 'second.cdx.json') $bom2
Assert-True ((Get-AuditSha256 (Join-Path $fixture 'first.cdx.json')) -ceq (Get-AuditSha256 (Join-Path $fixture 'second.cdx.json'))) 'deterministic SBOM independent of enumeration order'
Assert-True ($bom1.compositions[0].aggregate -ceq 'incomplete' -and @($bom1.components | Where-Object { $_.properties -and @($_.properties | Where-Object value -CEQ 'notice-inventory-declaration-not-link-proof').Count }).Count -eq 2) 'SBOM distinguishes declarations and incomplete coverage'
Assert-True (@($bom1.components | Group-Object { $_['bom-ref'] } | Where-Object Count -GT 1).Count -eq 0) 'unique SBOM component refs'
Write-Host "Artifact audit fixtures: $checks PASS. No binary installed, network modified, SDK downloaded or keys read."
