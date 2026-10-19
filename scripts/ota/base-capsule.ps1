# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
# Immutable compatible-build inputs, never executable update installation.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'aot-inputs.ps1')

function Get-ExvpnOtaCapsulePlan($Receipt,[string]$Version,[string]$SourceCommit,[string]$Target) {
    if ($Version -cnotmatch '^\d+\.\d+\.\d+\+[1-9]\d*$' -or $SourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
        $Target -cnotin @('Android','Windows') -or !$Receipt -or $Receipt.schemaVersion -ne 1 -or
        $Receipt.delivery -cne 'independent' -or $Receipt.published -ne $false -or $Receipt.version -cne $Version -or
        $Receipt.sourceCommit -cne $SourceCommit -or $Receipt.target -cne $Target -or
        $Receipt.flutterRevision -cne '5bef02a16146a0effc07da4acccaafe90a2739ce' -or
        $Receipt.engineRevision -cne '4b936a0c03e13389ddfb1ac48823f187964975c2' -or
        $Receipt.appRoot -cne 'apps/exvpn' -or $Receipt.dartEntrypoint -cne 'lib/main.dart' -or
        $Receipt.packagedUpdaterEndpoint -cne 'http://127.0.0.1:57791' -or $Receipt.autoUpdate -ne $false -or
        $Receipt.patchVerification -cne 'strict' -or $Receipt.sourceUpdaterPolicyUnchanged -ne $true -or
        $Receipt.packageBuildReceiptSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $Receipt.signingPublicKey.Count -ne 2 -or $Receipt.signingPublicKey.path -cne 'config/signing/shorebird-beta-public.pem' -or
        $Receipt.signingPublicKey.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'ota_capsule_receipt_invalid' }
    $allowed=@('schemaVersion','delivery','published','version','target','sourceCommit','flutterRevision','engineRevision',
        'appRoot','dartEntrypoint','dartDefines','protectedInputs','protectedInputsSha256','fingerprints','baseAot','tools',
        'signingPublicKey','packageBuildReceiptSha256','sourceUpdaterPolicyUnchanged','packagedUpdaterEndpoint','autoUpdate','patchVerification')
    if ($Receipt.Count -ne $allowed.Count -or @($Receipt.Keys | Where-Object {$_ -cnotin $allowed}).Count) { throw 'ota_capsule_receipt_fields_invalid' }
    if (@($Receipt.protectedInputs).Count -eq 0 -or @($Receipt.protectedInputs).Count -gt 10000 -or
        (Get-ExvpnOtaInputsFingerprint @($Receipt.protectedInputs)) -cne $Receipt.protectedInputsSha256) { throw 'ota_capsule_compatibility_invalid' }
    foreach ($input in $Receipt.protectedInputs) {
        if ($input.Count -ne 2 -or !(Test-ExvpnOtaProtectedPath $input.path) -or
            $input.path -match '(^|/)\.\.?(/|$)|[:\\\r\n\x00]' -or [IO.Path]::IsPathRooted($input.path)) { throw 'ota_capsule_input_path_invalid' }
    }
    $defines=@('EXVPN_DEMO=false','EXVPN_DART_UPDATE_TRACK=beta','EXVPN_OTA_PROVIDER=exvpn',('EXVPN_OTA_BASE_FINGERPRINT='+$Receipt.protectedInputsSha256))
    if (($defines | ConvertTo-Json -Compress) -cne (@($Receipt.dartDefines) | ConvertTo-Json -Compress)) { throw 'ota_capsule_defines_invalid' }
    if ($Receipt.fingerprints.Count -ne 4) { throw 'ota_capsule_fingerprints_invalid' }
    foreach ($name in @('native','assets','plugins','dependencies')) { if ($Receipt.fingerprints[$name] -cnotmatch '^[a-f0-9]{64}$') { throw 'ota_capsule_fingerprints_invalid' } }
    $toolPaths=@{dart='bin/cache/dart-sdk/bin/dart.exe';flutter='bin/cache/flutter_tools.snapshot';
        frontend='bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot';dartAotRuntime='bin/cache/dart-sdk/bin/dartaotruntime.exe';
        platformDill='bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill';
        patch='.tools/shorebird-1.6.129/bin/cache/artifacts/patch/patch.exe'}
    if ($Receipt.tools.Count -ne 8 -or $Receipt.tools.flutterSdkRoot -cne '.tools/shorebird-1.6.129/bin/cache/flutter/5bef02a16146a0effc07da4acccaafe90a2739ce') { throw 'ota_capsule_tools_invalid' }
    foreach ($name in $toolPaths.Keys) {
        $record=$Receipt.tools[$name]
        if (!$record -or $record.Count -ne 2 -or $record.path -cne $toolPaths[$name] -or $record.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'ota_capsule_tools_invalid' }
    }
    $plan=@(Get-ExvpnOtaAotPlan $Target)
    if ($Receipt.baseAot.Count -ne $plan.Count -or $Receipt.tools.genSnapshot.Count -ne $plan.Count) { throw 'ota_capsule_architectures_invalid' }
    foreach ($item in $plan) {
        $aot=$Receipt.baseAot[$item.key];$tool=$Receipt.tools.genSnapshot[$item.key]
        if (!$aot -or $aot.Count -ne 3 -or $aot.path -cne ('base-aot/'+$item.key+'/app.so') -or
            $aot.sha256 -cnotmatch '^[a-f0-9]{64}$' -or ($aot.size -isnot [long] -and $aot.size -isnot [int]) -or [long]$aot.size -lt 4096 -or [long]$aot.size -gt 134217728 -or
            !$tool -or $tool.Count -ne 2 -or $tool.path -cne $item.genSnapshot -or $tool.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'ota_capsule_aot_invalid' }
        $item['path']=$aot.path;$item['sha256']=$aot.sha256;$item['size']=[long]$aot.size
    }
    $plan
}

