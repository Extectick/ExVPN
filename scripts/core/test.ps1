param([string]$GoPath = '')
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1') -NativeOnly
if (!$GoPath) { $GoPath = Join-Path $repository '.tools\go\bin\go.exe' }
if (!(Test-Path -LiteralPath $GoPath)) { $GoPath = (Get-Command go -ErrorAction Stop).Source }
Push-Location (Join-Path $repository 'native\core')
try {
    & $GoPath mod verify
    if ($LASTEXITCODE -ne 0) { throw 'Go module verification failed.' }
    & $GoPath test -mod=readonly ./...
    if ($LASTEXITCODE -ne 0) { throw 'Native core tests failed.' }
    & $GoPath vet -mod=readonly ./...
    if ($LASTEXITCODE -ne 0) { throw 'Native core vet failed.' }
} finally { Pop-Location }
