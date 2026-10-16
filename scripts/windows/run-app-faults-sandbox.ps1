# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SandboxId,
    [Parameter(Mandatory)][string]$BundleDirectory,
    [Parameter(Mandatory)][int]$FixtureProcessId,
    [Parameter(Mandatory)][datetime]$FixtureStartedUtc
)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bundle=[IO.Path]::GetFullPath($BundleDirectory).TrimEnd('\')
$prefix=[IO.Path]::GetFullPath((Join-Path $repository 'artifacts/windows')).TrimEnd('\')+'\'
if (!$bundle.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Local QA artifact directory required.' }
$inputRoot=Join-Path $bundle 'input'
$outputRoot=Join-Path $bundle 'output'
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.faults -or $marker.forbiddenHost -ine $env:COMPUTERNAME -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'This host must own the fault-enabled bundle.' }
$fixtureExe=Join-Path $repository 'artifacts/windows/qa-protocol-server.exe'
function Assert-Fixture {
    $process=Get-Process -Id $FixtureProcessId -ErrorAction Stop
    if ($process.Path -ine $fixtureExe -or $process.StartTime.ToUniversalTime().Ticks -ne $FixtureStartedUtc.ToUniversalTime().Ticks) { throw 'Fixture process ownership differs.' }
    $process
}
$null=Assert-Fixture
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory=& $wsb list --raw | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) { throw 'Requested live Sandbox is unavailable.' }
function Guest-Command([string]$Script,[string]$Arguments='') {
    # Arguments are fixed strings from this script, never supplied by guest output.
    'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\'+$Script+' -ConfirmDisposableGuest '+$Arguments
}
function Invoke-Guest([string]$Script,[string]$Arguments='') {
    $raw=& $wsb exec --id $SandboxId.ToString() --run-as System --command (Guest-Command $Script $Arguments) --raw
    if ($LASTEXITCODE -ne 0 -or ($raw | ConvertFrom-Json).ExitCode -ne 0) { throw 'Guest control action failed; inspect the local guest reports.' }
}
$result=[ordered]@{runId=$marker.runId;startedUtc=[DateTime]::UtcNow.ToString('o');computerUse=$false;actions=@();passed=$false;cleanupPassed=$false}
$ownedSession=$false
$fixtureStopped=$false
$launcher=$null
try {
    Invoke-Guest 'guest-app-faults.ps1' '-Action Prepare'
    $ownedSession=$true
    Invoke-Guest 'guest-app-qa.ps1' '-Action Refresh'
    $psi=[Diagnostics.ProcessStartInfo]::new($wsb)
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    foreach ($argument in @('exec','--id',$SandboxId.ToString(),'--run-as','ExistingLogin','--command',(Guest-Command 'guest-app-launch.ps1'),'--raw')) { $psi.ArgumentList.Add($argument) }
    $launcher=[Diagnostics.Process]::Start($psi)
    $stdout=$launcher.StandardOutput.ReadToEndAsync()
    $stderr=$launcher.StandardError.ReadToEndAsync()
    $step=1
    $actions=@('stop-fixture','crash-service','restart-service')
    $deadline=[DateTime]::UtcNow.AddMinutes(20)
    while (!$launcher.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Bounded QA coordinator deadline expired.' }
        $requestFile=Join-Path $outputRoot 'fault-request.json'
        if ($step -le $actions.Count -and (Test-Path -LiteralPath $requestFile)) {
            if ((Get-Item -LiteralPath $requestFile).Length -gt 4096) { throw 'Oversized coordination request.' }
            $request=Get-Content -LiteralPath $requestFile -Raw | ConvertFrom-Json
            if ($request.runId -ceq $marker.runId -and $request.step -eq $step) {
                if ($request.action -cne $actions[$step-1]) { throw 'Unexpected fault action; no command executed.' }
                switch ($request.action) {
                    'stop-fixture' { $process=Assert-Fixture; Stop-Process -Id $process.Id; if(!$process.WaitForExit(10000)){throw 'Fixture did not stop'}; $fixtureStopped=$true }
                    'crash-service' { Invoke-Guest 'guest-app-faults.ps1' '-Action Crash' }
                    'restart-service' {
                        Invoke-Guest 'guest-app-faults.ps1' '-Action Restart'
                        # Cleanup may issue another restart after disconnect.
                        # Preserve the observed crash-latch recovery separately.
                        Copy-Item -LiteralPath (Join-Path $outputRoot 'fault-Restart.json') -Destination (Join-Path $outputRoot 'fault-Restart-request.json') -Force
                    }
                }
                $result.actions+=@([ordered]@{step=$step;action=$actions[$step-1];utc=[DateTime]::UtcNow.ToString('o')})
                $ack=Join-Path $outputRoot 'fault-ack.tmp'
                [ordered]@{runId=$marker.runId;step=$step;ok=$true} | ConvertTo-Json | Set-Content -LiteralPath $ack -Encoding utf8
                [IO.File]::Move($ack,(Join-Path $outputRoot 'fault-ack.json'),$true)
                $step++
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $native=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json
    $null=$stderr.GetAwaiter().GetResult()
    if ($launcher.ExitCode -ne 0 -or $native.ExitCode -ne 0) { throw 'Flutter integration process failed.' }
    $flutter=Get-Content -LiteralPath (Join-Path $outputRoot 'flutter-report.json') -Raw | ConvertFrom-Json
    if ($flutter.runId -cne $marker.runId -or !$flutter.frameworkPassed -or !$flutter.allProtocolsPassed -or !$flutter.faultsPassed -or $step -ne 4) { throw 'The required automated checks did not pass.' }
    if ($marker.PSObject.Properties['unelevated'] -and $marker.unelevated) {
        $launch=Get-Content -LiteralPath (Join-Path $outputRoot 'launch-report.json') -Raw | ConvertFrom-Json
        if ($launch.runId -cne $marker.runId -or $launch.administratorToken -ne $false -or $launch.elevated -ne $false -or !$launch.mediumIntegrity -or !$launch.adminPrivilegesAbsent -or !$launch.processTokenVerified -or !$launch.privilegedAccessDenied -or !$flutter.ordinaryUserTokenTested) { throw 'Unprivileged execution was not proven.' }
        $result.ordinaryUserTokenTested=$true
        $result.tokenMethod=$launch.tokenMethod
    }
    $result.passed=$true
} catch {
    $result.error='automated_fault_run_failed'
    Write-Warning $_.Exception.Message
} finally {
    if ($ownedSession) {
        try {
            # Restart preserves the latch. Only the subsequent explicit owned
            # maintenance disconnect may release protection during cleanup.
            Invoke-Guest 'guest-app-faults.ps1' '-Action Restart'
            Invoke-Guest 'guest-app-qa.ps1' '-Action Restore'
            Invoke-Guest 'guest-app-faults.ps1' '-Action Finish'
            $result.cleanupPassed=$true
        } catch { $result.cleanupError='guest_cleanup_failed'; Write-Warning $_.Exception.Message }
    }
    if (!$fixtureStopped -and (Get-Process -Id $FixtureProcessId -ErrorAction SilentlyContinue)) {
        $process=Assert-Fixture
        Stop-Process -Id $process.Id
        $fixtureStopped=$true
    }
    $result.fixtureStopped=$fixtureStopped
    $result.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'fault-coordinator.json') -Encoding utf8
}
if (!$result.passed -or !$result.cleanupPassed) { throw 'QA failed; sanitized results are retained in the bundle output.' }
Write-Host 'Flutter/SCM failure checks and guest cleanup passed without Computer Use.'
