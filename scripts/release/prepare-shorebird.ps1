# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Explicit SDK preparation only; never logs in, initializes an app, or publishes.
[CmdletBinding()]
param([ValidateSet('Android','Windows')][string]$Target='Windows')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
$policy=Get-ShorebirdPolicy
$pin=Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/shorebird.lock.json') -Raw | ConvertFrom-Json
if ($pin.cli.revision -cne $policy.cliRevision -or $pin.flutter.revision -cne $policy.flutterRevision) { throw 'shorebird_pin_mismatch' }
$root=Join-Path $repository ".tools/$($pin.cli.folder)"
$privateRun=New-ShorebirdPrivateDirectory $repository 'prepare'
$saved=@{}
foreach ($name in @('PUB_CACHE','FLUTTER_STORAGE_BASE_URL','CI','FLUTTER_SUPPRESS_ANALYTICS','DART_SUPPRESS_ANALYTICS')) {
    $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    if (!(Test-Path -LiteralPath $root)) {
        Assert-AuditNoLinks ([IO.Path]::GetDirectoryName($root))
        $null=Invoke-ShorebirdGit $repository @('init','--quiet',$root)
        $null=Invoke-ShorebirdGit $root @('config','core.autocrlf','false')
        $null=Invoke-ShorebirdGit $root @('config','core.longpaths','true')
        $null=Invoke-ShorebirdGit $root @('remote','add','origin','https://github.com/shorebirdtech/shorebird.git')
        $null=Invoke-ShorebirdGit $root @('fetch','--depth','1','--no-tags','origin',$policy.cliRevision)
        $null=Invoke-ShorebirdGit $root @('checkout','--detach','FETCH_HEAD')
    }
    Assert-ReleaseRuntimeCheckout $root $policy.cliRevision
    foreach ($entry in @(@('bin/shorebird.ps1',$pin.cli.powershellEntrypointSha256),@('pubspec.lock',$pin.cli.pubspecLockSha256))) {
        if ((Get-AuditSha256 (Join-Path $root $entry[0])) -cne $entry[1]) { throw 'shorebird_cli_pin_mismatch' }
    }
    # The official bootstrap may prepare its pinned dependencies/Flutter cache.
    # This is intentionally separate from guarded release/patch commands.
    $env:PUB_CACHE=Join-Path $repository '.tools/cache/shorebird-pub'
    $env:FLUTTER_STORAGE_BASE_URL='https://download.shorebird.dev'
    $env:CI='true';$env:FLUTTER_SUPPRESS_ANALYTICS='true';$env:DART_SUPPRESS_ANALYTICS='true'
    $entrypoint=Join-Path $root 'bin/shorebird.ps1'
    Initialize-ShorebirdCliCache $entrypoint $privateRun
    $null=Get-ShorebirdCli $repository
    $version=Invoke-ShorebirdJson $entrypoint @('--version') 'version' $privateRun 'version'
    if ($version.shorebird_version -cne $policy.cliVersion -or $version.flutter_revision -cne $policy.flutterRevision -or
        $version.engine_revision -cne $policy.engineRevision) { throw 'shorebird_bootstrap_version_mismatch' }
    $null=Get-ShorebirdCli $repository
    & $entrypoint flutter precache $(if ($Target -ceq 'Android') { '--android' } else { '--windows' }) *> (Join-Path $privateRun 'precache.log')
    if ($LASTEXITCODE -ne 0) { throw 'shorebird_precache_failed' }
    $runtime=Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release
} catch {
    ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $privateRun 'failure.log') -Encoding utf8NoBOM
    throw 'shorebird_prepare_failed; private diagnostics retained'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
}
[pscustomobject]@{Prepared=$true;Target=$Target;CliVersion=$policy.cliVersion;FlutterRevision=$runtime.Identity.flutterRevision}
