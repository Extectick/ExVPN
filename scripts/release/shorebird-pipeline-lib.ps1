# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Dot-sourcing has no SDK, network, signing or cloud side effects.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'shorebird-recovery-lib.ps1')

function Get-ShorebirdPolicy {
    [ordered]@{
        appId='ea97a683-02e5-4d86-9aa1-779d6b4bc81e'; track='beta'
        cliVersion='1.6.129'; cliRevision='9fe1370bdd1d2f117cc08c57ae416b794ed92440'
        flutterRevision='5bef02a16146a0effc07da4acccaafe90a2739ce'
        engineRevision='4b936a0c03e13389ddfb1ac48823f187964975c2'
    }
}

function Invoke-ShorebirdGit([string]$Repository, [string[]]$Arguments) {
    $result = & git -c core.fsmonitor=false -c core.quotepath=false -C $Repository @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'shorebird_git_failed' }
    ($result -join "`n").TrimEnd("`r", "`n")
}

function Get-ShorebirdSourceCommit([string]$Repository,[ValidateSet('source_guard','after_checks','after_sdk')][string]$Phase='source_guard') {
    $sha = Invoke-ShorebirdGit $Repository @('rev-parse','--verify','HEAD')
    $status = Invoke-ShorebirdGit $Repository @('status','--porcelain=v1','-z','--untracked-files=normal')
    if ($sha -cnotmatch '^[a-f0-9]{40}$' -or $status) {
        if ($sha -cmatch '^[a-f0-9]{40}$' -and $status) {
            try { $null=Write-ShorebirdSourceReceipt $Repository $sha $Phase $status } catch { }
        }
        throw 'shorebird_source_not_clean'
    }
    $sha
}

function Test-ShorebirdPublicSourcePath([string]$Path) {
    if (!$Path -or $Path.Length -gt 240 -or $Path -cnotmatch '^[A-Za-z0-9_. /-]+$') { return $false }
    $parts=$Path.Split('/')
    if ($parts[0] -cnotin @('apps','packages','native','scripts','config','docs','design','.github') -and
        $Path -cnotin @('AGENTS.md','README.md','LICENSE','NOTICE','.gitignore','.gitattributes')) { return $false }
    foreach ($part in $parts) {
        if (!$part -or $part -in @('.','..','.private','.tools','.cache','artifacts','secrets','credentials') -or
            $part -match '[. ]$' -or ($part.StartsWith('.') -and $part -cnotin @('.github','.metadata','.gitignore','.gitattributes'))) { return $false }
    }
    $true
}

