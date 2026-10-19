package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class AutomaticSelectionPolicyTest {
    @Test fun rotatesEveryUserCandidateThenBacksOff() {
        val policy = AutomaticSelectionPolicy(3, 0)
        assertEquals(AutomaticSelectionPolicy.Next(1, 2000), policy.failed())
        assertEquals(AutomaticSelectionPolicy.Next(2, 2000), policy.failed())
        assertEquals(AutomaticSelectionPolicy.Next(0, 30000), policy.failed())
        assertEquals(AutomaticSelectionPolicy.Next(1, 2000), policy.failed())
    }
    @Test fun successfulHttpsStartsAFreshSweepFromWorkingCandidate() {
        val policy = AutomaticSelectionPolicy(2, 0)
        assertEquals(AutomaticSelectionPolicy.Next(1, 2000), policy.failed())
        policy.succeeded()
        assertEquals(AutomaticSelectionPolicy.Next(0, 2000), policy.failed())
    }
    @Test fun singleCandidateRetriesSlowlyWithoutUnboundedImmediateRecursion() {
        val policy = AutomaticSelectionPolicy(1, 0)
        repeat(10) { assertEquals(AutomaticSelectionPolicy.Next(0, 30000), policy.failed()) }
    }
    @Test fun onlyKnownTransportFailuresPermitRotation() {
        for (code in listOf("network_unavailable", "endpoint_resolution_failed", "tunnel_https_failed", "tunnel_https_status")) {
            assertTrue(AutomaticSelectionPolicy.retryable(code))
        }
        for (code in listOf("native_storage_unavailable", "owner_policy_unavailable", "core_config_rejected", "tun_duplicate_failed", "native_start_failed", "core_not_running", "unknown")) {
            assertFalse(AutomaticSelectionPolicy.retryable(code))
        }
    }
    @Test fun rejectsUnboundedOrInvalidGroupIndices() {
        for ((count, index) in listOf(0 to 0, 33 to 0, 2 to -1, 2 to 2)) {
            try { AutomaticSelectionPolicy(count, index); fail("invalid group accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
