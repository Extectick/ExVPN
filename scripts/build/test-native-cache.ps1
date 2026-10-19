# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-cache-lib.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $repository ('artifacts/qa/native-cache-' + [Guid]::NewGuid().ToString('N'))
$checks = 0
function Check([bool]$Condition, [string]$Reason) { if (!$Condition) { throw $Reason }; $script:checks++ }
function Write-Fixture([string]$Relative, [string]$Text) {
    $path = Join-Path $fixture $Relative
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Text)
}
function Fixture-Identity([string]$Target = 'windows-amd64', [string]$Flag = 'safe') {
    Get-NativeCacheIdentity -Repository $fixture -Target $Target -Parameters @{flags=$Flag;go='pinned-synthetic'} -Tools @((Join-Path $fixture 'tool.exe'))
}
function Restore-Fixture($Identity = $script:identity, [string[]]$Names = @('service.exe')) {
    Restore-NativeCachedOutputs -CacheRoot $script:cache -Identity $Identity -OutputDirectory $script:output -Names $Names
}
try {
    Write-Fixture 'native/core/go.mod' "module synthetic.invalid/core`n"
    Write-Fixture 'native/core/source.go' '// original source'
    Write-Fixture 'scripts/bootstrap/toolchain.lock.json' '{"go":"synthetic"}'
    Write-Fixture 'native/android/build.ps1' '# synthetic JNI build recipe'
    Write-Fixture 'scripts/windows/build.ps1' '# synthetic service build recipe'
    Write-Fixture 'scripts/build/native-cache-lib.ps1' '# synthetic cache recipe'
    Write-Fixture 'apps/exvpn/pubspec.yaml' 'version: 1.0.0+1'
    Write-Fixture '.gitignore' "native/core/ignored.bin`n"
    Write-Fixture 'tool.exe' 'synthetic pinned tool'
    & git -C $fixture init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'fixture_git_init_failed' }
    & git -C $fixture add .
    if ($LASTEXITCODE -ne 0) { throw 'fixture_git_add_failed' }
    $identity = Fixture-Identity
    Check ($identity.key -cmatch '^[a-f0-9]{64}$' -and $identity.sourceCount -eq 6) 'source identity missing'
    Write-Fixture 'apps/exvpn/pubspec.yaml' 'version: 1.1.0+2'
    Check ((Fixture-Identity).key -ceq $identity.key) 'app version invalidated native-only output'
    Write-Fixture 'native/core/ignored.bin' 'must not enter source inventory'
    Check ((Fixture-Identity).key -ceq $identity.key) 'ignored file entered identity'
    Write-Fixture 'native/core/source.go' '// changed source'
    Check ((Fixture-Identity).key -cne $identity.key) 'modified source reused stale output'
    Write-Fixture 'native/core/source.go' '// original source'
    Write-Fixture 'native/core/new.go' '// untracked native source'
    Check ((Fixture-Identity).key -cne $identity.key) 'untracked source was omitted'
    Remove-Item -LiteralPath (Join-Path $fixture 'native/core/new.go')
    Check ((Fixture-Identity -Flag 'different').key -cne $identity.key) 'compiler flags were omitted'
    $androidX64 = Fixture-Identity -Target 'android-x86_64'
    Check ($androidX64.target -ceq 'android-x86_64' -and $androidX64.key -cmatch '^[a-f0-9]{64}$') 'actual Android x64 ABI target rejected'
    Check ($androidX64.key -cne $identity.key) 'platform was omitted'
    Write-Fixture 'tool.exe' 'changed tool'
    Check ((Fixture-Identity).key -cne $identity.key) 'compiler bytes were omitted'
    Write-Fixture 'tool.exe' 'synthetic pinned tool'
    $cache = Join-Path $fixture 'cache'; $output = Join-Path $fixture 'output'
    Check (!(Restore-Fixture)) 'missing cache accepted'
    Write-Fixture 'built/service.exe' 'exact finished binary'
    Save-NativeCachedOutputs -CacheRoot $cache -Identity $identity -OutputDirectory (Join-Path $fixture 'built') -Names @('service.exe')
    Check (Restore-Fixture) 'valid cache was not restored'
    Check ([IO.File]::ReadAllText((Join-Path $output 'service.exe')) -ceq 'exact finished binary') 'cache changed binary'
    Check (!(Restore-Fixture -Names @('../service.exe'))) 'output traversal accepted'
    Check (!(Restore-Fixture -Names @('service.exe','service.exe'))) 'duplicate output names accepted'
    $entry = Join-Path $cache $identity.key
    $manifestPath = Join-Path $entry 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText($manifestPath, $manifest.Replace($identity.key, ('0' * 64)))
    Check (!(Restore-Fixture)) 'wrong source key accepted'
    [IO.File]::WriteAllText($manifestPath, $manifest)
    [IO.File]::WriteAllText((Join-Path $entry 'service.exe'), 'corrupt binary')
    Check (!(Restore-Fixture)) 'corrupt cached output accepted'
    [IO.File]::WriteAllText((Join-Path $entry 'service.exe'), 'exact finished binary')
    [IO.File]::WriteAllText((Join-Path $entry 'unexpected.exe'), 'unexpected')
    Check (!(Restore-Fixture)) 'unknown cached output accepted'
    Remove-Item -LiteralPath (Join-Path $entry 'unexpected.exe')
    [IO.File]::WriteAllText($manifestPath, 'not-json')
    Check (!(Restore-Fixture)) 'damaged manifest accepted'
    [IO.File]::WriteAllText($manifestPath, $manifest)
    if ($IsWindows) {
        $alias = Join-Path $fixture 'hardlink.exe'
        New-Item -ItemType HardLink -Path $alias -Target (Join-Path $entry 'service.exe') | Out-Null
        Check (!(Restore-Fixture)) 'hardlinked cache bytes accepted'
        Remove-Item -LiteralPath $alias
        Check (Restore-Fixture) 'valid cache not recovered after link removal'
        Remove-Item -LiteralPath (Join-Path $output 'service.exe')
        New-Item -ItemType HardLink -Path (Join-Path $output 'service.exe') -Target (Join-Path $fixture 'built/service.exe') | Out-Null
        Check (!(Restore-Fixture)) 'hardlinked destination accepted'
        Check ([IO.File]::ReadAllText((Join-Path $fixture 'built/service.exe')) -ceq 'exact finished binary') 'rejected restore changed linked file'
        Remove-Item -LiteralPath (Join-Path $output 'service.exe')
        $aliasRoot = Join-Path $fixture 'cache-alias'
        New-Item -ItemType Junction -Path $aliasRoot -Target $cache | Out-Null
        Check (!(Restore-NativeCachedOutputs -CacheRoot $aliasRoot -Identity $identity -OutputDirectory $output -Names @('service.exe'))) 'junction cache accepted'
        Remove-Item -LiteralPath $aliasRoot
    }
    foreach ($relative in @('scripts/windows/build.ps1','native/android/build.ps1')) {
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository $relative), [ref]$null, [ref]$errors) | Out-Null
        Check (!$errors.Count) "build script syntax invalid: $relative"
    }
    Write-Host "Native completed-output cache: $checks checks passed; no product build or network changes."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts/qa')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Assert-NativeCacheNoLinks $resolved
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
