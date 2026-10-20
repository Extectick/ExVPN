package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class SiteRoutingPolicyTest {
    private val rules = listOf("example.com", "203.0.113.10", "198.51.100.0/24", "2001:db8::1", "2001:db8::/32")
    @Test fun allModesRetainCanonicalRulesAndLibraryRoundTrips() {
        for (mode in listOf("disabled", "exclude", "include")) {
            val policy = SiteRoutingPolicy(mode, rules)
            val state = SiteRoutingState(1, policy,
                listOf(SiteRoutingPreset("my-rules", "Мой пресет", policy.snapshot())), "my-rules")
            assertEquals(state, SiteRoutingState.fromWire(state.wire()))
            assertEquals(rules, state.policy.rules)
        }
        assertEquals("disabled", SiteRoutingState.default().policy.mode)
        assertEquals("russia-basic", SiteRoutingState.default().selectedPreset)
    }

    @Test fun malformedOrNoncanonicalRulesNeverBecomeAnEmptyPolicy() {
        val invalid = listOf("", " Example.com", "EXAMPLE.COM", "example.com.", "*.example.com",
            "http://example.com/path", "geosite:ru", "localhost", "a..com", "a_1.example.com", "a-.example.com", "example.123", "\u212a.example",
            "a.example.com\n", "[2001:db8::1]", "2001:0db8::1", "::ffff:192.0.2.1", "fe80::1%eth0",
            "203.0.113.10/24", "203.0.113.10/33", "2001:db8::1/32", "2001:db8::/129",
            "203.0.113.256", "203.0.113.01", "203.0.113", "2001:::1", "2001:db8::g", "192.0.2.1:443")
        for (rule in invalid) {
            try { SiteRoutingPolicy("exclude", listOf(rule)); fail("Noncanonical rule accepted") }
            catch (_: IllegalArgumentException) { }
        }
        try { SiteRoutingPolicy("exclude", listOf("example.com", "example.com")); fail("Duplicates accepted") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun exactSchemaTypesUnknownFieldsAndBoundsAreEnforced() {
        val base = SiteRoutingState.default().wire()
        val invalid = listOf(null, base + ("schema" to 2), base + ("schema" to 1L), base - "savedPresets",
            base + ("savedPresets" to null), base + ("direct" to true), base + ("selectedPreset" to "../file"),
            base + ("policy" to mapOf("mode" to "direct", "rules" to emptyList<String>())),
            base + ("policy" to mapOf("mode" to "exclude", "rules" to null)),
            base + ("policy" to mapOf("mode" to "include", "rules" to (0..1024).map { "a$it.example.com" })))
        for (value in invalid) {
            try { SiteRoutingState.fromWire(value); fail("Malformed state accepted") }
            catch (_: IllegalArgumentException) { }
        }
        val policy = SiteRoutingPolicy("include", (0..1023).map { "a$it.example.com" })
        try { SiteRoutingState(1, policy, listOf(SiteRoutingPreset("first", "First", policy),
            SiteRoutingPreset("second", "Second", policy)), "first"); fail("Total bound ignored") }
        catch (_: IllegalArgumentException) { }
        try { SiteRoutingPreset("first", "Hidden\u200bname", policy); fail("Format control accepted") }
        catch (_: IllegalArgumentException) { }
        try { SiteRoutingPreset("first", "Hidden\u0600name", policy); fail("Arabic format control accepted") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun encodedJSONByteLimitIncludesEscapedPresetNames() {
        // 2,048 canonical domains of 252 bytes fit with ordinary names, but
        // the same names using HTML characters exceed Go's encoded byte limit.
        val rules = (0..1023).map {
            it.toString().padStart(4, '0') + "a".repeat(59) + "." + "b".repeat(63) + "." +
                "c".repeat(63) + "." + "d".repeat(60)
        }
        assertEquals(252, rules.first().length)
        val policy = SiteRoutingPolicy("include", rules)
        val ordinary = (0..7).map { SiteRoutingPreset("preset-$it", "a".repeat(80),
            SiteRoutingPolicy("include", rules.take(128))) }
        SiteRoutingState(1, policy, ordinary, "preset-0")
        val escaped = ordinary.map { it.copy(name = "<".repeat(80)) }
        try { SiteRoutingState(1, policy, escaped, "preset-0"); fail("Encoded byte limit ignored") }
        catch (_: IllegalArgumentException) { }
    }
}
