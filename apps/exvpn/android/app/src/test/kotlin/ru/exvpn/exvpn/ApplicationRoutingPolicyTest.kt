package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class ApplicationRoutingPolicyTest {
    @Test fun disabledRetainsSelectionAndWireRoundTrips() {
        for (mode in listOf("disabled", "exclude", "include")) {
            val policy = ApplicationRoutingPolicy(mode, setOf("sample.first", "sample.second"))
            assertEquals(policy, ApplicationRoutingPolicy.fromWire(policy.wire()))
            assertEquals(2, policy.applications.size)
        }
    }
    @Test fun legacyPolicyMigrationIsExplicit() {
        assertEquals("disabled", ApplicationRoutingPolicy.legacy(emptySet()).mode)
        assertEquals("exclude", ApplicationRoutingPolicy.legacy(setOf("sample.first")).mode)
    }
    @Test fun malformedPolicyDoesNotBecomeAnEmptySelection() {
        val bad = listOf(
            null, mapOf("mode" to "include"),
            mapOf("mode" to "direct", "applications" to emptyList<String>()),
            mapOf("mode" to 1, "applications" to emptyList<String>()),
            mapOf("mode" to "include", "applications" to listOf(42)),
            mapOf("mode" to "include", "applications" to listOf("sample.first", "sample.first")),
            mapOf("mode" to "include", "applications" to listOf("../invalid")),
            mapOf("mode" to "include", "applications" to (0..128).map { "sample.app$it" }),
            mapOf("mode" to "include", "applications" to emptyList<String>(), "direct" to true))
        for (value in bad) {
            try { ApplicationRoutingPolicy.fromWire(value); fail("Malformed policy accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
