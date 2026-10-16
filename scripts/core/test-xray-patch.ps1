# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'xray-patch-lib.ps1')
$prepare=Join-Path $PSScriptRoot 'prepare-xray-patch.ps1'
$root=Join-Path $repository ('artifacts/release-audit/xray-proxy-fixtures/' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$checks=0
function Assert-True([bool]$Condition,[string]$Name) {
    if (!$Condition) { throw "fixture_failed:$Name" }; $script:checks++; Write-Host "PASS $Name"
}
function Assert-Refused([scriptblock]$Action,[string]$Name,[string]$Code) {
    $caught=''; try { & $Action | Out-Null } catch { $caught=$_.Exception.Message }
    Assert-True ($caught -ceq $Code) "$Name ($caught)"
}
function TextFile([string]$Path,[string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function FixtureZip([string]$Path,[string]$Prefix,$Files) {
    $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($name in @($Files.Keys | Sort-Object -CaseSensitive -Culture en-US)) {
            $entry=$zip.CreateEntry("$Prefix/$name",[IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
            $entry.ExternalAttributes=0
            $stream=$entry.Open(); try { $bytes=[Text.Encoding]::UTF8.GetBytes($Files[$name]); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
}
$module='github.com/xtls/xray-core'; $version='v1.0.1-exvpn.1'
$base=[ordered]@{
    'LICENSE'="Synthetic test source, no Xray implementation.`n"
    'go.mod'="module $module`n`ngo 1.27.1`n"
    'dependency.go'="package fixture`n`nfunc Value() string { return `"before`" }`n"
    'existing_test.go'="package fixture`n`n// TestExVPN fixture must remain in the distributed source.`n"
}
$after=[ordered]@{}
foreach($name in $base.Keys) { $after[$name]=$base[$name] }
$after['dependency.go']=$base['dependency.go'].Replace('"before"','"after"')
$upstream=Join-Path $root 'upstream.zip'; $expected=Join-Path $root 'expected.zip'
FixtureZip $upstream "$module@v1.0.0" $base
FixtureZip $expected "$module@$version" $after
$patchText=@'
diff --git a/dependency.go b/dependency.go
--- a/dependency.go
+++ b/dependency.go
@@ -1,3 +1,3 @@
 package fixture
 
-func Value() string { return "before" }
+func Value() string { return "after" }

'@
$fixtureCounter=0
function New-Fixture {
    $script:fixtureCounter++
    $dir=Join-Path $root "input-$script:fixtureCounter"
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $patch=Join-Path $dir 'xray-lifecycle.patch'; TextFile $patch $patchText
    $lock=[ordered]@{
        schemaVersion=1;module=$module
        upstream=[ordered]@{version='v1.0.0';commit=('a'*40);zipSha256=(Get-AuditSha256 $upstream);sum=(Get-AuditGoZipSum $upstream);goModSum=(Get-XrayGoModSum ([Text.Encoding]::UTF8.GetBytes($base['go.mod'])))}
        patch=[ordered]@{path='xray-lifecycle.patch';sha256=(Get-AuditSha256 $patch)}
        patched=[ordered]@{version=$version;time='2026-10-10T09:21:07Z';sum=(Get-AuditGoZipSum $expected);goModSum=(Get-XrayGoModSum ([Text.Encoding]::UTF8.GetBytes($after['go.mod'])))}
    }
    $path=Join-Path $dir 'xray-lifecycle.lock.json'; Write-AuditJson $path $lock
    [ordered]@{Root=$dir;Lock=$lock;Path=$path;Patch=$patch;Output=(Join-Path $dir 'output')}
}
function Save-Fixture($Fixture) { Write-AuditJson $Fixture.Path $Fixture.Lock }
function Run-Fixture($Fixture) { & $prepare -LockPath $Fixture.Path -UpstreamZipPath $upstream -OutputRoot $Fixture.Output -Offline }

$f=New-Fixture; $ready=Run-Fixture $f
$bytes=Read-AuditZipBytes $ready.ZipPath "$module@$version/dependency.go"
Assert-True ([Text.Encoding]::UTF8.GetString($bytes) -ceq $after['dependency.go']) 'verified patch changes actual source'
$files=Get-AuditZipFiles $ready.ZipPath -GoModule
Assert-True ($files.Count -eq $base.Count -and $files.ContainsKey("$module@$version/existing_test.go") -and !@($files.Keys | Where-Object { $_ -match '/\.git/' }).Count) 'source tests retained and private Git metadata excluded'
$again=Run-Fixture $f
Assert-True ($again.ProxyRoot -ceq $ready.ProxyRoot -and (Get-AuditSha256 $again.ZipPath) -ceq (Get-AuditSha256 $ready.ZipPath)) 'verified immutable cache reused'
$second=New-Fixture; $secondReady=Run-Fixture $second
Assert-True ((Get-AuditSha256 $ready.ZipPath) -ceq (Get-AuditSha256 $secondReady.ZipPath)) 'separate generation produces identical archive bytes'
$provenance=Get-Content -LiteralPath $ready.ProvenancePath -Raw | ConvertFrom-Json -AsHashtable
Assert-True ($provenance.upstream.zipUrl -ceq 'https://proxy.golang.org/github.com/xtls/xray-core/@v/v1.0.0.zip' -and $provenance.upstream.sourceUrl.EndsWith('a'*40)) 'provenance binds official archive and exact source commit'

$bad=New-Fixture; TextFile $bad.Patch ($patchText.Replace('after','other'))
Assert-Refused { Run-Fixture $bad } 'changed patch' 'xray_patch_sha256_mismatch'
$bad=New-Fixture; $bad.Lock.upstream.zipSha256='0'*64; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'wrong upstream archive' 'xray_patch_upstream_sha256_mismatch'
$bad=New-Fixture; $bad.Lock.upstream.sum='h1:'+[Convert]::ToBase64String([byte[]]::new(32)); Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'wrong upstream module sum' 'xray_patch_module_sum_mismatch'
$bad=New-Fixture; $bad.Lock.patched.sum='h1:'+[Convert]::ToBase64String([byte[]]::new(32)); Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'wrong patched module sum' 'xray_patch_module_sum_mismatch'
$bad=New-Fixture; $bad.Lock.patched.goModSum='h1:'+[Convert]::ToBase64String([byte[]]::new(32)); Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'wrong patched go.mod sum' 'xray_patch_go_mod_sum_mismatch'
$bad=New-Fixture; $bad.Lock.patch.sha256='PENDING_ROOT_WRITER_FREEZE'; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'unfinalized lock' 'xray_patch_unfinalized_hash'
$bad=New-Fixture; $bad.Lock.patch.path='../escape.patch'; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'patch path escapes lock directory' 'xray_patch_invalid_patch_path'
$bad=New-Fixture; TextFile $bad.Path (([IO.File]::ReadAllText($bad.Path)).Replace('"schemaVersion": 1','"schemaVersion": 1, "schemaVersion": 1'))
Assert-Refused { Run-Fixture $bad } 'duplicate lock field' 'xray_patch_duplicate_lock_field'
$bad=New-Fixture; TextFile $bad.Patch ($patchText.Replace('dependency.go','../escape.go')); $bad.Lock.patch.sha256=Get-AuditSha256 $bad.Patch; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'diff path escapes source' 'unsafe_relative_path'
$bad=New-Fixture; TextFile $bad.Patch ($patchText.Replace('dependency.go','.git/config')); $bad.Lock.patch.sha256=Get-AuditSha256 $bad.Patch; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'diff cannot alter private Git config' 'xray_patch_unsafe_or_duplicate_path'
$bad=New-Fixture; TextFile $bad.Patch ($patchText.Replace('--- a/dependency.go',"new file mode 120000`n--- a/dependency.go")); $bad.Lock.patch.sha256=Get-AuditSha256 $bad.Patch; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'symlink patch rejected' 'xray_patch_unsupported_file_mode'
$bad=New-Fixture; TextFile $bad.Patch ($patchText.Replace("`n","`r`n")); $bad.Lock.patch.sha256=Get-AuditSha256 $bad.Patch; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'checkout CRLF drift rejected' 'xray_patch_requires_utf8_lf'
$bad=New-Fixture; TextFile $bad.Patch ($patchText.Replace('return "before"','return "not-the-base"')); $bad.Lock.patch.sha256=Get-AuditSha256 $bad.Patch; Save-Fixture $bad
Assert-Refused { Run-Fixture $bad } 'patch must apply to verified base' 'xray_patch_git_apply_failed'
$bad=New-Fixture
Assert-Refused { & $prepare -LockPath $bad.Path -UpstreamZipPath $upstream -OutputRoot ([IO.Path]::GetPathRoot($repository)) -Offline } 'output cannot target filesystem root' 'xray_patch_output_outside_workspace_cache'
$bad=New-Fixture
Assert-Refused { & $prepare -LockPath $bad.Path -OutputRoot $bad.Output -Offline } 'offline cache miss refuses network fallback' 'xray_patch_verified_upstream_zip_unavailable_offline'

TextFile (Join-Path $ready.ProxyRoot "$module/@v/$version.mod") ($base['go.mod']+"// unexpected`n")
Assert-Refused { Run-Fixture $f } 'cached mod bytes reverified' 'xray_patch_proxy_mod_mismatch'
$bad=New-Fixture; $badReady=Run-Fixture $bad
TextFile (Join-Path $badReady.ProxyRoot 'provenance.json') '{}'
Assert-Refused { Run-Fixture $bad } 'provenance marker not trusted' 'xray_patch_provenance_mismatch'
$bad=New-Fixture; $badReady=Run-Fixture $bad
TextFile (Join-Path $badReady.ProxyRoot 'untracked.txt') 'extra'
Assert-Refused { Run-Fixture $bad } 'unexpected proxy files rejected' 'xray_patch_unexpected_proxy_file'
$bad=New-Fixture; $badReady=Run-Fixture $bad
$archive=[IO.Compression.ZipFile]::Open($badReady.ZipPath,[IO.Compression.ZipArchiveMode]::Update)
try {
    $entry=$archive.GetEntry("$module@$version/dependency.go"); $entry.Delete()
    $entry=$archive.CreateEntry("$module@$version/dependency.go")
    $stream=$entry.Open(); try { $content=[Text.Encoding]::UTF8.GetBytes('tampered'); $stream.Write($content,0,$content.Length) } finally { $stream.Dispose() }
} finally { $archive.Dispose() }
Assert-Refused { Run-Fixture $bad } 'cached ZIP source reverified' 'xray_patch_module_sum_mismatch'
$bad=New-Fixture; $malicious=Join-Path $bad.Root 'traversal.zip'
FixtureZip $malicious "$module@v1.0.0" ([ordered]@{'../../outside.go'='bad'})
$bad.Lock.upstream.zipSha256=Get-AuditSha256 $malicious; Save-Fixture $bad
Assert-Refused { & $prepare -LockPath $bad.Path -UpstreamZipPath $malicious -OutputRoot $bad.Output -Offline } 'archive traversal rejected even with matching ZIP hash' 'unsafe_relative_path'
$bad=New-Fixture; $wrongPrefix=Join-Path $bad.Root 'wrong-prefix.zip'
FixtureZip $wrongPrefix 'other.invalid/module@v1.0.0' $base
$bad.Lock.upstream.zipSha256=Get-AuditSha256 $wrongPrefix; Save-Fixture $bad
Assert-Refused { & $prepare -LockPath $bad.Path -UpstreamZipPath $wrongPrefix -OutputRoot $bad.Output -Offline } 'archive module prefix validated before extraction' 'xray_patch_wrong_zip_prefix'

foreach($pattern in @('*','github.com','github.com/*','github.com/xtls/*','github.com/[x]tls','github.com/?tls','github.com/[^a]tls','github.com/\xtls','private.invalid,github.com/xtls/xray-core')) {
    Assert-Refused { Test-XrayNoProxyConflict $pattern } "GONOPROXY conflict $pattern" 'xray_patch_no_proxy_conflict'
}
foreach($pattern in @('','none','private.invalid/*','github.com/elsewhere','github.com/[^x]tls','github.com/[z-a]tls','github.com/xtls/xray-core/submodule')) {
    Test-XrayNoProxyConflict $pattern
    Assert-True $true "unrelated GONOPROXY preserved $pattern"
}
foreach($pattern in @('github.com/[','github.com/[]','github.com/[a-]','github.com/\')) {
    Assert-Refused { Test-XrayNoProxyConflict $pattern } "malformed no-proxy pattern $pattern" 'xray_patch_invalid_no_proxy_pattern'
}

# Exercise the real environment entry point in a disposable miniature checkout.
# Its executable is the installed, pinned Go; its caches and module files are
# private copies. There is no build, SDK install or global `go env -w` operation.
$envRoot=Join-Path $root 'environment-workspace'
foreach($relative in @('scripts/core/xray-patch-lib.ps1','scripts/core/prepare-xray-patch.ps1','scripts/release/artifact-audit-lib.ps1','scripts/bootstrap/enter-environment.ps1')) {
    $destination=Join-Path $envRoot $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository $relative) -Destination $destination
}
[IO.Directory]::CreateDirectory((Join-Path $envRoot '.tools/go/bin')) | Out-Null
Copy-Item -LiteralPath (Join-Path $repository '.tools/go/bin/go.exe') -Destination (Join-Path $envRoot '.tools/go/bin/go.exe')
foreach($native in @('core','android','windows')) {
    TextFile (Join-Path $envRoot "native/$native/go.mod") "module example.invalid/$native`nrequire (`n $module $version`n)`n"
}
$envFixture=New-Fixture
[IO.Directory]::CreateDirectory((Join-Path $envRoot 'native/patches')) | Out-Null
Copy-Item -LiteralPath $envFixture.Patch -Destination (Join-Path $envRoot 'native/patches/xray-lifecycle.patch')
Copy-Item -LiteralPath $envFixture.Path -Destination (Join-Path $envRoot 'native/patches/xray-lifecycle.lock.json')
$cacheZip=Join-Path $envRoot ".tools/cache/go/pkg/mod/cache/download/$module/@v/v1.0.0.zip"
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cacheZip)) | Out-Null
Copy-Item -LiteralPath $upstream -Destination $cacheZip
$probe=Join-Path $envRoot 'probe.ps1'
TextFile $probe @'
param([switch]$Twice,[switch]$NativeOnly)
$ErrorActionPreference='Stop'
try {
    . (Join-Path $PSScriptRoot 'scripts/bootstrap/enter-environment.ps1') -NativeOnly:$NativeOnly
    if ($Twice) { . (Join-Path $PSScriptRoot 'scripts/bootstrap/enter-environment.ps1') -NativeOnly:$NativeOnly }
    $localFlutterBin = Join-Path $PSScriptRoot '.tools/flutter/bin'
    $flutterPrepended = $env:PATH.Split([IO.Path]::PathSeparator) -contains $localFlutterBin
    [ordered]@{ok=$true;proxy=$env:GOPROXY;noProxy=$env:GONOPROXY;noSum=$env:GONOSUMDB;sumDb=$env:GOSUMDB;work=$env:GOWORK;flutterPrepended=$flutterPrepended} | ConvertTo-Json -Compress
} catch {
    [ordered]@{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
}
'@
function Environment-Probe($Overrides,[switch]$Twice,[switch]$NativeOnly) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $PSHOME 'pwsh.exe'; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-File',$probe)) { $start.ArgumentList.Add($arg) }
    if ($Twice) { $start.ArgumentList.Add('-Twice') }
    if ($NativeOnly) { $start.ArgumentList.Add('-NativeOnly') }
    $defaults=@{GOENV='off';GOTOOLCHAIN='local';GOROOT=(Join-Path $repository '.tools/go');GOWORK='off';GOFLAGS='';GOPROXY='off';GONOPROXY='';GONOSUMDB='private.invalid/*';GOPRIVATE='';GOSUMDB='sum.golang.org'}
    foreach($name in $defaults.Keys) { $start.Environment[$name]=$defaults[$name] }
    foreach($name in $Overrides.Keys) { $start.Environment[$name]=$Overrides[$name] }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        [void]$process.Start(); $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) { $process.Kill($true); throw 'environment_fixture_timeout' }
        $output=$stdout.GetAwaiter().GetResult(); [void]$stderr.GetAwaiter().GetResult()
        $json=@($output -split "`n" | Where-Object { $_.StartsWith('{') })[-1]
        $json | ConvertFrom-Json -AsHashtable
    } finally { $process.Dispose() }
}
$probeResult=Environment-Probe @{} -NativeOnly
Assert-True ($probeResult.ok -and !$probeResult.flutterPrepended -and $probeResult.proxy.StartsWith('file:///')) 'native-only entry prepares pinned Go without Flutter'
$probeResult=Environment-Probe @{}
Assert-True (!$probeResult.ok -and $probeResult.error.StartsWith('Missing local SDK: ') -and $probeResult.error.Contains('flutter')) 'ordinary entry still requires Flutter'
[IO.Directory]::CreateDirectory((Join-Path $envRoot '.tools/flutter/bin')) | Out-Null
$probeResult=Environment-Probe @{}
Assert-True ($probeResult.ok -and $probeResult.proxy.StartsWith('file:///') -and !$probeResult.proxy.Contains(',')) 'offline entry point uses only local proxy'
Assert-True $probeResult.flutterPrepended 'ordinary entry activates Flutter'
Assert-True ($probeResult.noSum -ceq "private.invalid/*,$module" -and $probeResult.sumDb -ceq 'sum.golang.org' -and $probeResult.work -ceq 'off') 'preserve user sum patterns and sumdb while disabling workspace overrides'
$probeResult=Environment-Probe @{} -Twice
Assert-True ($probeResult.ok -and $probeResult.proxy.StartsWith('file:///') -and !$probeResult.proxy.Contains(',')) 'nested offline entry keeps local-only proxy'
Assert-True ($probeResult.noSum -ceq "private.invalid/*,$module") 'nested entry does not duplicate checksum exceptions'
$probeResult=Environment-Probe @{GOPROXY='file:///V:/synthetic-missing-local-proxy'}
Assert-True ($probeResult.ok -and $probeResult.proxy.StartsWith('file:///') -and !$probeResult.proxy.Contains(',')) 'caller local-only proxy remains offline'
$probeResult=Environment-Probe @{GOPROXY='https://proxy.golang.org,direct'}
Assert-True ($probeResult.ok -and $probeResult.proxy.StartsWith('file:///') -and $probeResult.proxy.EndsWith(',https://proxy.golang.org,direct')) 'online entry point prepends verified local proxy'
$probeResult=Environment-Probe @{GONOSUMDB='';GOPRIVATE='private.invalid/*'}
Assert-True ($probeResult.ok -and $probeResult.noSum -ceq "private.invalid/*,$module") 'effective GONOSUMDB inherits and preserves GOPRIVATE'
$probeResult=Environment-Probe @{GONOPROXY='';GOPRIVATE='github.com/xtls/*'}
Assert-True (!$probeResult.ok -and $probeResult.error -ceq 'xray_patch_no_proxy_conflict') 'effective GONOPROXY detects GOPRIVATE bypass'
$probeResult=Environment-Probe @{GONOPROXY='github.com/[x]tls'}
Assert-True (!$probeResult.ok -and $probeResult.error -ceq 'xray_patch_no_proxy_conflict') 'explicit class pattern cannot bypass proxy'
$probeResult=Environment-Probe @{GOFLAGS='-overlay=unreviewed.json'}
Assert-True (!$probeResult.ok -and $probeResult.error -ceq 'xray_patch_source_override_not_allowed') 'source overlay rejected'
$probeResult=Environment-Probe @{GOFLAGS='-modfile=other.mod'}
Assert-True (!$probeResult.ok -and $probeResult.error -ceq 'xray_patch_source_override_not_allowed') 'alternate module pins rejected'
TextFile (Join-Path $envRoot 'native/windows/go.mod') "module example.invalid/windows`nrequire (`n $module v1.0.0`n)`n"
$probeResult=Environment-Probe @{}
Assert-True (!$probeResult.ok -and $probeResult.error -ceq 'xray_patch_native_pins_disagree') 'mixed platform versions rejected'
Write-Host "Xray patch fixtures: $checks checks PASS. All fixture files remain under $root"
