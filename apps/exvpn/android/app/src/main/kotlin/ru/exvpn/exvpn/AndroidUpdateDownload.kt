// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.exvpn

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.FileOutputStream
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/** The signed Dart offer supplies only an immutable identity, never a URL/path.
 * JobScheduler owns network retries and process/reboot survival. All bytes stay
 * in our private cache; every redirect, range, size and final SHA is checked.
 * Neither scheduling nor downloading changes VPN routes or opens an installer. */
internal object AndroidUpdateDownload {
    private const val JOB_ID = 0x455855
    private const val PREFS = "app-update-download"
    private val lock = Any()
    private val worker = Executors.newSingleThreadExecutor()
    private var running: Transfer? = null

    data class Request(val install: AndroidInstallRequest, val size: Long) {
        val version get() = install.version
        val build get() = install.build
        val sha get() = install.sha256
        val url get() = URI("https://github.com/Extectick/ExVPN/releases/download/v$version/ExVPN-$version-$build-android.apk")
    }
    class Transfer(val request: Request) {
        val stopped = AtomicBoolean(false)
        @Volatile var connection: HttpsURLConnection? = null
        fun stop() { stopped.set(true); connection?.disconnect() }
    }
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun scheduler(context: Context) = context.getSystemService(JobScheduler::class.java)
    private fun root(context: Context): File {
        val parent = context.cacheDir.canonicalFile
        val directory = File(parent, "app-updates")
        if (!directory.exists() && !directory.mkdir()) throw AndroidUpdateFailure("cache_unavailable")
        if (directory.canonicalFile != directory || !OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) {
            throw AndroidUpdateFailure("cache_unavailable")
        }
        return directory
    }
    private fun file(context: Context, request: Request, partial: Boolean) =
        File(root(context), request.sha + if (partial) ".apk.download" else ".apk")

