# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
param([string]$Repository=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'base-capsule.ps1')
$script:checks=0
function Check([bool]$Value,[string]$Name){if(!$Value){throw ('capsule_fixture_failed_'+$Name)};$script:checks++}
function Reject([scriptblock]$Action,[string]$Name){try{& $Action|Out-Null}catch{Check $true $Name;return};throw ('capsule_fixture_did_not_reject_'+$Name)}
function Copy-Fixture($Value){$Value|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable}
$fixture=Join-Path $Repository ('artifacts/qa/ota-capsule-fixtures-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$version='0.1.10+31';$commit='e'*40
function New-Fixture([string]$Target){
    $root=Join-Path $fixture $Target;New-Item -ItemType Directory -Path $root|Out-Null
    $protected=@(@{path='.gitattributes';sha256=('a'*64)})
    $fingerprint=Get-ExvpnOtaInputsFingerprint $protected
    $tools=@{flutterSdkRoot='.tools/shorebird-1.6.129/bin/cache/flutter/5bef02a16146a0effc07da4acccaafe90a2739ce';genSnapshot=@{}}
    foreach($record in @(@('dart','bin/cache/dart-sdk/bin/dart.exe'),@('flutter','bin/cache/flutter_tools.snapshot'),@('frontend','bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),@('dartAotRuntime','bin/cache/dart-sdk/bin/dartaotruntime.exe'),@('platformDill','bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill'),@('patch','.tools/shorebird-1.6.129/bin/cache/artifacts/patch/patch.exe'))){$tools[$record[0]]=@{path=$record[1];sha256=('b'*64)}}
    $aot=@{};$bound=@()
    foreach($plan in @(Get-ExvpnOtaAotPlan $Target)){
        $relative='base-aot/'+$plan.key+'/app.so';$path=Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force|Out-Null
        $bytes=[byte[]]::new(4096);$bytes[0]=127;$bytes[1]=69;$bytes[2]=76;$bytes[3]=70;$bytes[4]=2;$bytes[5]=1;$bytes[18]=if($plan.arch -ceq 'aarch64'){183}else{62}
        [IO.File]::WriteAllBytes($path,$bytes)
        $hash=Get-ExvpnOtaSha256 $path;$aot[$plan.key]=@{path=$relative;sha256=$hash;size=4096}
        $tools.genSnapshot[$plan.key]=@{path=$plan.genSnapshot;sha256=('b'*64)}
        $bound+=@{arch=$plan.arch;sha256=$hash;bytes=4096}
    }
    $packagePath=Join-Path $root 'build.json'
    [IO.File]::WriteAllText($packagePath,'{"synthetic":"already-audited-package"}')
    $receipt=@{schemaVersion=1;delivery='independent';published=$false;version=$version;target=$Target;sourceCommit=$commit;
        flutterRevision='5bef02a16146a0effc07da4acccaafe90a2739ce';engineRevision='4b936a0c03e13389ddfb1ac48823f187964975c2';appRoot='apps/exvpn';dartEntrypoint='lib/main.dart';
        dartDefines=@('EXVPN_DEMO=false','EXVPN_DART_UPDATE_TRACK=beta','EXVPN_OTA_PROVIDER=exvpn',('EXVPN_OTA_BASE_FINGERPRINT='+$fingerprint));
        protectedInputs=$protected;protectedInputsSha256=$fingerprint;fingerprints=@{native=('b'*64);assets=('b'*64);plugins=('b'*64);dependencies=('b'*64)};
        baseAot=$aot;tools=$tools;signingPublicKey=@{path='config/signing/shorebird-beta-public.pem';sha256=('c'*64)};packageBuildReceiptSha256=(Get-ExvpnOtaSha256 $packagePath);
        sourceUpdaterPolicyUnchanged=$true;packagedUpdaterEndpoint='http://127.0.0.1:57791';autoUpdate=$false;patchVerification='strict'}
    $receiptPath=Join-Path $root 'base-receipt.json';[IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    @{root=$root;target=$Target;receiptPath=$packagePath;receiptSha256=$receipt.packageBuildReceiptSha256;base=@{publicKeySha256=('c'*64);baseAot=$bound};receipt=$receipt}
}
function New-ZipFixture($Entries){
    $path=Join-Path $fixture ([guid]::NewGuid().ToString('N')+'.zip')
    $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
    try{foreach($item in $Entries){$entry=$zip.CreateEntry($item.name);if($item.ContainsKey('attributes')){$entry.ExternalAttributes=$item.attributes};$stream=$entry.Open();try{$stream.Write($item.bytes,0,$item.bytes.Length)}finally{$stream.Dispose()}}}finally{$zip.Dispose()}
    $path
}
function Expand-Fixture([string]$Path,[string]$Target,[string]$Hash){Expand-ExvpnOtaBaseCapsule $Path $version $commit $Target $Hash (Join-Path $fixture ([guid]::NewGuid().ToString('N')))}
foreach($target in @('Windows','Android')){
    $base=New-Fixture $target
    $output1=Join-Path $base.root 'zip1';$output2=Join-Path $base.root 'zip2'
    New-Item -ItemType Directory -Path $output1,$output2|Out-Null
    $first=New-ExvpnOtaBaseCapsule $base $version $commit $target $output1
    $second=New-ExvpnOtaBaseCapsule $base $version $commit $target $output2
    Check ($first.asset.sha256 -ceq $second.asset.sha256) 'stable_zip_bytes'
    Check ($first.asset.file -ceq ('ExVPN-0.1.10-31-'+$target.ToLowerInvariant()+'-ota-inputs.zip')) 'permanent_asset_name'
    $expanded=Expand-Fixture $first.path $target $base.receiptSha256
    Check ((Get-ExvpnOtaSha256 $expanded) -ceq (Get-ExvpnOtaSha256 (Join-Path $base.root 'base-receipt.json'))) 'exact_receipt_roundtrip'
    foreach($plan in @(Get-ExvpnOtaCapsulePlan $base.receipt $version $commit $target)){
        Check ((Get-ExvpnOtaSha256 (Join-Path (Split-Path -Parent $expanded) $plan.path)) -ceq $plan.sha256) 'all_architectures_roundtrip'
    }
    Reject {Expand-Fixture $first.path $target ('d'*64)} 'package_receipt_binding'
    Reject {Expand-ExvpnOtaBaseCapsule $first.path $version $commit $target $base.receiptSha256 (Split-Path -Parent $expanded)} 'existing_destination_not_overwritten'
    $entries=@(@{name='base-receipt.json';bytes=[IO.File]::ReadAllBytes((Join-Path $base.root 'base-receipt.json'))})
    foreach($plan in @(Get-ExvpnOtaCapsulePlan $base.receipt $version $commit $target)){$entries+=@{name=$plan.path;bytes=[IO.File]::ReadAllBytes((Join-Path $base.root $plan.path))}}
    $unknown=New-ZipFixture ($entries+@(@{name='extra.exe';bytes=[byte[]](1,2,3)}))
    Reject {Expand-Fixture $unknown $target $base.receiptSha256} 'unknown_executable_rejected'
    $traversal=@($entries|ForEach-Object {if($_.name -ceq 'base-receipt.json'){@{name='../base-receipt.json';bytes=$_.bytes}}else{$_}})
    $badZip=New-ZipFixture $traversal;Reject {Expand-Fixture $badZip $target $base.receiptSha256} 'traversal_rejected'
    $duplicate=@($entries|ForEach-Object {if($_.name -ceq 'base-receipt.json'){@{name=$entries[1].name;bytes=$_.bytes}}else{$_}})
    $badZip=New-ZipFixture $duplicate;Reject {Expand-Fixture $badZip $target $base.receiptSha256} 'duplicate_entries_rejected'
    $links=@($entries|ForEach-Object {@{name=$_.name;bytes=$_.bytes;attributes=([int]0xa000 -shl 16)}})
    $badZip=New-ZipFixture $links;Reject {Expand-Fixture $badZip $target $base.receiptSha256} 'symlinks_rejected'
    $corrupt=@($entries|ForEach-Object {$bytes=[byte[]]$_.bytes.Clone();if($_.name -cne 'base-receipt.json'){$bytes[100]=42};@{name=$_.name;bytes=$bytes}})
    $badZip=New-ZipFixture $corrupt;Reject {Expand-Fixture $badZip $target $base.receiptSha256} 'aot_hash_change_rejected'
    foreach($change in @(@('sourceCommit',('f'*40)),@('version','0.1.11+32'),@('target',$(if($target -ceq 'Windows'){'Android'}else{'Windows'})),@('autoUpdate',$true),@('patchVerification','install_only'),@('packagedUpdaterEndpoint','https://example.invalid'))){
        $bad=Copy-Fixture $base.receipt;$bad[$change[0]]=$change[1]
        Reject {Get-ExvpnOtaCapsulePlan $bad $version $commit $target} 'receipt_policy_or_identity_drift_rejected'
    }
    $bad=Copy-Fixture $base.receipt;$bad.privateKey='must-never-export';Reject {Get-ExvpnOtaCapsulePlan $bad $version $commit $target} 'arbitrary_receipt_fields_rejected'
    $bad=Copy-Fixture $base.receipt;$bad.tools.dart.path='../../../untrusted.exe';Reject {Get-ExvpnOtaCapsulePlan $bad $version $commit $target} 'untrusted_compiler_path_rejected'
    $bad=Copy-Fixture $base.receipt;$bad.protectedInputsSha256='a'*64;Reject {Get-ExvpnOtaCapsulePlan $bad $version $commit $target} 'compatibility_hash_mismatch_rejected'
    $bad=Copy-Fixture $base.receipt;$bad.baseAot.Values|ForEach-Object {$_.path='../app.so'};Reject {Get-ExvpnOtaCapsulePlan $bad $version $commit $target} 'receipt_aot_traversal_rejected'
    $bad=Copy-Fixture $base.receipt;$bad.baseAot.Values|ForEach-Object {$_.size=4096.5};Reject {Get-ExvpnOtaCapsulePlan $bad $version $commit $target} 'noninteger_size_rejected'
    $bad=Copy-Fixture $base.receipt;$bad.baseAot.Values|ForEach-Object {$_.size=134217729};Reject {Get-ExvpnOtaCapsulePlan $bad $version $commit $target} 'oversized_aot_rejected_without_allocating_payload'
    $badBase=Copy-Fixture $base;$badBase.receiptSha256='a'*64
    Reject {New-ExvpnOtaBaseCapsule $badBase $version $commit $target $output1} 'package_hash_mismatch_rejected_before_staging'
}
foreach($path in @('base-capsule.ps1','download-base.ps1')){$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$tokens,[ref]$errors);Check (@($errors).Count -eq 0) 'capsule_tool_syntax'}
$sourceRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$publisherPath=Join-Path $sourceRoot 'scripts/release/publish-shorebird-preview.ps1'
$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($publisherPath,[ref]$tokens,[ref]$errors)
Check (@($errors).Count -eq 0) 'capsule_publisher_syntax'
$publisher=[IO.File]::ReadAllText($publisherPath)
Check ($publisher.Contains('if ($Independent) { New-ExvpnOtaBaseCapsule') -and $publisher.IndexOf('New-ExvpnOtaBaseCapsule') -lt $publisher.IndexOf('$manifest=')) 'capsule_included_before_release_manifest_only_independent'
$workflow=[IO.File]::ReadAllText((Join-Path $sourceRoot '.github/workflows/independent-ota.yml'))
Check ($workflow.Contains("if: inputs.operation == 'patch' && inputs.base_run_id == ''") -and $workflow.Contains("if: inputs.operation == 'patch' && inputs.base_run_id != ''")) 'artifact_or_permanent_release_paths_available'
Check ($workflow.Contains('./scripts/ota/download-base.ps1') -and $workflow.Contains('./scripts/ota/test-base-capsule.ps1')) 'workflow_uses_validated_capsules'
foreach($match in [regex]::Matches($workflow,'(?m)^        run: \|\r?\n((?:          [^\r\n]*\r?\n)+)')){
    $code=($match.Groups[1].Value -split '\r?\n'|ForEach-Object {if($_.Length -ge 10){$_.Substring(10)}else{$_}})-join "`n"
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) 'workflow_inline_powershell_syntax'
}
[ordered]@{schemaVersion=1;checks=$script:checks;passed=$true;scope='synthetic Windows/Android immutable-input ZIP roundtrips and refusal cases; no network, SDK builds, real keys or publication'}|ConvertTo-Json -Compress
