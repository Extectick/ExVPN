#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$installRoot = [IO.Path]::GetFullPath((Join-Path $programFiles 'ExVPN Service'))
$expectedRoot = [IO.Path]::GetFullPath($programFiles) + [IO.Path]::DirectorySeparatorChar
if (!$installRoot.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected installation directory.' }
$service = Get-Service -Name ExVPNService -ErrorAction SilentlyContinue
if ($service) {
    Stop-Service -Name ExVPNService -ErrorAction Stop
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
}
# Crash cleanup must prove adapter ownership before removing routes/DNS. Do not
# silently delete an adapter whose name alone is not sufficient evidence.
if (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) { throw 'An ExVPN tunnel adapter remains. Complete controlled network recovery before uninstalling.' }
$executable = Join-Path $installRoot 'exvpn-service.exe'
if (!(Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Recovery executable is missing; restore the matching service package first.' }
& $executable recover-guard
if ($LASTEXITCODE -ne 0) { throw 'Persistent guard recovery failed. Service files retained.' }
if ($service) {
    & (Join-Path $env:SystemRoot 'System32/sc.exe') delete ExVPNService | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Service deletion failed. Files retained.' }
}
foreach ($fileName in @('exvpn-service.exe','wintun.dll','Wintun-LICENSE.txt')) {
    $target = [IO.Path]::GetFullPath((Join-Path $installRoot $fileName))
    if (!$target.StartsWith($installRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected removal target.' }
    if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target }
}
if ((Get-ChildItem -LiteralPath $installRoot -Force | Measure-Object).Count -eq 0) { Remove-Item -LiteralPath $installRoot }
Write-Host 'ExVPN service and its owned guard removed. No unrelated firewall rules were changed.'
