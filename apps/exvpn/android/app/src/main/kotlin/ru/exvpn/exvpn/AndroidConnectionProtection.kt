package ru.exvpn.exvpn

/** System-owned Always-on + lockdown, never an application preference. */
internal data class AndroidConnectionProtectionState(val enabled: Boolean?) {
    fun wire(): Map<String, Any?> = mapOf(
        "supported" to true,
        "enabled" to enabled,
        "active" to (enabled == true),
        "systemManaged" to true,
    )
}

internal object AndroidConnectionProtection {
    fun validateRead(arguments: Any?) {
        require(arguments == null || arguments is Map<*, *> && arguments.isEmpty())
    }

    fun read(systemFlags: () -> Pair<Boolean, Boolean>?): AndroidConnectionProtectionState {
        val flags = try { systemFlags() } catch (_: Exception) { null }
        return AndroidConnectionProtectionState(flags?.let { it.first && it.second })
    }

    fun requestChange(
        arguments: Any?,
        openSystemSettings: (Boolean) -> Unit,
        readState: () -> AndroidConnectionProtectionState,
    ): AndroidConnectionProtectionState {
        val values = arguments as? Map<*, *> ?: throw IllegalArgumentException()
        require(values.keys == setOf("enabled"))
        val requested = values["enabled"] as? Boolean ?: throw IllegalArgumentException()
        // Both ON and OFF require a user action in Android Settings. The
        // requested value is not persisted and never impersonates OS state.
        openSystemSettings(requested)
        return readState()
    }
}