function Write-ShorebirdSourceReceipt([string]$Repository,[ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
    [ValidateSet('source_guard','after_checks','after_sdk')][string]$Phase,[string]$Porcelain) {
    # This report is public: fixed fields, bounded count/path/bytes, never raw
    # Git output, file contents, diff hunks, private paths or environment values.
    $root=[IO.Path]::GetFullPath($Repository)
    $destination=Join-Path $root 'artifacts/shorebird-source'
    $ancestor=$destination
    while (!(Test-Path -LiteralPath $ancestor)) { $ancestor=[IO.Path]::GetDirectoryName($ancestor) }
    Assert-AuditNoLinks $ancestor
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Assert-AuditNoLinks $destination
    $truncated=$Porcelain.Length -gt 128KB
    if ($truncated) {
        $Porcelain=$Porcelain.Substring(0,128KB)
        $lastSeparator=$Porcelain.LastIndexOf([char]0)
        $Porcelain=$(if ($lastSeparator -ge 0) {$Porcelain.Substring(0,$lastSeparator+1)} else {''})
    }
    $tokens=$Porcelain.Split([char]0)
    $entries=[Collections.Generic.List[object]]::new()
    $omitted=0;$observed=0;[long]$hashBudget=64MB
    for ($index=0;$index -lt $tokens.Count;$index++) {
        $token=$tokens[$index]
        if (!$token) { continue }
        $observed++
        if ($token.Length -lt 4 -or $token.Substring(0,3) -cnotmatch '^[ MADRCU?!T]{2} $') { $omitted++;continue }
        $state=$token.Substring(0,2);$path=$token.Substring(3).TrimEnd('/')
        # In porcelain -z rename/copy entries the destination is followed by
        # a second NUL-delimited original path. Do not mistake it for a status.
        if ($state -match '[RC]') { $index++ }
        if ($entries.Count -ge 64) { $omitted++;$truncated=$true;continue }
        if (!(Test-ShorebirdPublicSourcePath $path)) { $omitted++;continue }
        $full=[IO.Path]::GetFullPath((Join-Path $root $path))
        if (!$full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { $omitted++;continue }
        $hash=$null;$bytes=$null;$hashState='missing'
        if (Test-Path -LiteralPath $full) {
            try {
                Assert-AuditNoLinks $full
                $item=Get-Item -LiteralPath $full -Force
                if ($item.PSIsContainer) { $hashState='directory' }
                elseif ($item.Length -gt 16MB -or $item.Length -gt $hashBudget) { $hashState='size_budget' }
                else {
                    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                    try {
                        if ($stream.Length -gt 16MB -or $stream.Length -gt $hashBudget) { $hashState='size_budget' }
                        else {
                            $bytes=$stream.Length;$hash=Get-AuditStreamHash $stream $bytes;$hashBudget-=$bytes;$hashState='sha256'
                        }
                    } finally { $stream.Dispose() }
                }
            } catch { $hashState='unavailable' }
        }
        $entries.Add([ordered]@{status=$state;path=$path;sha256=$hash;bytes=$bytes;hashState=$hashState})
    }
    $receipt=[ordered]@{schemaVersion=1;action='source_guard';sourceCommit=$SourceCommit;phase=$Phase;clean=$false
        observedCount=$observed;omittedCount=$omitted;truncated=$truncated;entries=$entries.ToArray()
        distributionApproved=$false;rawDiagnosticsIncluded=$false}
    $path=Join-Path $destination ('source-'+[guid]::NewGuid().ToString('N')+'.json')
    $temporary=$path+'.tmp-'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary,($receipt | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$path)
    $path
}

function Assert-ShorebirdPatchPaths([string[]]$Paths) {
    if (!$Paths.Count) { throw 'shorebird_patch_has_no_dart_changes' }
    $production = 0
    foreach ($path in $Paths) {
        if ($path -match '\.\.|//|[\x00-\x1f\\:]') { throw 'shorebird_patch_path_invalid' }
        # Explicit project-owned Dart trees only. Dependencies, native runner,
        # assets, manifests, plugin registration, pins and build identity stay fixed.
        if ($path -cmatch '^apps/exvpn/lib/[a-zA-Z0-9_/-]+\.dart$' -and
            $path -cne 'apps/exvpn/lib/build_identity.dart') { $production++; continue }
        if ($path -cmatch '^packages/(?:exvpn_domain|exvpn_client_state|exvpn_updates)/lib/[a-zA-Z0-9_/-]+\.dart$') {
            $production++; continue
        }
        # Tests and prose do not enter the app. Tooling/config changes still fail.
        if ($path -cmatch '^(?:apps/exvpn|packages/(?:exvpn_domain|exvpn_client_state|exvpn_updates))/test/[a-zA-Z0-9_/-]+\.dart$' -or
            $path -cmatch '^docs/[a-zA-Z0-9_./-]+\.md$' -or
            $path -cmatch '^docs/evidence/(?:[a-zA-Z0-9_.-]+/)*[a-zA-Z0-9_.-]+\.json$') { continue }
        throw 'shorebird_patch_non_dart_change'
    }
    if (!$production) { throw 'shorebird_patch_has_no_dart_changes' }
}

function Get-ShorebirdCli([string]$Repository) {
    $policy = Get-ShorebirdPolicy
    $pin = Get-Content -LiteralPath (Join-Path $Repository 'scripts/bootstrap/shorebird.lock.json') -Raw | ConvertFrom-Json
    if ($pin.cli.version -cne $policy.cliVersion -or $pin.cli.revision -cne $policy.cliRevision -or
        $pin.flutter.revision -cne $policy.flutterRevision -or $pin.flutter.engineRevision -cne $policy.engineRevision) {
        throw 'shorebird_pin_mismatch'
    }
    $root = Join-Path $Repository ".tools/$($pin.cli.folder)"
    Assert-ReleaseRuntimeCheckout $root $policy.cliRevision
    foreach ($entry in @(@('bin/shorebird.ps1',$pin.cli.powershellEntrypointSha256),@('pubspec.lock',$pin.cli.pubspecLockSha256))) {
        $path = Join-Path $root $entry[0]; Assert-AuditNoLinks $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry[1]) { throw 'shorebird_cli_pin_mismatch' }
    }
    foreach ($relative in @('bin/cache/shorebird.snapshot','bin/cache/shorebird.stamp','bin/internal/flutter.version')) {
        Assert-AuditNoLinks (Join-Path $root $relative)
        if (!(Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) { throw 'shorebird_cli_cache_unprepared' }
    }
    if ([IO.File]::ReadAllText((Join-Path $root 'bin/cache/shorebird.stamp')).Trim() -cne $policy.cliRevision -or
        [IO.File]::ReadAllText((Join-Path $root 'bin/internal/flutter.version')).Trim() -cne $policy.flutterRevision -or
        (Get-Item -LiteralPath (Join-Path $root 'packages/shorebird_cli/pubspec.yaml')).LastWriteTimeUtc -gt
        (Get-Item -LiteralPath (Join-Path $root 'pubspec.lock')).LastWriteTimeUtc) { throw 'shorebird_cli_cache_stale' }
    Join-Path $root 'bin/shorebird.ps1'
}

function Assert-ShorebirdPatchSource([string]$Repository, [string]$BaseCommit) {
    if ($BaseCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'shorebird_base_commit_invalid' }
    $head = Get-ShorebirdSourceCommit $Repository
    $null = Invoke-ShorebirdGit $Repository @('merge-base','--is-ancestor',$BaseCommit,$head)
    $raw = Invoke-ShorebirdGit $Repository @('diff','--no-renames','--name-only',"$BaseCommit..$head",'--')
    $paths = @($raw -split "`n" | Where-Object { $_ })
    Assert-ShorebirdPatchPaths $paths
    foreach ($path in $paths) {
        if ($path -match '\.\.|//|[\x00-\x1f\\:]') { throw 'shorebird_patch_path_invalid' }
        foreach ($revision in @($BaseCommit,$head)) {
            $entry = Invoke-ShorebirdGit $Repository @('ls-tree',$revision,'--',$path)
            if ($entry -and $entry -cnotmatch '^100644 blob [a-f0-9]{40}\t') { throw 'shorebird_patch_file_mode_invalid' }
            if ($entry -and $path -cmatch '^docs/evidence/.*\.json$') {
                $size=Invoke-ShorebirdGit $Repository @('cat-file','-s',"${revision}:$path")
                if ($size -cnotmatch '^[0-9]+$' -or [long]$size -gt 1MB) { throw 'shorebird_patch_evidence_size_invalid' }
            }
        }
    }
    [ordered]@{baseCommit=$BaseCommit;sourceCommit=$head;paths=$paths;onlyDartProductionChanges=$true}
}

function Assert-ShorebirdJson($Envelope, [string]$Command) {
    $policy = Get-ShorebirdPolicy
    if ($null -eq $Envelope -or $Envelope.status -cne 'success' -or
        $Envelope.meta.version -cne $policy.cliVersion -or $Envelope.meta.command -cne $Command -or
        $null -eq $Envelope.data) { throw 'shorebird_cli_response_invalid' }
    $Envelope.data
}

function Get-ShorebirdCliFailure([string]$Path,[string]$Command,[int]$ExitCode) {
    if($ExitCode -eq 0){throw 'shorebird_cli_failure_requires_nonzero_exit'}
    $policy=Get-ShorebirdPolicy
    $allowedCommands=@('version','release','patch','releases info','patches info','patches rollback')
    $markers=Get-ShorebirdStderrMarkers ([IO.Path]::ChangeExtension($Path,'.log'))
    $safe=[ordered]@{schemaVersion=1;cliVersion=$policy.cliVersion;command=$(if($Command -cin $allowedCommands){$Command}else{'other'});errorCode='unknown';exitCode=$ExitCode;stderrMarker=$markers.stderrMarker;stageMarker=$markers.stageMarker}
    if($Command -cnotin $allowedCommands){return $safe}
    try {
        if(!(Test-Path -LiteralPath $Path -PathType Leaf)){return $safe}
        Assert-AuditNoLinks $Path
        $file=Get-Item -LiteralPath $Path -Force
        if($file.Length -le 0 -or $file.Length -gt 4MB){return $safe}
        $body=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if($body -isnot [Collections.IDictionary] -or $body['status'] -isnot [string] -or $body['status'] -cne 'error' -or
            $body['meta'] -isnot [Collections.IDictionary] -or $body['error'] -isnot [Collections.IDictionary] -or
            $body['meta']['version'] -isnot [string] -or $body['meta']['command'] -isnot [string] -or
            $body['meta']['version'] -cne $policy.cliVersion -or $body['meta']['command'] -cne $Command){return $safe}
        $code=$body['error']['code']
        if($code -is [string] -and $code -cin @('process_exit','usage_error','software_error','fetch_failed','precondition_failed','interactive_prompt_required')){$safe.errorCode=$code}
    } catch {
        # Raw messages, hints, details and unrecognized envelopes stay private.
        return $safe
    }
    $safe
}

function Write-ShorebirdCliFailure([string]$Repository,$Failure) {
    if($Failure.exitCode -isnot [int] -or $Failure.exitCode -eq 0){throw 'shorebird_cli_failure_requires_nonzero_exit'}
    $directory=Join-Path ([IO.Path]::GetFullPath($Repository)) 'artifacts/shorebird-recovery'
    $ancestor=$directory
    while(!(Test-Path -LiteralPath $ancestor)){$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    Assert-AuditNoLinks $ancestor
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Assert-AuditNoLinks $directory
    # Only this function's fixed safe fields; never serialize an API object.
    $safe=[ordered]@{schemaVersion=1;cliVersion=(Get-ShorebirdPolicy).cliVersion
        command=$(if($Failure.command -is [string] -and $Failure.command -cin @('version','release','patch','releases info','patches info','patches rollback')){$Failure.command}else{'other'})
        errorCode=$(if($Failure.errorCode -is [string] -and $Failure.errorCode -cin @('process_exit','usage_error','software_error','fetch_failed','precondition_failed','interactive_prompt_required')){$Failure.errorCode}else{'unknown'})
        exitCode=[int]$Failure.exitCode
        stderrMarker=$(if($Failure.stderrMarker -is [string] -and $Failure.stderrMarker -cin @('disk_space_marker','jvm_memory_marker','compiler_error_marker','gradle_daemon_marker')){$Failure.stderrMarker}else{'unknown'})
        stageMarker=$(if($Failure.stageMarker -is [string] -and $Failure.stageMarker -cin @('aab','apk')){$Failure.stageMarker}else{'unknown'})}
    $path=Join-Path $directory ('cli-error-'+[guid]::NewGuid().ToString('N')+'.json')
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($safe | ConvertTo-Json -Depth 3))
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    $path
}

function Get-ShorebirdStderrMarkers([string]$Path) {
    $safe=[ordered]@{stderrMarker='unknown';stageMarker='unknown'}
    $stream=$null
    try {
        if(!(Test-Path -LiteralPath $Path -PathType Leaf)){return $safe}
        Assert-AuditNoLinks $Path
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        # Seek before reading, even for a very large log. Never copy raw tail,
        # matched text, paths, arguments or captures into a diagnostic receipt.
        [void]$stream.Seek([Math]::Max(0L,$stream.Length-256KB),[IO.SeekOrigin]::Begin)
        $buffer=[byte[]]::new(256KB);$read=0
        while($read -lt $buffer.Length){
            $count=$stream.Read($buffer,$read,$buffer.Length-$read)
            if($count -eq 0){break};$read+=$count
        }
        $tail=[Text.Encoding]::UTF8.GetString($buffer,0,$read)
        # Priority only classifies observed markers, never proves a cause.
        if($tail.Contains('No space left on device') -or $tail.Contains('There is not enough space on the disk')){$safe.stderrMarker='disk_space_marker'}
        elseif($tail.Contains('java.lang.OutOfMemoryError') -or $tail.Contains('Java heap space') -or $tail.Contains('GC overhead limit exceeded') -or $tail.Contains('Could not reserve enough space for object heap')){$safe.stderrMarker='jvm_memory_marker'}
        elseif($tail.Contains('Compilation error. See log for more details') -or $tail.Contains('Compilation failed; see the compiler error output for details.') -or $tail.Contains('Dart compilation failed')){$safe.stderrMarker='compiler_error_marker'}
        elseif($tail.Contains('Gradle build daemon disappeared unexpectedly') -or $tail.Contains('DaemonDisappearedException')){$safe.stderrMarker='gradle_daemon_marker'}
        $aab=[Math]::Max($tail.LastIndexOf('Building Android app bundle with Flutter',[StringComparison]::Ordinal),$tail.LastIndexOf('Failed to build AAB.',[StringComparison]::Ordinal))
        $apk=[Math]::Max($tail.LastIndexOf('Building APK',[StringComparison]::Ordinal),$tail.LastIndexOf('Failed to build APK.',[StringComparison]::Ordinal))
        if($aab -ge 0 -and $aab -gt $apk){$safe.stageMarker='aab'}elseif($apk -ge 0){$safe.stageMarker='apk'}
    } catch {return $safe}
    finally {if($stream){$stream.Dispose()}}
    $safe
}

function Invoke-ShorebirdJson([string]$Cli, [string[]]$Arguments, [string]$Command, [string]$PrivateDirectory, [string]$Name) {
    # stdout can contain API URLs/details on errors. Never echo it, even when
    # parsing fails. The caller exports an allowlisted receipt, never raw JSON.
    $stdout = Join-Path $PrivateDirectory "$Name.json"
    $stderr = Join-Path $PrivateDirectory "$Name.log"
    $oldSystemConfig=$env:GIT_CONFIG_SYSTEM
    try {
        # The pinned PS entrypoint runs `git config --system core.longpaths`
        # and otherwise prints a warning before JSON. A process-only include
        # overlay preserves the real config and avoids changing system/global
        # files or accepting non-JSON prefixes as valid output.
        $env:GIT_CONFIG_SYSTEM=New-ShorebirdGitOverlay $PrivateDirectory
        & $Cli --json @Arguments 1> $stdout 2> $stderr
        $code=$LASTEXITCODE
    } finally { $env:GIT_CONFIG_SYSTEM=$oldSystemConfig }
    if ($code -ne 0) {
        $failure=Get-ShorebirdCliFailure $stdout $Command $code
        $failureRepository=Invoke-ShorebirdGit $PrivateDirectory @('rev-parse','--show-toplevel')
        $null=Write-ShorebirdCliFailure $failureRepository $failure
        throw 'shorebird_cli_failed'
    }
    if (!(Test-Path -LiteralPath $stdout -PathType Leaf) -or (Get-Item -LiteralPath $stdout).Length -gt 4MB) {
        throw 'shorebird_cli_response_invalid'
    }
    try { $envelope = Get-Content -LiteralPath $stdout -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'shorebird_cli_response_invalid' }
    Assert-ShorebirdJson $envelope $Command
}

function New-ShorebirdGitOverlay([string]$PrivateDirectory) {
    $original=$env:GIT_CONFIG_SYSTEM
    if (!$original) {
        $origins=@(& git config --system --no-includes --show-origin --name-only --list 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'shorebird_git_system_config_unreadable' }
        $paths=@($origins | ForEach-Object {
            if ($_ -cnotmatch '^file:([^\t\r\n]+)\t[^\r\n]+$') { throw 'shorebird_git_system_config_origin_invalid' }
            $Matches[1]
        } | Sort-Object -Unique)
        if ($paths.Count -gt 1) { throw 'shorebird_git_system_config_origin_ambiguous' }
        if ($paths.Count) { $original=$paths[0] }
    }
    $text=''
    if ($original) {
        if ($original -match '[\r\n\x00]' -or ![IO.Path]::IsPathFullyQualified($original)) { throw 'shorebird_git_system_config_origin_invalid' }
        Assert-AuditNoLinks $original
        $escaped=$original.Replace('\','\\').Replace('"','\"')
        $text="[include]`n`tpath = `"$escaped`"`n"
    }
    $text+="[core]`n`tlongpaths = true`n"
    $path=Join-Path $PrivateDirectory ('git-system-' + [guid]::NewGuid().ToString('N') + '.config')
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
    $path
}

function Initialize-ShorebirdCliCache([string]$Cli,[string]$PrivateDirectory) {
    # Preparation alone may run the official cold bootstrap. Its chatter is
    # intentionally private/non-JSON; every subsequent command stays strict.
    $oldSystemConfig=$env:GIT_CONFIG_SYSTEM
    $oldStorage=$env:FLUTTER_STORAGE_BASE_URL
    try {
        $env:GIT_CONFIG_SYSTEM=New-ShorebirdGitOverlay $PrivateDirectory
        & $Cli --version *> (Join-Path $PrivateDirectory 'bootstrap-private.log')
        $code=$LASTEXITCODE
    } finally {
        $env:GIT_CONFIG_SYSTEM=$oldSystemConfig
        # The pinned cold bootstrap removes this process variable after its
        # Flutter download. Do not let that change escape into later commands.
        $env:FLUTTER_STORAGE_BASE_URL=$oldStorage
    }
    if ($code -ne 0) { throw 'shorebird_cli_bootstrap_failed' }
}

function Get-ShorebirdPinnedFlutter([string]$Repository) {
    $policy=Get-ShorebirdPolicy
    $sdk=Join-Path $Repository ".tools/shorebird-$($policy.cliVersion)/bin/cache/flutter/$($policy.flutterRevision)"
    Assert-ReleaseRuntimeCheckout $sdk $policy.flutterRevision
    $engine=Invoke-ReleaseRuntimeGit $sdk @('show',"$($policy.flutterRevision):bin/internal/engine.version")
    $enginePath=Join-Path $sdk 'bin/internal/engine.version'
    Assert-AuditNoLinks $enginePath
    if ($engine -cne $policy.engineRevision -or [IO.File]::ReadAllText($enginePath).Trim() -cne $engine) {
        throw 'shorebird_flutter_pin_mismatch'
    }
    $flutter=Join-Path $sdk 'bin/flutter.bat'
    Assert-AuditNoLinks $flutter
    if (!(Test-Path -LiteralPath $flutter -PathType Leaf)) { throw 'shorebird_flutter_pin_mismatch' }
    $flutter
}

function Invoke-ShorebirdFlutterPrecache([string]$Repository,[ValidateSet('Android','Windows')][string]$Target,[string]$PrivateDirectory) {
    $flutter=Get-ShorebirdPinnedFlutter $Repository
    $oldStorage=$env:FLUTTER_STORAGE_BASE_URL
    try {
        $env:FLUTTER_STORAGE_BASE_URL='https://download.shorebird.dev'
        # `shorebird flutter` manages config/versions; it is not a Flutter
        # passthrough. Invoke only the verified, exact SDK selected above.
        & $flutter precache $(if ($Target -ceq 'Android') {'--android'} else {'--windows'}) *> (Join-Path $PrivateDirectory 'precache.log')
        if ($LASTEXITCODE -ne 0) { throw 'shorebird_precache_failed' }
    } finally { $env:FLUTTER_STORAGE_BASE_URL=$oldStorage }
}

function Get-ShorebirdPrepareErrorCode([string]$Message) {
    if ($Message -cin @('shorebird_pin_mismatch','shorebird_git_failed','shorebird_cli_pin_mismatch',
        'shorebird_cli_bootstrap_failed','shorebird_cli_cache_unprepared','shorebird_cli_cache_stale',
        'shorebird_cli_failed','shorebird_cli_response_invalid','shorebird_bootstrap_version_mismatch',
        'shorebird_flutter_pin_mismatch','shorebird_precache_failed','shorebird_prepare_source_invalid',
        'flutter_runtime_checkout_mismatch','flutter_runtime_checkout_modified','flutter_runtime_engine_pin_mismatch',
        'flutter_runtime_engine_stamp_mismatch','flutter_runtime_dart_version_mismatch','flutter_runtime_version_metadata_mismatch',
        'linked_input_not_allowed','audit_tool_timeout','audit_tool_failed')) { return $Message }
    'shorebird_prepare_operation_failed'
}

function Write-ShorebirdPrepareReceipt {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
        [ValidatePattern('^$|^[a-f0-9]{40}$')][string]$SourceCommit='',
        [Parameter(Mandatory)][ValidateSet('started','ready','failed')][string]$Status,
        [string]$Phase='other',[string]$ErrorCode='',[string]$Path=''
    )
    $root=[IO.Path]::GetFullPath((Join-Path $Repository 'artifacts/shorebird-prepare'))
    if (!(Test-Path -LiteralPath $root)) {
        $ancestor=[IO.Path]::GetDirectoryName($root)
        while (!(Test-Path -LiteralPath $ancestor)) { $ancestor=[IO.Path]::GetDirectoryName($ancestor) }
        Assert-AuditNoLinks $ancestor
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    Assert-AuditNoLinks $root
    if (!$Path) { $Path=Join-Path $root ('prepare-'+$Target.ToLowerInvariant()+'-'+[guid]::NewGuid().ToString('N')+'.json') }
    $Path=[IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($Path) -cne $root -or [IO.Path]::GetFileName($Path) -cnotmatch '^prepare-(android|windows)-[a-f0-9]{32}\.json$') { throw 'shorebird_prepare_receipt_path_invalid' }
    if (Test-Path -LiteralPath $Path) { Assert-AuditNoLinks $Path }
    if ($Phase -cnotin @('source_identity','private_directory','cli_pin','cli_checkout','cli_bootstrap','cli_cache','cli_version','flutter_precache','runtime_validation','complete')) { $Phase='other' }
    $policy=Get-ShorebirdPolicy
    $safe=[ordered]@{
        schemaVersion=1;action='prepare';target=$Target;sourceCommit=$SourceCommit;status=$Status;phase=$Phase
        errorCode=$(if ($Status -ceq 'failed') { Get-ShorebirdPrepareErrorCode $ErrorCode } else { $null })
        cliVersion=$policy.cliVersion;cliRevision=$policy.cliRevision;flutterRevision=$policy.flutterRevision;engineRevision=$policy.engineRevision
        nativeBuildStarted=$false;cloudRegistrationAttempted=$false;distributionApproved=$false
    }
    $temporary=$Path+'.tmp-'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary,($safe | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$Path,$true)
    $Path
}

function Write-ShorebirdRecovery {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][ValidateSet('base','patch')][string]$Action,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$Version,
        [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
        [Parameter(Mandatory)][ValidateSet('attempting','cloud_registered','ready','failed')][string]$Status,
        [Parameter(Mandatory)][ValidateSet('unknown','registered')][string]$CloudOutcome,
        [string]$Phase='other',
        [string]$Subphase='other',[string]$ErrorCode='',[string]$FailureLeaf='',[int]$FailureLine=0,
        [long]$ReleaseId=0,[long]$PatchId=0,[int]$PatchNumber=0,
        [ValidatePattern('^$|^[a-f0-9]{40}$')][string]$BaseSourceCommit='',
        [string]$Path=''
    )
    $root=[IO.Path]::GetFullPath((Join-Path $Repository 'artifacts/shorebird-recovery'))
    if (!(Test-Path -LiteralPath $root)) {
        $ancestor=[IO.Path]::GetDirectoryName($root)
        while (!(Test-Path -LiteralPath $ancestor)) { $ancestor=[IO.Path]::GetDirectoryName($ancestor) }
        Assert-AuditNoLinks $ancestor
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    Assert-AuditNoLinks $root
    if (!$Path) { $Path=Join-Path $root ($Action+'-'+$Target.ToLowerInvariant()+'-'+[guid]::NewGuid().ToString('N')+'.json') }
    $Path=[IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($Path) -cne $root -or [IO.Path]::GetFileName($Path) -cnotmatch '^(base|patch)-(android|windows)-[a-f0-9]{32}\.json$') { throw 'shorebird_recovery_path_invalid' }
    if (Test-Path -LiteralPath $Path) { Assert-AuditNoLinks $Path }
    if ($Phase -cnotin @('environment','shorebird_release','cloud_recovery','package_audit','promotion','patch','final_inputs')) { $Phase='other' }
    if ($Subphase -cnotin @('pub','android_signer','android_notices','maven_hook','release','lock_check','runtime_check',
        'windows_ui_binding','windows_msvc','windows_installer','windows_notice_binding','windows_audit','android_runtime',
        'android_jvm','android_identity','android_notice_supplement','source_final','promotion','recovery_equivalence',
        'recovery_readback','recovery_artifact','recovery_download')) {$Subphase='other'}
    if ($CloudOutcome -ceq 'registered' -and ($ReleaseId -le 0 -or ($Action -ceq 'patch' -and ($PatchId -le 0 -or $PatchNumber -le 0)))) { throw 'shorebird_recovery_identity_invalid' }
    # Never serialize exceptions, raw API responses, arguments, environment,
    # paths, credentials, or arbitrary caller fields. Unknown means read back
    # cloud state before retrying, never assume that upload did not happen.
    $safe=[ordered]@{
        schemaVersion=1;action=$Action;appId=(Get-ShorebirdPolicy).appId;version=$Version;target=$Target
        sourceCommit=$SourceCommit;baseSourceCommit=$BaseSourceCommit;status=$Status;phase=$Phase;cloudOutcome=$CloudOutcome
        subphase=$Subphase;errorCode=$(if($Status -ceq 'failed'){Get-ShorebirdSafeFailureCode $ErrorCode}else{$null})
        failureLeaf=$(if($Status -ceq 'failed'){Get-ShorebirdSafeFailureLeaf $FailureLeaf}else{''})
        failureLine=$(if($Status -ceq 'failed' -and $FailureLine -gt 0 -and $FailureLine -le 20000){$FailureLine}else{0})
        releaseId=$(if ($ReleaseId -gt 0) {$ReleaseId} else {$null})
        patchId=$(if ($PatchId -gt 0) {$PatchId} else {$null});patchNumber=$(if ($PatchNumber -gt 0) {$PatchNumber} else {$null})
        distributionApproved=$false;requiresCloudReadbackBeforeRetry=$true
    }
    $temporary=$Path+'.tmp-'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary,($safe | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$Path,$true)
    $Path
}

function Assert-ShorebirdCloudRelease($Release, [string]$Version, [string]$Target, [long]$ExpectedId = 0) {
    $policy = Get-ShorebirdPolicy
    $platform = $Target.ToLowerInvariant()
    if (!$Release -or $Release.id -isnot [long] -and $Release.id -isnot [int] -or $Release.id -le 0 -or
        ($ExpectedId -gt 0 -and $Release.id -ne $ExpectedId) -or $Release.app_id -cne $policy.appId -or
        $Release.version -cne $Version -or $Release.flutter_revision -cne $policy.flutterRevision -or
        $Release.platform_statuses[$platform] -cne 'active') { throw 'shorebird_cloud_base_mismatch' }
}

function Assert-ShorebirdBaseReceipt($Receipt, [string]$Version, [string]$Target) {
    $policy = Get-ShorebirdPolicy
    if (!$Receipt -or $Receipt.schemaVersion -ne 2 -or $Receipt.action -cne 'base' -or
        $Receipt.version -cne $Version -or $Receipt.target -cne $Target -or $Receipt.track -cne 'beta' -or
        $Receipt.appId -cne $policy.appId -or $Receipt.published -ne $true -or $Receipt.auditAccepted -ne $true -or
        $Receipt.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $Receipt.releaseId -le 0 -or
        $Receipt.publicKeySha256 -cnotmatch '^[a-f0-9]{64}$' -or $Receipt.autoUpdate -ne $false -or
        $Receipt.patchVerification -cne 'strict' -or $Receipt.runtime.identity.kind -cne 'shorebird' -or
        $Receipt.runtime.identity.target -cne $Target -or $Receipt.runtime.identity.buildMode -cne 'release' -or
        $Receipt.runtime.identity.flutterRevision -cne $policy.flutterRevision -or
        $Receipt.runtime.identity.engineRevision -cne $policy.engineRevision -or
        $Receipt.runtime.identity.cli.revision -cne $policy.cliRevision -or !$Receipt.packagedRuntime.engineBytesBound) {
        throw 'shorebird_base_receipt_invalid'
    }
    $compiled=Get-ReleaseRuntimeField $Receipt 'compiledSourceCommit'
    $recovery=Get-ReleaseRuntimeField $Receipt 'recoveryProof'
    if($compiled){
        if($compiled -cnotmatch '^[a-f0-9]{40}$'){throw 'shorebird_base_receipt_invalid'}
        if($recovery){
            if($Target -cne 'Windows' -or $Version -cne (Get-ShorebirdWindowsRecoveryPolicy).version -or $compiled -cne $recovery.compiledSourceCommit){throw 'shorebird_base_receipt_invalid'}
            Assert-ShorebirdRecoveryProof $recovery $Receipt.sourceCommit
        } elseif($compiled -cne $Receipt.sourceCommit){throw 'shorebird_base_receipt_invalid'}
    } elseif($recovery){throw 'shorebird_base_receipt_invalid'}
    Assert-ShorebirdPatchArtifacts $Receipt.baseAot $Target
}

function Assert-ShorebirdReceiptFiles([string]$ReceiptPath, $Receipt) {
    $root = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($ReceiptPath))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (!$Receipt.files.Count) { throw 'shorebird_base_files_missing' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Receipt.files) {
        if ($file.path -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or
            $file.path -match '(?:^|/)\.{1,2}(?:/|$)' -or !$seen.Add($file.path) -or
            $file.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'shorebird_base_file_invalid' }
        $path = [IO.Path]::GetFullPath((Join-Path $root $file.path))
        if (!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'shorebird_base_file_invalid' }
        Assert-AuditNoLinks $path
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) {
            throw 'shorebird_base_file_changed'
        }
    }
}

function New-ShorebirdPrivateDirectory([string]$Repository, [string]$Kind) {
    $parent = Join-Path $Repository '.private/shorebird-builds'
    $ancestor = $parent
    while (!(Test-Path -LiteralPath $ancestor)) { $ancestor = [IO.Path]::GetDirectoryName($ancestor) }
    Assert-AuditNoLinks $ancestor
    $path = Join-Path $parent ($Kind + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    # Current user + SYSTEM only; keys and raw cloud diagnostics never inherit
    # broader repository permissions. Existing directories are never reused.
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true,$false)
    foreach ($principal in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
    $path
}

function Get-ShorebirdPublicKey([string]$Repository) {
    $path = Join-Path $Repository 'config/signing/shorebird-beta-public.pem'
    Assert-AuditNoLinks $path
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem([IO.File]::ReadAllText($path))
        if ($rsa.KeySize -ne 4096) { throw 'shorebird_public_key_invalid' }
        [ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();encoded=[Convert]::ToBase64String($rsa.ExportRSAPublicKey())}
    } finally { $rsa.Dispose() }
}

function Export-ShorebirdPrivateKey([string]$Repository, [string]$PrivateDirectory) {
    $bytes = $null; $rsa = [Security.Cryptography.RSA]::Create()
    try {
        if ($env:EXVPN_SHOREBIRD_PRIVATE_KEY_BASE64) {
            $bytes = [Convert]::FromBase64String($env:EXVPN_SHOREBIRD_PRIVATE_KEY_BASE64)
        } else {
            $inputPath = Join-Path $Repository '.private/signing/shorebird/beta-private.dpapi'
            Assert-AuditNoLinks $inputPath
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($inputPath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $read = 0; $rsa.ImportPkcs8PrivateKey($bytes,[ref]$read)
        if ($read -ne $bytes.Length -or $rsa.KeySize -ne 4096) { throw 'shorebird_private_key_invalid' }
        $public = Get-ShorebirdPublicKey $Repository
        if ([Convert]::ToBase64String($rsa.ExportRSAPublicKey()) -cne $public.encoded) { throw 'shorebird_signing_key_mismatch' }
        $path = Join-Path $PrivateDirectory 'patch-private.pem'
        # CreateNew and the restricted, unique directory prevent substitution.
        $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $pemBytes = [Text.Encoding]::UTF8.GetBytes($rsa.ExportPkcs8PrivateKeyPem())
            try { $stream.Write($pemBytes,0,$pemBytes.Length) }
            finally { [Security.Cryptography.CryptographicOperations]::ZeroMemory($pemBytes) }
        } finally { $stream.Dispose() }
        $path
    } finally {
        if ($bytes) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes) }
        $rsa.Dispose()
    }
}

