param([string]$GoPath = '')
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1') -NativeOnly
if (!$GoPath) { $GoPath = Join-Path $repository '.tools\go\bin\go.exe' }
if (!(Test-Path -LiteralPath $GoPath)) { $GoPath = (Get-Command go -ErrorAction Stop).Source }
$output = Join-Path $repository 'artifacts\core'
New-Item -ItemType Directory -Force $output | Out-Null
Push-Location (Join-Path $repository 'native\core')
try {
    & $GoPath build -mod=readonly -trimpath -o (Join-Path $output 'exvpn-core.exe') ./cmd/exvpn-core
    if ($LASTEXITCODE -ne 0) { throw 'Native core build failed.' }
} finally { Pop-Location }
