package ru.exvpn.exvpn

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

internal data class ConnectRequest(val profile: String, val profileId: String, val packages: Set<String>,
    val routingMode: String = if (packages.isEmpty()) "disabled" else "exclude",
    val automaticProfiles: List<String> = emptyList(),
    val siteRouting: SiteRoutingState = SiteRoutingState.default())

/** Process-local command handoff: credentials never go into intents or logs. */
internal object VpnRuntime {
    private val main = Handler(Looper.getMainLooper())
    @Volatile var service: ExVpnService? = null
    @Volatile var pending: ConnectRequest? = null
    @Volatile var applicationRouting = ApplicationRoutingPolicy.legacy(emptySet())
    private val siteSnapshot = SiteRoutingSnapshot()
    val siteRouting: SiteRoutingState get() = siteSnapshot.capture()
    val exclusions: Set<String> get() = if (applicationRouting.mode == "exclude") applicationRouting.applications else emptySet()
    private var policyLoaded = false
    @Volatile var state: Map<String, Any> = mapOf("phase" to "disconnected", "processCrashProtection" to false)
    var stateSink: EventChannel.EventSink? = null
    var statsSink: EventChannel.EventSink? = null

    @Synchronized fun ensurePolicy(context: Context) {
        if (policyLoaded) return
        applicationRouting = VpnPersistence.loadApplicationRouting(context)
        policyLoaded = true
    }
    @Synchronized fun savePolicy(context: Context, packages: Set<String>) {
        saveApplicationRouting(context, ApplicationRoutingPolicy.legacy(packages))
    }
    @Synchronized fun saveApplicationRouting(context: Context, policy: ApplicationRoutingPolicy) {
        // Settings may open after process death but before Always-on restarts
        // the service. Never leave a dormant request with an older direct policy.
        VpnPersistence.clearResume(context)
        VpnPersistence.saveApplicationRouting(context, policy)
        applicationRouting = policy.copy(applications = policy.applications.toSet())
        policyLoaded = true
    }
    @Synchronized fun ensureSiteRouting(context: Context) {
        // Re-read durable state at each get/connect. Invalidation before I/O
        // prevents a failed read or uncertain write from reusing old policy.
        siteSnapshot.reload { VpnPersistence.loadSiteRouting(context) }
    }
    @Synchronized fun saveSiteRouting(context: Context, state: SiteRoutingState) {
        // Prevent a dormant Always-on request restoring a superseded policy.
        siteSnapshot.save(state) {
            VpnPersistence.clearResume(context)
            VpnPersistence.saveSiteRouting(context, it)
        }
    }

    fun status(): Map<String, Any> = state + mapOf(
        "processCrashProtection" to (service?.crashProtection() ?: false),
        "automaticSelection" to (service?.automaticSelection() ?: false))
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
