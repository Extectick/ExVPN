package ru.exvpn.exvpn

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Before Flutter starts its updater: bypass inherited proxies only for
        // our fixed local protocol bridge, without changing system proxy policy.
        for (name in listOf("NO_PROXY", "no_proxy")) {
            val existing = Os.getenv(name).orEmpty()
            val value = if (existing.split(',').any { it == "127.0.0.1" }) existing
                else if (existing.isEmpty()) "127.0.0.1" else "$existing,127.0.0.1"
            Os.setenv(name, value, true)
        }
        super.onCreate(savedInstanceState)
    }

    private var qrPicker: QrImagePicker? = null
    private var qrChannel: MethodChannel? = null
    private var appUpdates: AndroidAppUpdates? = null
    private var appUpdatesChannel: MethodChannel? = null
    private val activityHandler = Handler(Looper.getMainLooper())
    private var activityResumed = false
    private var notificationPermissionPending = false
    private var automaticSelectionCleared = false
    private val consent = VpnConsentCoordinator<ConnectRequest, MethodChannel.Result, Intent>(
        prepare = { VpnService.prepare(this) },
        nextToken = {
            permissionTokens.incrementAndGet().also { check(it in (VPN_PERMISSION_BASE + 1)..65535) }
        },
        launch = { intent, token ->
            startActivityForResult(intent, token)
            schedulePermissionCheck()
        },
        waiting = { request -> VpnRuntime.publish("requestingPermission", request.profileId) },
        start = { request, reply ->
            VpnRuntime.service?.prepareReplacement()
            startVpn(if (automaticSelectionCleared) request.copy(automaticProfiles = emptyList()) else request, reply)
        },
        fail = { request, reply, code ->
            if (code != "operation_in_progress") {
                val failed = VpnConsentFailureState.resolve(request.profileId,
                    servicePresent = VpnRuntime.service != null, requestPending = VpnRuntime.pending != null)
                VpnRuntime.publish(failed.phase, failed.profileId, error = code)
            }
            reply.error(code, "VPN connection could not be started", null)
        },
    )
    private val permissionCheck = Runnable {
        if (activityResumed && hasWindowFocus()) {
            consent.onFocusedForeground()
            requestNotificationsIfNeeded()
        }
    }
    private val iconWorker = Executors.newSingleThreadExecutor()
    private val knownApplicationIcons = mutableSetOf<String>()
    private val pendingIcons = mutableSetOf<MethodChannel.Result>()
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        appUpdates = AndroidAppUpdates(this)
        appUpdatesChannel = MethodChannel(messenger, "exvpn/app_updates").also { channel ->
            channel.setMethodCallHandler { call, reply -> appUpdates?.handle(call.method, call.arguments, reply)
                ?: reply.error("updater_unavailable", "Application updater unavailable", null) }
        }
        qrPicker = QrImagePicker(this)
        qrChannel = MethodChannel(messenger, "exvpn/qr_import").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "pickImage") qrPicker?.pick(result)
                    ?: result.error("unreadable", "QR image could not be read", null)
                else result.notImplemented()
            }
        }
        EventChannel(messenger, "exvpn/vpn_state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { VpnRuntime.stateSink = events; events.success(VpnRuntime.status()) }
            override fun onCancel(arguments: Any?) { VpnRuntime.stateSink = null }
        })
        EventChannel(messenger, "exvpn/vpn_stats").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { VpnRuntime.statsSink = events; VpnRuntime.statisticsUnavailable() }
            override fun onCancel(arguments: Any?) { VpnRuntime.statsSink = null }
        })
        MethodChannel(messenger, "exvpn/vpn").setMethodCallHandler { call, result ->
            try { when (call.method) {
                "getStatus" -> result.success(VpnRuntime.status())
                "getConnectionProtection" -> {
                    AndroidConnectionProtection.validateRead(call.arguments)
                    result.success(connectionProtection().wire())
                }
                "setConnectionProtection" -> {
                    try {
                        val state = AndroidConnectionProtection.requestChange(call.arguments,
                            openSystemSettings = { startActivity(Intent(Settings.ACTION_VPN_SETTINGS)) },
                            readState = { connectionProtection() })
                        result.success(state.wire())
                    } catch (_: ActivityNotFoundException) {
                        result.error("connection_protection_unavailable", "VPN settings unavailable", null)
                    } catch (_: SecurityException) {
                        result.error("connection_protection_unavailable", "VPN settings unavailable", null)
                    }
                }
                "getExclusions" -> { VpnRuntime.ensurePolicy(this); result.success(VpnRuntime.exclusions.sorted()) }
                "getApplicationRouting" -> {
                    VpnRuntime.ensurePolicy(this)
                    knownApplicationIcons.addAll(VpnRuntime.applicationRouting.applications)
                    result.success(VpnRuntime.applicationRouting.wire())
                }
                "coreVersion" -> result.success("26.10.10-exvpn.5")
                "connect", "reconnect" -> {
                    if (AndroidOtaRestart.pending) { result.error("operation_in_progress", "Application restart pending", null); return@setMethodCallHandler }
                    if (consent.pending) { result.error("operation_in_progress", "VPN permission request pending", null); return@setMethodCallHandler }
                    if (!NativeCore.available) { result.error("native_core_unavailable", "Native core is not installed", null); return@setMethodCallHandler }
                    val requestedMode = call.argument<String>("mode")
                    if (requestedMode != null && requestedMode != "vpn") {
                        result.error("mode_unsupported", "Only VPN mode is supported", null); return@setMethodCallHandler
                    }
                    val profile = call.argument<Map<String, Any>>("profile") ?: throw IllegalArgumentException()
                    val raw = JSONObject(profile).toString()
                    if (raw.toByteArray(Charsets.UTF_8).size > 1048576) throw IllegalArgumentException()
                    val code = NativeCore.validate(raw.toByteArray(Charsets.UTF_8))
                    if (code.isNotEmpty()) { result.error(code, "Profile rejected", null); return@setMethodCallHandler }
                    VpnRuntime.ensurePolicy(this)
                    val routing = VpnRuntime.applicationRouting
                    val primaryId = profile["id"] as? String ?: throw IllegalArgumentException()
                    val automaticInput = call.argument<List<Map<String, Any>>>("automaticProfiles")
                    val automatic = if (automaticInput == null) emptyList() else {
                        require(automaticInput.size in 1..32)
                        val ids = mutableSetOf<String>()
                        var bytes = 0
                        automaticInput.map { candidate ->
                            val candidateRaw = JSONObject(candidate).toString()
                            bytes += candidateRaw.toByteArray(Charsets.UTF_8).size
                            require(bytes <= 1048576)
                            val candidateId = candidate["id"] as? String ?: throw IllegalArgumentException()
                            require(candidateId.isNotEmpty() && ids.add(candidateId))
                            val candidateCode = NativeCore.validate(candidateRaw.toByteArray(Charsets.UTF_8))
                            require(candidateCode.isEmpty())
                            candidateRaw
                        }.also { candidates ->
                            require(primaryId in ids)
                            require(candidates.any { NativeProfileIdentity.equivalent(it, raw) })
                        }
                    }
                    automaticSelectionCleared = false
                    val request = ConnectRequest(raw, primaryId, routing.applications.toSet(), routing.mode, automatic)
                    // Re-check for every user connect/reconnect. Another VPN or
                    // system policy may have revoked this app's earlier grant.
                    consent.connect(request, result)
                }
                "clearAutomaticSelection" -> {
                    automaticSelectionCleared = true
                    VpnRuntime.pending = VpnRuntime.pending?.copy(automaticProfiles = emptyList())
                    val service = VpnRuntime.service
                    if (service == null) { VpnPersistence.loadResume(this)?.let { VpnPersistence.saveResume(this, it.copy(automaticProfiles = emptyList())) }; result.success(null) }
                    else service.clearAutomaticSelection { error -> runOnUiThread {
                        if (error == null) result.success(null)
                        else result.error(error, "Could not save connection selection", null)
                    } }
                }
                "disconnect" -> {
                    consent.cancel()?.second?.error("permission_cancelled", "Connection cancelled", null)
                    notificationPermissionPending = false
                    VpnRuntime.pending = null
                    if (VpnRuntime.service != null) startService(Intent(this, ExVpnService::class.java).setAction(ExVpnService.ACTION_STOP))
                    else { VpnPersistence.clearResume(this); VpnRuntime.publish("disconnected") }
                    result.success(null)
                }
                "setExclusions" -> {
                    if (VpnRuntime.service != null || consent.pending || VpnRuntime.pending != null) { result.error("reconnect_required", "Disconnect before changing exclusions", null); return@setMethodCallHandler }
                    val applications = call.argument<List<String>>("applications") ?: throw IllegalArgumentException()
                    if (applications.size > 500 || applications.any { !it.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+")) }) throw IllegalArgumentException()
                    VpnRuntime.savePolicy(this, applications.toSet()); result.success(null)
                }
                "setApplicationRouting" -> {
                    if (VpnRuntime.service != null || consent.pending || VpnRuntime.pending != null) {
                        result.error("reconnect_required", "Disconnect before changing application routing", null); return@setMethodCallHandler
                    }
                    val routing = try { ApplicationRoutingPolicy.fromWire(call.arguments) }
                        catch (_: Exception) { result.error("application_routing_rejected", "Application routing rejected", null); return@setMethodCallHandler }
                    VpnRuntime.saveApplicationRouting(this, routing); result.success(null)
                }
                "listApplications" -> {
                    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = packageManager.queryIntentActivities(launcher, 0).map { it.activityInfo.applicationInfo }
                        .distinctBy { it.packageName }.filter { it.packageName != packageName }.map { info ->
                            buildMap<String, Any> { put("id", info.packageName); put("displayName", packageManager.getApplicationLabel(info).toString())
                                if ((packageManager.getPackagesForUid(info.uid)?.size ?: 0) > 1) put("sharedIdentityGroup", info.uid.toString()) }
                        }.sortedBy { it["displayName"] as String }
                    knownApplicationIcons.addAll(apps.map { it["id"] as String })
                    result.success(apps)
                }
                "getApplicationIcon" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val id = arguments?.get("application") as? String
                    if (arguments?.keys != setOf("application") || id == null || id.length > 255 ||
                        id !in knownApplicationIcons || id == packageName) {
                        result.success(null); return@setMethodCallHandler
                    }
                    if (pendingIcons.size >= 8) {
                        result.error("application_icon_unavailable", "Application icon unavailable", null)
                        return@setMethodCallHandler
                    }
                    pendingIcons.add(result)
                    iconWorker.execute {
                        val icon = NativeApplicationIcons.png(applicationContext, id)
                        runOnUiThread { if (pendingIcons.remove(result)) result.success(icon) }
                    }
                }
                "probe" -> {
                    val profile = call.argument<Map<String, Any>>("profile") ?: throw IllegalArgumentException()
                    val service = VpnRuntime.service
                    if (service == null) result.success(mapOf("reachable" to false, "errorCode" to "probe_requires_active_tunnel"))
                    else service.probeActive(profile["id"] as? String ?: "") { value -> runOnUiThread { result.success(value) } }
                }
                "openSystemProtectionSettings" -> { startActivity(Intent(Settings.ACTION_VPN_SETTINGS)); result.success(null) }
                else -> result.notImplemented()
            } } catch (_: NativeStoreFailure) { result.error("native_storage_unavailable", "Protected VPN settings unavailable", null) }
            catch (_: Exception) { result.error("invalid_native_request", "Native request could not be applied", null) }
        }
    }
    private fun connectionProtection(): AndroidConnectionProtectionState = AndroidConnectionProtection.read {
        // These public API29+ methods require a real VpnService. Without one,
        // Android's persisted configuration cannot be confirmed by this app.
        val service = VpnRuntime.service
        if (service == null) null else {
            val flags = service.isAlwaysOn to service.isLockdownEnabled
            if (VpnRuntime.service === service) flags else null
        }
    }
    private fun startVpn(request: ConnectRequest, result: MethodChannel.Result) {
        VpnRuntime.pending = request
        VpnRuntime.publish("connecting", request.profileId)
        try {
            startForegroundService(Intent(this, ExVpnService::class.java).setAction(ExVpnService.ACTION_CONNECT))
        } catch (error: Exception) {
            if (VpnRuntime.pending === request) VpnRuntime.pending = null
            throw error
        }
        result.success(null)
        // Notifications explain the active connection; denying this optional
        // Android 13+ permission must not cancel or impersonate VPN consent.
        notificationPermissionPending = true
        schedulePermissionCheck()
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (qrPicker?.onActivityResult(requestCode, resultCode, data) == true) return
        if (appUpdates?.onActivityResult(requestCode) == true) return
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode > VPN_PERMISSION_BASE && requestCode <= 65535) {
            consent.onActivityResult(requestCode, resultCode == Activity.RESULT_OK)
        }
    }
    override fun onResume() {
        super.onResume()
        activityResumed = true
        schedulePermissionCheck()
    }
    override fun onPause() {
        activityResumed = false
        consent.onActivityPaused()
        activityHandler.removeCallbacks(permissionCheck)
        super.onPause()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) schedulePermissionCheck()
    }
    private fun schedulePermissionCheck() {
        activityHandler.removeCallbacks(permissionCheck)
        // Give Android time to display the external consent activity. While it
        // is visible this activity is paused/unfocused, so it cannot time out.
        activityHandler.postDelayed(permissionCheck, 1200)
    }
    private fun requestNotificationsIfNeeded() {
        if (!notificationPermissionPending || consent.pending || !activityResumed || !hasWindowFocus()) return
        notificationPermissionPending = false
        if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val preferences = getSharedPreferences("notification_permission", MODE_PRIVATE)
        if (preferences.getBoolean("requested", false)) return
        try {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION)
            preferences.edit().putBoolean("requested", true).apply()
        } catch (_: Exception) {
            // A notification denial/restriction is not a VPN connection error.
        }
    }
    override fun onDestroy() {
        activityHandler.removeCallbacks(permissionCheck)
        consent.dispose()
        appUpdates?.dispose()
        appUpdates = null
        appUpdatesChannel?.setMethodCallHandler(null)
        appUpdatesChannel = null
        pendingIcons.toList().forEach { it.success(null) }
        pendingIcons.clear()
        iconWorker.shutdownNow()
        qrPicker?.dispose()
        qrPicker = null
        qrChannel?.setMethodCallHandler(null)
        qrChannel = null
        super.onDestroy()
    }
    companion object {
        private const val VPN_PERMISSION_BASE = 7300
        private const val NOTIFICATION_PERMISSION = 7003
        private val permissionTokens = AtomicInteger(VPN_PERMISSION_BASE)
    }
}
