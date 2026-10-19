# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
# The host-generated Flutter app-jit snapshot is not a portable compiler pin.
# Execute reviewed SDK sources with a committed, offline build-tool-only lock.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'aot-inputs.ps1')

function Get-ExvpnOtaDriverPolicy {
    [ordered]@{flutterRevision='5bef02a16146a0effc07da4acccaafe90a2739ce';
        dependencyLockSha256='fa1786981448876ba5cdda3033749262e83d40d651d0e3399e48250cd6d9a854';
        sourcePins=[ordered]@{
            'packages/flutter_tools/bin/flutter_tools.dart'='554f38c4b048cd82e821a1ca296ec40cfc05f07f26cf1882d98b8a74af8b2a0b';
            'packages/flutter_tools/pubspec.yaml'='8d0143e1f5a4b0447ccf7f0c902f01c5ce0b36eebb826eccc517a6924cd2b5e1';
            'pubspec.lock'='e147a7ca8d33c1e204fade9fc48d92907b8f0c4499b0efae6fb3c82fd2614c35'
        }}
}

function Assert-ExvpnOtaDriverCheckout([string]$Sdk,[string]$ExpectedRevision) {
    Assert-ExvpnOtaNoLinks $Sdk
    $actualRoot=(& git -c core.fsmonitor=false -c core.longpaths=true -C $Sdk rev-parse --show-toplevel 2>$null)-join "`n"
    if($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($actualRoot.Trim()) -ine [IO.Path]::GetFullPath($Sdk)){throw 'ota_flutter_driver_checkout_mismatch'}
    $head=(& git -c core.fsmonitor=false -c core.longpaths=true -C $Sdk rev-parse HEAD 2>$null)-join "`n"
    if($LASTEXITCODE -ne 0 -or $head.Trim() -cne $ExpectedRevision -or $ExpectedRevision -cnotmatch '^[a-f0-9]{40}$'){throw 'ota_flutter_driver_revision_mismatch'}
    $status=@(& git -c core.fsmonitor=false -c core.longpaths=true -C $Sdk status --porcelain=v1 --untracked-files=normal 2>$null)
    if($LASTEXITCODE -ne 0){throw 'ota_flutter_driver_sources_modified'}
    # Official CLI bookkeeping files are data, never imported Dart sources.
    foreach($line in $status){
        if($line -cnotin @('?? .shorebird_last_used','?? .shorebird_precache')){throw 'ota_flutter_driver_sources_modified'}
        $marker=Resolve-ExvpnOtaPath $Sdk $line.Substring(3)
        $item=Get-Item -LiteralPath $marker
        if($item.PSIsContainer -or $item.Length -gt 4096){throw 'ota_flutter_driver_sources_modified'}
    }
    $policy=Get-ExvpnOtaDriverPolicy
    foreach($entry in $policy.sourcePins.GetEnumerator()){
        $path=Resolve-ExvpnOtaPath $Sdk $entry.Key
        if((Get-ExvpnOtaSha256 $path) -cne $entry.Value){throw 'ota_flutter_driver_source_pin_mismatch'}
    }
}

function Get-ExvpnOtaDriverPackageNames([string]$LockPath) {
    if((Get-ExvpnOtaSha256 $LockPath) -cne (Get-ExvpnOtaDriverPolicy).dependencyLockSha256){throw 'ota_flutter_driver_lock_mismatch'}
    $text=[IO.File]::ReadAllText($LockPath)
    $body=[regex]::Match($text,'(?ms)^packages:\r?\n(?<body>.+?)^sdks:\r?\n')
    if(!$body.Success){throw 'ota_flutter_driver_lock_invalid'}
    $names=@([regex]::Matches($body.Groups['body'].Value,'(?m)^  ([a-z_][a-z0-9_]*):\r?$')|ForEach-Object {$_.Groups[1].Value})
    if($names.Count -ne 102 -or @($names|Sort-Object -Unique).Count -ne 102){throw 'ota_flutter_driver_lock_invalid'}
    $names
}

