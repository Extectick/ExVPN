# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Scoped byte preparation for the two text assets in an already audited base.
# No SDK, Git index staging, dependency resolution, or cloud operations.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')

function Invoke-ShorebirdPatchInputGit([string]$Repository,[string[]]$Arguments) {
    $git=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    (Invoke-AuditTool $git (@('-c','core.fsmonitor=false','-c','core.quotepath=false','-C',$Repository)+$Arguments) 15).TrimEnd("`r","`n")
}

function Get-ShorebirdPatchInputHash([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-ShorebirdPatchTextHash([byte[]]$Bytes) {
    if($Bytes.Length -eq 0 -or $Bytes.Length -gt 64KB){throw 'shorebird_patch_text_asset_size_invalid'}
    try {$text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)} catch {throw 'shorebird_patch_text_asset_utf8_invalid'}
    $normalized=$text.Replace("`r`n","`n")
    if($normalized.Contains("`r")){throw 'shorebird_patch_text_asset_newlines_invalid'}
    Get-ShorebirdPatchInputHash ([Text.UTF8Encoding]::new($false).GetBytes($normalized))
}

function Assert-ShorebirdPatchInputFile([string]$Path,[long]$MaximumBytes) {
    Assert-AuditNoLinks $Path
    $item=Get-Item -LiteralPath $Path -Force
    if($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt $MaximumBytes -or
        ($item.PSObject.Properties['LinkType'] -and $item.LinkType)){throw 'shorebird_patch_asset_file_invalid'}
    $item
}

function Get-ShorebirdPatchInputBlob([string]$Repository,[string]$Commit,[string]$Path) {
    $object=$Commit+':'+$Path
    $size=Invoke-ShorebirdPatchInputGit $Repository @('cat-file','-s',$object)
    if($size -cnotmatch '\A[1-9][0-9]*\z' -or [long]$size -gt 64KB){throw 'shorebird_patch_asset_blob_size_invalid'}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-c','core.fsmonitor=false','-C',$Repository,'cat-file','blob',$object)){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start)
    $output=[IO.MemoryStream]::new()
    try {
        $stdout=$process.StandardOutput.BaseStream.CopyToAsync($output)
        $stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(15000)){$process.Kill($true);throw 'shorebird_patch_asset_git_timeout'}
        $null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $output.Length -ne [long]$size){throw 'shorebird_patch_asset_blob_read_failed'}
        return ,$output.ToArray()
    } finally {$output.Dispose();$process.Dispose()}
}

function Get-ShorebirdPatchInputIndex([string]$Repository,[string]$Path) {
    $entry=Invoke-ShorebirdPatchInputGit $Repository @('ls-files','--stage','--',$Path)
    if($entry -cnotmatch ('\A100644 [a-f0-9]{40} 0\t'+[regex]::Escape($Path)+'\z')){throw 'shorebird_patch_asset_index_invalid'}
    $entry
}

function Assert-ShorebirdPatchInputPrivate([string]$Path) {
    Assert-AuditNoLinks $Path
    $acl=Get-Acl -LiteralPath $Path
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $owner -or
        $rules.Count -ne 2 -or @($rules|Where-Object {$_.IsInherited -or $_.AccessControlType -ne 'Allow' -or $_.IdentityReference.Value -cnotin @($owner,'S-1-5-18')}).Count){throw 'shorebird_patch_asset_private_directory_invalid'}
}

function Assert-ShorebirdPatchInputSource([string]$Repository,[string]$Commit) {
    if((Invoke-ShorebirdPatchInputGit $Repository @('rev-parse','HEAD')) -cne $Commit -or
        (Invoke-ShorebirdPatchInputGit $Repository @('status','--porcelain=v1','--untracked-files=normal'))){throw 'shorebird_patch_asset_source_not_clean'}
}

