# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Offline source provenance for the updater's own notices, not its crate or
# Rust-runtime license closure and not a publisher build/link attestation.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')

function Get-ShorebirdUpdaterPinnedFile([string]$Root, [string]$Name, $Pin) {
    if ($Pin.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Pin.gitBlob -cnotmatch '^[a-f0-9]{40}$' -or
        ($Pin.size -isnot [long] -and $Pin.size -isnot [int]) -or $Pin.size -le 0 -or $Pin.size -gt 1MB) { throw 'shorebird_updater_pin_invalid' }
    if (!(Test-Path -LiteralPath (Join-Path $Root $Name) -PathType Leaf)) { throw 'shorebird_updater_input_missing' }
    $file = Get-ReleaseRuntimeFile $Root $Name
    if ($file.sha256 -cne $Pin.sha256 -or $file.size -ne $Pin.size) { throw 'shorebird_updater_input_mismatch' }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Root $Name))
    $header = [Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)`0")
    $blob = [byte[]]::new($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $blob, 0, $header.Length)
    [Array]::Copy($bytes, 0, $blob, $header.Length, $bytes.Length)
    if ([Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($blob)).ToLowerInvariant() -cne $Pin.gitBlob -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $file.sha256) { throw 'shorebird_updater_input_mismatch' }
    [ordered]@{path=$Name;sha256=$file.sha256;size=$file.size;gitBlob=$Pin.gitBlob}
}

function Get-ShorebirdUpdaterNotices([string]$Repository, $Runtime) {
    # The caller supplies the selected result of Get-ReleaseFlutterRuntime.
    # Ordinary builds neither read these inputs nor acquire a new component.
    $identity = Get-ReleaseRuntimeField $Runtime 'Identity'
    $kind = Get-ReleaseRuntimeField $identity 'kind'
    if ($kind -ceq 'ordinary') { return $null }
    if ($kind -cne 'shorebird' -or $identity.buildMode -cne 'release' -or $identity.target -cnotin @('Android','Windows')) { throw 'shorebird_updater_runtime_invalid' }
    $pinPath = 'scripts/release/shorebird-updater-notices.lock.json'
    $pinFile = Get-ReleaseRuntimeFile $Repository $pinPath
    if ($pinFile.size -gt 16KB) { throw 'shorebird_updater_pin_invalid' }
    $pin = Get-Content -LiteralPath (Join-Path $Repository $pinPath) -Raw | ConvertFrom-Json -AsHashtable
    if ($pin.schemaVersion -ne 1 -or $pin.updater.repository -cne 'https://github.com/shorebirdtech/updater' -or
        $pin.updater.revision -cnotmatch '^[a-f0-9]{40}$' -or $pin.flutter.revision -cnotmatch '^[a-f0-9]{40}$' -or
        $pin.flutter.engineRevision -cnotmatch '^[a-f0-9]{40}$' -or $pin.flutter.depsSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $pin.flutter.depsGitBlob -cnotmatch '^[a-f0-9]{40}$' -or
        ($pin.flutter.depsSize -isnot [int] -and $pin.flutter.depsSize -isnot [long]) -or $pin.flutter.depsSize -le 0 -or $pin.flutter.depsSize -gt 1MB -or
        $pin.updater.notices -isnot [Collections.IList] -or $pin.updater.notices.Count -ne 2 -or
        $pin.updater.notices[0].path -cne 'LICENSE-APACHE' -or $pin.updater.notices[1].path -cne 'LICENSE-MIT') { throw 'shorebird_updater_pin_invalid' }
    if ($identity.flutterRevision -cne $pin.flutter.revision -or $identity.engineRevision -cne $pin.flutter.engineRevision) { throw 'shorebird_updater_runtime_mismatch' }
    Assert-ReleaseRuntimeCheckout $Runtime.SdkRoot $identity.flutterRevision
    $deps = Get-ReleaseRuntimeFile $Runtime.SdkRoot 'DEPS'
    if ($deps.size -gt 1MB) { throw 'shorebird_updater_deps_mismatch' }
    $committedBlob = Invoke-ReleaseRuntimeGit $Runtime.SdkRoot @('rev-parse','--verify',"$($identity.flutterRevision):DEPS")
    if ($committedBlob -cne $pin.flutter.depsGitBlob) { throw 'shorebird_updater_deps_mismatch' }
    # Source checkouts may have CRLF; authenticate the commit's exact blob and
    # permit only its literal LF or CRLF checkout form. Do not apply Git filters
    # or normalize an arbitrary modified source into a matching hash.
    $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $depsText = Invoke-AuditTool $git @('-c','core.fsmonitor=false','-C',$Runtime.SdkRoot,'cat-file','blob',"$($identity.flutterRevision):DEPS") 30
    $depsBytes = [Text.Encoding]::UTF8.GetBytes($depsText)
    $depsSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($depsBytes)).ToLowerInvariant()
    $crlfBytes = [Text.Encoding]::UTF8.GetBytes($depsText.Replace("`n","`r`n"))
    $crlfSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($crlfBytes)).ToLowerInvariant()
    if ($depsText.Contains("`r") -or $depsBytes.Length -ne $pin.flutter.depsSize -or $depsSha256 -cne $pin.flutter.depsSha256 -or
        ($deps.sha256 -cne $depsSha256 -and $deps.sha256 -cne $crlfSha256)) { throw 'shorebird_updater_deps_mismatch' }
    # Read only fixed literal fields from the authenticated DEPS; never execute
    # the Python configuration or fetch its dependencies.
    $revision = [regex]::Matches($depsText, '(?m)^\s*["'']updater_rev["'']:\s*["'']([a-f0-9]{40})["''],?\s*$')
    $repositoryMatches = [regex]::Matches($depsText, '(?m)^\s*["'']updater_git["'']:\s*["'']([^"'']+)["''],?\s*$')
    if ($revision.Count -ne 1 -or $revision[0].Groups[1].Value -cne $pin.updater.revision -or
        $repositoryMatches.Count -ne 1 -or $repositoryMatches[0].Groups[1].Value -cne "$($pin.updater.repository).git") { throw 'shorebird_updater_deps_selection_mismatch' }
    $root = Join-Path $Repository "scripts/release/licenses/shorebird-updater-$($pin.updater.revision)"
    Assert-AuditNoLinks $root
    $lock = Get-ShorebirdUpdaterPinnedFile $root 'Cargo.lock' $pin.updater.cargoLock
    $notices = @($pin.updater.notices | ForEach-Object { Get-ShorebirdUpdaterPinnedFile $root $_.path $_ })
    # The existing Add-Notice scans recursively. Reject unexpected additions
    # before it can copy an unreviewed license or create an incomplete bundle.
    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force)) {
        if ($entry.PSIsContainer -or $entry.Name -cnotin @('Cargo.lock','LICENSE-APACHE','LICENSE-MIT','.gitattributes')) { throw 'shorebird_updater_input_unexpected' }
    }
    [pscustomobject]@{
        Name='Shorebird native updater'; Version=$pin.updater.revision; SourceRoot=$root
        SourceUrl="$($pin.updater.repository)/tree/$($pin.updater.revision)"
        Evidence=[ordered]@{
            schema=1; binding='engine-deps-and-source-lock'; repository=$pin.updater.repository; revision=$pin.updater.revision
            flutterRevision=$identity.flutterRevision; engineRevision=$identity.engineRevision
            inputPin=[ordered]@{path=$pinPath;sha256=$pinFile.sha256}
            deps=[ordered]@{path='DEPS';sha256=$depsSha256;size=$depsBytes.Length;gitBlob=$committedBlob;checkoutSha256=$deps.sha256}
            cargoLock=$lock; notices=$notices
            binaryDependencyClosureVerified=$false; completeLicenseCoverage=$false
        }
    }
}

