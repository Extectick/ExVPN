# SPDX-License-Identifier: Apache-2.0
# Host-only staging shared by every QA mode. Sandbox RO shares can overlay an
# existing destination, so all modes must seal the same helper filename set.
function Copy-AppQaModeHelpers([string]$Repository, [string]$InputRoot) {
    foreach ($relative in @(
        'scripts/qa/guest-transport-observe.ps1',
        'scripts/windows/sandbox/guest-app-subscriptions.ps1',
        'scripts/qa/windows-subscriptions-lib.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $Repository $relative) -Destination $InputRoot
    }
}
