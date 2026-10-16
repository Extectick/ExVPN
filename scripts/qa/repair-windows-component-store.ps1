#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory)

# Separate explicit owner authorization is required. This repairs Windows' own
# component store using DISM/Windows Update; it does not accept unofficial ISOs,
# remove packages, change update policies, or reboot the computer.
$ErrorActionPreference = 'Stop'
$directory = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$resultPath = Join-Path $directory 'repair-result.json'
try {
    @{ status = 'repairing'; noRestart = $true } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    & "$env:SystemRoot\System32\dism.exe" /Online /Cleanup-Image /RestoreHealth /NoRestart "/LogPath:$directory\repair-dism.log" 2>&1 |
        Out-File -LiteralPath (Join-Path $directory 'repair-output.txt') -Encoding UTF8
    $code = $LASTEXITCODE
    @{ status = $(if ($code -eq 0 -or $code -eq 3010) { 'complete' } else { 'failed' }); exitCode = $code; restartNeeded = ($code -eq 3010); noRestart = $true } |
        ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    exit $code
} catch {
    @{ status = 'failed'; errorType = $_.Exception.GetType().FullName; hresult = $_.Exception.HResult; noRestart = $true } |
        ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    exit 1
}
