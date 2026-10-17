# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UiDirectory,
    [string]$RuntimeDirectory = '',
    [string]$DumpbinPath = ''
)
$ErrorActionPreference = 'Stop'
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'msvc-runtime.lock.json') -Raw | ConvertFrom-Json
function Assert-MsvcNoLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    if ($current -notmatch '^[A-Za-z]:[\\/]') { throw 'MSVC input must be a local path.' }
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'MSVC input/output must not contain a reparse point.' }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Assert-MsvcRuntimeImports([string[]]$Imports, $RuntimePin) {
    foreach ($line in $Imports) {
        if ($line -match '^\s+((?:MSVCP|VCRUNTIME|CONCRT|VCCORLIB)[A-Za-z0-9_]*\.dll)\s*$') {
            if ($Matches[1] -notin @($RuntimePin.files.file)) { throw 'A packaged binary requires an unpinned C++ runtime dependency.' }
        }
    }
}
if ([bool]$RuntimeDirectory -ne [bool]$DumpbinPath) { throw 'Explicit MSVC runtime input requires both RuntimeDirectory and DumpbinPath.' }
if ($RuntimeDirectory) {
    $runtime = [IO.Path]::GetFullPath($RuntimeDirectory)
    $dumpbin = [IO.Path]::GetFullPath($DumpbinPath)
} else {
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$instances = @(& $vswhere -products '*' -version "[$($pin.visualStudioMajor).0,$($pin.visualStudioMajor + 1).0)" -format json | ConvertFrom-Json | Where-Object { !$_.isPrerelease })
$candidates = @($instances | Where-Object { Test-Path -LiteralPath (Join-Path $_.installationPath $pin.sourceRelativePath) })
if (!$candidates.Count) { throw 'The pinned release MSVC redistributable is missing. Install the pinned toolset or explicitly review a new runtime pin; never take arbitrary System32 DLLs.' }
$studio = $candidates[0].installationPath
$runtime = Join-Path $studio $pin.sourceRelativePath
$dumpbin = Join-Path $studio "VC/Tools/MSVC/$($pin.toolsetDirectory)/bin/Hostx64/x64/dumpbin.exe"
}
Assert-MsvcNoLinks $runtime
Assert-MsvcNoLinks $dumpbin
Assert-MsvcNoLinks $UiDirectory
$inspector = Get-Item -LiteralPath $dumpbin
$inspectorSignature = Get-AuthenticodeSignature -FilePath $dumpbin
if ($inspector.Name -ine 'dumpbin.exe' -or $inspector.VersionInfo.OriginalFilename -ine 'dumpbin.exe' -or
    $inspectorSignature.Status -ne 'Valid' -or $inspectorSignature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'Microsoft dumpbin identity/signature verification failed.' }
foreach ($record in $pin.files) {
    $source = Join-Path $runtime $record.file
    Assert-MsvcNoLinks $source
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.sha256 -or
        (Get-Item -LiteralPath $source).VersionInfo.FileVersion -ne $pin.fileVersion) { throw 'MSVC runtime pin mismatch.' }
    $signature = Get-AuthenticodeSignature -FilePath $source
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'MSVC runtime Microsoft Authenticode verification failed.' }
    $target = Join-Path $UiDirectory $record.file
    if (Test-Path -LiteralPath $target) { throw 'UI bundle already contains a runtime DLL; do not overwrite an unreviewed file.' }
}
foreach ($record in $pin.files) {
    $source = Join-Path $runtime $record.file
    $target = Join-Path $UiDirectory $record.file
    Copy-Item -LiteralPath $source -Destination $target
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.sha256) { throw 'Copied MSVC runtime pin mismatch.' }
}
# Verify transitive CRT imports in every packaged PE, including the added DLLs.
# OS API sets/UCRT are supplied by the supported Windows 10/11 installation.
foreach ($binary in Get-ChildItem -LiteralPath $UiDirectory -File | Where-Object Extension -in '.exe','.dll') {
    Assert-MsvcNoLinks $binary.FullName
    $imports = & $dumpbin /DEPENDENTS $binary.FullName
    if ($LASTEXITCODE -ne 0) { throw 'PE runtime import inspection failed.' }
    Assert-MsvcRuntimeImports $imports $pin
}
Write-Host "Pinned app-local MSVC runtime $($pin.fileVersion) verified; no global runtime installed."
