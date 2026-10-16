#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Flutter)

$ErrorActionPreference = 'Stop'
# A clean Flutter SDK compiles flutter_tool and runs pub before the requested
# command. That bootstrap writes progress to stdout, including with --machine.
# Initialize separately; do not strip arbitrary text from the identity response.
& $Flutter --version | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Flutter tool initialization failed with exit code $LASTEXITCODE." }

$machineOutput = @(& $Flutter --version --machine)
if ($LASTEXITCODE -ne 0) { throw "Flutter SDK identity failed with exit code $LASTEXITCODE." }
($machineOutput -join "`n") | ConvertFrom-Json
