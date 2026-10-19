# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shorebird-runtime-notices.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $repository ('artifacts/qa/shorebird-runtime-notices-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$script:checks = 0
function Check([bool]$Passed, [string]$Label) {
    if (!$Passed) { throw "shorebird_runtime_notices_test_$Label" }
    $script:checks++
}
function Reject([scriptblock]$Body, [string]$Code) {
    $failed = $false
    try { & $Body | Out-Null } catch {
        $failed = $true
        if ($_.Exception.Message -cne $Code) { throw "Expected $Code; received $($_.Exception.Message)" }
    }
    Check $failed $Code
}
function Clone($Value) { $Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable }
$runtime = @{Identity=@{kind='shorebird';target='Android';buildMode='release';
    flutterRevision='5bef02a16146a0effc07da4acccaafe90a2739ce';engineRevision='4b936a0c03e13389ddfb1ac48823f187964975c2'}}
$ordinary = @{Identity=@{kind='ordinary'}}
Check ($null -eq (Get-ShorebirdRuntimeNotices 'Z:/does-not-exist' $ordinary)) 'ordinary_no_inputs_read'
$expected = Get-ShorebirdRuntimeNotices $repository $runtime
Check ($expected.Files.Count -eq 200) 'complete_pinned_file_set'
Check (!$expected.Evidence.exactLinkedMembership -and !$expected.Evidence.stableReleaseReady) 'no_link_or_stable_claim'
$pin = Get-Content -LiteralPath (Join-Path $repository 'scripts/release/shorebird-runtime-notices.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$sourceInventory = Get-Content -LiteralPath (Join-Path $repository ($pin.directory+'/inventory.json')) -Raw | ConvertFrom-Json -AsHashtable
Check ($sourceInventory.sourceCrates.Count -eq 282) 'source_superset_count'
Check ($sourceInventory.updaterProductionAndBuildSourceClosure.Count -eq 200) 'source_production_build_roots'
$comde = @($sourceInventory.sourceCrates | Where-Object name -CEQ 'comde')
Check ($comde.Count -eq 1 -and $comde[0].declaredLicense -ceq 'Apache-2.0 OR MIT' -and
    $comde[0].selection -ceq 'declared-Apache-2.0-branch-standard-text-with-complete-published-source' -and
    $comde[0].notices.Count -eq 1 -and $comde[0].sources.Count -eq 1) 'comde_declared_branch_complete_source'
Check (@($sourceInventory.sourceCrates | Where-Object { !$_.notices.Count }).Count -eq 3) 'unrelated_source_only_exclusions_explicit'
foreach ($name in $sourceInventory.updaterProductionAndBuildSourceClosure) {
    Check (@($sourceInventory.sourceCrates | Where-Object { ($_.name+'@'+$_.version) -ceq $name -and $_.notices.Count }).Count -eq 1) 'rooted_source_has_notices'
}
$component = Copy-ShorebirdRuntimeNotices $expected $fixture
$manifest = @{components=@($component);shorebirdRuntimeSupplement=$expected.Evidence}
Assert-ShorebirdRuntimeNotices $manifest $expected $fixture
$script:checks++
Assert-ShorebirdRuntimeNotices @{components=@()} $null $fixture
$script:checks++
Reject { Assert-ShorebirdRuntimeNotices $manifest $null $fixture } 'shorebird_runtime_notices_unexpected'
$badRuntime = Clone $runtime; $badRuntime.Identity.engineRevision = '0000000000000000000000000000000000000000'
Reject { Get-ShorebirdRuntimeNotices $repository $badRuntime } 'shorebird_runtime_notices_selection_mismatch'
$badRuntime = Clone $runtime; $badRuntime.Identity.buildMode = 'debug'
Reject { Get-ShorebirdRuntimeNotices $repository $badRuntime } 'shorebird_runtime_notices_selection_invalid'
$badRuntime = Clone $runtime; $badRuntime.Identity.kind = 'future'
Reject { Get-ShorebirdRuntimeNotices $repository $badRuntime } 'shorebird_runtime_notices_selection_invalid'
$windows = Clone $runtime; $windows.Identity.target = 'Windows'
Check ((Get-ShorebirdRuntimeNotices $repository $windows).Files.Count -eq 200) 'same_pinned_windows_notices'
$bad = Clone $manifest; $bad.shorebirdRuntimeSupplement.exactLinkedMembership = $true
Reject { Assert-ShorebirdRuntimeNotices $bad $expected $fixture } 'shorebird_runtime_notices_binding_mismatch'
$bad = Clone $manifest; $bad.components[0].notices = @($bad.components[0].notices | Select-Object -Skip 1)
Reject { Assert-ShorebirdRuntimeNotices $bad $expected $fixture } 'shorebird_runtime_notices_binding_mismatch'
$extra = Join-Path $fixture 'shorebird-runtime/extra.txt'
[IO.File]::WriteAllText($extra, 'unexpected')
Reject { Assert-ShorebirdRuntimeNotices $manifest $expected $fixture } 'shorebird_runtime_notices_file_set_mismatch'
Remove-Item -LiteralPath $extra
$copiedText = Join-Path $fixture ('shorebird-runtime/'+$expected.Files[0].path)
$original = [IO.File]::ReadAllBytes($copiedText)
[IO.File]::WriteAllText($copiedText, 'tampered')
Reject { Assert-ShorebirdRuntimeNotices $manifest $expected $fixture } 'shorebird_runtime_notices_copy_mismatch'
[IO.File]::WriteAllBytes($copiedText, $original)
Assert-ShorebirdRuntimeNotices $manifest $expected $fixture
$script:checks++
Reject { Copy-ShorebirdRuntimeNotices $expected $fixture } 'shorebird_runtime_notices_destination_exists'
Write-Host "Shorebird runtime notices: $script:checks focused checks passed."
