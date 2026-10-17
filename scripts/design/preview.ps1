# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([ValidateRange(1024, 65535)][int]$Port = 8127)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$flutter = Join-Path $repository '.tools/flutter/bin/flutter.bat'
if (!(Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw 'Pinned Flutter SDK missing; see scripts/bootstrap/README.md.'
}
if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
    Write-Host "A preview is already listening at http://127.0.0.1:$Port/?desktop=1&layout=medium"
    Write-Host 'Use its original terminal for r (hot reload) or R (restart).'
    return
}
Write-Host "Design preview: http://127.0.0.1:$Port/?desktop=1&layout=medium"
Write-Host 'Browser only; synthetic data, no VPN, native build, installer or release.'
Write-Host 'After editing: r = hot reload; R = restart; q = stop preview.'
Push-Location (Join-Path $repository 'apps/exvpn')
try {
    & $flutter run -d web-server --target lib/design_preview.dart --web-hostname 127.0.0.1 --web-port $Port --no-pub --no-web-resources-cdn
    if ($LASTEXITCODE -ne 0) { throw 'Design preview stopped with an error.' }
} finally { Pop-Location }
