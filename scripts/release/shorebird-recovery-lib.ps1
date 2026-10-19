# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# One reviewed recovery only. Dot-sourcing has no network/build side effects.
Set-StrictMode -Version Latest

function Get-ShorebirdWindowsRecoveryPolicy {
    [ordered]@{version='0.1.8+29';compiledSourceCommit='e8cba9fc7f849013c804b02d2c401b07a907d9e8'
        releaseId=908884;artifactId=4043762;sha256='85ad5bc927874a0284862f82a159c53b28ee01cfbcc20323edee3344784ddc49'
        bytes=30552700;files=283;host='storage.googleapis.com'}
}

function Get-ShorebirdRecoveryBlob([string]$Repository,[string]$Commit,[string]$Path) {
    $git=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Invoke-AuditTool $git @('-c','core.fsmonitor=false','-C',$Repository,'cat-file','blob',"${Commit}:$Path") 30
}

function Assert-ShorebirdRecoveryPaths([string[]]$Paths) {
    $tooling=@('scripts/release/shorebird-release.ps1','scripts/release/shorebird-pipeline-lib.ps1',
        'scripts/release/shorebird-recovery-lib.ps1','scripts/release/test-shorebird-pipeline.ps1','.github/workflows/shorebird.yml',
        '.github/workflows/android-analyzer-probe.yml',
        'scripts/release/shorebird-runtime-notices.ps1','scripts/release/test-shorebird-runtime-notices.ps1',
        'scripts/release/shorebird-runtime-notices.lock.json',
        'scripts/release/licenses/shorebird-runtime-4b936a0c03e13389ddfb1ac48823f187964975c2/inventory.json',
        '.gitattributes','scripts/release/shorebird-updater-notices-crates.lock.json')
    foreach ($path in $Paths) {
        if ($path -match '\.\.|//|[\x00-\x1f\\:]' -or ($path -cnotin $tooling -and
            $path -cnotmatch '^docs/[A-Za-z0-9_./-]+\.md$' -and
            $path -cnotmatch '^docs/evidence/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.json$')) {
            throw 'shorebird_recovery_compiled_input_changed'
        }
    }
}

function Assert-ShorebirdRecoveryAttributes([string]$Before,[string]$After) {
    $rule='scripts/release/shorebird-updater-notices-crates.lock.json -text -whitespace'
    $old=@($Before -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_ -and !($_.StartsWith('#'))})
    $new=@($After -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_ -and !($_.StartsWith('#'))})
    if (@($new | Where-Object {$_ -ceq $rule}).Count -ne 1 -or $old -ccontains $rule -or
        (($old | ConvertTo-Json -Compress) -cne (@($new | Where-Object {$_ -cne $rule}) | ConvertTo-Json -Compress))) {
        throw 'shorebird_recovery_attributes_changed'
    }
}

function Assert-ShorebirdRecoveryCratePin([string]$Before,[string]$After) {
    try { $null=$Before | ConvertFrom-Json -AsHashtable -ErrorAction Stop;$null=$After | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'shorebird_recovery_crate_pin_changed' }
    # The reviewed change is byte preservation only. This is stricter than
    # merely equal parsed objects: no fields/order/values/whitespace change.
    if ($Before.Replace("`r`n","`n") -cne $After.Replace("`r`n","`n") -or
        (Get-AuditTextHash $After) -cne '60089d1c2c264863ec57ae1fd71cf60a85561c293f6bbbb7d404f6e3a196461a') {
        throw 'shorebird_recovery_crate_pin_changed'
    }
}