function Get-ShorebirdPatchArguments([string]$Target,[string]$Version,[string]$PublicKey,[string]$PrivateKey,[switch]$PublishCloud) {
    if ($Target -cnotin @('Android','Windows') -or $Version -cnotmatch '^\d+\.\d+\.\d+\+[1-9]\d*$') { throw 'shorebird_patch_identity_invalid' }
    $args = @('patch',$Target.ToLowerInvariant(),"--release-version=$Version",'--track=beta',
        "--public-key-path=$PublicKey","--private-key-path=$PrivateKey",'--dart-define=EXVPN_DART_UPDATE_TRACK=beta','--dart-define=EXVPN_DEMO=false')
    if (!$PublishCloud) { $args += '--dry-run' }
    $args += @('--',$(if ($Target -ceq 'Android') { '--pub' } else { '--no-pub' }))
    # PatchCommand does not parse target-platform; it belongs to Flutter after
    # the forwarding separator (ReleaseCommand has its own separate option).
    if ($Target -ceq 'Android') { $args += '--target-platform=android-arm64,android-x64' }
    $args
}

function Assert-ShorebirdPatchArtifacts($Artifacts,[string]$Target) {
    $expected = @(if ($Target -ceq 'Android') { 'aarch64';'x86_64' } elseif ($Target -ceq 'Windows') { 'x86_64' } else { throw 'shorebird_patch_target_invalid' })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($artifact in $Artifacts) {
        if ($artifact.platform -cne $Target.ToLowerInvariant() -or $artifact.arch -cnotin $expected -or
            !$seen.Add($artifact.arch) -or $artifact.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $artifact.bytes -le 0) { throw 'shorebird_patch_artifact_invalid' }
    }
    if ($seen.Count -ne $expected.Count) { throw 'shorebird_patch_architecture_missing' }
}

