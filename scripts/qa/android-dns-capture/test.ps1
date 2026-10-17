# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1') -NativeOnly
$go=Join-Path $repository '.tools/go/bin/go.exe'
Push-Location (Join-Path $repository 'native/core')
try {
    # Reuse the ordinary pinned module graph. No new module/lockfile or capture
    # driver is installed; tests consume only in-memory synthetic packets.
    & $go test -mod=readonly -count=1 (Join-Path $PSScriptRoot 'main.go') (Join-Path $PSScriptRoot 'main_test.go')
    if ($LASTEXITCODE -ne 0) { throw 'qa_dns_capture_fixtures_failed' }
    & $go vet -mod=readonly (Join-Path $PSScriptRoot 'main.go') (Join-Path $PSScriptRoot 'main_test.go')
    if ($LASTEXITCODE -ne 0) { throw 'qa_dns_capture_vet_failed' }
} finally { Pop-Location }
