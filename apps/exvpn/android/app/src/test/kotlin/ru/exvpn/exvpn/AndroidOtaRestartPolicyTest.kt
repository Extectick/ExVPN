package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class AndroidOtaRestartPolicyTest {
    private val token = "a".repeat(32)
    private fun refuses(code: String, action: () -> Unit) {
        try { action(); fail("Expected rejection") }
        catch (failure: AndroidUpdateFailure) { assertEquals(code, failure.code) }
    }
    @Test fun allowsOnlyArgumentFreeForegroundIdleRestart() {
        for (input in listOf(mapOf("url" to "https://example.invalid"), mapOf("pid" to 12), "restart", false)) {
            refuses("invalid_request") { AndroidOtaRestartPolicy().begin(input, token, true, true) }
        }
        for (idle in listOf(false, true)) for (foreground in listOf(false, true)) {
            if (!idle || !foreground) refuses("restart_blocked") { AndroidOtaRestartPolicy().begin(null, token, idle, foreground) }
        }
        val policy = AndroidOtaRestartPolicy()
        policy.begin(null, token, true, true)
        assertTrue(policy.pending)
    }
    @Test fun rejectsMalformedSessionAndConcurrentRequests() {
        for (value in listOf("", "../escape", "A".repeat(32), "a".repeat(31), "a".repeat(33))) {
            refuses("invalid_request") { AndroidOtaRestartPolicy().begin(null, value, true, true) }
        }
        val policy = AndroidOtaRestartPolicy()
        policy.begin(null, token, true, true)
        refuses("operation_busy") { policy.begin(null, "b".repeat(32), true, true) }
        assertTrue(policy.owns(token))
    }
    @Test fun refusesCommitIfVpnStartedOrBrokerSessionIsStale() {
        val policy = AndroidOtaRestartPolicy()
        policy.begin(null, token, true, true)
        assertFalse(policy.commit("b".repeat(32), true))
        assertFalse(policy.commit(token, false))
        assertTrue(policy.pending)
        assertTrue(policy.cancel(token))
        assertFalse(policy.commit(token, true))
    }
    @Test fun cancellationReleasesLeaseAndLateBrokerCannotCommitNewSession() {
        val policy = AndroidOtaRestartPolicy()
        policy.begin(null, token, true, true)
        assertTrue(policy.cancel(token))
        val next = "b".repeat(32)
        policy.begin(null, next, true, true)
        assertFalse(policy.cancel(token))
        assertFalse(policy.commit(token, true))
        assertTrue(policy.owns(next))
    }
    @Test fun acceptedCommitIsSingleUse() {
        val policy = AndroidOtaRestartPolicy()
        policy.begin(null, token, true, true)
        assertTrue(policy.commit(token, true))
        assertFalse(policy.pending)
        assertFalse(policy.commit(token, true))
        assertFalse(policy.cancel(token))
    }
}