function Read-ExvpnOtaCapsuleReceipt([string]$Path) {
    Assert-ExvpnOtaNoLinks $Path
    $item=Get-Item -LiteralPath $Path
    if ($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 16MB) { throw 'ota_capsule_receipt_size_invalid' }
    $text=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($Path))
    $text | ConvertFrom-Json -AsHashtable
}

function Assert-ExvpnOtaCapsuleAot([string]$Path,$Plan) {
    Assert-ExvpnOtaNoLinks $Path
    $item=Get-Item -LiteralPath $Path
    if ($item.PSIsContainer -or $item.Length -ne $Plan.size -or (Get-ExvpnOtaSha256 $Path) -cne $Plan.sha256) { throw 'ota_capsule_aot_bytes_invalid' }
    Assert-ExvpnOtaElf $Path $Plan.arch
}

function New-ExvpnOtaBaseCapsule($PackageBase,[string]$Version,[string]$SourceCommit,[string]$Target,[string]$OutputDirectory) {
    $receiptPath=Resolve-ExvpnOtaPath $PackageBase.root 'base-receipt.json'
    $receipt=Read-ExvpnOtaCapsuleReceipt $receiptPath
    $plan=@(Get-ExvpnOtaCapsulePlan $receipt $Version $SourceCommit $Target)
    if ($PackageBase.target -cne $Target -or $receipt.packageBuildReceiptSha256 -cne $PackageBase.receiptSha256 -or
        $receipt.signingPublicKey.sha256 -cne $PackageBase.base.publicKeySha256 -or
        (Get-ExvpnOtaSha256 $PackageBase.receiptPath) -cne $PackageBase.receiptSha256) { throw 'ota_capsule_package_binding_invalid' }
    foreach ($item in $plan) {
        $bound=@($PackageBase.base.baseAot | Where-Object arch -CEQ $item.arch)
        if ($bound.Count -ne 1 -or $bound[0].sha256 -cne $item.sha256 -or $bound[0].bytes -ne $item.size) { throw 'ota_capsule_package_aot_mismatch' }
        Assert-ExvpnOtaCapsuleAot (Resolve-ExvpnOtaPath $PackageBase.root $item.path) $item
    }
    $receiptHash=Get-ExvpnOtaSha256 $receiptPath
    $name='ExVPN-'+$Version.Replace('+','-')+'-'+$Target.ToLowerInvariant()+'-ota-inputs.zip'
    $output=Resolve-ExvpnOtaPath $OutputDirectory $name
    $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        foreach ($relative in @('base-receipt.json')+@($plan | ForEach-Object path)) {
            $entry=$archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime=[DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
            $entry.ExternalAttributes=0
            $input=[IO.File]::OpenRead((Join-Path $PackageBase.root $relative));$entryStream=$entry.Open()
            try { $input.CopyTo($entryStream) } finally { $input.Dispose();$entryStream.Dispose() }
        }
    } finally { $archive.Dispose();$stream.Dispose() }
    if ((Get-ExvpnOtaSha256 $receiptPath) -cne $receiptHash -or (Get-ExvpnOtaSha256 $PackageBase.receiptPath) -cne $PackageBase.receiptSha256) { throw 'ota_capsule_sources_changed' }
    foreach ($item in $plan) { Assert-ExvpnOtaCapsuleAot (Resolve-ExvpnOtaPath $PackageBase.root $item.path) $item }
    [ordered]@{path=$output;asset=[ordered]@{file=$name;sha256=(Get-ExvpnOtaSha256 $output);bytes=(Get-Item -LiteralPath $output).Length}}
}