function Get-ShorebirdPatchReceiptFile([string]$Root,$Receipt,[string]$Relative,[long]$MaximumBytes) {
    $records=@($Receipt.files|Where-Object {$_.path -ieq $Relative})
    if($records.Count -ne 1 -or $records[0].path -cne $Relative -or $records[0].sha256 -cnotmatch '\A[a-f0-9]{64}\z'){throw 'shorebird_patch_asset_receipt_entry_invalid'}
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(!$path.StartsWith($Root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'shorebird_patch_asset_receipt_path_invalid'}
    $null=Assert-ShorebirdPatchInputFile $path $MaximumBytes
    if((Get-AuditSha256 $path) -cne $records[0].sha256){throw 'shorebird_patch_asset_receipt_hash_mismatch'}
    $path
}

function Get-ShorebirdPatchAabText([IO.Compression.ZipArchive]$Archive,[string]$Relative) {
    if($Archive.Entries.Count -gt 30000){throw 'shorebird_patch_asset_archive_limit'}
    $name='base/assets/flutter_assets/'+$Relative
    $matches=@($Archive.Entries|Where-Object {$_.FullName -ieq $name})
    if($matches.Count -ne 1 -or $matches[0].FullName -cne $name -or $matches[0].Length -le 0 -or
        $matches[0].Length -gt 64KB -or (($matches[0].ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000){throw 'shorebird_patch_asset_archive_entry_invalid'}
    $stream=$matches[0].Open();$output=[IO.MemoryStream]::new()
    try {
        $buffer=[byte[]]::new(8192)
        while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0){if($output.Length+$count -gt 64KB){throw 'shorebird_patch_asset_archive_limit'};$output.Write($buffer,0,$count)}
        if($output.Length -ne $matches[0].Length){throw 'shorebird_patch_asset_archive_read_failed'}
        return ,$output.ToArray()
    }
    finally {$stream.Dispose();$output.Dispose()}
}

function Enter-ShorebirdPatchTextAssetsLease {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
        [Parameter(Mandatory)][string]$BaseReceiptPath,[Parameter(Mandatory)]$BaseReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
        [Parameter(Mandatory)][string]$PrivateDirectory)
    $repositoryRoot=[IO.Path]::GetFullPath($Repository).TrimEnd('\','/')
    if([IO.Path]::GetFullPath((Invoke-ShorebirdPatchInputGit $repositoryRoot @('rev-parse','--show-toplevel'))).TrimEnd('\','/') -ine $repositoryRoot){throw 'shorebird_patch_asset_repository_invalid'}
    Assert-ShorebirdPatchInputSource $repositoryRoot $SourceCommit
    $null=Assert-ShorebirdPatchInputFile $BaseReceiptPath 4MB
    $receiptHash=Get-AuditSha256 $BaseReceiptPath
    $actual=Get-Content -LiteralPath $BaseReceiptPath -Raw|ConvertFrom-Json -AsHashtable
    if(($actual|ConvertTo-Json -Depth 100 -Compress) -cne ($BaseReceipt|ConvertTo-Json -Depth 100 -Compress) -or
        $actual.sourceCommit -cnotmatch '\A[a-f0-9]{40}\z' -or $actual.target -cne $Target -or
        $actual.version -cnotmatch '\A\d+\.\d+\.\d+\+[1-9]\d*\z'){throw 'shorebird_patch_asset_receipt_changed'}
    $baseRoot=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($BaseReceiptPath)).TrimEnd('\','/')
    $private=[IO.Path]::GetFullPath($PrivateDirectory).TrimEnd('\','/')
    Assert-AuditNoLinks $private
    if(!(Test-Path -LiteralPath $private -PathType Container)){throw 'shorebird_patch_asset_private_directory_invalid'}
    Assert-ShorebirdPatchInputPrivate $private
    $entries=[Collections.Generic.List[object]]::new()
    $lease=[ordered]@{repository=$repositoryRoot;sourceCommit=$SourceCommit;receiptPath=$BaseReceiptPath;receiptSha256=$receiptHash;privateDirectory=$private;entries=$entries;active=$false;restored=$false;summary=@()}
    $archive=$null;$archiveStream=$null
    try {
        if($Target -ceq 'Android'){
            $aab=Get-ShorebirdPatchReceiptFile $baseRoot $actual ('ExVPN-'+$actual.version.Replace('+','-')+'-android.aab') 1GB
            $aabRecord=@($actual.files|Where-Object {$_.path -ceq [IO.Path]::GetFileName($aab)})[0]
            $archiveStream=[IO.File]::Open($aab,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archiveStream)).ToLowerInvariant() -cne $aabRecord.sha256){throw 'shorebird_patch_asset_receipt_hash_mismatch'}
            $archiveStream.Position=0
            $archive=[IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Read,$true)
        }
        foreach($relative in @('assets/flags/countries.txt','assets/licenses/FlagIcons.txt')){
            $sourceRelative='apps/exvpn/'+$relative
            $path=Join-Path $repositoryRoot $sourceRelative
            $item=Assert-ShorebirdPatchInputFile $path 64KB
            $original=[IO.File]::ReadAllBytes($path)
            $index=Get-ShorebirdPatchInputIndex $repositoryRoot $sourceRelative
            $head=Get-ShorebirdPatchInputBlob $repositoryRoot $SourceCommit $sourceRelative
            $baseSource=Get-ShorebirdPatchInputBlob $repositoryRoot $actual.sourceCommit $sourceRelative
            $raw=if($Target -ceq 'Windows'){
                $baseFile=Get-ShorebirdPatchReceiptFile $baseRoot $actual ('ui/data/flutter_assets/'+$relative) 64KB
                [IO.File]::ReadAllBytes($baseFile)
            }else{Get-ShorebirdPatchAabText $archive $relative}
            if($Target -ceq 'Windows'){
                $record=@($actual.files|Where-Object {$_.path -ceq ('ui/data/flutter_assets/'+$relative)})[0]
                if((Get-ShorebirdPatchInputHash $raw) -cne $record.sha256){throw 'shorebird_patch_asset_receipt_hash_mismatch'}
            }
            $normalized=Get-ShorebirdPatchTextHash $original
            foreach($bytes in @($head,$baseSource,$raw)){if((Get-ShorebirdPatchTextHash $bytes) -cne $normalized){throw 'shorebird_patch_asset_semantic_change'}}
            $entries.Add([ordered]@{path=$path;relative=$sourceRelative;original=$original;originalHash=(Get-ShorebirdPatchInputHash $original);mtime=$item.LastWriteTimeUtc;index=$index;baseBytes=[byte[]]$raw;baseHash=(Get-ShorebirdPatchInputHash $raw);normalizedHash=$normalized;restoreRequired=$false})
        }
    } finally {if($archive){$archive.Dispose()};if($archiveStream){$archiveStream.Dispose()}}
    # Validate both complete plans before the first source write.
    foreach($entry in $entries){if((Get-AuditSha256 $entry.path) -cne $entry.originalHash -or (Get-ShorebirdPatchInputIndex $repositoryRoot $entry.relative) -cne $entry.index){throw 'shorebird_patch_asset_plan_changed'}}
    if((Get-AuditSha256 $BaseReceiptPath) -cne $receiptHash){throw 'shorebird_patch_asset_receipt_changed'}
    $lease.active=$true
    try {
        foreach($entry in $entries){
            if($entry.originalHash -cne $entry.baseHash){$entry.restoreRequired=$true;[IO.File]::WriteAllBytes($entry.path,$entry.baseBytes)}
            $lease.summary+=@{path=$entry.relative;sourceRawSha256=$entry.originalHash;baseRawSha256=$entry.baseHash;normalizedSha256=$entry.normalizedHash}
        }
    } catch {Restore-ShorebirdPatchTextAssetsLease $lease;throw}
    $lease
}

function Restore-ShorebirdPatchTextAssetsLease($Lease) {
    if(!$Lease -or !$Lease.active){return}
    $failure=$false
    try {
        foreach($entry in $Lease.entries){
            try {
                $null=Assert-ShorebirdPatchInputFile $entry.path 64KB
                $currentHash=Get-AuditSha256 $entry.path
                if($currentHash -cne $entry.baseHash){
                    $failure=$true
                    # Preserve an unexpected concurrent/child write before
                    # restoring our original bytes; never print its contents.
                    Assert-ShorebirdPatchInputPrivate $Lease.privateDirectory
                    $backup=Join-Path $Lease.privateDirectory ('unexpected-asset-'+[guid]::NewGuid().ToString('N')+'.bin')
                    $output=[IO.File]::Open($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    try{$bytes=[IO.File]::ReadAllBytes($entry.path);$output.Write($bytes);$output.Flush($true)}finally{$output.Dispose()}
                }
                if($currentHash -cne $entry.originalHash){[IO.File]::WriteAllBytes($entry.path,$entry.original)}
                if($entry.restoreRequired -or $currentHash -cne $entry.originalHash){[IO.File]::SetLastWriteTimeUtc($entry.path,$entry.mtime)}
                if((Get-AuditSha256 $entry.path) -cne $entry.originalHash -or
                    (Get-ShorebirdPatchInputIndex $Lease.repository $entry.relative) -cne $entry.index){$failure=$true}
            } catch {$failure=$true}
        }
        if((Get-AuditSha256 $Lease.receiptPath) -cne $Lease.receiptSha256){$failure=$true}
        Assert-ShorebirdPatchInputSource $Lease.repository $Lease.sourceCommit
        if($failure){throw 'shorebird_patch_asset_restore_failed'}
        $Lease.restored=$true
    } finally {$Lease.active=$false}
}
