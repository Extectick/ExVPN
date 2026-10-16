package ru.exvpn.exvpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private var permissionRequest: ConnectRequest? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
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
                "getExclusions" -> { VpnRuntime.ensurePolicy(this); result.success(VpnRuntime.exclusions.sorted()) }
                "coreVersion" -> result.success("26.10.10")
                "connect" -> {
                    if (permissionResult != null) { result.error("operation_in_progress", "VPN permission request pending", null); return@setMethodCallHandler }
                    if (!NativeCore.available) { result.error("native_core_unavailable", "Native core is not installed", null); return@setMethodCallHandler }
                    val profile = call.argument<Map<String, Any>>("profile") ?: throw IllegalArgumentException()
                    val raw = JSONObject(profile).toString()
                    if (raw.toByteArray(Charsets.UTF_8).size > 1048576) throw IllegalArgumentException()
                    val code = NativeCore.validate(raw.toByteArray(Charsets.UTF_8))
                    if (code.isNotEmpty()) { result.error(code, "Profile rejected", null); return@setMethodCallHandler }
                    VpnRuntime.ensurePolicy(this)
                    val request = ConnectRequest(raw, profile["id"] as? String ?: "", VpnRuntime.exclusions.toSet())
                    val prepare = VpnService.prepare(this)
                    if (prepare != null) {
                        permissionResult = result; permissionRequest = request
                        VpnRuntime.publish("requestingPermission", request.profileId)
                        startActivityForResult(prepare, VPN_PERMISSION)
                    } else startVpn(request, result)
                }
                "disconnect" -> {
                    permissionRequest = null
                    permissionResult?.error("permission_cancelled", "Connection cancelled", null); permissionResult = null
                    VpnRuntime.pending = null
                    if (VpnRuntime.service != null) startService(Intent(this, ExVpnService::class.java).setAction(ExVpnService.ACTION_STOP))
                    else { VpnPersistence.clearResume(this); VpnRuntime.publish("disconnected") }
                    result.success(null)
                }
                "setExclusions" -> {
                    if (VpnRuntime.service != null || permissionResult != null) { result.error("reconnect_required", "Disconnect before changing exclusions", null); return@setMethodCallHandler }
                    val applications = call.argument<List<String>>("applications") ?: throw IllegalArgumentException()
                    if (applications.size > 500 || applications.any { !it.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+")) }) throw IllegalArgumentException()
                    VpnRuntime.savePolicy(this, applications.toSet()); result.success(null)
                }
                "listApplications" -> {
                    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = packageManager.queryIntentActivities(launcher, 0).map { it.activityInfo.applicationInfo }
                        .distinctBy { it.packageName }.filter { it.packageName != packageName }.map { info ->
                            buildMap<String, Any> { put("id", info.packageName); put("displayName", packageManager.getApplicationLabel(info).toString())
                                if ((packageManager.getPackagesForUid(info.uid)?.size ?: 0) > 1) put("sharedIdentityGroup", info.uid.toString()) }
                        }.sortedBy { it["displayName"] as String }
                    result.success(apps)
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
    private fun startVpn(request: ConnectRequest, result: MethodChannel.Result) {
        VpnRuntime.pending = request
        VpnRuntime.publish("connecting", request.profileId)
        startForegroundService(Intent(this, ExVpnService::class.java).setAction(ExVpnService.ACTION_CONNECT))
        result.success(null)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION) return
        val result = permissionResult; val request = permissionRequest
        permissionResult = null; permissionRequest = null
        if (result == null || request == null) return
        if (resultCode == Activity.RESULT_OK) startVpn(request, result) else {
            VpnRuntime.publish("error", error = "permission_denied")
            result.error("permission_denied", "VPN permission was not granted", null)
        }
    }
    companion object { private const val VPN_PERMISSION = 7001 }
}