function Get-ShorebirdAndroidAot([string]$Archive,[switch]$Apk) {
    foreach ($abi in @(@('aarch64','arm64-v8a'),@('x86_64','x86_64'))) {
        $entry = $(if ($Apk) { 'lib/' } else { 'base/lib/' }) + $abi[1] + '/libapp.so'
        $file = Get-ReleaseRuntimeJarEngine $Archive $entry
        [ordered]@{platform='android';arch=$abi[0];sha256=$file.sha256;bytes=$file.size}
    }
}

function Assert-ShorebirdAndroidAotBinding([string]$Apk,[string]$Aab) {
    $apkAot = @(Get-ShorebirdAndroidAot $Apk -Apk)
    $aabAot = @(Get-ShorebirdAndroidAot $Aab)
    if (($apkAot | ConvertTo-Json -Compress) -cne ($aabAot | ConvertTo-Json -Compress)) { throw 'shorebird_base_apk_aab_aot_mismatch' }
    $apkAot
}

function Get-ShorebirdRollbackGroups([int]$AndroidPatchNumber,[int]$WindowsPatchNumber) {
    if ($AndroidPatchNumber -le 0 -or $WindowsPatchNumber -le 0) { throw 'shorebird_rollback_numbers_invalid' }
    if ($AndroidPatchNumber -eq $WindowsPatchNumber) {
        [ordered]@{number=$AndroidPatchNumber;targets=@('Android','Windows')}
    } else {
        [ordered]@{number=$AndroidPatchNumber;targets=@('Android')}
        [ordered]@{number=$WindowsPatchNumber;targets=@('Windows')}
    }
}
