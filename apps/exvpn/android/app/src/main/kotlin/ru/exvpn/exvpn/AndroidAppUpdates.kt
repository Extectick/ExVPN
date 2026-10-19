package ru.exvpn.exvpn

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Only APK installation is native. URLs/keys are never accepted on this channel.
 * The final package is rehashed and checked against both the installed and pinned
 * signing identity immediately before a user-controlled system installer opens. */
internal class AndroidAppUpdates(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var disposed = false
    private fun cache(): File {
        val parent = activity.cacheDir.canonicalFile
        val directory = File(parent, "app-updates")
        if (!directory.exists() && !directory.mkdir()) throw AndroidUpdateFailure("cache_unavailable")
        if (directory.canonicalFile != directory || !OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) throw AndroidUpdateFailure("cache_unavailable")
        return directory
    }
    private fun installed(): PackageInfo = activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
    private fun identity(info: PackageInfo): AndroidPackageIdentity {
        val signing = info.signingInfo ?: throw AndroidUpdateFailure("signature_invalid")
        if (signing.hasMultipleSigners()) throw AndroidUpdateFailure("signature_invalid")
        val signers = signing.apkContentsSigners?.map { hash(it.toByteArray()) }?.toSet() ?: emptySet()
        return AndroidPackageIdentity(info.packageName, info.versionName ?: "", info.longVersionCode, info.applicationInfo?.minSdkVersion ?: 0, signers)
    }
    fun handle(method: String, arguments: Any?, reply: MethodChannel.Result) {
        if (disposed) { reject(reply, "cancelled"); return }
        when (method) {
            "getContext" -> try {
                if (arguments != null) throw AndroidUpdateFailure("invalid_request")
                val current = installed()
                reply.success(mapOf("version" to current.versionName, "build" to current.longVersionCode,
                    "sdk" to Build.VERSION.SDK_INT, "cacheDirectory" to cache().path))
            } catch (failure: Exception) { reject(reply, (failure as? AndroidUpdateFailure)?.code ?: "cache_unavailable") }
            "install" -> install(arguments, reply)
            else -> reply.notImplemented()
        }
    }
    private fun idle() = VpnRuntime.service == null && VpnRuntime.pending == null &&
        VpnRuntime.state["phase"] == "disconnected" && VpnRuntime.state["activeProfileId"] == null
    private fun foreground() = !activity.isFinishing && !activity.isDestroyed && activity.hasWindowFocus()

    private fun install(arguments: Any?, reply: MethodChannel.Result) {
        if (pending != null) { reject(reply, "operation_busy"); return }
        val request = try { AndroidInstallRequest.parse(arguments) } catch (_: Exception) { reject(reply, "invalid_request"); return }
        if (!idle() || !foreground()) { reject(reply, "restart_blocked"); return }
        pending = reply
        worker.execute {
            var error: String? = null
            var file: File? = null
            try {
                val candidate = File(cache(), "${request.sha256}.apk")
                if (!candidate.isFile || candidate.canonicalFile != candidate || !OsConstants.S_ISREG(Os.lstat(candidate.path).st_mode)) throw AndroidUpdateFailure("apk_invalid")
                val fd = Os.open(candidate.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
                val before = try {
                    val stat = Os.fstat(fd)
                    if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_nlink != 1L || stat.st_size !in 1..AndroidUpdatePolicy.MAX_BYTES) throw AndroidUpdateFailure("apk_invalid")
                    val digest = MessageDigest.getInstance("SHA-256")
                    FileInputStream(fd).use { input ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) { val count = input.read(buffer); if (count < 0) break
                            total += count; if (total > stat.st_size) throw AndroidUpdateFailure("integrity_failed")
                            digest.update(buffer, 0, count) }
                        if (total != stat.st_size) throw AndroidUpdateFailure("integrity_failed")
                    }
                    if (hex(digest.digest()) != request.sha256) throw AndroidUpdateFailure("integrity_failed")
                    stat
                } finally { try { Os.close(fd) } catch (_: Exception) {} }
                val archive = activity.packageManager.getPackageArchiveInfo(candidate.path, PackageManager.GET_SIGNING_CERTIFICATES)
                    ?: throw AndroidUpdateFailure("apk_invalid")
                AndroidUpdatePolicy.validate(request, identity(installed()), identity(archive), Build.VERSION.SDK_INT)
                val after = Os.lstat(candidate.path)
                if (!OsConstants.S_ISREG(after.st_mode) || before.st_ino != after.st_ino || before.st_dev != after.st_dev || before.st_size != after.st_size || before.st_mtime != after.st_mtime) throw AndroidUpdateFailure("integrity_failed")
                file = candidate
            } catch (failure: Exception) { error = (failure as? AndroidUpdateFailure)?.code ?: "apk_invalid" }
            activity.runOnUiThread {
                if (pending !== reply || disposed) return@runOnUiThread
                pending = null
                if (error != null) { reject(reply, error!!); return@runOnUiThread }
                if (!idle() || !foreground()) { reject(reply, "restart_blocked"); return@runOnUiThread }
                try {
                    if (!activity.packageManager.canRequestPackageInstalls()) {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                        reject(reply, "install_permission_required")
                        return@runOnUiThread
                    }
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file!!)
                    val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        putExtra(Intent.EXTRA_RETURN_RESULT, true)
                    }
                    // An explicit resolved system installer receives the only
                    // read grant. No exported broad file provider or file:// URI.
                    val candidates = activity.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY).filter {
                        it.activityInfo.exported && it.activityInfo.enabled &&
                            it.activityInfo.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM != 0
                    }
                    val preferred = activity.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
                    val handler = candidates.firstOrNull { it.activityInfo.packageName == preferred?.activityInfo?.packageName && it.activityInfo.name == preferred?.activityInfo?.name }
                        ?: candidates.firstOrNull() ?: throw AndroidUpdateFailure("install_failed")
                    intent.setClassName(handler.activityInfo.packageName, handler.activityInfo.name)
                    activity.startActivityForResult(intent, INSTALL_REQUEST)
                    // This means only that Android opened its consent UI.
                    reply.success("installerOpened")
                } catch (failure: Exception) { reject(reply, (failure as? AndroidUpdateFailure)?.code ?: "install_failed") }
            }
        }
    }
    fun onActivityResult(requestCode: Int): Boolean = requestCode == INSTALL_REQUEST
    fun dispose() {
        disposed = true
        pending?.let { reject(it, "cancelled") }; pending = null
        worker.shutdownNow()
    }
    private fun reject(reply: MethodChannel.Result, code: String) { reply.error(code, "Application update could not be installed", null) }
    private fun hash(bytes: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    companion object { private const val INSTALL_REQUEST = 7004 }
}
