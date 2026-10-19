# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'shorebird-patch-inputs.ps1')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixtureRoot=Join-Path $repository ('artifacts/qa/shorebird-patch-inputs-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:checks=0
function Check([bool]$Value,[string]$Name){if(!$Value){throw "patch_inputs_test_failed:$Name"};$script:checks++}
function Refuses([scriptblock]$Action,[string]$Name){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Check $caught $Name}
function Bytes([string]$Text){return ,([Text.UTF8Encoding]::new($false).GetBytes($Text))}
function Save-Receipt($Fixture){$Fixture.receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Fixture.receiptPath -Encoding utf8NoBOM}
function New-Fixture([string]$Target,[bool]$AutoCrlf=$true,[bool]$CrlfCheckout=$false,[string]$BaseEol="`n"){
    $root=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $repo=Join-Path $root 'source';$base=Join-Path $root 'base';$private=Join-Path $root 'private'
    foreach($dir in @($repo,$base,$private)){[void][IO.Directory]::CreateDirectory($dir)}
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($owner);$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    Set-Acl -LiteralPath $private -AclObject $acl
    $null=Invoke-ShorebirdPatchInputGit $repo @('init','-q')
    $null=Invoke-ShorebirdPatchInputGit $repo @('config','core.autocrlf',$(if($AutoCrlf){'true'}else{'false'}))
    $texts=[ordered]@{'assets/flags/countries.txt'="synthetic-country-list`nNL`nDE`n";'assets/licenses/FlagIcons.txt'="Synthetic asset license`nCopyright fixture`n"}
    foreach($name in $texts.Keys){$path=Join-Path $repo ('apps/exvpn/'+$name);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllBytes($path,(Bytes $texts[$name]))}
    $pinRelative='scripts/bootstrap/shorebird.lock.json';$pinPath=Join-Path $repo $pinRelative
    $pinText="{`n  `"schemaVersion`": 1,`n  `"fixture`": `"exact synthetic dependency pin`"`n}`n"
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pinPath));[IO.File]::WriteAllBytes($pinPath,(Bytes $pinText))
    $null=Invoke-ShorebirdPatchInputGit $repo @('add','--','apps/exvpn/assets',$pinRelative)
    $null=Invoke-ShorebirdPatchInputGit $repo @('-c','user.name=ExVPN fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','commit','-qm','synthetic base')
    $commit=Invoke-ShorebirdPatchInputGit $repo @('rev-parse','HEAD')
    if($CrlfCheckout){$null=Invoke-ShorebirdPatchInputGit $repo @('checkout-index','-f','-u','--','apps/exvpn/assets/flags/countries.txt','apps/exvpn/assets/licenses/FlagIcons.txt',$pinRelative)}
    $files=@()
    if($Target -ceq 'Windows'){
        foreach($name in $texts.Keys){$relative='ui/data/flutter_assets/'+$name;$path=Join-Path $base $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllBytes($path,(Bytes ($texts[$name].Replace("`n",$BaseEol))));$files+=@{path=$relative;sha256=(Get-AuditSha256 $path)}}
    }else{
        $relative='ExVPN-0.1.8-29-android.aab';$path=Join-Path $base $relative;$zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
        try{foreach($name in $texts.Keys){$entry=$zip.CreateEntry('base/assets/flutter_assets/'+$name);$stream=$entry.Open();try{$bytes=Bytes ($texts[$name].Replace("`n",$BaseEol));$stream.Write($bytes)}finally{$stream.Dispose()}}}finally{$zip.Dispose()}
        $files+=@{path=$relative;sha256=(Get-AuditSha256 $path)}
    }
    $receipt=[ordered]@{version='0.1.8+29';target=$Target;sourceCommit=$commit;files=$files;runtime=@{identity=@{pin=@{path=$pinRelative;sha256=(Get-ShorebirdPatchInputHash (Bytes $pinText))}}}}
    $f=@{repo=$repo;base=$base;private=$private;commit=$commit;receipt=$receipt;receiptPath=(Join-Path $base 'build.json');texts=$texts;target=$Target;pinPath=$pinPath;pinRelative=$pinRelative;pinText=$pinText}
    Save-Receipt $f
    Assert-ShorebirdPatchInputSource $repo $commit
    $f
}
function Enter-Fixture($Fixture){Enter-ShorebirdPatchTextAssetsLease -Repository $Fixture.repo -Target $Fixture.target -BaseReceiptPath $Fixture.receiptPath -BaseReceipt $Fixture.receipt -SourceCommit $Fixture.commit -PrivateDirectory $Fixture.private}
function Fingerprints($Fixture){$r=[ordered]@{};foreach($name in $Fixture.texts.Keys){$path='apps/exvpn/'+$name;$r[$name]=@{hash=(Get-AuditSha256 (Join-Path $Fixture.repo $path));mtime=[IO.File]::GetLastWriteTimeUtc((Join-Path $Fixture.repo $path));index=(Get-ShorebirdPatchInputIndex $Fixture.repo $path)}};$r}
function Check-Restored($Fixture,$Before,[string]$Name){$after=Fingerprints $Fixture;Check (($Before|ConvertTo-Json -Depth 5 -Compress) -ceq ($after|ConvertTo-Json -Depth 5 -Compress)) ($Name+'_bytes_mtime_index');Assert-ShorebirdPatchInputSource $Fixture.repo $Fixture.commit;Check $true ($Name+'_clean_source')}
function Enter-PinFixture($Fixture){Enter-ShorebirdPatchRuntimePinLease -Repository $Fixture.repo -BaseReceiptPath $Fixture.receiptPath -BaseReceipt $Fixture.receipt -SourceCommit $Fixture.commit -PrivateDirectory $Fixture.private}
function Pin-Fingerprint($Fixture){@{hash=(Get-AuditSha256 $Fixture.pinPath);mtime=[IO.File]::GetLastWriteTimeUtc($Fixture.pinPath);index=(Get-ShorebirdPatchInputIndex $Fixture.repo $Fixture.pinRelative)}}
function Check-PinRestored($Fixture,$Before,[string]$Name){$after=Pin-Fingerprint $Fixture;Check (($Before|ConvertTo-Json -Compress) -ceq ($after|ConvertTo-Json -Compress)) ($Name+'_bytes_mtime_index');Assert-ShorebirdPatchInputSource $Fixture.repo $Fixture.commit;Check $true ($Name+'_clean_source')}

