package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class VpnConsentCoordinatorTest {
    private class Fixture {
        var prepared = false
        var prepareFails = false
        var launchFails = false
        var startFails = false
        var token = 7300
        val launches = mutableListOf<Int>()
        val waiting = mutableListOf<String>()
        val started = mutableListOf<String>()
        val failures = mutableListOf<Triple<String, String, String>>()
        val coordinator = VpnConsentCoordinator<String, String, String>(
            prepare = { if (prepareFails) throw IllegalStateException() else if (prepared) null else "system-consent" },
            nextToken = { ++token },
            launch = { _, code -> if (launchFails) throw IllegalStateException() else launches.add(code) },
            waiting = { waiting.add(it) },
            start = { request, _ -> if (startFails) throw IllegalStateException() else started.add(request) },
            fail = { request, reply, code -> failures.add(Triple(request, reply, code)) },
        )
        fun connect(request: String = "one") { coordinator.connect(request, "reply-$request") }
        fun error(): String = failures.single().third
    }

    @Test fun alreadyPreparedStartsWithoutClaimingToWaitForSystemDialog() {
        val fixture = Fixture().apply { prepared = true }
        fixture.connect()
        assertEquals(listOf("one"), fixture.started)
        assertTrue(fixture.launches.isEmpty())
        assertTrue(fixture.waiting.isEmpty())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun unpreparedLaunchesExactlyOneSystemRequestBeforeWaiting() {
        val fixture = Fixture()
        fixture.connect()
        assertEquals(listOf(7301), fixture.launches)
        assertEquals(listOf("one"), fixture.waiting)
        assertTrue(fixture.started.isEmpty())
        assertTrue(fixture.coordinator.pending)
    }

    @Test fun launcherFailureDoesNotLeaveFakeWaitingState() {
        val fixture = Fixture().apply { launchFails = true }
        fixture.connect()
        assertEquals("vpn_permission_unavailable", fixture.error())
        assertTrue(fixture.waiting.isEmpty())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun prepareFailureIsNotReportedAsUserDenial() {
        val fixture = Fixture().apply { prepareFails = true }
        fixture.connect()
        assertEquals("vpn_permission_unavailable", fixture.error())
        assertTrue(fixture.started.isEmpty())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun actualGrantRechecksPreparedStateAndStartsOnce() {
        val fixture = Fixture()
        fixture.connect()
        fixture.prepared = true
        fixture.coordinator.onActivityResult(7301, true)
        fixture.coordinator.onActivityResult(7301, true)
        assertEquals(listOf("one"), fixture.started)
        assertFalse(fixture.coordinator.pending)
        assertTrue(fixture.failures.isEmpty())
    }

    @Test fun okResultWithRevokedGrantDoesNotStartService() {
        val fixture = Fixture()
        fixture.connect()
        fixture.coordinator.onActivityResult(7301, true)
        assertEquals("vpn_permission_unavailable", fixture.error())
        assertTrue(fixture.started.isEmpty())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun actualDenialSettlesTheRequestAndCanBeRetried() {
        val fixture = Fixture()
        fixture.connect()
        fixture.coordinator.onActivityResult(7301, false)
        assertEquals("permission_denied", fixture.error())
        assertFalse(fixture.coordinator.pending)
        fixture.connect("two")
        assertEquals(listOf(7301, 7302), fixture.launches)
        assertTrue(fixture.coordinator.pending)
    }

    @Test fun lostResultCallbackRecoversPreparedGrantOnFocusedResume() {
        val fixture = Fixture()
        fixture.connect()
        fixture.coordinator.onActivityPaused()
        fixture.prepared = true
        fixture.coordinator.onFocusedForeground()
        assertEquals(listOf("one"), fixture.started)
        assertTrue(fixture.failures.isEmpty())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun returnedDialogWithoutGrantSettlesDenial() {
        val fixture = Fixture()
        fixture.connect()
        fixture.coordinator.onActivityPaused()
        fixture.coordinator.onFocusedForeground()
        assertEquals("permission_denied", fixture.error())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun noOpLaunchWhileActivityNeverLeftIsUnavailableNotWaitingForever() {
        val fixture = Fixture()
        fixture.connect()
        fixture.coordinator.onFocusedForeground()
        assertEquals("vpn_permission_unavailable", fixture.error())
        assertFalse(fixture.coordinator.pending)
        assertTrue(fixture.started.isEmpty())
    }

    @Test fun cancelReturnsReplyAndLateGrantCannotStartTunnel() {
        val fixture = Fixture()
        fixture.connect()
        assertEquals("one" to "reply-one", fixture.coordinator.cancel())
        fixture.prepared = true
        fixture.coordinator.onActivityResult(7301, true)
        assertTrue(fixture.started.isEmpty())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun lateOldGrantCannotCompleteANewerConsentRequest() {
        val fixture = Fixture()
        fixture.connect()
        fixture.coordinator.cancel()
        fixture.connect("two")
        fixture.prepared = true
        fixture.coordinator.onActivityResult(7301, true)
        assertTrue(fixture.started.isEmpty())
        assertTrue(fixture.coordinator.pending)
        fixture.coordinator.onActivityResult(7302, true)
        assertEquals(listOf("two"), fixture.started)
    }

    @Test fun competingRequestDoesNotSupersedeOriginalConsent() {
        val fixture = Fixture()
        fixture.connect()
        fixture.connect("two")
        assertEquals(Triple("two", "reply-two", "operation_in_progress"), fixture.failures.single())
        assertEquals(listOf(7301), fixture.launches)
        fixture.prepared = true
        fixture.coordinator.onActivityResult(7301, true)
        assertEquals(listOf("one"), fixture.started)
    }

    @Test fun activityDestroyedCompletesReplyAndIgnoresStaleResult() {
        val fixture = Fixture()
        fixture.connect()
        fixture.coordinator.dispose()
        fixture.coordinator.dispose()
        fixture.prepared = true
        fixture.coordinator.onActivityResult(7301, true)
        assertEquals("permission_cancelled", fixture.error())
        assertTrue(fixture.started.isEmpty())
        assertFalse(fixture.coordinator.pending)
    }

    @Test fun foregroundServiceStartFailureIsSettledAsConnectionError() {
        val fixture = Fixture().apply { prepared = true; startFails = true }
        fixture.connect()
        assertEquals("native_start_failed", fixture.error())
        assertFalse(fixture.coordinator.pending)
        assertTrue(fixture.waiting.isEmpty())
    }
}
