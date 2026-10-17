# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../windows/installer/package-common.ps1')
$parseErrors = $null
$source = Join-Path $PSScriptRoot 'update-installed-ui.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Function definitions only; never run the elevated entrypoint, locks or SCM.
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $definition.Extent.Text
}
function Set-ProtectedPackageACL([string]$Path, [switch]$Directory) {}
function Assert-ProtectedPackage([string]$Root) { [void](Get-PackageTree $Root) }
function Get-CimInstance { throw 'System access is forbidden in file-only checks.' }
function Enter-MachineMaintenanceLock { throw 'System mutexes are forbidden in file-only checks.' }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $repository ('artifacts/qa/design-ui-swap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$passed = 0
foreach ($scenario in @('success', 'before_promote', 'before_state', 'after_state', 'completed', 'modified_old', 'unknown_old', 'stale_state')) {
    $case = Join-Path $fixture $scenario
    New-Item -ItemType Directory -Path $case | Out-Null
    $installed = Join-Path $case 'ui'; $replacement = Join-Path $case 'next'; $retained = Join-Path $case 'backup'
    foreach ($directory in @($installed, $replacement)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    Set-Content -LiteralPath (Join-Path $installed 'exvpn.exe') -Value 'previous UI'
    Set-Content -LiteralPath (Join-Path $replacement 'exvpn.exe') -Value 'next UI'
    $oldRecords = @(Get-TreeManifest $installed); $newRecords = @(Get-TreeManifest $replacement)
    $statePath = Join-Path $case 'install-state.json'
    $previousState = Join-Path $case 'previous-state.json'; $nextState = Join-Path $case 'next-state.json'
    [IO.File]::WriteAllText($previousState, '{"build":18,"revision":"previous"}')
    [IO.File]::WriteAllText($nextState, '{"build":18,"revision":"next"}')
    [IO.File]::Copy($previousState, $statePath)
    $journal = [pscustomobject]@{ phase = 'prepared' }
    $journalPath = Join-Path $case 'journal.json'
    Write-DesignJournal $journalPath $journal 'prepared'
    if ($scenario -eq 'modified_old') { Set-Content -LiteralPath (Join-Path $installed 'exvpn.exe') -Value 'unknown modification' }
    if ($scenario -eq 'unknown_old') { Set-Content -LiteralPath (Join-Path $installed 'unknown.txt') -Value 'preserve' }
    if ($scenario -eq 'stale_state') { Set-Content -LiteralPath $statePath -Value 'preserve changed state' }
    $beforeUi = Get-DesignManifestHash @(Get-TreeManifest $installed)
    $beforeState = Get-DesignHash $statePath
    $script:injected = $false
    $recordPhase = {
        param($phase)
        if (!$script:injected -and $phase -eq $scenario) { $script:injected = $true; throw 'Injected file transaction failure.' }
        Write-DesignJournal $journalPath $journal $phase
    }
    $failed = $false; $failureText = ''
    try { Invoke-DesignUiSwap $installed $replacement $retained $statePath $previousState $nextState $oldRecords $newRecords $recordPhase {} }
    catch { $failed = $true; $failureText = $_.Exception.Message }
    if ($scenario -eq 'success') {
        if ($failed -or (Get-DesignHash $statePath) -cne (Get-DesignHash $nextState)) { throw "Successful transaction did not commit: $failureText" }
        Assert-TreeManifest $installed $newRecords; Assert-TreeManifest $retained $oldRecords
        # Explicit rollback uses the same transaction primitive, with old/new reversed.
        Invoke-DesignUiSwap $installed $retained (Join-Path $case 'reverted') $statePath $nextState $previousState $newRecords $oldRecords {} {}
        Assert-TreeManifest $installed $oldRecords
        if ((Get-DesignHash $statePath) -cne (Get-DesignHash $previousState)) { throw 'Explicit rollback did not restore exact state bytes.' }
    } else {
        if (!$failed) { throw "Failure was not rejected: $scenario" }
        if ((Get-DesignManifestHash @(Get-TreeManifest $installed)) -cne $beforeUi -or
            (Get-DesignHash $statePath) -cne $beforeState) { throw "Previous UI/state was changed: $scenario" }
    }
    $passed++
}
[ordered]@{ passed = $passed; systemMutation = $false; checks = @('commit and explicit rollback', 'four injected transaction failures', 'modified/unknown files', 'stale state'); aclAndService = 'not exercised; file-only checks' } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $fixture 'report.json') -Encoding UTF8
Write-Host "$passed file-only design UI checks passed. No installed files, ACLs, mutexes, service, network or storage were changed."