    fun parse(raw: Any?): Request {
        val map = raw as? Map<*, *> ?: throw AndroidUpdateFailure("invalid_request")
        if (map.keys != setOf("version", "build", "sha256", "sizeBytes")) throw AndroidUpdateFailure("invalid_request")
        val install = AndroidInstallRequest.parse(map.filterKeys { it != "sizeBytes" })
        val size = when (val value = map["sizeBytes"]) {
            is Long -> value
            is Int -> value.toLong()
            else -> throw AndroidUpdateFailure("invalid_request")
        }
        if (size !in 1..AndroidUpdatePolicy.MAX_BYTES) throw AndroidUpdateFailure("invalid_request")
        return Request(install, size)
    }
    private fun stored(context: Context): Request? {
        val preferences = prefs(context)
        if (!preferences.contains("sha256")) return null
        return parse(mapOf("version" to preferences.getString("version", null), "build" to preferences.getLong("build", 0),
            "sha256" to preferences.getString("sha256", null), "sizeBytes" to preferences.getLong("sizeBytes", 0)))
    }
    private fun save(context: Context, request: Request, state: String, error: String? = null) {
        if (!prefs(context).edit().putString("version", request.version).putLong("build", request.build)
                .putString("sha256", request.sha).putLong("sizeBytes", request.size)
                .putString("state", state).putString("error", error).commit()) throw AndroidUpdateFailure("cache_unavailable")
    }
    private fun length(candidate: File): Long {
        if (!candidate.exists()) return 0
        val stat = Os.lstat(candidate.path)
        if (candidate.canonicalFile != candidate || !OsConstants.S_ISREG(stat.st_mode) || stat.st_nlink != 1L) {
            throw AndroidUpdateFailure("cache_unavailable")
        }
        return stat.st_size
    }
    private fun schedule(context: Context) {
        if (scheduler(context).getPendingJob(JOB_ID) != null) return
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, AndroidUpdateDownloadService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .setBackoffCriteria(10_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .build()
        if (scheduler(context).schedule(job) != JobScheduler.RESULT_SUCCESS) throw AndroidUpdateFailure("download_failed")
    }
    fun start(context: Context, request: Request): Map<String, Any?> = synchronized(lock) {
        val previous = stored(context)
        if (previous != request) {
            running?.stop()
            scheduler(context).cancel(JOB_ID)
            if (previous != null) {
                file(context, previous, true).delete()
                // A different signed release supersedes its own private cache.
                file(context, previous, false).delete()
            }
            save(context, request, "queued")
        } else if (prefs(context).getString("state", null) == "failed") {
            save(context, request, "queued")
        }
        val state = prefs(context).getString("state", "queued")
        if (state != "ready") schedule(context)
        status(context, request) ?: throw AndroidUpdateFailure("download_failed")
    }
    fun status(context: Context, request: Request): Map<String, Any?>? = synchronized(lock) {
        if (stored(context) != request) return null
        var state = prefs(context).getString("state", "queued") ?: "queued"
        var received = length(file(context, request, state != "ready"))
        if (received > request.size) throw AndroidUpdateFailure("integrity_failed")
        if (state == "ready" && received != request.size) {
            save(context, request, "queued")
            state = "queued"
            received = length(file(context, request, true))
        }
        if (state != "ready" && state != "failed" && running?.request != request) schedule(context)
        mapOf("state" to state, "received" to received, "total" to request.size,
            "error" to prefs(context).getString("error", null))
    }
    fun cancel(context: Context) = synchronized(lock) {
        running?.stop()
        scheduler(context).cancel(JOB_ID)
        stored(context)?.let { file(context, it, true).delete() }
        if (!prefs(context).edit().clear().commit()) throw AndroidUpdateFailure("cache_unavailable")
    }
    fun begin(service: JobService, parameters: JobParameters): Transfer? = synchronized(lock) {
        val request = try { stored(service) } catch (_: Exception) { null } ?: return null
        val installed = service.packageManager.getPackageInfo(service.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        if (request.build <= installed.longVersionCode) {
            // A successful package upgrade may leave the persisted job behind.
            // Never fetch the same or an older package after the OS installed it.
            prefs(service).edit().clear().commit()
            return null
        }
        val phase = prefs(service).getString("state", null)
        if (phase == "ready" || phase == "failed" || running?.stopped?.get() == false) return null
        val transfer = Transfer(request)
        running = transfer
        worker.execute {
            var retry = false
            try {
                synchronized(lock) { if (stored(service) == request) save(service, request, "downloading") }
                download(service, transfer)
            } catch (failure: Exception) {
                if (!transfer.stopped.get()) {
                    val code = (failure as? AndroidUpdateFailure)?.code
                    retry = code == null || code == "network_failed"
                    synchronized(lock) {
                        if (stored(service) == request) {
                            if (!retry) file(service, request, true).delete()
                            save(service, request, if (retry) "waiting" else "failed", if (retry) null else code)
                        }
                    }
                }
            } finally {
                transfer.connection?.disconnect()
                synchronized(lock) { if (running === transfer) running = null }
                Handler(Looper.getMainLooper()).post {
                    if (!transfer.stopped.get()) service.jobFinished(parameters, retry)
                }
            }
        }
        transfer
    }
    private fun checkRunning(context: Context, transfer: Transfer) {
        if (transfer.stopped.get() || synchronized(lock) { stored(context) != transfer.request }) throw IOException("stopped")
    }
    private fun allowed(uri: URI, initial: URI): Boolean {
        if (uri.scheme != "https" || uri.rawUserInfo != null || uri.port !in listOf(-1, 443) || uri.rawFragment != null ||
            uri.toString().length > 4096 || uri.rawPath.contains('%') || uri.path.contains('\\') || uri.path.contains("//") ||
            uri.path.split('/').any { it == "." || it == ".." }) return false
        if (uri.host == "github.com") return uri.rawQuery == null && uri.path == initial.path
        if (uri.host == "api.github.com") return uri.rawQuery == null &&
            Regex("/repos/Extectick/ExVPN/releases/assets/[1-9][0-9]*").matches(uri.path)
        return uri.host in setOf("release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com") &&
            (uri.path.startsWith("/github-production-release-asset/") ||
                (uri.path.startsWith("/github-production-release-asset-") && uri.path.length > "/github-production-release-asset-".length))
    }
    private fun connection(context: Context, transfer: Transfer, offset: Long): HttpsURLConnection {
        var current = transfer.request.url
        for (redirects in 0..4) {
            checkRunning(context, transfer)
            if (!allowed(current, transfer.request.url)) throw AndroidUpdateFailure("download_failed")
            val connection = current.toURL().openConnection() as? HttpsURLConnection ?: throw AndroidUpdateFailure("download_failed")
            transfer.connection = connection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.useCaches = false
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
            val status = connection.responseCode
            if (status in setOf(301, 302, 303, 307, 308)) {
                val next = connection.getHeaderField("Location")
                connection.disconnect()
                if (redirects == 4 || next == null) throw AndroidUpdateFailure("download_failed")
                current = current.resolve(next)
                continue
            }
            if (status == 408 || status == 429 || status in 500..599) throw IOException("retry")
            if (status != 200 && status != 206) throw AndroidUpdateFailure("download_failed")
            if (connection.getHeaderField("Content-Encoding").let { it != null && it != "identity" }) throw AndroidUpdateFailure("integrity_failed")
            return connection
        }
        throw AndroidUpdateFailure("download_failed")
    }
    private fun download(context: Context, transfer: Transfer) {
        val request = transfer.request
        val partial = file(context, request, true)
        var received = length(partial)
        if (received > request.size) throw AndroidUpdateFailure("integrity_failed")
        if (received < request.size) {
            val connection = connection(context, transfer, received)
            val rangeResponse = connection.responseCode == 206
            if (rangeResponse) {
                val range = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)")
                    .matchEntire(connection.getHeaderField("Content-Range") ?: "") ?: throw AndroidUpdateFailure("integrity_failed")
                if (range.groupValues[1].toLongOrNull() != received || range.groupValues[2].toLongOrNull() != request.size - 1 ||
                    range.groupValues[3].toLongOrNull() != request.size) throw AndroidUpdateFailure("integrity_failed")
            } else received = 0 // Server does not support Range: restart safely.
            val remaining = request.size - received
            val announced = connection.contentLengthLong
            if (announced >= 0 && announced != remaining) throw AndroidUpdateFailure("integrity_failed")
            if (root(context).usableSpace < remaining + 8L * 1024 * 1024) throw AndroidUpdateFailure("cache_unavailable")
            val descriptor = Os.open(partial.path,
                OsConstants.O_CREAT or OsConstants.O_WRONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0x180)
            FileOutputStream(descriptor).use { output ->
                val before = Os.fstat(descriptor)
                if (!OsConstants.S_ISREG(before.st_mode) || before.st_nlink != 1L || before.st_size > request.size) {
                    throw AndroidUpdateFailure("cache_unavailable")
                }
                if (!rangeResponse) output.channel.truncate(0)
                output.channel.position(received)
                connection.inputStream.use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        checkRunning(context, transfer)
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (received + count > request.size) throw AndroidUpdateFailure("integrity_failed")
                        output.write(buffer, 0, count)
                        received += count
                    }
                }
                descriptor.sync()
            }
            if (received != request.size) throw IOException("interrupted")
        }
        checkRunning(context, transfer)
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(partial).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                checkRunning(context, transfer)
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        if (length(partial) != request.size || digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } != request.sha) {
            throw AndroidUpdateFailure("integrity_failed")
        }
        synchronized(lock) {
            checkRunning(context, transfer)
            val target = file(context, request, false)
            Os.rename(partial.path, target.path)
            save(context, request, "ready")
        }
    }
}

/** Framework entry point remains private and is callable only by JobScheduler. */
class AndroidUpdateDownloadService : JobService() {
    private var transfer: AndroidUpdateDownload.Transfer? = null
    override fun onStartJob(parameters: JobParameters): Boolean {
        transfer = AndroidUpdateDownload.begin(this, parameters)
        return transfer != null
    }
    override fun onStopJob(parameters: JobParameters): Boolean {
        transfer?.stop()
        transfer = null
        return true
    }
}
