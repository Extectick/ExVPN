package ru.exvpn.exvpn

/** Local rules only. No URL, provider configuration, DNS lookup or network I/O. */
internal data class SiteRoutingPolicy(val mode: String, val rules: List<String>) {
    init {
        require(mode in setOf("disabled", "exclude", "include"))
        require(rules.size <= MAX_RULES && rules.toSet().size == rules.size)
        require(rules.all { SiteRule.canonical(it) == it })
    }
    fun snapshot() = copy(rules = rules.toList())
    fun wire(): Map<String, Any> = mapOf("mode" to mode, "rules" to rules.toList())
    companion object {
        const val MAX_RULES = 1024
        fun disabled() = SiteRoutingPolicy("disabled", emptyList())
        fun fromWire(value: Any?): SiteRoutingPolicy {
            val fields = strictMap(value, setOf("mode", "rules"))
            val mode = fields["mode"] as? String ?: throw IllegalArgumentException()
            val values = fields["rules"] as? List<*> ?: throw IllegalArgumentException()
            require(values.size <= MAX_RULES && values.all { it is String })
            return SiteRoutingPolicy(mode, values.map { it as String })
        }
    }
}

internal data class SiteRoutingPreset(val id: String, val name: String, val policy: SiteRoutingPolicy) {
    init {
        require(validSitePresetId(id))
        require(name.isNotEmpty() && name == name.trim() && name.codePointCount(0, name.length) <= 80)
        require(name.codePoints().allMatch { Character.getType(it) != Character.CONTROL.toInt() &&
            Character.getType(it) != Character.FORMAT.toInt() &&
            Character.getType(it) != Character.SURROGATE.toInt() && it != 0x2028 && it != 0x2029 })
    }
    fun snapshot() = copy(policy = policy.snapshot())
    fun wire(): Map<String, Any> = mapOf("id" to id, "name" to name, "policy" to policy.wire())
    companion object {
        fun fromWire(value: Any?): SiteRoutingPreset {
            val fields = strictMap(value, setOf("id", "name", "policy"))
            return SiteRoutingPreset(fields["id"] as? String ?: throw IllegalArgumentException(),
                fields["name"] as? String ?: throw IllegalArgumentException(), SiteRoutingPolicy.fromWire(fields["policy"]))
        }
    }
}

internal data class SiteRoutingState(val schema: Int, val policy: SiteRoutingPolicy,
    val savedPresets: List<SiteRoutingPreset>, val selectedPreset: String) {
    init {
        require(schema == 1 && savedPresets.size <= 8)
        require(savedPresets.map { it.id }.toSet().size == savedPresets.size)
        require(policy.rules.size + savedPresets.sumOf { it.policy.rules.size } <= 2048)
        require(selectedPreset.isEmpty() || validSitePresetId(selectedPreset))
        require(siteJSONByteSize(wire()) <= MAX_BYTES)
    }
    fun snapshot() = copy(policy = policy.snapshot(), savedPresets = savedPresets.map { it.snapshot() })
    fun wire(): Map<String, Any> = mapOf("schema" to schema, "policy" to policy.wire(),
        "savedPresets" to savedPresets.map { it.wire() }, "selectedPreset" to selectedPreset)
    companion object {
        const val MAX_BYTES = 512 * 1024
        fun default() = SiteRoutingState(1, SiteRoutingPolicy.disabled(), emptyList(), "russia-basic")
        fun fromWire(value: Any?): SiteRoutingState {
            val fields = strictMap(value, setOf("schema", "policy", "savedPresets", "selectedPreset"))
            // Flutter's StandardMessageCodec represents a small integer as Int.
            require(fields["schema"] == 1 && fields["schema"] is Int)
            val presets = fields["savedPresets"] as? List<*> ?: throw IllegalArgumentException()
            require(presets.size <= 8)
            return SiteRoutingState(1, SiteRoutingPolicy.fromWire(fields["policy"]),
                presets.map { SiteRoutingPreset.fromWire(it) },
                fields["selectedPreset"] as? String ?: throw IllegalArgumentException())
        }
    }
}