function Set-ExvpnOtaDriverPackageConfig([string]$ConfigPath,[string]$ResolverDirectory,[string]$Sdk,[string]$PubCache,[string]$LockPath) {
    Assert-ExvpnOtaNoLinks $ConfigPath
    if((Get-Item -LiteralPath $ConfigPath).Length -gt 1MB){throw 'ota_flutter_driver_package_config_invalid'}
    $config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json -AsHashtable
    $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in @(Get-ExvpnOtaDriverPackageNames $LockPath)){$null=$expected.Add($name)}
    $null=$expected.Add('flutter_tools')
    if($config.configVersion -ne 2 -or $config.packages.Count -ne $expected.Count){throw 'ota_flutter_driver_package_config_invalid'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $configUri=[uri]::new([IO.Path]::GetFullPath($ConfigPath))
    $cacheRoot=[IO.Path]::GetFullPath($PubCache).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $resolverRoot=[IO.Path]::GetFullPath($ResolverDirectory).TrimEnd('\','/')
    $toolRoot=[IO.Path]::GetFullPath((Join-Path $Sdk 'packages/flutter_tools')).TrimEnd('\','/')
    foreach($package in $config.packages){
        if($package.name -isnot [string] -or !$expected.Contains($package.name) -or !$seen.Add($package.name) -or
            $package.packageUri -cne 'lib/' -or $package.rootUri -isnot [string]){throw 'ota_flutter_driver_package_config_invalid'}
        $uri=[uri]::new($configUri,$package.rootUri)
        if(!$uri.IsFile -or $uri.IsUnc){throw 'ota_flutter_driver_package_root_invalid'}
        $root=[IO.Path]::GetFullPath($uri.LocalPath).TrimEnd('\','/')
        Assert-ExvpnOtaNoLinks $root
        if($package.name -ceq 'flutter_tools'){
            if($root -ine $resolverRoot){throw 'ota_flutter_driver_package_root_invalid'}
            $package.rootUri=[uri]::new($toolRoot+[IO.Path]::DirectorySeparatorChar).AbsoluteUri
        } elseif(!$root.StartsWith($cacheRoot,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $root -PathType Container)){
            throw 'ota_flutter_driver_package_root_invalid'
        }
    }
    [IO.File]::WriteAllText($ConfigPath,($config|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [ordered]@{path=$ConfigPath;sha256=(Get-ExvpnOtaSha256 $ConfigPath);packages=$seen.Count}
}

function Initialize-ExvpnOtaSourceDriver([string]$Repository,[string]$Sdk,[string]$Dart,[string]$PrivateDirectory,[switch]$OnlineDependencies) {
    $policy=Get-ExvpnOtaDriverPolicy
    Assert-ExvpnOtaDriverCheckout $Sdk $policy.flutterRevision
    $lock=Resolve-ExvpnOtaPath $PSScriptRoot 'flutter-tools.lock'
    $null=Get-ExvpnOtaDriverPackageNames $lock
    $resolver=Resolve-ExvpnOtaPath $PrivateDirectory 'flutter-tool-resolver'
    if(Test-Path -LiteralPath $resolver){throw 'ota_flutter_driver_resolver_exists'}
    New-Item -ItemType Directory -Path $resolver|Out-Null
    Copy-Item -LiteralPath (Join-Path $Sdk 'packages/flutter_tools/pubspec.yaml') -Destination (Join-Path $resolver 'pubspec.yaml')
    Copy-Item -LiteralPath $lock -Destination (Join-Path $resolver 'pubspec.lock')
    $cache=Resolve-ExvpnOtaPath $Repository '.tools/cache/shorebird-pub'
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Dart;$info.WorkingDirectory=$resolver
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment['PUB_CACHE']=$cache;$info.Environment['CI']='true';$info.Environment['DART_SUPPRESS_ANALYTICS']='true'
    $arguments=@('pub','get','--enforce-lockfile')
    if(!$OnlineDependencies){$arguments+='--offline'}
    foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try{
        if(!$process.Start()){throw 'ota_flutter_driver_pub_start_failed'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(120000)){$process.Kill($true);throw 'ota_flutter_driver_pub_timeout'}
        [IO.File]::WriteAllText((Join-Path $PrivateDirectory 'flutter-driver-pub.log'),($stdout.GetAwaiter().GetResult()+"`n"+$stderr.GetAwaiter().GetResult()),[Text.UTF8Encoding]::new($false))
        if($process.ExitCode -ne 0){throw 'ota_flutter_driver_locked_dependencies_unavailable'}
    }finally{$process.Dispose()}
    if((Get-ExvpnOtaSha256 (Join-Path $resolver 'pubspec.lock')) -cne $policy.dependencyLockSha256 -or
        (Get-ExvpnOtaSha256 (Join-Path $resolver 'pubspec.yaml')) -cne $policy.sourcePins['packages/flutter_tools/pubspec.yaml']){throw 'ota_flutter_driver_resolution_changed'}
    $config=Set-ExvpnOtaDriverPackageConfig (Join-Path $resolver '.dart_tool/package_config.json') $resolver $Sdk $cache $lock
    Assert-ExvpnOtaDriverCheckout $Sdk $policy.flutterRevision
    [ordered]@{entrypoint=(Resolve-ExvpnOtaPath $Sdk 'packages/flutter_tools/bin/flutter_tools.dart');packageConfig=$config.path;
        packageConfigSha256=$config.sha256;dependencyLockSha256=$policy.dependencyLockSha256;
        entrypointSha256=$policy.sourcePins['packages/flutter_tools/bin/flutter_tools.dart'];kind='verified-sdk-source';sdkCommit=$policy.flutterRevision}
}

function Assert-ExvpnOtaSourceDriver([string]$Sdk,$Driver) {
    if($Driver.kind -cne 'verified-sdk-source' -or $Driver.sdkCommit -cne (Get-ExvpnOtaDriverPolicy).flutterRevision){throw 'ota_flutter_driver_identity_invalid'}
    Assert-ExvpnOtaDriverCheckout $Sdk $Driver.sdkCommit
    Assert-ExvpnOtaNoLinks $Driver.packageConfig
    if((Get-ExvpnOtaSha256 $Driver.packageConfig) -cne $Driver.packageConfigSha256 -or
        (Get-ExvpnOtaSha256 $Driver.entrypoint) -cne $Driver.entrypointSha256){throw 'ota_flutter_driver_changed'}
}
