#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultPath)

# Run only after the workstation owner authorizes this optional feature change.
# Reboot is deliberately not part of this operation.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Write-Result($Value) {
    $Value | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}
try {
    $before = Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM
    Write-Result @{ status = 'enabling'; previousState = $before.State.ToString(); noRestart = $true }
    $result = Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart
    $after = Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM
    Write-Result @{ status = 'complete'; featureState = $after.State.ToString(); restartNeeded = [bool]$result.RestartNeeded; noRestart = $true }
    exit 0
} catch {
    Write-Result @{ status = 'failed'; errorType = $_.Exception.GetType().FullName; hresult = $_.Exception.HResult; noRestart = $true }
    exit 1
}