function Assert-ShorebirdRecoveryNoticeMetadata([string]$Before,[string]$After,[string]$BeforePin,[string]$AfterPin) {
    try {
        $old=$Before | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $new=$After | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $oldPin=$BeforePin | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $newPin=$AfterPin | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {throw 'shorebird_recovery_notice_metadata_changed'}
    # Android's asset packager omits dotfiles. Remove only our own Git metadata
    # from the notice manifest; every upstream license/source record stays exact.
    $metadata=@($old.files | Where-Object path -CEQ '.gitattributes')
    if((Get-AuditTextHash $Before) -cne 'bf4886f683436415923de72aaf4f504b696cece8f98960189700a76789f78c4a' -or
        @($old.files).Count -ne 199 -or $metadata.Count -ne 1 -or $metadata[0].size -ne 20 -or
        $metadata[0].sha256 -cne 'e97602ab9cac70102245345c5ab0fc9830df8b17f1072b188265a662a3a547ae') {
        throw 'shorebird_recovery_notice_metadata_changed'
    }
    $old.files=@($old.files | Where-Object path -CNE '.gitattributes')
    if(($old | ConvertTo-Json -Depth 60 -Compress) -cne ($new | ConvertTo-Json -Depth 60 -Compress)) {
        throw 'shorebird_recovery_notice_metadata_changed'
    }
    if($oldPin.inventorySha256 -cne (Get-AuditTextHash $Before) -or
        $oldPin.inventorySize -ne [Text.Encoding]::UTF8.GetByteCount($Before) -or
        $newPin.inventorySha256 -cne (Get-AuditTextHash $After) -or
        $newPin.inventorySize -ne [Text.Encoding]::UTF8.GetByteCount($After)) {
        throw 'shorebird_recovery_notice_metadata_changed'
    }
    $oldPin.inventorySha256=$newPin.inventorySha256;$oldPin.inventorySize=$newPin.inventorySize
    if(($oldPin | ConvertTo-Json -Depth 20 -Compress) -cne ($newPin | ConvertTo-Json -Depth 20 -Compress)) {
        throw 'shorebird_recovery_notice_metadata_changed'
    }
}

function Assert-ShorebirdRecoverySource([string]$Repository,[string]$SourceCommit='') {
    $policy=Get-ShorebirdWindowsRecoveryPolicy
    if (!$SourceCommit) { $SourceCommit=Get-ShorebirdSourceCommit $Repository }
    if ($SourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'shorebird_recovery_source_invalid' }
    $null=Invoke-ShorebirdGit $Repository @('merge-base','--is-ancestor',$policy.compiledSourceCommit,$SourceCommit)
    $raw=Invoke-ShorebirdGit $Repository @('diff','--no-renames','--name-only',"$($policy.compiledSourceCommit)..$SourceCommit",'--')
    $paths=@($raw -split "`n" | Where-Object {$_})
    Assert-ShorebirdRecoveryPaths $paths
    foreach ($path in $paths) {
        foreach ($commit in @($policy.compiledSourceCommit,$SourceCommit)) {
            $entry=Invoke-ShorebirdGit $Repository @('ls-tree',$commit,'--',$path)
            if ($entry -and $entry -cnotmatch '^100644 blob [a-f0-9]{40}\t') { throw 'shorebird_recovery_source_mode_invalid' }
            if ($entry) {
                $size=Invoke-ShorebirdGit $Repository @('cat-file','-s',"${commit}:$path")
                if ($size -cnotmatch '^\d+$' -or [long]$size -gt 1MB) { throw 'shorebird_recovery_source_size_invalid' }
            }
        }
    }
    $attributes='.gitattributes';$crate='scripts/release/shorebird-updater-notices-crates.lock.json'
    Assert-ShorebirdRecoveryAttributes (Get-ShorebirdRecoveryBlob $Repository $policy.compiledSourceCommit $attributes) (Get-ShorebirdRecoveryBlob $Repository $SourceCommit $attributes)
    Assert-ShorebirdRecoveryCratePin (Get-ShorebirdRecoveryBlob $Repository $policy.compiledSourceCommit $crate) (Get-ShorebirdRecoveryBlob $Repository $SourceCommit $crate)
    $inventory='scripts/release/licenses/shorebird-runtime-4b936a0c03e13389ddfb1ac48823f187964975c2/inventory.json'
    $runtimePin='scripts/release/shorebird-runtime-notices.lock.json'
    if($paths -ccontains $inventory -or $paths -ccontains $runtimePin){
        Assert-ShorebirdRecoveryNoticeMetadata (Get-ShorebirdRecoveryBlob $Repository $policy.compiledSourceCommit $inventory) `
            (Get-ShorebirdRecoveryBlob $Repository $SourceCommit $inventory) `
            (Get-ShorebirdRecoveryBlob $Repository $policy.compiledSourceCommit $runtimePin) `
            (Get-ShorebirdRecoveryBlob $Repository $SourceCommit $runtimePin)
    }
    [ordered]@{compiledSourceCommit=$policy.compiledSourceCommit;sourceCommit=$SourceCommit;onlyPackagingChanges=$true;paths=$paths}
}

function Assert-ShorebirdRecoveryUri([uri]$Uri) {
    if (!$Uri.IsAbsoluteUri -or $Uri.AbsoluteUri.Length -gt 8192 -or $Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or
        $Uri.Host -cne (Get-ShorebirdWindowsRecoveryPolicy).host -or $Uri.UserInfo -or $Uri.Fragment -or $Uri.AbsolutePath -ceq '/') {
        throw 'shorebird_recovery_uri_rejected'
    }
}

function Assert-ShorebirdRecoveryArtifact($Artifact) {
    $policy=Get-ShorebirdWindowsRecoveryPolicy
    if (!$Artifact -or $Artifact.id -ne $policy.artifactId -or $Artifact.release_id -ne $policy.releaseId -or
        $Artifact.platform -cne 'windows' -or $Artifact.arch -cne 'win_archive' -or
        $Artifact.hash -cne $policy.sha256 -or $Artifact.size -ne $policy.bytes) { throw 'shorebird_recovery_artifact_mismatch' }
    Assert-ShorebirdRecoveryUri ([uri]$Artifact.url)
}

function Get-ShorebirdRecoveryArtifact([string]$Cli,[string]$PrivateDirectory) {
    $policy=Get-ShorebirdWindowsRecoveryPolicy;$appId=(Get-ShorebirdPolicy).appId
    $stdout=Join-Path $PrivateDirectory 'recovery-artifacts.json';$stderr=Join-Path $PrivateDirectory 'recovery-artifacts.log'
    $oldSystem=$env:GIT_CONFIG_SYSTEM
    try {
        $env:GIT_CONFIG_SYSTEM=New-ShorebirdGitOverlay $PrivateDirectory
        # The official api command returns the body directly, not an envelope;
        # it explicitly rejects the global --json flag. Only this fixed GET.
        & $Cli api --method=GET "/apps/$appId/releases/$($policy.releaseId)/artifacts" -f 'platform=windows' 1> $stdout 2> $stderr
        $code=$LASTEXITCODE
    } finally {$env:GIT_CONFIG_SYSTEM=$oldSystem}
    if ($code -ne 0 -or !(Test-Path -LiteralPath $stdout) -or (Get-Item -LiteralPath $stdout).Length -gt 4MB) { throw 'shorebird_recovery_readback_failed' }
    try { $body=Get-Content -LiteralPath $stdout -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch {throw 'shorebird_recovery_readback_failed'}
    $selected=@($body.artifacts | Where-Object {$_.id -eq $policy.artifactId})
    if ($selected.Count -ne 1) {throw 'shorebird_recovery_artifact_mismatch'}
    Assert-ShorebirdRecoveryArtifact $selected[0]
    $selected[0]
}

function Receive-ShorebirdRecoveryArchive($Artifact,[string]$PrivateDirectory) {
    Assert-ShorebirdRecoveryArtifact $Artifact
    $policy=Get-ShorebirdWindowsRecoveryPolicy
    $path=Join-Path $PrivateDirectory 'recovered-windows.zip'
    Assert-AuditNoLinks $PrivateDirectory
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseDefaultCredentials=$false
    $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromMinutes(10)
    $cancel=[Threading.CancellationTokenSource]::new(600000)
    $response=$null;$input=$null;$output=$null;$digest=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        # No bearer/default credentials/Authorization header goes to storage.
        $response=$client.GetAsync([uri]$Artifact.url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200 -or ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne $policy.bytes)) {throw 'shorebird_recovery_download_failed'}
        $input=$response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
        $output=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=[byte[]]::new(65536);[long]$total=0
        while (($count=$input.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0) {
            $total+=$count;if ($total -gt $policy.bytes) {throw 'shorebird_recovery_download_failed'}
            $digest.AppendData($buffer,0,$count);$output.Write($buffer,0,$count)
        }
        if ($total -ne $policy.bytes -or [Convert]::ToHexString($digest.GetHashAndReset()).ToLowerInvariant() -cne $policy.sha256) {throw 'shorebird_recovery_download_failed'}
    } finally {
        if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()}
        $digest.Dispose();$cancel.Dispose();$client.Dispose();$handler.Dispose()
    }
    $path
}

function Expand-ShorebirdRecoveryArchive([string]$Archive,[string]$Destination) {
    Assert-AuditNoLinks $Archive
    Assert-AuditNoLinks ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination)))
    if (Test-Path -LiteralPath $Destination) {throw 'shorebird_recovery_output_exists'}
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        [long]$bytes=0
        if($zip.Entries.Count -gt 1000){throw 'shorebird_recovery_archive_invalid'}
        foreach($entry in $zip.Entries){
            $bytes+=$entry.Length
            if($entry.Length -gt 128MB -or $bytes -gt 512MB -or ($entry.ExternalAttributes -band 0x400) -ne 0){throw 'shorebird_recovery_archive_invalid'}
        }
    } finally {$zip.Dispose()}
    $expected=Get-AuditZipFiles $Archive
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Destination)
    $actual=Get-AuditTreeFiles $Destination
    if($expected.Count -ne $actual.Count){throw 'shorebird_recovery_archive_invalid'}
    foreach($entry in $expected.Values){
        if(!$actual.ContainsKey($entry.path) -or $actual[$entry.path].sha256 -cne $entry.sha256 -or $actual[$entry.path].size -ne $entry.size){throw 'shorebird_recovery_archive_invalid'}
    }
    ,$actual
}

function Assert-ShorebirdRecoveryProof($Proof,[string]$SourceCommit) {
    $policy=Get-ShorebirdWindowsRecoveryPolicy
    if(!$Proof -or $Proof.compiledSourceCommit -cne $policy.compiledSourceCommit -or $Proof.sourceCommit -cne $SourceCommit -or
        $Proof.releaseId -ne $policy.releaseId -or $Proof.artifactId -ne $policy.artifactId -or
        $Proof.archiveSha256 -cne $policy.sha256 -or $Proof.archiveBytes -ne $policy.bytes -or $Proof.uiFiles -ne $policy.files -or
        $Proof.uiTreeSha256 -cnotmatch '^[a-f0-9]{64}$' -or !$Proof.sourceEquivalence.onlyPackagingChanges -or
        $Proof.sourceEquivalence.sourceCommit -cne $SourceCommit -or $Proof.sourceEquivalence.compiledSourceCommit -cne $policy.compiledSourceCommit -or
        $Proof.uiBuildPerformed -ne $false -or $Proof.cloudUploadPerformed -ne $false) {throw 'shorebird_recovery_proof_invalid'}
    Assert-ShorebirdRecoveryPaths @($Proof.sourceEquivalence.paths)
}

function Get-ShorebirdSafeFailureCode([string]$Message) {
    if($Message -cin @('shorebird_recovery_compiled_input_changed','shorebird_recovery_attributes_changed','shorebird_recovery_crate_pin_changed','shorebird_recovery_notice_metadata_changed',
        'shorebird_recovery_source_invalid','shorebird_recovery_source_mode_invalid','shorebird_recovery_source_size_invalid',
        'shorebird_recovery_uri_rejected','shorebird_recovery_artifact_mismatch','shorebird_recovery_readback_failed','shorebird_recovery_download_failed',
        'shorebird_recovery_output_exists','shorebird_recovery_archive_invalid','shorebird_recovery_proof_invalid','shorebird_recovery_version_mismatch',
        'shorebird_recovery_ui_identity_invalid','shorebird_installer_failed','shorebird_installer_ambiguous','shorebird_android_jvm_failed','shorebird_maven_notices_failed',
        'shorebird_apk_signer_mismatch','shorebird_source_not_clean','shorebird_source_changed','shorebird_preview_audit_failed','shorebird_preview_artifact_binding_failed',
        'shorebird_preview_unexpected_audit_finding','shorebird_runtime_notices_inventory_invalid','shorebird_runtime_notices_inventory_mismatch',
        'shorebird_runtime_notices_file_mismatch','shorebird_runtime_notices_copy_mismatch','shorebird_runtime_notices_binding_mismatch',
        'shorebird_updater_input_mismatch','shorebird_updater_deps_mismatch','nsis_download_status','nsis_download_hash_mismatch',
        'nsis_download_uri_rejected','nsis_download_failed','audit_tool_failed','audit_tool_timeout')){return $Message}
    'shorebird_operation_failed'
}

function Get-ShorebirdSafeFailureLeaf([string]$Path) {
    $leaf=[IO.Path]::GetFileName($Path)
    if($leaf -cin @('shorebird-release.ps1','shorebird-recovery-lib.ps1','shorebird-pipeline-lib.ps1','shorebird-preview-lib.ps1',
        'collect-notices.ps1','notice-inputs.ps1','shorebird-runtime-notices.ps1','shorebird-updater-notices.ps1','artifact-audit-lib.ps1',
        'flutter-runtime-inputs.ps1','android-notice-inputs.ps1','prepare-android-notices.ps1','prepare-demo-maven-notices.ps1',
        'build-installer.ps1','build-app-updater.ps1','prepare-nsis.ps1','prepare-msvc-runtime.ps1','prepare-ci-msvc-runtime.ps1')){return $leaf}
    ''
}