function Expand-ExvpnOtaBaseCapsule([string]$Archive,[string]$Version,[string]$SourceCommit,[string]$Target,[string]$PackageReceiptSha256,[string]$OutputDirectory) {
    Assert-ExvpnOtaNoLinks $Archive
    $source=Get-Item -LiteralPath $Archive
    if ($source.PSIsContainer -or $source.Length -le 0 -or $source.Length -gt 288MB -or $PackageReceiptSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'ota_capsule_archive_size_invalid' }
    $destination=Resolve-ExvpnOtaPath (Get-Location).Path $OutputDirectory
    if (Test-Path -LiteralPath $destination) { throw 'ota_capsule_destination_exists' }
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $plans=@(Get-ExvpnOtaAotPlan $Target)
        $allowed=@('base-receipt.json')+@($plans | ForEach-Object { 'base-aot/'+$_.key+'/app.so' })
        if ($zip.Entries.Count -ne $allowed.Count) { throw 'ota_capsule_archive_entry_set_invalid' }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $type=($entry.ExternalAttributes -shr 16) -band 0xf000
            if ($entry.FullName -cnotin $allowed -or !$seen.Add($entry.FullName) -or $type -notin @(0,0x8000) -or
                ($entry.ExternalAttributes -band 0x400) -ne 0 -or $entry.Length -le 0 -or $entry.Length -gt 134217728 -or
                ($entry.FullName -ceq 'base-receipt.json' -and $entry.Length -gt 16MB)) { throw 'ota_capsule_archive_entry_invalid' }
        }
        $entry=$zip.GetEntry('base-receipt.json');$memory=[IO.MemoryStream]::new();$input=$entry.Open()
        try {
            $buffer=[byte[]]::new(65536);$total=0L
            while(($count=$input.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$count;if($total -gt $entry.Length -or $total -gt 16MB){throw 'ota_capsule_receipt_size_invalid'};$memory.Write($buffer,0,$count)}
            if($total -ne $entry.Length){throw 'ota_capsule_receipt_size_invalid'}
            $receiptBytes=$memory.ToArray()
        } finally { $input.Dispose();$memory.Dispose() }
        $receipt=[Text.UTF8Encoding]::new($false,$true).GetString($receiptBytes) | ConvertFrom-Json -AsHashtable
        $plan=@(Get-ExvpnOtaCapsulePlan $receipt $Version $SourceCommit $Target)
        if ($receipt.packageBuildReceiptSha256 -cne $PackageReceiptSha256) { throw 'ota_capsule_package_binding_invalid' }
        foreach ($item in $plan) { if ($zip.GetEntry($item.path).Length -ne $item.size) { throw 'ota_capsule_aot_bytes_invalid' } }
        New-Item -ItemType Directory -Path $destination | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $destination 'base-receipt.json'),$receiptBytes)
        foreach ($item in $plan) {
            $path=Resolve-ExvpnOtaPath $destination $item.path
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            $input=$zip.GetEntry($item.path).Open();$output=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $buffer=[byte[]]::new(65536);$total=0L
                while(($count=$input.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$count;if($total -gt $item.size){throw 'ota_capsule_aot_bytes_invalid'};$output.Write($buffer,0,$count)}
                if($total -ne $item.size){throw 'ota_capsule_aot_bytes_invalid'}
            } finally { $input.Dispose();$output.Dispose() }
            Assert-ExvpnOtaCapsuleAot $path $item
        }
        Join-Path $destination 'base-receipt.json'
    } finally { $zip.Dispose() }
}
