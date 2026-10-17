# SPDX-License-Identifier: Apache-2.0
# Pure demo policy is separate from the unchanged stable release audit.
#requires -Version 7.0
Set-StrictMode -Version Latest

function Get-DemoSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-DemoAudit($Report, [ValidateSet('Android','Windows')][string]$Target, [string]$ArtifactHash, [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$')][string]$ExpectedVersion = '0.1.0+18') {
    if ($Report.schema -ne 1 -or $Report.target -cne $Target -or
        $Report.appVersion -cne $ExpectedVersion -or $Report.expectedAppVersion -cne $ExpectedVersion -or
        $Report.artifact.sha256 -cne $ArtifactHash -or $ArtifactHash -cnotmatch '^[a-f0-9]{64}$' -or
        !$Report.flutterRuntime.engineBytesBound -or $Report.flutterRuntime.identity.kind -cne 'ordinary' -or
        $Report.flutterRuntime.identity.buildMode -cne 'release' -or
        !$Report.noticeEvidence.xraySource.matched -or !$Report.noticeEvidence.xraySource.patch.included) {
        throw 'demo_artifact_binding_failed'
    }
    # These are disclosed demo limitations, not a stable audit PASS. The Maven
    # license bundle is supplied separately; this audit does not claim its final
    # post-R8 link graph. Any other finding (bytes, pin, signature, source) fails.
    $allowed = @('dart_flutter_runtime_link_inventory_incomplete',
        'license_expressions_and_distribution_obligations_not_fully_reviewed')
    if ($Target -ceq 'Android') {
        $allowed += 'android_gradle_maven_runtime_inventory_missing'
        if (!$Report.signature.verified -or !$Report.signature.trustedSignerMatched -or $Report.signature.debug -or
            $Report.noticeSource -cne 'actual-apk-entries') { throw 'demo_android_signature_or_notices_failed' }
    } else {
        $allowed += @('development_package','release_signer_not_pinned','windows_signature_not_valid')
        if (!$Report.nsisExtraction.verified -or $Report.noticeSource -cne 'installer-payload-verified') {
            throw 'demo_windows_payload_failed'
        }
    }
    foreach ($finding in $Report.findings) {
        if ($finding.code -cnotin $allowed) { throw "demo_unexpected_audit_finding_$($finding.code)" }
    }
    if ($Report.releaseReady -or $Report.complete) { throw 'demo_must_not_claim_stable_acceptance' }
}

function Export-DemoAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$ExpectedSignerSha256 = '',
        [string]$AndroidSdkPath = '',
        [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$')][string]$ExpectedVersion = '0.1.0+18'
    )
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $auditDirectory = Join-Path $repository ('artifacts/release-audit/demo-' + $Target.ToLowerInvariant() + '-' + [Guid]::NewGuid().ToString('N'))
    $arguments = @('-NoProfile','-NonInteractive','-File', (Join-Path $PSScriptRoot 'audit-artifact.ps1'),
        '-ArtifactPath',$ArtifactPath,'-OutputDirectory',$auditDirectory,'-FlutterRuntime','ordinary','-FlutterBuildMode','release')
    if ($Target -ceq 'Android') {
        if ($ExpectedSignerSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'demo_signer_required' }
        $arguments += @('-ExpectedSignerSha256',$ExpectedSignerSha256,'-AndroidSdkPath',$AndroidSdkPath,
            '-JavaPath',(Join-Path $env:JAVA_HOME 'bin/java.exe'))
    }
    & (Join-Path $PSHOME 'pwsh.exe') @arguments
    if ($LASTEXITCODE -ne 2) { throw 'demo_stable_audit_unexpected_exit' }
    $report = Get-Content -LiteralPath (Join-Path $auditDirectory 'audit.json') -Raw | ConvertFrom-Json
    $binary = if ($Target -ceq 'Android') { $ArtifactPath } else { Join-Path $ArtifactPath $report.artifact.file }
    Assert-DemoAudit $report $Target (Get-DemoSha256 $binary) $ExpectedVersion
    $stem = $Target.ToLowerInvariant()
    Copy-Item -LiteralPath (Join-Path $auditDirectory 'audit.json') -Destination (Join-Path $OutputDirectory "$stem-audit.json")
    Copy-Item -LiteralPath (Join-Path $auditDirectory 'sbom.cdx.json') -Destination (Join-Path $OutputDirectory "$stem-sbom.cdx.json")
}

function Get-DemoAssetRecord([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]+$' -or $file.Length -le 0) {
        throw 'demo_asset_invalid'
    }
    [ordered]@{file=$file.Name;bytes=$file.Length;sha256=(Get-DemoSha256 $file.FullName)}
}