function Assert-ShorebirdUpdaterNotices($Inventory, $Expected, [string]$Directory) {
    $components = @($Inventory.components | Where-Object name -CEQ 'Shorebird native updater')
    if ($null -eq $Expected) {
        if ($components.Count -or $null -ne (Get-ReleaseRuntimeField $Inventory 'shorebirdUpdater')) { throw 'shorebird_updater_notice_unexpected' }
        return
    }
    if (($Inventory.shorebirdUpdater | ConvertTo-Json -Depth 10 -Compress) -cne ($Expected.Evidence | ConvertTo-Json -Depth 10 -Compress) -or
        $components.Count -ne 1 -or $components[0].version -cne $Expected.Version -or $components[0].source -cne $Expected.SourceUrl -or
        @($components[0].notices).Count -ne 2) { throw 'shorebird_updater_notice_mismatch' }
    foreach ($notice in $Expected.Evidence.notices) {
        $matches = @($components[0].notices | Where-Object { [IO.Path]::GetFileName($_.path) -ceq $notice.path })
        if ($matches.Count -ne 1 -or $matches[0].sha256 -cne $notice.sha256) { throw 'shorebird_updater_notice_mismatch' }
        $actual = Get-ReleaseRuntimeFile $Directory $matches[0].path
        if ($actual.sha256 -cne $notice.sha256 -or $actual.size -ne $notice.size) { throw 'shorebird_updater_notice_mismatch' }
    }
}
