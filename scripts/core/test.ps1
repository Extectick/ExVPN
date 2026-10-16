param([string]$GoPath = '')
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (!$GoPath) { $GoPath = Join-Path $repository '.tools\go\bin\go.exe' }
if (!(Test-Path -LiteralPath $GoPath)) { $GoPath = (Get-Command go -ErrorAction Stop).Source }
Push-Location (Join-Path $repository 'native\core')
try {
    & $GoPath mod verify
    if ($LASTEXITCODE -ne 0) { throw 'Go module verification failed.' }
    & $GoPath test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Native core tests failed.' }
    & $GoPath vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'Native core vet failed.' }
} finally { Pop-Location }