/** Match Go encoding/json's UTF-8 byte limit, including HTML escaping in names. */
private fun siteJSONByteSize(value: Any): Int = when (value) {
    is String -> value.toByteArray(Charsets.UTF_8).size + 2 + value.sumOf { character ->
        when (character) {
            '\\', '"', '\b', '\u000c', '\n', '\r', '\t' -> 1
            '<', '>', '&' -> 5
            '\u2028', '\u2029' -> 3
            else -> if (character.code < 32) 5 else 0
        }
    }
    is Int -> value.toString().length
    is List<*> -> 2 + (value.size - 1).coerceAtLeast(0) + value.sumOf { siteJSONByteSize(requireNotNull(it)) }
    is Map<*, *> -> 2 + (value.size - 1).coerceAtLeast(0) + value.entries.sumOf {
        siteJSONByteSize(it.key as String) + 1 + siteJSONByteSize(requireNotNull(it.value))
    }
    else -> throw IllegalArgumentException()
}

private fun validSitePresetId(value: String) = value.matches(Regex("[a-z0-9][a-z0-9._-]{0,63}"))
private fun strictMap(value: Any?, keys: Set<String>): Map<*, *> {
    val fields = value as? Map<*, *> ?: throw IllegalArgumentException()
    require(fields.keys == keys)
    return fields
}

/** Numeric literal parsing is deliberately pure: InetAddress.getByName is never used. */
internal object SiteRule {
    fun canonical(value: String): String {
        require(value.isNotEmpty() && value.length <= 253 && value.all { it.code in 33..126 })
        require(value == value.lowercase() && !value.contains('%'))
        val slash = value.indexOf('/')
        val address = if (slash < 0) value else value.substring(0, slash)
        val prefix = if (slash < 0) null else value.substring(slash + 1).also {
            require(it.matches(Regex("0|[1-9][0-9]{0,2}")))
        }.toInt()
        if (address.contains(':')) {
            val words = ipv6(address)
            if (prefix != null) {
                require(prefix in 0..128)
                for (index in words.indices) {
                    val keep = (prefix - index * 16).coerceIn(0, 16)
                    words[index] = words[index] and (if (keep == 0) 0 else (0xffff shl (16 - keep)) and 0xffff)
                }
            }
            val normalized = format6(words)
            return if (prefix == null) normalized else "$normalized/$prefix"
        }
        if (address.matches(Regex("[0-9.]+"))) {
            val octets = address.split('.')
            require(octets.size == 4 && octets.all { it.matches(Regex("0|[1-9][0-9]{0,2}")) && it.toInt() <= 255 })
            var number = octets.fold(0L) { n, octet -> (n shl 8) or octet.toLong() }
            if (prefix != null) {
                require(prefix in 0..32)
                val mask = if (prefix == 0) 0L else (0xffffffffL shl (32 - prefix)) and 0xffffffffL
                number = number and mask
            }
            val normalized = (3 downTo 0).joinToString(".") { ((number shr (it * 8)) and 255).toString() }
            return if (prefix == null) normalized else "$normalized/$prefix"
        }
        require(prefix == null)
        val labels = address.split('.')
        require(labels.size >= 2 && labels.all { it.matches(Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")) })
        require(labels.last().any { it in 'a'..'z' })
        return address
    }

    private fun ipv6(value: String): IntArray {
        require(value.all { it in '0'..'9' || it in 'a'..'f' || it == ':' })
        val halves = value.split("::")
        require(halves.size <= 2)
        fun words(part: String): List<Int> = if (part.isEmpty()) emptyList() else part.split(':').map {
            require(it.matches(Regex("[0-9a-f]{1,4}"))); it.toInt(16)
        }
        val left = words(halves[0])
        val right = if (halves.size == 2) words(halves[1]) else emptyList()
        if (halves.size == 1) require(left.size == 8) else require(left.size + right.size < 8)
        val result = (left + List(8 - left.size - right.size) { 0 } + right).toIntArray()
        // IPv4-mapped input is canonicalized as IPv4 by the common contract.
        require(!(result.take(5).all { it == 0 } && result[5] == 0xffff))
        return result
    }

    private fun format6(words: IntArray): String {
        var bestStart = -1; var bestLength = 1; var index = 0
        while (index < 8) {
            if (words[index] != 0) { index++; continue }
            val start = index
            while (index < 8 && words[index] == 0) index++
            if (index - start > bestLength) { bestStart = start; bestLength = index - start }
        }
        if (bestStart < 0) return words.joinToString(":") { it.toString(16) }
        val left = words.take(bestStart).joinToString(":") { it.toString(16) }
        val right = words.drop(bestStart + bestLength).joinToString(":") { it.toString(16) }
        return "$left::$right"
    }
}
