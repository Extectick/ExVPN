package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class AndroidConnectionProtectionTest {
    @Test fun missingServiceIsUnknownAndNeverActive() {
        assertEquals(mapOf("supported" to true, "enabled" to null, "active" to false, "systemManaged" to true),
            AndroidConnectionProtection.read { null }.wire())
    }

    @Test fun onlyBothPublicSystemFlagsConfirmProtection() {
        for (alwaysOn in listOf(false, true)) for (lockdown in listOf(false, true)) {
            val state = AndroidConnectionProtection.read { alwaysOn to lockdown }.wire()
            assertEquals(alwaysOn && lockdown, state["enabled"])
            assertEquals(alwaysOn && lockdown, state["active"])
            assertEquals(true, state["supported"])
            assertEquals(true, state["systemManaged"])
        }
    }

    @Test fun systemReadFailureDoesNotTurnUnknownIntoDisabled() {
        val state = AndroidConnectionProtection.read { throw SecurityException() }.wire()
        assertNull(state["enabled"])
        assertEquals(false, state["active"])
    }

    @Test fun enableRequestOpensSettingsButDoesNotClaimItEnabled() {
        val requested = mutableListOf<Boolean>()
        val state = AndroidConnectionProtection.requestChange(mapOf("enabled" to true),
            { requested.add(it) }, { AndroidConnectionProtectionState(false) })
        assertEquals(listOf(true), requested)
        assertEquals(false, state.enabled)
        assertEquals(false, state.wire()["active"])
    }

    @Test fun disableRequestCannotClaimProtectionStopped() {
        val requested = mutableListOf<Boolean>()
        val state = AndroidConnectionProtection.requestChange(mapOf("enabled" to false),
            { requested.add(it) }, { AndroidConnectionProtectionState(true) })
        assertEquals(listOf(false), requested)
        assertEquals(true, state.enabled)
        assertEquals(true, state.wire()["active"])
    }

    @Test fun unknownStateStaysUnknownAfterOpeningSettings() {
        val state = AndroidConnectionProtection.requestChange(mapOf("enabled" to true),
            {}, { AndroidConnectionProtectionState(null) })
        assertNull(state.enabled)
        assertEquals(false, state.wire()["active"])
    }

    @Test fun settingsLaunchFailureDoesNotReturnASuccessfulChange() {
        var reads = 0
        try {
            AndroidConnectionProtection.requestChange(mapOf("enabled" to true),
                { throw SecurityException() }, { reads++; AndroidConnectionProtectionState(true) })
            fail("Expected a settings launch failure")
        } catch (_: SecurityException) { }
        assertEquals(0, reads)
    }

    @Test fun setterRejectsWrongTypesMissingOrExtraFieldsBeforeOpeningSettings() {
        var opens = 0
        for (invalid in listOf(null, true, "true", emptyMap<String, Any>(), mapOf("enabled" to null),
                mapOf("enabled" to 1), mapOf("enabled" to "true"),
                mapOf("enabled" to true, "extra" to false), mapOf(1 to true))) {
            try {
                AndroidConnectionProtection.requestChange(invalid,
                    { opens++ }, { AndroidConnectionProtectionState(true) })
                fail("Invalid request accepted")
            } catch (_: IllegalArgumentException) { }
        }
        assertEquals(0, opens)
    }

    @Test fun getterAcceptsOnlyAbsentOrEmptyArguments() {
        AndroidConnectionProtection.validateRead(null)
        AndroidConnectionProtection.validateRead(emptyMap<String, Any>())
        for (invalid in listOf(true, "", 0, listOf<Any>(), mapOf("enabled" to true))) {
            try {
                AndroidConnectionProtection.validateRead(invalid)
                fail("Invalid read arguments accepted")
            } catch (_: IllegalArgumentException) { }
        }
    }
}
