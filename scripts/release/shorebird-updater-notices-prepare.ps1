# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$Acquire
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'shorebird-updater-notices-crates.ps1')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pins=Get-UpdaterCratePins $repository
$collectorInputs=@(Get-UpdaterCollectorInputs $repository)
$inputsUnchanged=$false
$limits=Get-UpdaterCrateLimits
$cache=Assert-UpdaterPrivatePath $repository $CacheDirectory
$output=Assert-UpdaterPrivatePath $repository $OutputDirectory
if ($cache -eq $output -or $output.StartsWith($cache+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
    $cache.StartsWith($output+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) { throw 'updater_crate_output_exists_or_overlaps' }
[IO.Directory]::CreateDirectory($output)|Out-Null
[IO.Directory]::CreateDirectory($cache)|Out-Null
$clock=[Diagnostics.Stopwatch]::StartNew()
$cancellation=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($limits.Seconds))
$network=[hashtable]::Synchronized(@{Bytes=0L})
$receipts=[Collections.Generic.List[object]]::new()
$components=[Collections.Generic.List[object]]::new()
$cacheLock=$null;$status='FAILED';$failure=$null
try {
    $cacheLock=[IO.File]::Open((Join-Path $cache 'collector.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $missing=[Collections.Generic.List[object]]::new()
    foreach($crate in $pins.Pin.crates){
        $archive=Get-UpdaterCrateArchivePath $cache $crate
        if(Test-Path -LiteralPath $archive){
            $size=Assert-UpdaterCrateArchive $archive $crate $limits
            $receipts.Add([ordered]@{name=$crate.name;version=$crate.version;sha256=$crate.sha256;size=$size;status='verified-cache'})
        }else{$missing.Add($crate)}
    }
    if($missing.Count -and !$Acquire){throw 'updater_crate_archive_missing_offline'}
    # Only the explicit acquisition command has network access. Fixed URLs,
    # one attempt per missing archive, at most four concurrent transfers.
    for($index=0;$index -lt $missing.Count;$index+=4){
        if($clock.Elapsed.TotalSeconds -ge $limits.Seconds){throw 'updater_crate_deadline'}
        $batch=@($missing | Select-Object -Skip $index -First 4)
        $batchResults=@($batch | ForEach-Object -Parallel {
            $ErrorActionPreference='Stop'
            $crate=$_;$bounds=$using:limits;$folder=$using:cache;$shared=$using:network;$globalCancel=$using:cancellation
            $tokenSource=[Threading.CancellationTokenSource]::CreateLinkedTokenSource($globalCancel.Token)
            $tokenSource.CancelAfter(45000)
            $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
            $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
            $response=$null;$source=$null;$destination=$null;$bytes=0L;$resultStatus='FAILED';$reason=$null
            $partial=Join-Path $folder ([Guid]::NewGuid().ToString('N')+'.partial')
            try{
                $uri="https://static.crates.io/crates/$($crate.name)/$($crate.name)-$($crate.version).crate"
                $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$uri)
                try{$response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$tokenSource.Token).GetAwaiter().GetResult()}finally{$request.Dispose()}
                if([int]$response.StatusCode -ne 200){throw "updater_crate_http_$([int]$response.StatusCode)"}
                if($null -ne $response.Content.Headers.ContentLength -and ($response.Content.Headers.ContentLength -le 0 -or $response.Content.Headers.ContentLength -gt $bounds.ArchiveBytes)){throw 'updater_crate_archive_limit'}
                $source=$response.Content.ReadAsStreamAsync($tokenSource.Token).GetAwaiter().GetResult()
                $destination=[IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $buffer=[byte[]]::new(65536)
                while(($count=$source.ReadAsync($buffer,0,$buffer.Length,$tokenSource.Token).GetAwaiter().GetResult()) -gt 0){
                    $bytes+=$count
                    if($bytes -gt $bounds.ArchiveBytes){throw 'updater_crate_archive_limit'}
                    [Threading.Monitor]::Enter($shared.SyncRoot)
                    try{$shared.Bytes+=$count;if($shared.Bytes -gt $bounds.NetworkBytes){$globalCancel.Cancel();throw 'updater_crate_network_limit'}}finally{[Threading.Monitor]::Exit($shared.SyncRoot)}
                    $destination.Write($buffer,0,$count)
                }
                $destination.Dispose();$destination=$null
                if($bytes -le 0 -or (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -cne $crate.sha256){throw 'updater_crate_archive_checksum_mismatch'}
                $final=Join-Path $folder "$($crate.name)-$($crate.version)-$($crate.sha256).crate"
                [IO.File]::Move($partial,$final,$false)
                $resultStatus='downloaded-verified'
            }catch{
                $message=$_.Exception.Message
                $reason=if($message -cmatch '^updater_crate_[a-z0-9_]+$'){$message}else{'updater_crate_transfer_failed'}
            }finally{
                if($destination){$destination.Dispose()};if($source){$source.Dispose()};if($response){$response.Dispose()}
                $client.Dispose();$handler.Dispose();$tokenSource.Dispose()
            }
            [ordered]@{name=$crate.name;version=$crate.version;sha256=$crate.sha256;size=$bytes;status=$resultStatus;failure=$reason}
        } -ThrottleLimit 4)
        foreach($receipt in $batchResults){$receipts.Add($receipt)}
        Write-AuditJson (Join-Path $output 'acquisition.json') ([ordered]@{schema=1;receipts=$receipts.ToArray();networkBytes=$network.Bytes;attempts=$index+$batch.Count;automaticRetries=0})
        if(@($batchResults | Where-Object status -CEQ 'FAILED').Count){throw 'updater_crate_acquisition_incomplete'}
        if(($index % 32) -eq 0){Write-Output "Verified archives: $($receipts.Count)/$($pins.Count)"}
    }
    $expanded=0L;$noticeBytes=0L
    foreach($crate in $pins.Pin.crates){
        if($clock.Elapsed.TotalSeconds -ge $limits.Seconds){throw 'updater_crate_deadline'}
        $remaining=Get-UpdaterRemainingLimits $limits $expanded $noticeBytes
        $folder=Join-Path $output "components/$($crate.name)-$($crate.version)"
        [IO.Directory]::CreateDirectory($folder)|Out-Null
        $component=Export-UpdaterCrateNotices (Get-UpdaterCrateArchivePath $cache $crate) $crate $folder $remaining $clock
        $expanded+=$component.expandedBytes;$noticeBytes+=$component.noticeBytes
        if($expanded -gt $limits.TotalExpandedBytes -or $noticeBytes -gt $limits.TotalNoticeBytes){throw 'updater_crate_total_output_limit'}
        $components.Add([ordered]@{name=$crate.name;version=$crate.version;scopes=$crate.scopes;archiveSha256=$crate.sha256;componentPath="components/$($crate.name)-$($crate.version)/component.json";componentSha256=(Get-AuditSha256 (Join-Path $folder 'component.json'));noticeCount=$component.notices.Count;issues=$component.issues})
    }
    $after=Get-UpdaterCratePins $repository
    $collectorAfter=@(Get-UpdaterCollectorInputs $repository)
    if($after.Sha256 -cne $pins.Sha256 -or ($collectorInputs|ConvertTo-Json -Depth 8 -Compress) -cne ($collectorAfter|ConvertTo-Json -Depth 8 -Compress)){throw 'updater_crate_inputs_changed'}
    $inputsUnchanged=$true
    $status='SOURCE_NOTICE_CANDIDATE_REVIEW_REQUIRED'
}catch{
    $message=$_.Exception.Message
    $failure=if($message -cmatch '^updater_crate_[a-z0-9_]+$'){$message}else{'updater_crate_preparation_failed'}
    throw
}finally{
    $report=[ordered]@{
        schema=1;status=$status;failure=$failure;pinSha256=$pins.Sha256;updaterRevision=$pins.Pin.updaterRevision;rustSourceRevision=$pins.Pin.rustSourceRevision
        expectedCrates=$pins.Count;verifiedArchives=@($receipts | Where-Object status -In @('verified-cache','downloaded-verified')).Count;components=$components.ToArray();receipts=$receipts.ToArray()
        collectorInputs=$collectorInputs;collectorInputsUnchanged=$inputsUnchanged;sources=$pins.Pin.sources
        acquisitionExplicit=[bool]$Acquire;networkBytes=$network.Bytes;automaticRetries=0;elapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);limits=$limits
        archiveMembership='conservative-source-lock-superset';completeLicenseCoverage=$false;publisherBuildInputsAttested=$false;exactLinkedMembership=$false;rustStandardLibraryAggregatePresent=$false
    }
    Write-AuditJson (Join-Path $output 'report.json') $report
    if($cacheLock){$cacheLock.Dispose()};$cancellation.Dispose()
}
Write-Output "Prepared $($components.Count) source notice candidates; coverage remains REVIEW_REQUIRED."