foreach($auto in @($true,$false)){
    $f=New-Fixture Windows $auto $false "`r`n";$before=Fingerprints $f;$lease=Enter-Fixture $f
    foreach($entry in $lease.entries){Check ((Get-AuditSha256 $entry.path) -ceq $entry.baseHash) 'windows_exact_base_raw_bytes'}
    $null=Invoke-ShorebirdPatchInputGit $f.repo @('status','--porcelain=v1')
    Restore-ShorebirdPatchTextAssetsLease $lease
    Restore-ShorebirdPatchTextAssetsLease $lease
    Check $lease.restored 'idempotent_cleanup'
    Check-Restored $f $before ('windows_autocrlf_'+$auto)
}
$f=New-Fixture Android $true $true;$before=Fingerprints $f;$lease=Enter-Fixture $f
foreach($entry in $lease.entries){Check ((Get-AuditSha256 $entry.path) -ceq $entry.baseHash) 'android_exact_aab_lf_bytes'}
$caught=$false
try{try{throw 'synthetic_upstream_failure'}finally{Restore-ShorebirdPatchTextAssetsLease $lease}}catch{$caught=$_.Exception.Message -ceq 'synthetic_upstream_failure'}
Check $caught 'upstream_failure_is_preserved_after_cleanup'
Check-Restored $f $before 'android_failure_cleanup'

$f=New-Fixture Windows;$before=Fingerprints $f
$file=Join-Path $f.base 'ui/data/flutter_assets/assets/licenses/FlagIcons.txt'
[IO.File]::WriteAllBytes($file,(Bytes "different semantic content`n"));$f.receipt.files[1].sha256=Get-AuditSha256 $file;Save-Receipt $f
Refuses {Enter-Fixture $f} 'base_semantic_change_rejected_before_writes';Check-Restored $f $before 'semantic_rejection'

$f=New-Fixture Windows
[IO.File]::WriteAllBytes((Join-Path $f.repo 'apps/exvpn/assets/flags/countries.txt'),(Bytes "new source semantic content`n"))
$null=Invoke-ShorebirdPatchInputGit $f.repo @('add','--','apps/exvpn/assets/flags/countries.txt')
$null=Invoke-ShorebirdPatchInputGit $f.repo @('-c','user.name=ExVPN fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','commit','-qm','source asset changed')
$f.commit=Invoke-ShorebirdPatchInputGit $f.repo @('rev-parse','HEAD');$before=Fingerprints $f
Refuses {Enter-Fixture $f} 'head_and_base_source_semantics_must_match';Check-Restored $f $before 'source_semantic_rejection'

$f=New-Fixture Windows;$before=Fingerprints $f
[IO.File]::WriteAllBytes((Join-Path $f.base 'ui/data/flutter_assets/assets/flags/countries.txt'),(Bytes "tampered base`n"))
Refuses {Enter-Fixture $f} 'receipt_bound_asset_tamper_rejected';Check-Restored $f $before 'tamper_rejection'

