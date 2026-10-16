#requires -Version 7.0
<#
.SYNOPSIS
Adds the required Flutter Windows C++ components to an existing Visual Studio.
.DESCRIPTION
Uses only the installed, Microsoft-signed Visual Studio installer. Does not
download a bootstrapper, change security policy, bypass UAC, accept license UI,
close running Visual Studio, or restart Windows. A standard-user launch can
require the user to confirm the Windows elevation prompt or installer UI.
The installer is asynchronous; verify its completion with flutter doctor.
.EXAMPLE
./scripts/bootstrap/install-windows-build-tools.ps1 -CheckOnly
.EXAMPLE
./scripts/bootstrap/install-windows-build-tools.ps1
.LINK
https://learn.microsoft.com/en-us/visualstudio/install/use-command-line-parameters-to-install-visual-studio
#>
[CmdletBinding()]
param(
    [string]$InstallPath = 'C:/Program Files/Microsoft Visual Studio/18/Community',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$installerRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer'
$installerPath = Join-Path $installerRoot 'setup.exe'
$vswherePath = Join-Path $installerRoot 'vswhere.exe'
foreach ($executable in @($installerPath, $vswherePath)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Existing Visual Studio installer component is missing: $executable"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $executable
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw "Microsoft Authenticode verification failed: $executable"
    }
}

$requestedPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
$instances = @(& $vswherePath -products '*' -format json -utf8 | ConvertFrom-Json)
$instance = $instances | Where-Object {
    [IO.Path]::GetFullPath($_.installationPath).TrimEnd([IO.Path]::DirectorySeparatorChar) -eq $requestedPath
} | Select-Object -First 1
if (-not $instance -or -not $instance.isComplete -or $instance.productId -notmatch '^Microsoft\.VisualStudio\.Product\.(Community|Professional|Enterprise)$') {
    throw 'The requested path is not an existing complete Visual Studio IDE installation.'
}
if ($requestedPath.Contains('"')) { throw 'Invalid installation path.' }

$requiredComponents = @(
    'Microsoft.VisualStudio.Workload.NativeDesktop',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.CMake.Project',
    'Microsoft.VisualStudio.Component.VC.ATL',
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)
$catalogPath = Join-Path $env:ProgramData "Microsoft/VisualStudio/Packages/_Instances/$($instance.instanceId)/catalog.json"
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
foreach ($component in $requiredComponents) {
    if ($component -notin $catalog.packages.id) { throw "Component not present in the existing official catalog: $component" }
}
$available = @(& $vswherePath -products '*' -requires @requiredComponents -format json -utf8 | ConvertFrom-Json)
if ($available.installationPath -contains $instance.installationPath) {
    [pscustomobject]@{ Status = 'AlreadyInstalled'; InstallPath = $requestedPath }
    return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$installerArguments = @('modify', '--installPath', ('"{0}"' -f $requestedPath), '--channelId', $instance.channelId)
foreach ($component in $requiredComponents) { $installerArguments += @('--add', $component) }
# Explicitly authorized component installation. The official installer enforces
# elevation; this script never invokes RunAs, bypasses UAC or accepts a license.
$installerArguments += @('--passive', '--norestart')

$request = [ordered]@{
    Status = $(if ($CheckOnly) { 'ValidatedOnly' } else { 'ReadyToLaunch' })
    RequestedAtUtc = [DateTime]::UtcNow.ToString('o')
    InstallPath = $requestedPath
    Product = $instance.productId
    Version = $instance.installationVersion
    Installer = $installerPath
    Arguments = $installerArguments
    Administrator = $isAdministrator
    LogPatterns = @((Join-Path $env:TEMP 'dd_installer_*.log'), (Join-Path $env:TEMP 'dd_setup_*.log'))
}
if ($CheckOnly) { [pscustomobject]$request; return }
if (Get-Process -Name setup,vs_installer,vs_installershell -ErrorAction SilentlyContinue) {
    throw 'An installer process is already running; inspect it before starting another modification.'
}
if (Get-Process -Name devenv -ErrorAction SilentlyContinue) {
    throw 'Visual Studio is running. Close it after saving work before modifying components.'
}

$process = Start-Process -FilePath $installerPath -ArgumentList $installerArguments `
    -WorkingDirectory $workspacePath -WindowStyle Hidden -PassThru
$request.Status = 'Started'
$request.ProcessId = $process.Id
if ($process.WaitForExit(2000)) {
    $request.ExitCode = $process.ExitCode
    $request.Status = if ($process.ExitCode -in @(0, 3010)) { 'Exited; verify components' } else { 'Failed' }
}
$logDirectory = Join-Path $workspacePath 'artifacts/setup'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $logDirectory 'windows-build-tools-request.json') -Encoding utf8
[pscustomobject]$request
if ($request.ExitCode -eq 5007) {
    throw 'Visual Studio Installer exit 5007: --passive requires an elevated process. Run this script in a user-approved administrator PowerShell. No UAC bypass was attempted.'
}
if ($request.Status -eq 'Failed') { throw "Visual Studio Installer exited with code $($request.ExitCode). Inspect its dd_installer log." }
