package ru.exvpn.exvpn

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.Process
import android.widget.FrameLayout
import android.widget.ProgressBar
import kotlin.system.exitProcess

/** Non-exported, app-private process. It observes an actual owner Binder death
 * before relaunching the fixed application entry point in a fresh Dart VM. */
class AndroidOtaRestartActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private var grant: IBinder? = null
    private var token: String? = null
    private var ready = false
    private var oldProcessExited = false
    private var launched = false
    private var resumed = false
    private val timeout = Runnable { finishBroker() }
    private val ownerDeath = IBinder.DeathRecipient {
        handler.post { oldProcessExited = true; launchWhenForeground() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null || Application.getProcessName() != packageName + AndroidOtaRestart.BROKER_PROCESS ||
            intent?.action != AndroidOtaRestart.ACTION || intent.extras?.keySet() != setOf(AndroidOtaRestart.SESSION, AndroidOtaRestart.GRANT)) {
            finishBroker(); return
        }
        token = intent.getStringExtra(AndroidOtaRestart.SESSION)?.takeIf { AndroidOtaRestartPolicy.TOKEN.matches(it) }
        grant = intent.extras?.getBinder(AndroidOtaRestart.GRANT)
        if (token == null || grant == null || grant?.isBinderAlive != true) { finishBroker(); return }
        try { grant!!.linkToDeath(ownerDeath, 0) }
        catch (_: Exception) { finishBroker(); return }
        setContentView(FrameLayout(this).apply {
            addView(ProgressBar(this@AndroidOtaRestartActivity), FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, android.view.Gravity.CENTER))
        })
        handler.postDelayed(timeout, AndroidOtaRestart.TIMEOUT_MILLIS)
    }

    override fun onResume() { super.onResume(); resumed = true; launchWhenForeground() }
    override fun onPause() { resumed = false; super.onPause() }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || !resumed || isFinishing || isDestroyed) return
        if (!ready) {
            ready = true
            // The owner may exit immediately after accepting readiness, before
            // Binder delivers the reply. Death notification, not this reply,
            // decides whether to launch. An unaccepted request times out.
            signal(AndroidOtaRestart.READY)
        }
        launchWhenForeground()
    }

    private fun launchWhenForeground() {
        if (!oldProcessExited || !resumed || !hasWindowFocus() || launched || isFinishing || isDestroyed) return
        launched = true
        try {
            startActivity(Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            })
        } catch (_: Exception) {
            // No blind retry or arbitrary fallback target. The next ordinary
            // launcher open still loads the verified SDK-selected AOT.
        } finally { finishBroker() }
    }

    private fun signal(code: Int): Boolean {
        val remote = grant ?: return false
        val nonce = token ?: return false
        val data = Parcel.obtain()
        val response = Parcel.obtain()
        return try {
            data.writeInterfaceToken(AndroidOtaRestart.DESCRIPTOR)
            data.writeString(nonce)
            if (!remote.transact(code, data, response, 0)) false
            else { response.readException(); response.readInt() == 1 }
        } catch (_: Exception) { false }
        finally { data.recycle(); response.recycle() }
    }

    private fun finishBroker() {
        handler.removeCallbacks(timeout)
        if (!oldProcessExited) signal(AndroidOtaRestart.ABORT)
        try { grant?.unlinkToDeath(ownerDeath, 0) } catch (_: Exception) {}
        grant = null
        finishAndRemoveTask()
        // This component is constrained by the manifest and a process-name
        // check to its own short-lived process, never the VPN/UI process.
        if (Application.getProcessName() == packageName + AndroidOtaRestart.BROKER_PROCESS) {
            Process.killProcess(Process.myPid())
            exitProcess(0)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(timeout)
        if (!oldProcessExited) signal(AndroidOtaRestart.ABORT)
        try { grant?.unlinkToDeath(ownerDeath, 0) } catch (_: Exception) {}
        super.onDestroy()
    }
}
