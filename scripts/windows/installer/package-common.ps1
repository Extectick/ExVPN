# SPDX-License-Identifier: Apache-2.0
Set-StrictMode -Version Latest

function Get-PackageTree([string]$Root) {
    $absolute = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefix = $absolute + '\'
    $rootItem = Get-Item -LiteralPath $absolute -Force
    if (!$rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid package directory.' }
    $found = [Collections.Generic.List[IO.FileSystemInfo]]::new()
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($absolute)
    while ($queue.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $queue.Dequeue() -Force) {
            if (!$item.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Package path or reparse point rejected.' }
            $found.Add($item); if ($found.Count -gt 30000) { throw 'Package entry limit exceeded.' }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
        }
    }
    $found.ToArray()
}

function Get-OwnedPath([string]$Root, [string]$Relative) {
    if (!$Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative -match '(^|[\\/])\.{1,2}([\\/]|$)') { throw 'Invalid manifest relative path.' }
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $result = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (!$result.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest target escaped its root.' }
    $result
}

function Get-TreeManifest([string]$Root, [string[]]$Ignore = @()) {
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    @(Get-PackageTree $Root | Where-Object { !$_.PSIsContainer } | ForEach-Object {
        $relative = $_.FullName.Substring($prefix.Length)
        if ($relative -notin $Ignore) { [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
    })
}

function Assert-TreeManifest([string]$Root, $Records, [string[]]$Ignore = @(), [switch]$AllowMissing) {
    $map = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($Records)) {
        if ($record.path -isnot [string] -or $record.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid manifest entry.' }
        $path = Get-OwnedPath $Root $record.path
        if ($map.ContainsKey($path)) { throw 'Duplicate manifest target.' }; $map.Add($path, $record.sha256)
    }
    if (!(Test-Path -LiteralPath $Root)) { if ($AllowMissing) { return }; throw 'Installed tree is missing.' }
    foreach ($item in Get-PackageTree $Root | Where-Object { !$_.PSIsContainer }) {
        $relative = $item.FullName.Substring([IO.Path]::GetFullPath($Root).TrimEnd('\').Length + 1)
        if ($relative -in $Ignore) { continue }
        if (!$map.ContainsKey($item.FullName)) { throw 'Unknown file in owned installation; nothing removed.' }
        if ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $map[$item.FullName]) { throw 'Installed file changed; manual inspection required.' }
    }
    if (!$AllowMissing) { foreach ($path in $map.Keys) { if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Installed file is missing.' } } }
}

function Set-ProtectedPackageACL([string]$Path, [switch]$Directory) {
    if ($Directory) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)')
    } else {
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)')
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-ProtectedPackage([string]$Root) {
    $trusted = @('S-1-5-18','S-1-5-32-544',([Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value))
    $write = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($item in @((Get-Item -LiteralPath $Root -Force)) + @(Get-PackageTree $Root)) {
        $acl = Get-Acl -LiteralPath $item.FullName
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Untrusted installation owner.' }
        foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $write) -and $rule.IdentityReference.Value -notin $trusted) { throw 'Installation is writable by an ordinary user.' }
        }
    }
}

function Copy-OwnedTree([string]$Source, [string]$Destination, $Records) {
    if (Test-Path -LiteralPath $Destination) { throw 'Destination already exists.' }
    New-Item -ItemType Directory -Path $Destination | Out-Null; Set-ProtectedPackageACL $Destination -Directory
    foreach ($record in @($Records)) {
        $from = Get-OwnedPath $Source $record.path; $to = Get-OwnedPath $Destination $record.path
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($to)) | Out-Null
        Copy-Item -LiteralPath $from -Destination $to; Set-ProtectedPackageACL $to
    }
    foreach ($directory in Get-PackageTree $Destination | Where-Object PSIsContainer) { Set-ProtectedPackageACL $directory.FullName -Directory }
    Assert-TreeManifest $Destination $Records
}

function Remove-OwnedTree([string]$Root, $Records, [string[]]$Ignore = @()) {
    Assert-TreeManifest $Root $Records $Ignore -AllowMissing
    if (!(Test-Path -LiteralPath $Root)) { return }
    $items = @(Get-PackageTree $Root)
    foreach ($record in @($Records)) { $target = Get-OwnedPath $Root $record.path; if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target } }
    foreach ($relative in $Ignore) { $target = Get-OwnedPath $Root $relative; if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target } }
    foreach ($directory in $items | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending) { if (!(Get-ChildItem -LiteralPath $directory.FullName -Force)) { Remove-Item -LiteralPath $directory.FullName } }
    if (!(Get-ChildItem -LiteralPath $Root -Force)) { Remove-Item -LiteralPath $Root }
}

function Resolve-PackageOwner([string]$Explicit) {
    if ($Explicit -and $Explicit -ne 'AUTO') { $sid = $Explicit } else {
        $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $owners = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sessionId" | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid } | Sort-Object -Unique)
        if ($owners.Count -ne 1) { throw 'Cannot identify the desktop user. Relaunch setup with /OWNER_SID=S-1-5-21-... for the intended UI account.' }
        $sid = $owners[0]
    }
    if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'A local or domain user SID is required.' }
    [void]([Security.Principal.SecurityIdentifier]::new($sid).Translate([Security.Principal.NTAccount]))
    $sid
}
