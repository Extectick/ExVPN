package ru.exvpn.exvpn

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.Process
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import kotlin.system.exitProcess

/** A cold Flutter VM restart, only after persistence is flushed by Dart and
 * native confirms that this shared UI/VpnService process is completely idle.
 * The private foreground broker survives this process; no alarm or background
 * activity launch, SDK pointer mutation, or externally supplied target is used. */
internal object AndroidOtaRestart {
    private val main = Handler(Looper.getMainLooper())
    private val policy = AndroidOtaRestartPolicy()
    private var stage: Stage? = null
    val pending: Boolean get() = policy.pending

    private class Stage(val activity: Activity, val reply: MethodChannel.Result, val token: String) {
        lateinit var timeout: Runnable
    }

    private fun idle() = VpnRuntime.service == null && VpnRuntime.pending == null &&
        VpnRuntime.state["phase"] == "disconnected" && VpnRuntime.state["activeProfileId"] == null

    fun begin(activity: Activity, arguments: Any?, reply: MethodChannel.Result) {
        check(Looper.myLooper() == Looper.getMainLooper())
        val token = ByteArray(16).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        try {
            policy.begin(arguments, token, idle(),
                !activity.isFinishing && !activity.isDestroyed && activity.hasWindowFocus())
        } catch (failure: AndroidUpdateFailure) {
            reject(reply, failure.code)
            return
        }
        val current = Stage(activity, reply, token)
        current.timeout = Runnable { cancel(current, "handoff_failed") }
        stage = current
        val grant = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, response: Parcel?, flags: Int): Boolean {
                if (code != READY && code != ABORT) return super.onTransact(code, data, response, flags)
                data.enforceInterface(DESCRIPTOR)
                val received = data.readString()
                val caller = Binder.getCallingPid()
                val sameOwner = Binder.getCallingUid() == Process.myUid() &&
                    activity.getSystemService(ActivityManager::class.java).runningAppProcesses.orEmpty().any {
                        it.pid == caller && it.uid == Process.myUid() &&
                            it.processName == activity.packageName + BROKER_PROCESS
                    }
                if (!sameOwner || received != token || data.dataAvail() != 0) {
                    response?.writeNoException(); response?.writeInt(0)
                    return true
                }
                main.post {
                    if (code == ABORT) cancel(current, "handoff_failed")
                    else commit(current)
                }
                response?.writeNoException(); response?.writeInt(1)
                return true
            }
        }
        val extras = Bundle().apply { putString(SESSION, token); putBinder(GRANT, grant) }
        try {
            main.postDelayed(current.timeout, TIMEOUT_MILLIS)
            activity.startActivity(Intent(activity, AndroidOtaRestartActivity::class.java).apply {
                action = ACTION
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                putExtras(extras)
            })
        } catch (_: Exception) { cancel(current, "handoff_failed") }
    }

    private fun commit(current: Stage) {
        if (stage !== current || !policy.owns(current.token)) return
        if (current.activity.isFinishing || current.activity.isDestroyed || !idle()) {
            cancel(current, "restart_blocked")
            return
        }
        if (!policy.commit(current.token, idle = true)) return
        stage = null
        main.removeCallbacks(current.timeout)
        // No asynchronous gap after this final native idle check: service and
        // activity starts run on the same main thread. Never terminate another
        // PID. Dart has already awaited all durable writes before requesting us.
        current.reply.success("accepted")
        Process.killProcess(Process.myPid())
        exitProcess(0)
    }

    private fun cancel(current: Stage, code: String) {
        if (stage !== current || !policy.cancel(current.token)) return
        stage = null
        main.removeCallbacks(current.timeout)
        reject(current.reply, code)
    }

    /** An OS Always-on start is never suppressed or killed for an update. */
    fun beforeVpnStart() { stage?.let { cancel(it, "restart_blocked") } }
    fun dispose(activity: Activity) { stage?.takeIf { it.activity === activity }?.let { cancel(it, "cancelled") } }
    private fun reject(reply: MethodChannel.Result, code: String) = reply.error(code, "Application could not be restarted", null)

    internal const val ACTION = "ru.exvpn.exvpn.OTA_RESTART"
    internal const val SESSION = "session"
    internal const val GRANT = "grant"
    internal const val BROKER_PROCESS = ":ota_restart"
    internal const val DESCRIPTOR = "ru.exvpn.exvpn.ota.restart.v1"
    internal const val READY = IBinder.FIRST_CALL_TRANSACTION
    internal const val ABORT = IBinder.FIRST_CALL_TRANSACTION + 1
    internal const val TIMEOUT_MILLIS = 8000L
}
