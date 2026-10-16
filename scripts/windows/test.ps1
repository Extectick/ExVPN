param([string]$GoPath = '')
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$GoPath) { $GoPath = Join-Path $repository '.tools/go/bin/go.exe' }
Push-Location (Join-Path $repository 'native/windows')
try {
    & $GoPath mod verify
    if ($LASTEXITCODE -ne 0) { throw 'Module checksums failed.' }
    & $GoPath test -count=1 ./...
    if ($LASTEXITCODE -ne 0) { throw 'Windows service unit tests failed.' }
    & $GoPath vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'Windows service vet failed.' }
} finally { Pop-Location }
# Tests use mocks for guard/core lifetime, temporary named pipes and loopback
# sockets owned by child test processes (TCP/UDP owner ambiguity regressions).
# They do not install a service or change WFP, routes, DNS, or network adapters.