foreach($invalid in @([byte[]]@(0xff,0xfe,0x41),[byte[]]@(0x41,0x0d,0x42))){
    $f=New-Fixture Windows;$before=Fingerprints $f;$path=Join-Path $f.base 'ui/data/flutter_assets/assets/flags/countries.txt'
    [IO.File]::WriteAllBytes($path,$invalid);$f.receipt.files[0].sha256=Get-AuditSha256 $path;Save-Receipt $f
    Refuses {Enter-Fixture $f} 'invalid_text_encoding_or_newline_rejected';Check-Restored $f $before 'invalid_text_rejection'
}
$f=New-Fixture Android;$before=Fingerprints $f;$aab=Join-Path $f.base 'ExVPN-0.1.8-29-android.aab'
$zip=[IO.Compression.ZipFile]::Open($aab,[IO.Compression.ZipArchiveMode]::Update)
try{$entry=$zip.CreateEntry('base/assets/flutter_assets/assets/flags/countries.txt');$stream=$entry.Open();try{$stream.Write((Bytes "duplicate`n"))}finally{$stream.Dispose()}}finally{$zip.Dispose()}
$f.receipt.files[0].sha256=Get-AuditSha256 $aab;Save-Receipt $f
Refuses {Enter-Fixture $f} 'duplicate_aab_asset_rejected';Check-Restored $f $before 'duplicate_aab_rejection'

$f=New-Fixture Android $false;$before=Fingerprints $f;$lease=Enter-Fixture $f
[IO.File]::WriteAllBytes((Join-Path $f.repo 'apps/exvpn/assets/flags/countries.txt'),(Bytes "unexpected during build`n"))
Refuses {Restore-ShorebirdPatchTextAssetsLease $lease} 'unexpected_build_asset_write_fails_closed'
Check-Restored $f $before 'unexpected_write_cleanup'
$backups=@(Get-ChildItem -LiteralPath $f.private -File -Filter 'unexpected-asset-*.bin')
Check ($backups.Count -eq 1 -and (Get-AuditSha256 $backups[0].FullName) -ceq (Get-ShorebirdPatchInputHash (Bytes "unexpected during build`n"))) 'unexpected_write_preserved_privately'

$f=New-Fixture Windows $true $false "`r`n";$before=Fingerprints $f;$readonly=Join-Path $f.repo 'apps/exvpn/assets/licenses/FlagIcons.txt'
(Get-Item -LiteralPath $readonly).IsReadOnly=$true
try{Refuses {Enter-Fixture $f} 'partial_write_failure_rejected'}finally{(Get-Item -LiteralPath $readonly).IsReadOnly=$false}
Check-Restored $f $before 'partial_write_cleanup'

foreach($target in @('Windows','Android')){
    $f=New-Fixture $target $true $true;$before=Pin-Fingerprint $f;$lease=Enter-PinFixture $f
    Check ((Get-AuditSha256 $f.pinPath) -ceq $f.receipt.runtime.identity.pin.sha256 -and $lease.summary.path -ceq $f.pinRelative) 'pin_crlf_checkout_exact_receipt_lf'
    Check ((Get-ShorebirdPatchInputIndex $f.repo $f.pinRelative) -ceq $before.index) 'pin_index_unchanged_during_lease'
    Assert-ShorebirdPatchInputSource $f.repo $f.commit
    $caught=$false
    try{try{throw 'synthetic_runtime_evidence_failure'}finally{Restore-ShorebirdPatchRuntimePinLease $lease}}catch{$caught=$_.Exception.Message -ceq 'synthetic_runtime_evidence_failure'}
    Check $caught 'pin_runtime_failure_preserved_after_cleanup'
    Restore-ShorebirdPatchRuntimePinLease $lease
    Check-PinRestored $f $before ($target+'_pin_cleanup')
}
$f=New-Fixture Windows $true;$before=Pin-Fingerprint $f
$f.receipt.runtime.identity.pin.sha256=Get-ShorebirdPatchInputHash (Bytes ($f.pinText.Replace("`n","`r`n")));Save-Receipt $f
$lease=Enter-PinFixture $f
Check ((Get-AuditSha256 $f.pinPath) -ceq $f.receipt.runtime.identity.pin.sha256) 'pin_lf_checkout_exact_receipt_crlf'
Restore-ShorebirdPatchRuntimePinLease $lease;Check-PinRestored $f $before 'pin_crlf_cleanup'

$f=New-Fixture Windows $true $true;$before=Pin-Fingerprint $f;$assetBefore=Fingerprints $f
$lease=Enter-PinFixture $f;$assets=Enter-Fixture $f;Restore-ShorebirdPatchTextAssetsLease $assets
Check ((Get-AuditSha256 $f.pinPath) -ceq $f.receipt.runtime.identity.pin.sha256) 'asset_cleanup_keeps_active_pin_lease'
Restore-ShorebirdPatchRuntimePinLease $lease
Check-PinRestored $f $before 'nested_pin_cleanup';Check-Restored $f $assetBefore 'nested_assets_cleanup'

