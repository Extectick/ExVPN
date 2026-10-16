$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wintun.lock.json') -Raw | ConvertFrom-Json
$cache = Join-Path $repository '.cache/wintun'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$archive = Join-Path $cache ('wintun-' + $pin.version + '.zip')
if (!(Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $pin.url -OutFile $archive -TimeoutSec 60 }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.sha256) { throw 'Wintun archive checksum mismatch.' }
$unpacked = Join-Path $cache $pin.version
Expand-Archive -LiteralPath $archive -DestinationPath $unpacked -Force
$dll = Join-Path $unpacked $pin.archiveDll
if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.dllSha256) { throw 'Wintun DLL checksum mismatch.' }
$signature = Get-AuthenticodeSignature -LiteralPath $dll
if ($signature.Status -ne 'Valid') { throw 'Wintun Authenticode validation failed.' }
$output = Join-Path $repository 'artifacts/windows'
New-Item -ItemType Directory -Force -Path $output | Out-Null
Copy-Item -LiteralPath $dll -Destination (Join-Path $output 'wintun.dll')
Copy-Item -LiteralPath (Join-Path $unpacked $pin.archiveLicense) -Destination (Join-Path $output 'Wintun-LICENSE.txt')
Write-Host 'Pinned Wintun DLL checksum and Authenticode verified; driver has not been installed.'
