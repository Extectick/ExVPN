#Requires -RunAsAdministrator
# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'client-bundle.ps1')
$root = [IO.Path]::GetFullPath((Join-Path (Get-ExVpnProgramFiles) 'ExVPN'))
$prefix = $root + [IO.Path]::DirectorySeparatorChar
$manifestPath = Join-Path $root 'installed-files.json'
if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Controlled UI installation manifest is missing.' }
if ((Get-Item -LiteralPath $manifestPath).Length -gt 5MB) { throw 'Invalid UI installation manifest.' }
$service = Get-Service -Name ExVPNService -ErrorAction SilentlyContinue
if ($service) { throw 'Remove the ExVPN service and its guard before removing the UI bundle.' }
foreach ($process in @(Get-Process -Name exvpn -ErrorAction SilentlyContinue)) {
    if (!$process.Path -or [string]::Equals($process.Path, (Join-Path $root 'exvpn.exe'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Close ExVPN before removing its installed files.' }
}
$items = [Collections.Generic.List[IO.FileSystemInfo]]::new()
$rootItem = Get-Item -LiteralPath $root -Force
if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing UI cleanup through a reparse point.' }
$items.Add($rootItem)
$directories = [Collections.Generic.Queue[string]]::new()
$directories.Enqueue($root)
while ($directories.Count) {
    foreach ($item in Get-ChildItem -LiteralPath $directories.Dequeue() -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing UI cleanup through a reparse point.' }
        if (!$item.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'UI cleanup escaped its fixed installation root.' }
        $items.Add($item)
        if ($items.Count -gt 20000) { throw 'UI installation contains too many entries.' }
        if ($item.PSIsContainer) { $directories.Enqueue($item.FullName) }
    }
}
$records = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
if ($records.Count -lt 2 -or $records.Count -gt 20000) { throw 'Invalid UI installation manifest.' }
$targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($record in $records) {
    if ($record.path -isnot [string] -or [IO.Path]::IsPathRooted($record.path) -or $record.path.Contains(':') -or $record.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid UI installation entry.' }
    $target = [IO.Path]::GetFullPath((Join-Path $root $record.path))
    if (!$target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($target, $manifestPath, [StringComparison]::OrdinalIgnoreCase) -or !$targets.Add($target)) { throw 'Invalid UI removal target.' }
    if (Test-Path -LiteralPath $target) {
        if (!(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.sha256) { throw 'Installed UI file changed; inspect before removal.' }
    }
}
foreach ($item in $items | Where-Object { !$_.PSIsContainer }) {
    if ($item.FullName -ne $manifestPath -and !$targets.Contains($item.FullName)) { throw 'Unknown files found in installation; nothing removed.' }
}
# All absolute targets were checked against the fixed installation root above.
# No recursive remove, wildcards, or deletion of user subscription storage.
foreach ($target in $targets) { if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target } }
Remove-Item -LiteralPath $manifestPath
foreach ($directory in $items | Where-Object { $_.PSIsContainer -and $_.FullName -ne $root } | Sort-Object { $_.FullName.Length } -Descending) {
    if (!$directory.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected directory removal target.' }
    if ((Get-ChildItem -LiteralPath $directory.FullName -Force | Measure-Object).Count -eq 0) { Remove-Item -LiteralPath $directory.FullName }
}
if ((Get-ChildItem -LiteralPath $root -Force | Measure-Object).Count -eq 0) { Remove-Item -LiteralPath $root }
Write-Host 'Controlled UI bundle removed. Per-user encrypted subscription data retained.'
