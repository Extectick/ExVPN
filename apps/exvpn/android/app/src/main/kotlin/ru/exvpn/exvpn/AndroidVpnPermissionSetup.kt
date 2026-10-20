package ru.exvpn.exvpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.UserManager
import android.provider.Settings
import java.util.Locale

/** Read-only public Android permission state. A missing/failed policy query is
 * unknown, never evidence that the app is ready to create a VPN. */
internal class AndroidVpnPermissionSetup(private val activity: Activity) {
    fun validateRead(arguments: Any?) { require(arguments == null) }

    fun policyRestricted(): Boolean? = try {
        activity.getSystemService(UserManager::class.java)
            ?.hasUserRestriction(UserManager.DISALLOW_CONFIG_VPN)
    } catch (_: Exception) { null }

    fun prepareVpn(): Intent? {
        check(policyRestricted() == false)
        return VpnService.prepare(activity)
    }

    fun wire(): Map<String, Any> = mapOf(
        "schema" to 1,
        "vpn" to vpnState(),
        "notifications" to if (notificationsGranted()) "granted" else "required",
        "vendor" to if (Build.MANUFACTURER.trim().lowercase(Locale.ROOT) in
            setOf("xiaomi", "redmi", "poco")) "xiaomi" else "android",
    )

    fun notificationsGranted(): Boolean = Build.VERSION.SDK_INT < 33 ||
        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /** The only external destination is Android's settings for this app. No
     * package/component/URI supplied by Flutter or a subscription is accepted. */
    fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", activity.packageName, null))
        check(intent.resolveActivity(activity.packageManager) != null)
        activity.startActivity(intent)
    }

    private fun vpnState(): String {
        when (policyRestricted()) {
            true -> return "restricted"
            null -> return "unavailable"
            false -> Unit
        }
        return try {
            val consent = VpnService.prepare(activity)
            when {
                consent == null -> "granted"
                consent.resolveActivity(activity.packageManager) != null -> "required"
                else -> "unavailable"
            }
        } catch (_: Exception) { "unavailable" }
    }
}
