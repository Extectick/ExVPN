param([string]$GoPath = '')
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1') -NativeOnly
. (Join-Path $repository 'scripts/build/native-cache-lib.ps1')
if (!$GoPath) { $GoPath = Join-Path $repository '.tools/go/bin/go.exe' }
$output = Join-Path $repository 'artifacts/windows'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$savedOS = $env:GOOS
$savedArch = $env:GOARCH
$savedCgo = $env:CGO_ENABLED
Push-Location (Join-Path $repository 'native/windows')
try {
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:CGO_ENABLED = '0'
    $goVersion = (& $GoPath version) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $goVersion -cne 'go version go1.27.2 windows/amd64') { throw 'Windows service requires pinned Go 1.27.2.' }
    $parameters = [ordered]@{go=$goVersion;flags='-mod=readonly -trimpath -buildvcs=false';package='./cmd/exvpn-service';goos='windows';goarch='amd64';cgo='0'}
    foreach ($name in @('GOFLAGS','GOEXPERIMENT','GOAMD64','GOFIPS140','GODEBUG')) { $parameters[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    $effective = (& $GoPath env -json GOFLAGS GOEXPERIMENT GOAMD64 GOFIPS140 GODEBUG GOWORK GOROOT GOTOOLDIR) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Windows service effective build environment unavailable.' }
    $parameters.effectiveEnvironment = $effective
    $tools = @(Get-NativeCacheGoTools $GoPath)
    $identity = $null
    try {
        $effectiveValues = $effective | ConvertFrom-Json
        $expectedRoot = Split-Path (Split-Path ([IO.Path]::GetFullPath($GoPath)))
        if ($effectiveValues.GOFLAGS -or $effectiveValues.GOWORK -cne 'off' -or
            [IO.Path]::GetFullPath($effectiveValues.GOROOT) -ine $expectedRoot -or
            [IO.Path]::GetFullPath($effectiveValues.GOTOOLDIR) -ine (Join-Path $expectedRoot 'pkg/tool/windows_amd64')) { throw 'native_cache_external_build_override' }
        $identity = Get-NativeCacheIdentity -Repository $repository -Target 'windows-amd64' -Parameters $parameters -Tools $tools
    }
    catch { Write-Warning 'Native cache identity unavailable; compiling Windows service.' }
    $cache = Join-Path $repository '.tools/cache/native-outputs-v1'
    $reused = Restore-NativeCachedOutputs -CacheRoot $cache -Identity $identity -OutputDirectory $output -Names @('exvpn-service.exe')
    if ($reused) {
        try {
            $after = Get-NativeCacheIdentity -Repository $repository -Target 'windows-amd64' -Parameters $parameters -Tools $tools
            if ($after.key -cne $identity.key) { throw 'native_cache_inputs_changed' }
        } catch { $reused = $false; $identity = $null; Write-Warning 'Native inputs changed during cache restore; compiling Windows service.' }
    }
    if (!$reused) {
        & $GoPath build -mod=readonly -trimpath -buildvcs=false -o (Join-Path $output 'exvpn-service.exe') ./cmd/exvpn-service
        if ($LASTEXITCODE -ne 0) { throw 'Windows service build failed.' }
        if ($identity) {
            try {
                $after = Get-NativeCacheIdentity -Repository $repository -Target 'windows-amd64' -Parameters $parameters -Tools $tools
                if ($after.key -ceq $identity.key) { Save-NativeCachedOutputs -CacheRoot $cache -Identity $identity -OutputDirectory $output -Names @('exvpn-service.exe') }
            } catch { Write-Warning 'Native inputs changed or cache unavailable; output was not cached.' }
        }
    }
    Write-Host $(if ($reused) { 'Reused exact source-bound Windows service output.' } else { 'Compiled Windows service output.' })
} finally {
    $env:GOOS = $savedOS
    $env:GOARCH = $savedArch
    $env:CGO_ENABLED = $savedCgo
    Pop-Location
}
Write-Host 'Built artifacts/windows/exvpn-service.exe. Not installed, signed, or system-tested.'
