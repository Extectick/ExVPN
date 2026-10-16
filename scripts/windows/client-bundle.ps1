# SPDX-License-Identifier: Apache-2.0
# Shared by controlled installation/staging scripts. No side effects on import.

function Get-ExVpnProgramFiles {
    $directory = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles))
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Program Files must not be a reparse point.' }
    $directory
}

function Get-ExVpnBundleFiles([string]$Directory) {
    $root = (Resolve-Path -LiteralPath $Directory).Path
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UI bundle cannot contain reparse points.' }
    $items = [Collections.Generic.List[IO.FileSystemInfo]]::new()
    $directories = [Collections.Generic.Queue[string]]::new()
    $directories.Enqueue($root)
    while ($directories.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $directories.Dequeue() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UI bundle cannot contain reparse points.' }
            $items.Add($item)
            if ($items.Count -gt 20000) { throw 'UI bundle has too many files.' }
            if ($item.PSIsContainer) { $directories.Enqueue($item.FullName) }
        }
    }
    foreach ($required in @('exvpn.exe', 'flutter_windows.dll', 'data/flutter_assets')) {
        if (!(Test-Path -LiteralPath (Join-Path $root $required))) { throw 'Incomplete Flutter Windows bundle.' }
    }
    @($items | Where-Object { !$_.PSIsContainer })
}

function Assert-ExVpnProtectedClient([string]$Executable) {
    $programFiles = Get-ExVpnProgramFiles
    $root = Join-Path $programFiles 'ExVPN'
    $expected = Join-Path $root 'exvpn.exe'
    $actual = (Resolve-Path -LiteralPath $Executable).Path
    if (![string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The IPC client must be the protected Program Files/ExVPN/exvpn.exe. Run stage-client.ps1 first.'
    }
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    $installer = [Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')
    $trusted += $installer.Translate([Security.Principal.SecurityIdentifier]).Value
    $write = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    $null = Get-ExVpnBundleFiles $root
    $items = @((Get-Item -LiteralPath $programFiles), (Get-Item -LiteralPath $root)) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installed bundle cannot contain reparse points.' }
        $acl = Get-Acl -LiteralPath $item.FullName
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Installed bundle has an untrusted owner.' }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $write) -and $rule.IdentityReference.Value -notin $trusted) {
                throw 'Installed bundle allows modification by an ordinary user.'
            }
        }
    }
    $actual
}
