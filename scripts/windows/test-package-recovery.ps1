# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
# Load function definitions only. Never execute package.ps1's elevated entry
# point. SCM, registration and ACL mutations below are explicit in-memory mocks;
# manifests, copies, deletion and Windows file-sharing failures use real files.
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'installer/package.ps1'),[ref]$null,[ref]$errors)
if ($errors.Count) { throw 'Package source did not parse.' }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { Invoke-Expression $definition.Extent.Text }
function Set-ProtectedPackageACL([string]$Path,[switch]$Directory) {}
function Assert-ProtectedPackage([string]$Root) { [void](Get-PackageTree $Root) }
function Assert-OwnedService($State) {
    if ($script:serviceExists) {
        if ($script:serviceBuild -ne $State.build) { throw 'Mock foreign service identity.' }
        [pscustomobject]@{State='Stopped'}
    }
}
function Stop-OwnedService($State) { [void](Assert-OwnedService $State) }
function Delete-OwnedService($State) {
    [void](Assert-OwnedService $State)
    $script:serviceExists=$false; $script:serviceDeleted=$true
    if ($script:survivorFault -eq 'unknown') { Set-Content -LiteralPath (Join-Path $roots.control 'unknown.txt') -Value 'must survive' }
    if ($script:survivorFault -eq 'modified') { Set-Content -LiteralPath (Join-Path $roots.control 'owned.txt') -Value 'changed; must survive' }
}
function Create-OwnedService($State) { $script:serviceExists=$true; $script:serviceBuild=$State.build }
function Register-InstalledPackage($State) { $script:registeredBuild=$State.build }
function Remove-OwnedRegistration {
    if ($scenario -eq 'registration_failure_uninstall') { throw 'Injected registration removal failure after file removal.' }
    $script:registeredBuild=0
}
function Start-Service { throw 'Host SCM access is forbidden in recovery unit tests.' }
function Get-Service { throw 'Host SCM access is forbidden in recovery unit tests.' }
$originalRemoveOwnedTree = ${function:Remove-OwnedTree}
function Remove-OwnedTree([string]$Root,$Records,[string[]]$Ignore=@()) {
    try { & $originalRemoveOwnedTree $Root $Records $Ignore }
    catch {
        if ($Root -eq $roots.ui -and !(Test-Path -LiteralPath (Join-Path $Root 'a.txt'))) { $script:observedPartialRemoval=$true }
        throw
    }
}
$fixtureRoot = Join-Path $repository ('artifacts/windows/recovery-test-' + [Guid]::NewGuid().ToString('N'))
if (!$fixtureRoot.StartsWith($repository + '\artifacts\windows\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped workspace.' }
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$owner='S-1-5-21-100-200-300-1001'
$results=[Collections.Generic.List[object]]::new()
foreach ($scenario in @('locked_previous','unknown_survivor','modified_survivor','failed_new_copy','locked_new','failed_explicit_rollback','successful_upgrade','successful_explicit_rollback','locked_uninstall','unknown_uninstall','modified_uninstall','successful_uninstall','registration_failure_uninstall')) {
    $caseRoot=Join-Path $fixtureRoot $scenario
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $roots=@{ui=(Join-Path $caseRoot 'ui');service=(Join-Path $caseRoot 'service');control=(Join-Path $caseRoot 'control')}
    $statePath=Join-Path $roots.control 'install-state.json'
    $rollbackRoot=Join-Path $caseRoot 'rollback'
    $previousBuild=1; $nextBuild=2
    if ($scenario -in @('failed_explicit_rollback','successful_explicit_rollback')) { $previousBuild=2; $nextBuild=1 }
    $previous=[pscustomobject]@{format=1;version='0.1.0';build=$previousBuild;ownerSid=$owner;networkTesting=$false;rollbackPath=$null;trees=[pscustomobject]@{ui=@();service=@();control=@()}}
    foreach ($tree in @('ui','service','control')) {
        New-Item -ItemType Directory -Path $roots[$tree] | Out-Null
        if ($tree -eq 'ui') {
            Set-Content -LiteralPath (Join-Path $roots[$tree] 'a.txt') -Value 'previous A'
            Set-Content -LiteralPath (Join-Path $roots[$tree] 'b.dll') -Value 'previous locked B'
        } else { Set-Content -LiteralPath (Join-Path $roots[$tree] 'owned.txt') -Value "previous $tree" }
        $previous.trees.$tree=@(Get-TreeManifest $roots[$tree])
    }
    Write-InstalledState $previous
    $source=Join-Path $caseRoot 'replacement'
    New-Item -ItemType Directory -Path $source | Out-Null
    $next=[pscustomobject]@{format=1;version='0.1.0';build=$nextBuild;ownerSid=$owner;networkTesting=$false;rollbackPath=$null;trees=[pscustomobject]@{ui=@();service=@();control=@()}}
    foreach ($tree in @('ui','service','control')) {
        $treeRoot=Join-Path $source $tree
        New-Item -ItemType Directory -Path $treeRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $treeRoot 'replacement.txt') -Value "replacement $tree"
        $next.trees.$tree=@(Get-TreeManifest $treeRoot)
    }
    $script:serviceExists=$true; $script:serviceBuild=$previousBuild; $script:serviceDeleted=$false
    $script:registeredBuild=$previousBuild; $script:observedPartialRemoval=$false
    $script:survivorFault=''
    if ($scenario -in @('unknown_survivor','unknown_uninstall')) { $script:survivorFault='unknown' }
    if ($scenario -in @('modified_survivor','modified_uninstall')) { $script:survivorFault='modified' }
    $script:newLock=$null; $oldLock=$null; $failure=''
    if ($scenario -in @('locked_previous','failed_explicit_rollback','locked_uninstall')) {
        $oldLock=[IO.File]::Open((Join-Path $roots.ui 'b.dll'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    }
    try {
        if ($scenario.EndsWith('_uninstall')) { Invoke-PackageUninstall $previous }
        else { Invoke-PackageReplacement $previous $next {
            param($State)
            Copy-OwnedTree (Join-Path $source 'ui') $roots.ui $State.trees.ui
            if ($scenario -in @('successful_upgrade','successful_explicit_rollback')) {
                foreach ($tree in @('service','control')) { Copy-OwnedTree (Join-Path $source $tree) $roots[$tree] $State.trees.$tree }
                return
            }
            if ($scenario -eq 'locked_new') { $script:newLock=[IO.File]::Open((Join-Path $roots.ui 'replacement.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read) }
            throw 'Injected copy failure after old SCM/files were removed.'
        } -RecordPreviousBackup:($scenario -notin @('failed_explicit_rollback','successful_explicit_rollback')) }
    } catch { $failure=$_.Exception.Message }
    finally { if ($oldLock) { $oldLock.Dispose() }; if ($script:newLock) { $script:newLock.Dispose() } }
    if (!$script:serviceDeleted) { throw "${scenario}: did not exercise removal after SCM deletion." }
    $backups=@(Get-ChildItem -LiteralPath $rollbackRoot -Directory)
    if ($backups.Count -ne 1) { throw "${scenario}: previous backup was not retained." }
    [void](Read-PackageBackup $backups[0].FullName $owner)
    if ($scenario -eq 'successful_uninstall') {
        if ($failure) { throw "${scenario}: uninstall failed: $failure" }
        foreach ($root in $roots.Values) { if (Test-Path -LiteralPath $root) { throw 'Owned installation remains after successful uninstall.' } }
        if ($script:serviceExists -or $script:registeredBuild -ne 0) { throw 'Service/registration remains after successful uninstall.' }
    } elseif ($scenario -in @('successful_upgrade','successful_explicit_rollback')) {
        if ($failure) { throw "${scenario}: replacement failed: $failure" }
        foreach ($tree in @('ui','service','control')) {
            $ignore=@(); if ($tree -eq 'control') { $ignore=@('install-state.json') }
            Assert-TreeManifest $roots[$tree] $next.trees.$tree $ignore
        }
        if (!$script:serviceExists -or $script:serviceBuild -ne $nextBuild -or $script:registeredBuild -ne $nextBuild) { throw "${scenario}: new service/registration missing." }
        $writtenState=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($writtenState.build -ne $nextBuild) { throw 'Wrong installed version persisted.' }
        if ($scenario -eq 'successful_upgrade' -and $writtenState.rollbackPath -ne $backups[0].FullName) { throw 'Upgrade did not record previous backup.' }
    } elseif ($scenario -in @('locked_previous','failed_new_copy','failed_explicit_rollback','locked_uninstall','registration_failure_uninstall')) {
        if ($failure -notmatch 'previous package and service were restored') { throw "${scenario}: truthful restoration result missing: $failure" }
        foreach ($tree in @('ui','service','control')) {
            $ignore=@(); if ($tree -eq 'control') { $ignore=@('install-state.json') }
            Assert-TreeManifest $roots[$tree] $previous.trees.$tree $ignore
        }
        if (!$script:serviceExists -or $script:serviceBuild -ne $previousBuild -or $script:registeredBuild -ne $previousBuild) { throw "${scenario}: previous service/registration not restored." }
        if ($scenario -in @('locked_previous','failed_explicit_rollback','locked_uninstall') -and !$script:observedPartialRemoval) { throw "${scenario}: no partial file deletion was exercised." }
    } else {
        if ($failure -notmatch 'automatic recovery is INCOMPLETE' -or $failure -match 'were restored') { throw "${scenario}: recovery failure was misreported: $failure" }
        if ($scenario -in @('unknown_survivor','unknown_uninstall') -and (Get-Content -LiteralPath (Join-Path $roots.control 'unknown.txt') -Raw).Trim() -ne 'must survive') { throw 'Unknown survivor changed.' }
        if ($scenario -in @('modified_survivor','modified_uninstall') -and (Get-Content -LiteralPath (Join-Path $roots.control 'owned.txt') -Raw).Trim() -ne 'changed; must survive') { throw 'Modified survivor changed.' }
        if ($scenario -eq 'locked_new' -and !(Test-Path -LiteralPath (Join-Path $roots.ui 'replacement.txt'))) { throw 'Locked replacement was removed.' }
    }
    $results.Add([ordered]@{scenario=$scenario;passed=$true;realFileSharing=$true;scmMocked=$true;hostNetworkChanged=$false})
}
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $fixtureRoot 'result.json') -Encoding UTF8
Write-Host "Package recovery tests passed ($($results.Count) scenarios). SCM/ACL mocked; real file sharing/manifests. Evidence: $fixtureRoot"
