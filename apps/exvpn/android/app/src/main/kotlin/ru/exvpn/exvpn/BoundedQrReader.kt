package ru.exvpn.exvpn

import java.io.InputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal interface QrReadSource {
    fun open(): InputStream
    fun cancel()
    fun close()
}

internal sealed class QrReadOutcome {
    class Bytes(val value: ByteArray) : QrReadOutcome()
    class Failure(val code: String) : QrReadOutcome()
}

/** Process-wide capacity: a timed-out provider keeps its slot until it really
 * exits. Neither an Activity recreation nor repeated requests can accumulate
 * blocked provider calls. No provider method runs on the caller/UI thread. */
internal class BoundedQrReader(
    private val worker: Executor,
    private val timer: ScheduledExecutorService,
    private val cleanup: Executor,
    private val maxBytes: Int = 5 * 1024 * 1024,
    private val timeoutMillis: Long = 20_000,
) {
    private val lock = Any()
    private var active: Read? = null

    init { require(maxBytes > 0 && timeoutMillis > 0) }

    internal interface Ticket { fun cancel() }

    private class Read(val source: QrReadSource, var reply: ((QrReadOutcome) -> Unit)?) {
        val cancelled = AtomicBoolean(false)
        var terminal = false
        var reading = true
        var cleanupPending = 0
        var deadline: ScheduledFuture<*>? = null
    }

    val busy: Boolean get() = synchronized(lock) { active != null }

    fun start(source: QrReadSource, reply: (QrReadOutcome) -> Unit): Ticket? {
        val read = synchronized(lock) {
            if (active != null) return null
            Read(source, reply).also { active = it }
        }
        // These process-owned executors are never shut down during Activity
        // lifecycle changes. Publishing deadline under lock closes the fast
        // timeout / assignment race.
        synchronized(lock) {
            read.deadline = timer.schedule({ abort(read, true) }, timeoutMillis, TimeUnit.MILLISECONDS)
        }
        worker.execute { perform(read) }
        return object : Ticket { override fun cancel() = abort(read, false) }
    }

    private fun perform(read: Read) {
        val outcome = try {
            check(!read.cancelled.get())
            read.source.open().use { input ->
                // Never allocate from ContentProvider SIZE or available().
                // One fixed buffer plus its bounded result; no disk/cache copy.
                val bytes = ByteArray(maxBytes)
                var size = 0
                while (size < bytes.size) {
                    check(!read.cancelled.get())
                    val count = input.read(bytes, size, minOf(8192, bytes.size - size))
                    if (count < 0) break
                    if (count == 0) {
                        val single = input.read()
                        if (single < 0) break
                        bytes[size++] = single.toByte()
                    } else size += count
                }
                check(!read.cancelled.get())
                if (size == bytes.size && input.read() != -1) QrReadOutcome.Failure("too_large")
                else QrReadOutcome.Bytes(bytes.copyOf(size))
            }
        } catch (_: Exception) {
            QrReadOutcome.Failure("unreadable")
        } finally {
            // A provider's close may itself stall. The deadline can still reply
            // while this worker remains owned; no replacement reader is started.
            try { read.source.close() } catch (_: Exception) { }
        }
        val reply = synchronized(lock) {
            read.reading = false
            val callback = if (read.terminal) null else read.reply
            read.terminal = true
            read.reply = null
            read.deadline?.cancel(false)
            releaseIfFinished(read)
            callback
        }
        reply?.invoke(outcome)
    }

    private fun abort(read: Read, reportTimeout: Boolean) {
        val reply = synchronized(lock) {
            if (read.terminal) return
            read.terminal = true
            read.cancelled.set(true)
            read.deadline?.cancel(false)
            read.cleanupPending = 2
            val callback = if (reportTimeout) read.reply else null
            read.reply = null
            callback
        }
        // CancellationSignal.cancel can block on a remote provider. Closing
        // the descriptor gets its own bounded executor slot, independent of it.
        for (action in listOf<() -> Unit>({ read.source.cancel() }, { read.source.close() })) {
            cleanup.execute {
                try { action() } catch (_: Exception) { }
                finally {
                    synchronized(lock) {
                        read.cleanupPending--
                        releaseIfFinished(read)
                    }
                }
            }
        }
        reply?.invoke(QrReadOutcome.Failure("unreadable"))
    }

    private fun releaseIfFinished(read: Read) {
        if (!read.reading && read.cleanupPending == 0 && active === read) active = null
    }

    companion object {
        val shared by lazy {
            fun factory(label: String) = java.util.concurrent.ThreadFactory { task ->
                Thread(task, label).apply { isDaemon = true }
            }
            BoundedQrReader(
                Executors.newSingleThreadExecutor(factory("exvpn-qr-read")),
                Executors.newSingleThreadScheduledExecutor(factory("exvpn-qr-deadline")),
                Executors.newFixedThreadPool(2, factory("exvpn-qr-cancel")),
            )
        }
    }
}
