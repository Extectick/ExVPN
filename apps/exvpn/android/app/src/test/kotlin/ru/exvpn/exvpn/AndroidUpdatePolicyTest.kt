package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class AndroidUpdatePolicyTest {
    private val sha = "a".repeat(64)
    private val request = AndroidInstallRequest("0.1.5", 26, sha)
    private val installed = AndroidPackageIdentity(AndroidUpdatePolicy.PACKAGE, "0.1.4", 25, 30, setOf(AndroidUpdatePolicy.SIGNER))
    private val archive = installed.copy(version = "0.1.5", build = 26)
    private fun refused(code: String, action: () -> Unit) {
        try { action(); fail("Expected rejection") } catch (failure: AndroidUpdateFailure) { assertEquals(code, failure.code) }
    }
    @Test fun acceptsOnlyNewerSamePackageAndPinnedCurrentSigner() { AndroidUpdatePolicy.validate(request, installed, archive, 30) }
    @Test fun requestRejectsExtraPathUrlAndWrongTypes() {
        val good = mapOf("version" to "0.1.5", "build" to 26, "sha256" to sha)
        assertEquals(request, AndroidInstallRequest.parse(good))
        for (extra in listOf("path", "url", "publicKey")) refused("invalid_request") { AndroidInstallRequest.parse(good + (extra to "ignored")) }
        for (build in listOf(26.0, "26", true, 0, -1, 2147483648L)) refused("invalid_request") { AndroidInstallRequest.parse(good + ("build" to build)) }
        refused("invalid_request") { AndroidInstallRequest.parse(good + ("sha256" to "../escape")) }
        refused("invalid_request") { AndroidInstallRequest.parse(good + ("version" to "00.1.5")) }
    }
    @Test fun rejectsForeignPackageAndMetadataNotBoundToApprovedOffer() {
        refused("apk_invalid") { AndroidUpdatePolicy.validate(request, installed, archive.copy(packageName = "other.app"), 36) }
        refused("apk_invalid") { AndroidUpdatePolicy.validate(request, installed, archive.copy(build = 27), 36) }
        refused("apk_invalid") { AndroidUpdatePolicy.validate(request, installed, archive.copy(version = "0.1.6"), 36) }
    }
    @Test fun rejectsUnpinnedArchiveAndUnpinnedInstalledOrMultipleSigners() {
        for (signers in listOf(emptySet(), setOf(sha), setOf(sha, AndroidUpdatePolicy.SIGNER))) {
            refused("signature_invalid") { AndroidUpdatePolicy.validate(request, installed, archive.copy(signers = signers), 36) }
            refused("signature_invalid") { AndroidUpdatePolicy.validate(request, installed.copy(signers = signers), archive, 36) }
        }
    }
    @Test fun rejectsEqualOrOlderBuildEvenWhenVersionIsHigher() {
        for (build in listOf(24L, 25L)) refused("apk_incompatible") {
            AndroidUpdatePolicy.validate(request.copy(build = build), installed, archive.copy(build = build), 36)
        }
    }
    @Test fun rejectsSemverDowngradeEvenWithHigherBuild() {
        refused("apk_incompatible") { AndroidUpdatePolicy.validate(request.copy(version = "0.1.3"), installed, archive.copy(version = "0.1.3"), 36) }
    }
    @Test fun rejectsUnsupportedSdkAndUnknownCurrentVersion() {
        refused("apk_incompatible") { AndroidUpdatePolicy.validate(request, installed, archive.copy(minSdk = 36), 30) }
        refused("apk_incompatible") { AndroidUpdatePolicy.validate(request, installed.copy(version = "invalid"), archive, 36) }
    }
}
