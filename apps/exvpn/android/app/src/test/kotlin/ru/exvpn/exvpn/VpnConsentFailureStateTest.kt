package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class VpnConsentFailureStateTest {
    private fun failedAfterConsent(code: String, service: Boolean?, pending: Boolean?): Map<String, String> {
        val state = VpnConsentFailureState.resolve("requested-profile", service, pending)
        return buildMap {
            put("phase", state.phase)
            state.profileId?.let { put("activeProfileId", it) }
            put("errorCode", code)
        }
    }

    @Test fun initialDenialIsAuthoritativeIdleWithRetryableError() {
        assertEquals(mapOf("phase" to "disconnected", "errorCode" to "permission_denied"),
            failedAfterConsent("permission_denied", false, false))
    }

    @Test fun unavailableSystemPromptIsIdleWithoutAnInventedProfile() {
        assertEquals(mapOf("phase" to "disconnected", "errorCode" to "vpn_permission_unavailable"),
            failedAfterConsent("vpn_permission_unavailable", false, false))
    }

    @Test fun initialActivityCancellationIsIdleWithTheActualCancellationCode() {
        assertEquals(mapOf("phase" to "disconnected", "errorCode" to "permission_cancelled"),
            failedAfterConsent("permission_cancelled", false, false))
    }

    @Test fun existingServiceOrQueuedRequestNeverClearsConservativeOwnership() {
        for ((service, pending) in listOf(true to false, false to true, true to true)) {
            assertEquals(mapOf("phase" to "error", "activeProfileId" to "requested-profile", "errorCode" to "permission_denied"),
                failedAfterConsent("permission_denied", service, pending))
        }
    }

    @Test fun unknownNativeOwnershipIsNotProofOfIdle() {
        for ((service, pending) in listOf(null to false, false to null, null to null)) {
            val state = failedAfterConsent("vpn_permission_unavailable", service, pending)
            assertEquals("error", state["phase"])
            assertEquals("requested-profile", state["activeProfileId"])
        }
    }
}
