package ru.exvpn.exvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.InetAddresses
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.InetAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class ExVpnService : VpnService() {
    private val worker = Executors.newSingleThreadScheduledExecutor()
    private lateinit var connectivity: ConnectivityManager
    private var tunnel: ParcelFileDescriptor? = null
    @Volatile private var request: ConnectRequest? = null
    private val latestRequests = LatestConnectRequest<ConnectRequest>()
    private var requestNeedsSave = false
    private val generation = AtomicLong()
    @Volatile private var activeRequestGeneration = 0L
    private var healthTask: ScheduledFuture<*>? = null
    private var failoverTask: ScheduledFuture<*>? = null
    @Volatile private var automaticPolicy: AutomaticSelectionPolicy? = null
    private var statsTask: ScheduledFuture<*>? = null
    @Volatile private var underlying: Network? = null
    @Volatile private var resolvedUIDs: Set<Int> = emptySet()
    @Volatile private var stopping = false
    @Volatile private var endpointLookup: EndpointLookup? = null
    private var connectedAt: Long? = null
    private var callbackRegistered = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            enqueueNetworkChange {
                if (request != null && network != underlying) { underlying = network; restart() }
            }
        }
        override fun onLost(network: Network) {
            enqueueNetworkChange {
                if (request != null && network == underlying) { underlying = null; restart() }
            }
        }
    }

    private fun enqueueNetworkChange(action: () -> Unit) {
        if (stopping) return
        try { worker.execute { if (!stopping) action() } }
        catch (_: RejectedExecutionException) { /* A callback raced service destruction. */ }
    }

    override fun onCreate() {
        super.onCreate()
        AndroidOtaRestart.beforeVpnStart()
        connectivity = getSystemService(ConnectivityManager::class.java)
        VpnRuntime.service = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL, "VPN-соединение", NotificationManager.IMPORTANCE_LOW)
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopExplicitly(); return START_NOT_STICKY }
        val next = VpnRuntime.pending
        VpnRuntime.pending = null
        // An unsolicited system start must not supersede an explicit stop that
        // is still clearing the durable resume record on the worker.
        if (stopping && next == null) return START_NOT_STICKY
        latestRequests.accept(next)
        val notification = notification("Подключение VPN…")
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        else startForeground(NOTIFICATION, notification)
        stopping = false
        val command = generation.incrementAndGet()
        worker.execute {
            if (stopping || command != generation.get()) return@execute
            try {
                ensureTunnel()
                val accepted = latestRequests.current
                if (accepted != null && request !== accepted) {
                    request = accepted
                    requestNeedsSave = true
                    resetAutomaticPolicy()
                } else if (request == null) {
                    request = VpnPersistence.loadResume(this)
                    resetAutomaticPolicy()
                }
                VpnRuntime.ensurePolicy(this)
                VpnRuntime.ensureSiteRouting(this)
                if (stopping || command != generation.get()) return@execute
                activeRequestGeneration = command
                if (!callbackRegistered) {
                    connectivity.registerNetworkCallback(NetworkRequest.Builder()
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), networkCallback)
                    callbackRegistered = true
                }
                if (request == null) blocked("profile_required") else restart()
            } catch (_: NativeStoreFailure) {
                if (!stopping && command == generation.get()) blocked("native_storage_unavailable")
            } catch (_: Exception) {
                if (!stopping && command == generation.get()) blocked("vpn_setup_failed")
            }
        }
        // OS Always-on/sticky restart restores only the last encrypted accepted
        // request. Missing/corrupt storage keeps a blocking TUN and visible error.
        return START_STICKY
    }

    private fun ensureTunnel() {
        if (tunnel != null) return
        tunnel = Builder().setSession("ExVPN").setMtu(1500)
            .addAddress("10.89.0.1", 30).addAddress("fd42:6578:7670::1", 126)
            .addRoute("0.0.0.0", 0).addRoute("::", 0)
            .addDnsServer("10.89.0.2").addDnsServer("fd42:6578:7670::2")
            .setMetered(false).setBlocking(false).establish()
            ?: throw IllegalStateException("vpn_permission_revoked")
    }

    /** Main-thread replacement cancels bounded work immediately. The existing
     * all-app TUN remains open until the queued latest request restarts its core. */
    fun prepareReplacement() {
        if (stopping) return
        generation.incrementAndGet()
        endpointLookup?.cancel()
        healthTask?.cancel(false)
        failoverTask?.cancel(false); failoverTask = null
        statsTask?.cancel(false)
        if (NativeCore.available) NativeCore.cancel()
    }

    private fun selectUnderlying(): Network? = (listOfNotNull(underlying) + connectivity.allNetworks.toList()).firstOrNull {
        val capabilities = connectivity.getNetworkCapabilities(it)
        capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }

    private fun resolveExclusions(packages: Set<String>): Set<Int> {
        val uids = mutableSetOf<Int>()
        for (name in packages) {
            val uid = packageManager.getApplicationInfo(name, 0).uid
            if (!ApplicationOwnerConfirmation.isApplicationUID(uid) || uid == applicationInfo.uid) throw IllegalArgumentException("invalid_exclusion")
            // A shared UID is only safe when every package sharing it was explicitly selected.
            val owners = packageManager.getPackagesForUid(uid)?.toSet() ?: emptySet()
            if (owners.isEmpty() || !packages.containsAll(owners)) throw IllegalArgumentException("shared_uid_requires_all_packages")
            uids.add(uid)
        }
        return uids
    }

    private class EndpointLookup {
        val cancellation = CancellationSignal()
        val result = CompletableFuture<List<InetAddress>>()
        fun cancel() { result.cancel(false); cancellation.cancel() }
    }

    private fun resolveEndpoint(network: Network, server: String): String? {
        if (InetAddresses.isNumericAddress(server)) return InetAddresses.parseNumericAddress(server).hostAddress
        val lookup = EndpointLookup()
        endpointLookup = lookup
        try {
            if (stopping) { lookup.cancel(); return null }
            DnsResolver.getInstance().query(network, server, DnsResolver.FLAG_EMPTY,
                mainExecutor, lookup.cancellation, object : DnsResolver.Callback<List<InetAddress>> {
                    override fun onAnswer(answer: List<InetAddress>, rcode: Int) { lookup.result.complete(if (rcode == 0) answer else emptyList()) }
                    override fun onError(error: DnsResolver.DnsException) { lookup.result.complete(emptyList()) }
                })
            return lookup.result.get(8, TimeUnit.SECONDS).firstOrNull()?.hostAddress
        } catch (_: Exception) { return null }
        finally {
            lookup.cancel()
            if (endpointLookup === lookup) endpointLookup = null
        }
    }

    fun clearAutomaticSelection(complete: (String?) -> Unit) {
        try { worker.execute {
            failoverTask?.cancel(false); failoverTask = null; automaticPolicy = null
            val current = request
            if (current == null) { complete(null); return@execute }
            val manual = current.copy(automaticProfiles = emptyList())
            request = manual
            latestRequests.accept(manual)
            try {
                VpnPersistence.saveResume(this, manual)
                requestNeedsSave = false
                complete(null)
            } catch (_: NativeStoreFailure) { complete("native_storage_unavailable") }
        } } catch (_: RejectedExecutionException) { complete("service_unavailable") }
    }

    fun automaticSelection(): Boolean = automaticPolicy != null

    private fun resetAutomaticPolicy() {
        failoverTask?.cancel(false); failoverTask = null
        val current = request
        automaticPolicy = current?.automaticProfiles?.takeIf { it.isNotEmpty() }?.let { profiles ->
            val index = profiles.indexOfFirst { JSONObject(it).getString("id") == current.profileId }
            AutomaticSelectionPolicy(profiles.size, index)
        }
    }

    private fun scheduleFailover() {
        val current = request ?: return
        val policy = automaticPolicy ?: return
        if (stopping || activeRequestGeneration != generation.get() || failoverTask != null) return
        val next = policy.failed()
        val command = activeRequestGeneration
        failoverTask = worker.schedule({
            failoverTask = null
            if (stopping || command != generation.get() || request !== current) return@schedule
            val profile = current.automaticProfiles[next.index]
            request = current.copy(profile = profile, profileId = JSONObject(profile).getString("id"))
            latestRequests.accept(request)
            requestNeedsSave = true
            VpnRuntime.publish("reconnecting", request?.profileId)
            restart()
        }, next.delayMillis, TimeUnit.MILLISECONDS)
    }

    private fun restart() {
        if (stopping) return
        val current = request ?: return
        val command = activeRequestGeneration
        if (command != generation.get()) return
        healthTask?.cancel(false); statsTask?.cancel(false)
        failoverTask?.cancel(false); failoverTask = null
        if (NativeCore.available) NativeCore.stop()
        connectedAt = null
        VpnRuntime.publish("connecting", current.profileId)
        try {
            if (!NativeCore.available) { blocked("native_core_unavailable"); return }
            val validation = NativeCore.validate(current.profile.toByteArray(Charsets.UTF_8))
            if (validation.isNotEmpty()) { blocked(validation); return }
            resolvedUIDs = if (current.routingMode == "disabled") emptySet() else resolveExclusions(current.packages)
            if (requestNeedsSave) {
                VpnPersistence.saveResume(this, current)
                requestNeedsSave = false
            }
            val network = selectUnderlying() ?: run { blocked("network_unavailable", retryable = true); return }
            underlying = network
            setUnderlyingNetworks(arrayOf(network))
            val server = JSONObject(current.profile).getString("server")
            // Only the selected VPN endpoint is bootstrapped outside the tunnel.
            // No application DNS request reaches this API.
            val endpoint = resolveEndpoint(network, server)
            if (stopping || command != generation.get()) return
            if (endpoint == null) { blocked("endpoint_resolution_failed", retryable = true); return }
            ensureTunnel()
            val code = NativeCore.startWithSiteRouting(this, tunnel!!.fd, current.profile.toByteArray(Charsets.UTF_8), endpoint,
                resolvedUIDs.toIntArray(), current.routingMode,
                SiteRoutingJson.encode(current.siteRouting).toString().toByteArray(Charsets.UTF_8))
            if (stopping || command != generation.get()) { NativeCore.stop(); return }
            if (code.isNotEmpty()) { blocked(code); return }
            checkHealth()
            healthTask = worker.scheduleWithFixedDelay({ if (!stopping && command == generation.get()) checkHealth() }, 20, 20, TimeUnit.SECONDS)
            statsTask = worker.scheduleWithFixedDelay({
                if (!stopping && command == generation.get() && NativeCore.available) try {
                    val values = JSONObject(NativeCore.stats())
                    if (values.has("errorCode")) VpnRuntime.statisticsUnavailable()
                    else VpnRuntime.statistics(values.getLong("uploadBytes"), values.getLong("downloadBytes"))
                } catch (_: Exception) { VpnRuntime.statisticsUnavailable() }
            }, 1, 1, TimeUnit.SECONDS)
        } catch (_: NativeStoreFailure) {
            if (!stopping && command == generation.get()) blocked("native_storage_unavailable")
        } catch (_: Exception) {
            if (!stopping && command == generation.get()) blocked("native_start_failed")
        }
    }

    private fun checkHealth() {
        val current = request ?: return
        val command = activeRequestGeneration
        if (stopping || command != generation.get()) return
        try {
            val result = JSONObject(NativeCore.health())
            if (stopping || command != generation.get() || command != activeRequestGeneration) return
            if (result.optBoolean("reachable")) {
                automaticPolicy?.succeeded()
                failoverTask?.cancel(false); failoverTask = null
                if (connectedAt == null) connectedAt = System.currentTimeMillis()
                VpnRuntime.publish("connected", current.profileId, connectedAt)
                notifyStatus("VPN подключён")
            } else blocked(result.optString("errorCode", "tunnel_https_failed"), retryable = true)
        } catch (_: Exception) {
            if (!stopping && command == generation.get()) blocked("tunnel_health_failed")
        }
    }

    private fun blocked(code: String, retryable: Boolean = false) {
        connectedAt = null
        VpnRuntime.publish(if (tunnel != null) "blocked" else "error", request?.profileId, error = code)
        notifyStatus(if (tunnel != null) "VPN недоступен · трафик удерживается" else "VPN не запущен")
        if (retryable && AutomaticSelectionPolicy.retryable(code)) scheduleFailover()
        else {
            failoverTask?.cancel(false); failoverTask = null; automaticPolicy = null
            healthTask?.cancel(false)
        }
        // Keep the established TUN and its default routes. There is no direct
        // fallback and no closing the interface just because the server failed.
    }

    /** Called from Go threads. Failure must abort creation of the socket. */
    fun protectSocket(fd: Int): Boolean {
        if (stopping || !protect(fd)) return false
        val network = underlying ?: return false
        return try { ParcelFileDescriptor.fromFd(fd).use { network.bindSocket(it.fileDescriptor) }; true }
        catch (_: Exception) { false }
    }

    /** Confirm the exact tuple owner; native code applies the routing selection. */
    fun connectionOwner(protocol: Int, localIP: String, localPort: Int, remoteIP: String, remotePort: Int): Int {
        if (stopping) return -1
        val current = request ?: return -1
        return try {
            val uid = connectivity.getConnectionOwnerUid(protocol,
                InetSocketAddress(InetAddresses.parseNumericAddress(localIP), localPort),
                InetSocketAddress(InetAddresses.parseNumericAddress(remoteIP), remotePort))
            val packages = packageManager.getPackagesForUid(uid)?.toSet() ?: emptySet()
            if (stopping || request !== current) -1 else ApplicationOwnerConfirmation.confirm(
                uid, applicationInfo.uid, packages, current.routingMode, current.packages, resolvedUIDs,
                current.siteRouting.policy.mode == "include" ||
                    (current.siteRouting.policy.mode == "exclude" && current.siteRouting.policy.rules.isNotEmpty()))
        } catch (_: Exception) { -1 }
    }

    fun crashProtection(): Boolean = try { isAlwaysOn && isLockdownEnabled } catch (_: Exception) { false }

    fun probeActive(profileId: String, complete: (Map<String, Any>) -> Unit) {
        val command = activeRequestGeneration
        val stale = mapOf<String, Any>("reachable" to false, "errorCode" to "probe_requires_active_tunnel")
        fun isCurrent() = !stopping && request?.profileId == profileId &&
            command == generation.get() && command == activeRequestGeneration
        if (!isCurrent() || !NativeCore.available) {
            complete(stale); return
        }
        try { worker.execute {
            if (!isCurrent()) { complete(stale); return@execute }
            val result = try {
                val value = JSONObject(NativeCore.health())
                buildMap<String, Any> {
                    put("reachable", value.optBoolean("reachable"))
                    if (value.has("latencyMs")) put("latencyMs", value.getLong("latencyMs"))
                    if (value.has("errorCode")) put("errorCode", value.getString("errorCode"))
                }
            } catch (_: Exception) { mapOf("reachable" to false, "errorCode" to "tunnel_health_failed") }
            complete(if (isCurrent()) result else stale)
        } } catch (_: RejectedExecutionException) { complete(stale) }
    }

    private fun notification(message: String): Notification {
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 2, Intent(this, ExVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, NOTIFICATION_CHANNEL).setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentTitle("ExVPN").setContentText(message).setContentIntent(open).setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE).setOnlyAlertOnce(true).setShowWhen(false)
            .apply { if (Build.VERSION.SDK_INT >= 31) setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE) }
            .addAction(Notification.Action.Builder(null, "Отключить", stop).build()).build()
    }
    private fun notifyStatus(message: String) { getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(message)) }

    private fun stopExplicitly(revoked: Boolean = false) {
        stopping = true
        latestRequests.clear()
        val command = generation.incrementAndGet()
        endpointLookup?.cancel()
        healthTask?.cancel(true); statsTask?.cancel(true)
        failoverTask?.cancel(true); failoverTask = null; automaticPolicy = null
        if (NativeCore.available) NativeCore.cancel()
        worker.execute {
            if (command != generation.get()) return@execute
            // Stop existing outbound flows even if durable cleanup fails. The
            // TUN is retained for an ordinary stop failure, so it blocks.
            if (NativeCore.available) NativeCore.stop()
            try { VpnPersistence.clearResume(this) }
            catch (_: NativeStoreFailure) {
                if (!revoked) { blocked("native_storage_unavailable"); return@execute }
                // Permission revocation already tears down OS routing. Never
                // label a revoked descriptor as a blocking tunnel.
                tunnel?.close(); tunnel = null; request = null; resolvedUIDs = emptySet()
                VpnRuntime.publish("error", error = "native_storage_unavailable")
                stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
                return@execute
            }
            tunnel?.close(); tunnel = null; request = null; requestNeedsSave = false; resolvedUIDs = emptySet()
            VpnRuntime.publish("disconnected")
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        }
    }
    // The default implementation calls stopSelf immediately, which could cancel
    // the worker before it clears the durable resume record.
    override fun onRevoke() { stopExplicitly(revoked = true) }
    override fun onDestroy() {
        stopping = true
        latestRequests.clear()
        generation.incrementAndGet()
        endpointLookup?.cancel()
        healthTask?.cancel(true); statsTask?.cancel(true)
        failoverTask?.cancel(true); failoverTask = null; automaticPolicy = null
        if (callbackRegistered) connectivity.unregisterNetworkCallback(networkCallback)
        if (NativeCore.available) NativeCore.stop()
        tunnel?.close(); tunnel = null
        worker.shutdownNow(); VpnRuntime.service = null
        val cleanupError = VpnRuntime.state["errorCode"] as? String
        VpnRuntime.publish("disconnected", error = cleanupError?.takeIf { it == "native_storage_unavailable" })
        super.onDestroy()
    }
    companion object {
        const val ACTION_CONNECT = "ru.exvpn.exvpn.CONNECT"
        const val ACTION_STOP = "ru.exvpn.exvpn.STOP"
        internal const val NOTIFICATION_CHANNEL = "exvpn_connection"
        private const val NOTIFICATION = 7001
    }
}