foreach($bad in @('hash','path')){
    $f=New-Fixture Windows $true $true;$before=Pin-Fingerprint $f
    if($bad -ceq 'hash'){$f.receipt.runtime.identity.pin.sha256='0'*64}else{$f.receipt.runtime.identity.pin.path='scripts/bootstrap/toolchain.lock.json'}
    Save-Receipt $f
    Refuses {Enter-PinFixture $f} ('pin_bad_receipt_'+$bad+'_rejected');Check-PinRestored $f $before ('pin_bad_'+$bad)
}
$f=New-Fixture Windows
[IO.File]::WriteAllBytes($f.pinPath,(Bytes ($f.pinText.Replace('exact synthetic dependency pin','changed dependency'))))
$null=Invoke-ShorebirdPatchInputGit $f.repo @('add','--',$f.pinRelative)
$null=Invoke-ShorebirdPatchInputGit $f.repo @('-c','user.name=ExVPN fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','commit','-qm','synthetic pin semantic change')
$f.commit=Invoke-ShorebirdPatchInputGit $f.repo @('rev-parse','HEAD');$before=Pin-Fingerprint $f
Refuses {Enter-PinFixture $f} 'pin_semantic_change_rejected';Check-PinRestored $f $before 'pin_semantic_rejection'

$f=New-Fixture Windows $true $true;$before=Pin-Fingerprint $f;$lease=Enter-PinFixture $f
[IO.File]::WriteAllBytes($f.pinPath,(Bytes "unexpected pin write`n"))
Refuses {Restore-ShorebirdPatchRuntimePinLease $lease} 'unexpected_pin_write_fails_closed'
Check-PinRestored $f $before 'unexpected_pin_cleanup'
$backups=@(Get-ChildItem -LiteralPath $f.private -File -Filter 'unexpected-asset-*.bin')
Check ($backups.Count -eq 1 -and (Get-AuditSha256 $backups[0].FullName) -ceq (Get-ShorebirdPatchInputHash (Bytes "unexpected pin write`n"))) 'unexpected_pin_write_preserved_privately'

$wrapper=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'shorebird-patch.ps1') -Raw
Check ($wrapper.Contains('finally { Restore-ShorebirdPatchTextAssetsLease $textAssetLease }') -and $wrapper.Contains('try { Restore-ShorebirdPatchTextAssetsLease $textAssetLease }')) 'actual_wrapper_immediate_and_outer_cleanup'
Check (!$wrapper.Contains('--allow-asset-diffs')) 'upstream_asset_diff_guard_not_bypassed'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($wrapper,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'actual_wrapper_parses'
$mainTry=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.CatchClauses.Count -gt 0 -and $node.Body.Extent.Text.Contains('Enter-ShorebirdPatchRuntimePinLease')},$true))
Check ($mainTry.Count -eq 1) 'runtime_inputs_inside_main_protected_try'
$body=$mainTry[0].Body.Extent.Text
Check ($body.IndexOf('Enter-ShorebirdPatchRuntimePinLease') -lt $body.IndexOf('Get-ReleaseFlutterRuntime') -and $body.IndexOf('Get-ReleaseFlutterRuntime') -lt $body.IndexOf('Get-ShorebirdCli')) 'pin_lease_precedes_runtime_and_cli'
Check ($body.LastIndexOf('Assert-ReleaseFlutterRuntimeEvidence') -lt $body.IndexOf('Restore-ShorebirdPatchRuntimePinLease') -and $body.IndexOf('Restore-ShorebirdPatchRuntimePinLease') -lt $body.IndexOf('runtimePinInput=')) 'pin_restored_after_final_runtime_audit_before_receipt'
Check ($mainTry[0].Finally.Extent.Text.Contains('Restore-ShorebirdPatchRuntimePinLease') -and $mainTry[0].Finally.Extent.Text.Contains('Restore-DemoAndroidEnvironment')) 'outer_cleanup_keeps_pin_keys_environment_finally'
Check ($mainTry[0].CatchClauses[0].Body.Extent.Text.Contains("'failure.json'") -and $mainTry[0].CatchClauses[0].Body.Extent.Text.Contains('actualRuntimeEvidence=$actualRuntimeEvidence;expectedRuntimeEvidence=$base.runtime') -and $mainTry[0].CatchClauses[0].Body.Extent.Text.Contains('Write-ShorebirdEncryptedDiagnostic')) 'early_runtime_failure_exports_only_encrypted_private_pair'
Write-Host "Shorebird fixed text inputs: $script:checks focused checks PASS; no SDK, app/native builds, signing or cloud."
