# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Pure selection plus read-only Git helpers; dot-sourcing never runs tests.
Set-StrictMode -Version Latest

function Get-FastValidationLaneNames {
    @('domain', 'state', 'updates', 'app', 'core', 'android', 'windows', 'xray', 'installer', 'scripts')
}

function Get-FastValidationExecutionOrder {
    param([string[]]$Lanes = @())
    # Start long independent suites first so the scripts lane does not become
    # the tail of Full. This is scheduling only: never add or remove a suite.
    # Priorities use observed local durations, not mutable cached test results.
    $priority = @('scripts', 'app', 'core', 'xray', 'android', 'windows', 'updates', 'domain', 'state', 'installer')
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($lane in $Lanes) {
        if ($lane -cnotin $priority -or !$selected.Add($lane)) {
            throw 'Unknown or duplicate validation lane in execution schedule.'
        }
    }
    @($priority | Where-Object { $selected.Contains($_) })
}

function Get-FastValidationPlan {
    param([string[]]$ChangedPaths = @(), [switch]$Full)
    $all = @(Get-FastValidationLaneNames)
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $reasons = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Queue[string]]::new()
    # Reverse dependencies. Domain/native profile contracts are deliberately
    # coupled; a core change must exercise BOTH native adapters and Dart consumers.
    $dependents = @{
        domain = @('state', 'app', 'core')
        state = @('app')
        updates = @('app')
        core = @('domain', 'android', 'windows')
        android = @('app')
        windows = @('app', 'installer')
        xray = @('core')
    }
    if ($Full) {
        foreach ($lane in $all) { $pending.Enqueue($lane) }
        $reasons.Add('full behavioral suite requested')
    } else {
        foreach ($raw in $ChangedPaths) {
            $path = $raw.Replace('\', '/')
            $lane = switch -Regex ($path) {
                '^packages/exvpn_domain/' { 'domain'; break }
                '^packages/exvpn_client_state/' { 'state'; break }
                '^packages/exvpn_updates/' { 'updates'; break }
                '^apps/exvpn/android/' { 'android'; break }
                '^apps/exvpn/windows/' { 'windows'; break }
                '^apps/exvpn/' { 'app'; break }
                '^native/core/' { 'core'; break }
                '^native/android/' { 'android'; break }
                '^native/windows/' { 'windows'; break }
                '^native/patches/' { 'xray'; break }
                '^docs/evidence/(?:[a-zA-Z0-9_.-]+/)*[a-zA-Z0-9_.-]+\.json$' { 'documentation'; break }
                '^(docs|design)/.*\.(md|png|jpe?g|gif|webp|svg|pdf)$' { 'documentation'; break }
                '^(README\.md|LICENSE|NOTICE)$' { 'documentation'; break }
                default { 'all' }
            }
            if ($lane -eq 'documentation') { continue }
            if ($lane -eq 'all') {
                foreach ($item in $all) { $pending.Enqueue($item) }
                $reasons.Add('unclassified/shared tooling change: full behavioral suite')
            } else {
                $pending.Enqueue($lane)
            }
        }
    }
    while ($pending.Count) {
        $lane = $pending.Dequeue()
        if (!$selected.Add($lane)) { continue }
        if ($dependents.ContainsKey($lane)) {
            foreach ($consumer in $dependents[$lane]) { $pending.Enqueue($consumer) }
        }
    }
    [pscustomobject]@{
        lanes = @($all | Where-Object { $selected.Contains($_) })
        executionOrder = @(Get-FastValidationExecutionOrder @($all | Where-Object { $selected.Contains($_) }))
        reasons = @($reasons | Sort-Object -Unique)
        changedFileCount = $ChangedPaths.Count
        requiresBuildAndRuntimeAcceptance = $selected.Count -gt 0
    }
}

function Invoke-FastValidationGit {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git.exe'
    $start.WorkingDirectory = $Repository
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Read-only Git inspection failed; no checks were skipped.' }
        $output
    } finally { $process.Dispose() }
}

function Get-FastValidationChangedPaths {
    param([Parameter(Mandatory)][string]$Repository, [string]$BaseRef = '')
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    # Separate staged/unstaged diffs also catch a staged edit reverted in the
    # working tree. Disabling rename folding retains both old and new paths.
    $queries = [Collections.Generic.List[object]]::new()
    $queries.Add(@('diff', '--name-only', '-z', '--no-renames', '--'))
    $queries.Add(@('diff', '--cached', '--name-only', '-z', '--no-renames', '--'))
    $queries.Add(@('ls-files', '--others', '--exclude-standard', '-z'))
    if ($BaseRef) {
        $revision = (Invoke-FastValidationGit $Repository @('rev-parse', '--verify', '--end-of-options', "$BaseRef^{commit}")).Trim()
        if ($revision -notmatch '^[a-f0-9]{40,64}$') { throw 'Invalid base commit.' }
        $queries.Add(@('diff', '--name-only', '-z', '--no-renames', "$revision...HEAD", '--'))
    }
    foreach ($query in $queries) {
        $output = Invoke-FastValidationGit $Repository $query
        foreach ($path in $output.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
            $null = $paths.Add($path)
        }
    }
    @($paths | Sort-Object)
}

function Get-FastValidationSourceFingerprint {
    param([Parameter(Mandatory)][string]$Repository)
    $listing = Invoke-FastValidationGit $Repository @('ls-files', '--cached', '--others', '--exclude-standard', '-z')
    $files = @($listing.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($relative in $files) {
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes($relative + [char]0))
            $path = Join-Path $Repository $relative
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $fileHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                $hash.AppendData([Text.Encoding]::UTF8.GetBytes($fileHash))
            } else { $hash.AppendData([Text.Encoding]::UTF8.GetBytes('deleted')) }
        }
        [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally { $hash.Dispose() }
}
