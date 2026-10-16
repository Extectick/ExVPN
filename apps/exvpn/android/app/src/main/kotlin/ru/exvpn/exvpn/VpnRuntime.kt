package ru.exvpn.exvpn

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

internal data class ConnectRequest(val profile: String, val profileId: String, val packages: Set<String>)

/** Process-local command handoff: credentials never go into intents or logs. */
internal object VpnRuntime {
    private val main = Handler(Looper.getMainLooper())
    @Volatile var service: ExVpnService? = null
    @Volatile var pending: ConnectRequest? = null
    @Volatile var exclusions: Set<String> = emptySet()
    private var policyLoaded = false
    @Volatile var state: Map<String, Any> = mapOf("phase" to "disconnected", "processCrashProtection" to false)
    var stateSink: EventChannel.EventSink? = null
    var statsSink: EventChannel.EventSink? = null

    @Synchronized fun ensurePolicy(context: Context) {
        if (policyLoaded) return
        exclusions = VpnPersistence.loadPolicy(context)
        policyLoaded = true
    }
    @Synchronized fun savePolicy(context: Context, packages: Set<String>) {
        // Settings may open after process death but before Always-on restarts
        // the service. Never leave a dormant request with an older direct policy.
        VpnPersistence.clearResume(context)
        VpnPersistence.savePolicy(context, packages)
        exclusions = packages.toSet()
        policyLoaded = true
    }

    fun status(): Map<String, Any> = state + ("processCrashProtection" to (service?.crashProtection() ?: false))
    fun publish(phase: String, profileId: String? = null, connectedAt: Long? = null, error: String? = null) {
        state = buildMap {
            put("phase", phase); put("processCrashProtection", service?.crashProtection() ?: false)
            if (profileId != null) put("activeProfileId", profileId)
            if (connectedAt != null) put("connectedAt", connectedAt)
            if (error != null) put("errorCode", error)
        }
        main.post { stateSink?.success(status()) }
    }
    fun statistics(up: Long, down: Long) { main.post { statsSink?.success(mapOf("uploadBytes" to up, "downloadBytes" to down)) } }
    fun statisticsUnavailable() { main.post { statsSink?.error("statistics_unavailable", "Traffic counters unavailable", null) } }
}
