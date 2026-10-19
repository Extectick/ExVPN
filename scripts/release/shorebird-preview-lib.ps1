# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Separate preview policy: ordinary/stable artifact policies remain unchanged.
Set-StrictMode -Version Latest

function Assert-ShorebirdPreviewAudit($Report,[string]$Target,[string]$Hash,[string]$Version) {
    if ($Report.schema -ne 1 -or $Report.target -cne $Target -or $Report.appVersion -cne $Version -or
        $Report.expectedAppVersion -cne $Version -or $Report.artifact.sha256 -cne $Hash -or
        !$Report.flutterRuntime.engineBytesBound -or $Report.flutterRuntime.identity.kind -cne 'shorebird' -or
        $Report.flutterRuntime.identity.buildMode -cne 'release' -or
        !$Report.noticeEvidence.xraySource.matched -or !$Report.noticeEvidence.xraySource.patch.included) {
        throw 'shorebird_preview_artifact_binding_failed'
    }
    $allowed = @('dart_flutter_runtime_link_inventory_incomplete','license_expressions_and_distribution_obligations_not_fully_reviewed')
    if ($Target -ceq 'Android') {
        $allowed += 'android_gradle_maven_runtime_inventory_missing'
        if (!$Report.signature.verified -or !$Report.signature.trustedSignerMatched -or $Report.signature.debug -or
            $Report.noticeSource -cne 'actual-apk-entries') { throw 'shorebird_preview_android_signature_failed' }
    } elseif ($Target -ceq 'Windows') {
        $allowed += @('development_package','release_signer_not_pinned','windows_signature_not_valid')
        if (!$Report.nsisExtraction.verified -or $Report.noticeSource -cne 'installer-payload-verified') { throw 'shorebird_preview_windows_payload_failed' }
    } else { throw 'shorebird_preview_target_invalid' }
    foreach ($finding in $Report.findings) {
        if ($finding.code -cnotin $allowed) { throw 'shorebird_preview_unexpected_audit_finding' }
    }
    if ($Report.releaseReady -or $Report.complete) { throw 'shorebird_preview_must_not_claim_stable_acceptance' }
}

function Export-ShorebirdPreviewAudit([string]$Repository,[string]$Target,[string]$ArtifactPath,[string]$OutputDirectory,[string]$Version,[string]$PrivateDirectory,[string]$AndroidSdkPath='',[string]$ExpectedSigner='') {
    $auditDirectory = Join-Path $Repository ('artifacts/release-audit/shorebird-' + [Guid]::NewGuid().ToString('N'))
    $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $Repository 'scripts/release/audit-artifact.ps1'),
        '-ArtifactPath',$ArtifactPath,'-OutputDirectory',$auditDirectory,'-FlutterRuntime','shorebird','-FlutterBuildMode','release')
    if ($Target -ceq 'Android') {
        $arguments += @('-ExpectedSignerSha256',$ExpectedSigner,'-AndroidSdkPath',$AndroidSdkPath,'-JavaPath',(Join-Path $env:JAVA_HOME 'bin/java.exe'))
    }
    & (Join-Path $PSHOME 'pwsh.exe') @arguments *> (Join-Path $PrivateDirectory 'audit-private.log')
    if ($LASTEXITCODE -notin @(0,2)) { throw 'shorebird_preview_audit_failed' }
    $report = Get-Content -LiteralPath (Join-Path $auditDirectory 'audit.json') -Raw | ConvertFrom-Json
    $binary = if ($Target -ceq 'Android') { $ArtifactPath } else { Join-Path $ArtifactPath $report.artifact.file }
    Assert-ShorebirdPreviewAudit $report $Target (Get-AuditSha256 $binary) $Version
    foreach ($file in @('audit.json','sbom.cdx.json')) {
        Copy-Item -LiteralPath (Join-Path $auditDirectory $file) -Destination (Join-Path $OutputDirectory "$($Target.ToLowerInvariant())-$file")
    }
}
