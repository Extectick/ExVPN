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
$phase='source_identity';$privateRun=$null;$prepareReceipt='';$sourceCommit=''
$saved=@{}
foreach ($name in @('PUB_CACHE','FLUTTER_STORAGE_BASE_URL','CI','FLUTTER_SUPPRESS_ANALYTICS','DART_SUPPRESS_ANALYTICS')) {
    $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    $sourceCommit=Invoke-ShorebirdGit $repository @('rev-parse','--verify','HEAD')
    if ($sourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'shorebird_prepare_source_invalid' }
    $prepareReceipt=Write-ShorebirdPrepareReceipt -Repository $repository -Target $Target -SourceCommit $sourceCommit -Status started -Phase $phase
    $phase='private_directory'
    $privateRun=New-ShorebirdPrivateDirectory $repository 'prepare'
    $phase='cli_pin'
    $pin=Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/shorebird.lock.json') -Raw | ConvertFrom-Json
    if ($pin.cli.version -cne $policy.cliVersion -or $pin.cli.revision -cne $policy.cliRevision -or
        $pin.cli.folder -cne "shorebird-$($policy.cliVersion)" -or $pin.flutter.revision -cne $policy.flutterRevision -or
        $pin.flutter.engineRevision -cne $policy.engineRevision) { throw 'shorebird_pin_mismatch' }
    $root=Join-Path $repository ".tools/$($pin.cli.folder)"
    $phase='cli_checkout'
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
    $phase='cli_pin'
    foreach ($entry in @(@('bin/shorebird.ps1',$pin.cli.powershellEntrypointSha256),@('pubspec.lock',$pin.cli.pubspecLockSha256))) {
        if ((Get-AuditSha256 (Join-Path $root $entry[0])) -cne $entry[1]) { throw 'shorebird_cli_pin_mismatch' }
    }
    # The official bootstrap may prepare its pinned dependencies/Flutter cache.
    # This is intentionally separate from guarded release/patch commands.
    $env:PUB_CACHE=Join-Path $repository '.tools/cache/shorebird-pub'
    $env:FLUTTER_STORAGE_BASE_URL='https://download.shorebird.dev'
    $env:CI='true';$env:FLUTTER_SUPPRESS_ANALYTICS='true';$env:DART_SUPPRESS_ANALYTICS='true'
    $entrypoint=Join-Path $root 'bin/shorebird.ps1'
    $phase='cli_bootstrap'
    Initialize-ShorebirdCliCache $entrypoint $privateRun
    $phase='cli_cache'
    $null=Get-ShorebirdCli $repository
    $phase='cli_version'
    $version=Invoke-ShorebirdJson $entrypoint @('--version') 'version' $privateRun 'version'
    if ($version.shorebird_version -cne $policy.cliVersion -or $version.flutter_revision -cne $policy.flutterRevision -or
        $version.engine_revision -cne $policy.engineRevision) { throw 'shorebird_bootstrap_version_mismatch' }
    $null=Get-ShorebirdCli $repository
    $phase='flutter_precache'
    Invoke-ShorebirdFlutterPrecache $repository $Target $privateRun
    $phase='runtime_validation'
    $runtime=Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release
    $phase='complete'
    $null=Write-ShorebirdPrepareReceipt -Repository $repository -Target $Target -SourceCommit $sourceCommit -Status ready -Phase $phase -Path $prepareReceipt
} catch {
    $errorCode=Get-ShorebirdPrepareErrorCode $_.Exception.Message
    if ($privateRun) { ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $privateRun 'failure.log') -Encoding utf8NoBOM }
    try { $null=Write-ShorebirdPrepareReceipt -Repository $repository -Target $Target -SourceCommit $sourceCommit -Status failed -Phase $phase -ErrorCode $errorCode -Path $prepareReceipt } catch { }
    # All public fields are fixed enums. Raw exceptions and bootstrap logs stay
    # private; a runner can still preserve this diagnosis after it is removed.
    throw "shorebird_prepare_failed; phase=$phase; errorCode=$errorCode; private diagnostics retained"
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
}
[pscustomobject]@{Prepared=$true;Target=$Target;CliVersion=$policy.cliVersion;FlutterRevision=$runtime.Identity.flutterRevision}
