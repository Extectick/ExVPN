package ru.exvpn.exvpn

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Owns only the picker/result lifecycle. The VPN permission request has its
 * own request code and continues through MainActivity unchanged. */
internal class QrImagePicker(private val activity: Activity) {
    private val reader = BoundedQrReader.shared
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var ticket: BoundedQrReader.Ticket? = null
    private var destroyed = false

    fun pick(result: MethodChannel.Result) {
        if (destroyed) { fail(result, "unreadable"); return }
        if (pending != null || reader.busy) { fail(result, "busy"); return }
        pending = result
        try {
            activity.startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "image/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/png", "image/jpeg"))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }, REQUEST,
            )
        } catch (_: Exception) {
            pending = null
            fail(result, "unreadable")
        }
    }

    fun onActivityResult(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        val result = pending ?: return true
        // Ignore duplicate or late picker replies while already reading.
        if (ticket != null || destroyed) return true
        if (resultCode != Activity.RESULT_OK) {
            pending = null
            result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT) {
            pending = null
            fail(result, "unreadable")
            return true
        }
        ticket = reader.start(AndroidQrSource(activity.applicationContext.contentResolver, uri)) { outcome ->
            main.post {
                if (!destroyed && pending === result) {
                    pending = null
                    ticket = null
                    when (outcome) {
                        is QrReadOutcome.Bytes -> result.success(outcome.value)
                        is QrReadOutcome.Failure -> fail(result, outcome.code)
                    }
                }
            }
        }
        if (ticket == null) {
            pending = null
            fail(result, "busy")
        }
        return true
    }

    fun dispose() {
        destroyed = true
        ticket?.cancel()
        ticket = null
        val result = pending
        pending = null
        if (result != null) fail(result, "unreadable")
    }

    private fun fail(result: MethodChannel.Result, code: String) {
        // Never forward provider exceptions, paths, URIs, metadata, or bytes.
        result.error(code, "QR image could not be read", null)
    }

    companion object { const val REQUEST = 7002 }
}

private class AndroidQrSource(private val resolver: ContentResolver, private val uri: Uri) : QrReadSource {
    private val cancellation = CancellationSignal()
    private val closed = AtomicBoolean(false)
    private val descriptor = AtomicReference<AssetFileDescriptor?>(null)

    override fun open(): InputStream {
        if (closed.get()) throw IOException()
        val opened = resolver.openAssetFileDescriptor(uri, "r", cancellation) ?: throw IOException()
        descriptor.set(opened)
        // Cancellation/close can occur while a broken provider is in open().
        if (closed.get()) { close(); throw IOException() }
        return opened.createInputStream()
    }

    override fun cancel() { cancellation.cancel() }

    override fun close() {
        closed.set(true)
        descriptor.getAndSet(null)?.close()
    }
}
