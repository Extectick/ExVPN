# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
param([string]$Repository=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'source-driver.ps1')
$script:checks=0
function Check([bool]$Value,[string]$Name){if(!$Value){throw ('driver_fixture_failed_'+$Name)};$script:checks++}
function Reject([scriptblock]$Action,[string]$Name){try{& $Action|Out-Null}catch{Check $true $Name;return};throw ('driver_fixture_did_not_reject_'+$Name)}
function JsonCopy($Value){$Value|ConvertTo-Json -Depth 12|ConvertFrom-Json -AsHashtable}
$fixture=Join-Path $Repository ('artifacts/qa/ota-driver-fixtures-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$policy=Get-ExvpnOtaDriverPolicy
$sdkSource=Join-Path $Repository ('.tools/shorebird-1.6.129/bin/cache/flutter/'+$policy.flutterRevision)
$sdk=Join-Path $fixture 'sdk';New-Item -ItemType Directory -Path $sdk|Out-Null
foreach($relative in $policy.sourcePins.Keys){$path=Join-Path $sdk $relative;New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force|Out-Null;Copy-Item -LiteralPath (Join-Path $sdkSource $relative) -Destination $path}
& git -C $sdk init --quiet
& git -C $sdk -c core.autocrlf=false add -- .
& git -C $sdk -c user.name='OTA fixture' -c user.email='fixture@example.invalid' commit --quiet -m 'Synthetic source driver fixture'
if($LASTEXITCODE -ne 0){throw 'driver_fixture_git_failed'}
$revision=(& git -C $sdk rev-parse HEAD).Trim()
Assert-ExvpnOtaDriverCheckout $sdk $revision
Check $true 'clean_source_checkout_accepted'
Reject {Assert-ExvpnOtaDriverCheckout $sdk ('a'*40)} 'wrong_source_revision_rejected'
$entrypoint=Join-Path $sdk 'packages/flutter_tools/bin/flutter_tools.dart'
$original=[IO.File]::ReadAllBytes($entrypoint)
[IO.File]::WriteAllText($entrypoint,'untrusted source')
Reject {Assert-ExvpnOtaDriverCheckout $sdk $revision} 'modified_tracked_source_rejected'
[IO.File]::WriteAllBytes($entrypoint,$original)
$untracked=Join-Path $sdk 'untracked.dart';[IO.File]::WriteAllText($untracked,'untrusted code')
Reject {Assert-ExvpnOtaDriverCheckout $sdk $revision} 'untracked_source_rejected'
Remove-Item -LiteralPath $untracked
[IO.File]::WriteAllText((Join-Path $sdk '.shorebird_last_used'),'data')
[IO.File]::WriteAllText((Join-Path $sdk '.shorebird_precache'),'data')
Assert-ExvpnOtaDriverCheckout $sdk $revision
Check $true 'only_exact_official_bookkeeping_markers_accepted'
[IO.File]::WriteAllText((Join-Path $sdk '.shorebird_untrusted.dart'),'code')
Reject {Assert-ExvpnOtaDriverCheckout $sdk $revision} 'arbitrary_shorebird_prefix_does_not_hide_code'
Remove-Item -LiteralPath (Join-Path $sdk '.shorebird_untrusted.dart')
$lock=Join-Path $PSScriptRoot 'flutter-tools.lock'
$names=@(Get-ExvpnOtaDriverPackageNames $lock)
Check ($names.Count -eq 102 -and $names -ccontains '_fe_analyzer_shared' -and $names -ccontains 'shorebird_build_trace') 'all_pinned_build_dependencies_present'
$badLock=Join-Path $fixture 'untrusted.lock';[IO.File]::WriteAllText($badLock,'arbitrary dependencies')
Reject {Get-ExvpnOtaDriverPackageNames $badLock} 'changed_dependency_lock_rejected'
$resolver=Join-Path $fixture 'resolver';$cache=Join-Path $fixture 'pub-cache'
New-Item -ItemType Directory -Path (Join-Path $resolver '.dart_tool'),$cache -Force|Out-Null
$configPath=Join-Path $resolver '.dart_tool/package_config.json'
$packages=@()
foreach($name in $names){$path=Join-Path $cache $name;New-Item -ItemType Directory -Path $path|Out-Null;$packages+=@{name=$name;rootUri=[uri]::new($path+[IO.Path]::DirectorySeparatorChar).AbsoluteUri;packageUri='lib/';languageVersion='3.11'}}
$packages+=@{name='flutter_tools';rootUri='../';packageUri='lib/';languageVersion='3.11'}
$config=@{configVersion=2;packages=$packages}
function Write-Config($Value){[IO.File]::WriteAllText($configPath,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
Write-Config $config
$prepared=Set-ExvpnOtaDriverPackageConfig $configPath $resolver $sdk $cache $lock
$actual=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json -AsHashtable
$tool=@($actual.packages|Where-Object name -CEQ 'flutter_tools')
Check ($prepared.packages -eq 103 -and [uri]::new($tool[0].rootUri).LocalPath.TrimEnd('\','/') -ieq (Join-Path $sdk 'packages/flutter_tools')) 'source_root_replaced_only_with_verified_sdk'
Check ((Get-ExvpnOtaSha256 $configPath) -ceq $prepared.sha256) 'generated_package_config_bound_to_hash'
foreach($badRoot in @('https://example.invalid/','file://example.invalid/share/','file:///C:/untrusted/')){
    $bad=JsonCopy $config;$bad.packages[0].rootUri=$badRoot;Write-Config $bad
    Reject {Set-ExvpnOtaDriverPackageConfig $configPath $resolver $sdk $cache $lock} 'external_or_nonfile_package_roots_rejected'
}
$bad=JsonCopy $config;$bad.packages[0].name='not-in-reviewed-lock';Write-Config $bad
Reject {Set-ExvpnOtaDriverPackageConfig $configPath $resolver $sdk $cache $lock} 'unreviewed_package_rejected'
$bad=JsonCopy $config;$bad.packages[0].name=$bad.packages[1].name;Write-Config $bad
Reject {Set-ExvpnOtaDriverPackageConfig $configPath $resolver $sdk $cache $lock} 'duplicate_package_rejected'
$bad=JsonCopy $config;$bad.packages=@($bad.packages[0..100]);Write-Config $bad
Reject {Set-ExvpnOtaDriverPackageConfig $configPath $resolver $sdk $cache $lock} 'missing_package_rejected'
Write-Config $config
$driver=@{kind='verified-sdk-source';sdkCommit=$policy.flutterRevision;entrypoint=$entrypoint;entrypointSha256=$policy.sourcePins['packages/flutter_tools/bin/flutter_tools.dart'];packageConfig=$configPath;packageConfigSha256=('a'*64)}
$sourceRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$builder=[IO.File]::ReadAllText((Join-Path $sourceRoot 'scripts/ota/build-ui-patch.ps1'))
Check ($builder.Contains("('--packages='+`$driver.packageConfig),`$driver.entrypoint") -and !$builder.Contains("`$flutter = Assert-OtaPinnedTool")) 'aot_builder_executes_verified_source_instead_of_host_jit'
Check ($builder.Contains('Assert-ExvpnOtaDriverCheckout') -and $builder.Contains('Assert-ExvpnOtaSourceDriver')) 'driver_checked_before_and_after_compilation'
foreach($name in @('dart','frontend','dartAotRuntime','platformDill')){Check ($builder.Contains("Assert-OtaPinnedTool `$sdk `$receipt.tools.$name ")) 'actual_aot_compilers_keep_exact_raw_pins'}
Check ($builder.Contains("Assert-OtaPinnedTool `$root `$receipt.tools.patch ") -and $builder.Contains('Assert-OtaPinnedTool $sdk $receipt.tools.genSnapshot')) 'snapshot_and_diff_tools_keep_exact_raw_pins'
$helper=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'source-driver.ps1'))
Check ($helper.Contains("@('pub','get','--enforce-lockfile')") -and $helper.Contains("if(!`$OnlineDependencies){`$arguments+='--offline'}") -and $helper -notmatch 'pub.*upgrade|--upgrade') 'dependency_resolution_locked_and_offline_by_default'
foreach($path in @('build-ui-patch.ps1','source-driver.ps1','prepare-driver.ps1')){$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$tokens,[ref]$errors);Check (@($errors).Count -eq 0) 'driver_tool_syntax'}
$tokens=$null;$errors=$null;$baseAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build-base.ps1'),[ref]$tokens,[ref]$errors)
$selection=@($baseAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$selected'},$true))
Check ($selection.Count -eq 1) 'base_category_selector_found'
$protectedInputs=@(@{path='native/core/core.go';sha256=('a'*64)},@{path='apps/exvpn/assets/icon.svg';sha256=('b'*64)},@{path='apps/exvpn/pubspec.lock';sha256=('c'*64)})
foreach($category in @('native','assets','plugins','dependencies')){
    . ([scriptblock]::Create($selection[0].Extent.Text))
    Check ($selected.Count -eq 1) 'base_fingerprint_categories_keep_input_record_inside_switch'
}
[ordered]@{schemaVersion=1;checks=$script:checks;passed=$true;scope='source checkout, locked driver package roots, compiler command guards and receipt category fixtures; no SDK mutation, native build or cloud calls'}|ConvertTo-Json -Compress
