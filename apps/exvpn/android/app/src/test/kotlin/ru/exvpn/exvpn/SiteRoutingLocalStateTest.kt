package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class SiteRoutingLocalStateTest {
    private fun include(vararg rules: String) = SiteRoutingState(1,
        SiteRoutingPolicy("include", rules.toList()), emptyList(), "")

    @Test fun absentInitializedRecordCannotBecomeFreshDisabledPolicy() {
        assertEquals(SiteRoutingState.default(), SiteRoutingRecovery.absent(initialized = false))
        try { SiteRoutingRecovery.absent(initialized = true); fail("Lost policy was reset") }
        catch (_: IllegalStateException) { }
    }

    @Test fun uncertainDurableSaveInvalidatesOldSnapshotUntilConfirmedRead() {
        val old = include("first.example")
        val requested = include("first.example", "second.example")
        var durable = old
        val snapshot = SiteRoutingSnapshot()
        snapshot.reload { durable }
        assertEquals(old, snapshot.capture())
        try {
            snapshot.save(requested) {
                durable = it // Atomic rename succeeded, but its read-back failed.
                throw IllegalStateException("readback unavailable")
            }
            fail("Failed durable operation succeeded")
        } catch (_: IllegalStateException) { }
        try { snapshot.capture(); fail("Old include policy remained usable") }
        catch (_: IllegalStateException) { }
        snapshot.reload { durable }
        assertEquals(requested, snapshot.capture())
    }

    @Test fun failedReadOrPreWriteOperationCannotReusePreviousPolicy() {
        val snapshot = SiteRoutingSnapshot()
        val old = include("first.example")
        snapshot.reload { old }
        try { snapshot.reload { SiteRoutingRecovery.absent(initialized = true) }; fail("Lost record accepted") }
        catch (_: IllegalStateException) { }
        try { snapshot.capture(); fail("Old snapshot survived failed read") }
        catch (_: IllegalStateException) { }
        snapshot.reload { old }
        try { snapshot.save(include("second.example")) { throw IllegalStateException("resume clear failed") } }
        catch (_: IllegalStateException) { }
        try { snapshot.capture(); fail("Old snapshot survived failed pre-write") }
        catch (_: IllegalStateException) { }
    }
}
