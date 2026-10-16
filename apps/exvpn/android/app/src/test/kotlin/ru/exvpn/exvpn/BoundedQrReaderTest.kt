package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class BoundedQrReaderTest {
    private class Harness(timeout: Long = 2_000) : AutoCloseable {
        val worker = Executors.newSingleThreadExecutor()
        val timer = Executors.newSingleThreadScheduledExecutor()
        val cleanup = Executors.newFixedThreadPool(2)
        val reader = BoundedQrReader(worker, timer, cleanup, 32, timeout)
        override fun close() {
            worker.shutdownNow(); timer.shutdownNow(); cleanup.shutdownNow()
            assertTrue(worker.awaitTermination(3, TimeUnit.SECONDS))
            assertTrue(cleanup.awaitTermination(3, TimeUnit.SECONDS))
        }
    }

    private open class Source(private val bytes: ByteArray = byteArrayOf(1, 2, 3)) : QrReadSource {
        val cancels = AtomicInteger()
        val closes = AtomicInteger()
        override fun open(): InputStream = ByteArrayInputStream(bytes)
        override fun cancel() { cancels.incrementAndGet() }
        override fun close() { closes.incrementAndGet() }
    }

    private class Reply {
        val ready = CountDownLatch(1)
        val count = AtomicInteger()
        @Volatile var value: QrReadOutcome? = null
        fun receive(outcome: QrReadOutcome) { value = outcome; count.incrementAndGet(); ready.countDown() }
        fun await(): QrReadOutcome { assertTrue(ready.await(3, TimeUnit.SECONDS)); return value!! }
    }

    private fun idle(reader: BoundedQrReader) {
        val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (reader.busy && System.nanoTime() < until) Thread.sleep(5)
        assertFalse("Provider work must have finished", reader.busy)
    }

    private fun awaitIgnoringInterrupt(latch: CountDownLatch) {
        while (true) try { latch.await(); return } catch (_: InterruptedException) { }
    }

    @Test fun smallAndExactLimitFilesReturnBytesOffCallerThread() = Harness().use { h ->
        val caller = Thread.currentThread()
        for (size in listOf(0, 3, 32)) {
            val data = ByteArray(size) { it.toByte() }
            val source = object : Source(data) {
                override fun open(): InputStream { assertNotSame(caller, Thread.currentThread()); return super.open() }
            }
            val reply = Reply()
            assertNotNull(h.reader.start(source, reply::receive))
            assertArrayEquals(data, (reply.await() as QrReadOutcome.Bytes).value)
            idle(h.reader)
            assertEquals(1, source.closes.get())
            assertEquals(1, reply.count.get())
        }
    }

    @Test fun actualStreamLimitReadsOnlyOneByteBeyondCap() = Harness().use { h ->
        val readBytes = AtomicInteger()
        val source = object : Source() {
            override fun open() = object : InputStream() {
                override fun read(): Int { readBytes.incrementAndGet(); return 1 }
            }
        }
        val reply = Reply()
        h.reader.start(source, reply::receive)
        assertEquals("too_large", (reply.await() as QrReadOutcome.Failure).code)
        idle(h.reader)
        assertEquals(33, readBytes.get())
    }

    @Test fun brokenZeroLengthReadsStillMakeBoundedProgress() = Harness().use { h ->
        val source = object : Source() {
            override fun open() = object : InputStream() {
                var size = 0
                override fun read(bytes: ByteArray, offset: Int, length: Int) = 0
                override fun read() = if (size++ < 3) 7 else -1
            }
        }
        val reply = Reply()
        h.reader.start(source, reply::receive)
        assertArrayEquals(byteArrayOf(7, 7, 7), (reply.await() as QrReadOutcome.Bytes).value)
    }

    @Test fun providerExceptionsNeverEscapeWithSensitiveDetails() = Harness().use { h ->
        val source = object : Source() {
            override fun open(): InputStream = throw IllegalStateException("private-uri-and-content")
        }
        val reply = Reply()
        h.reader.start(source, reply::receive)
        assertEquals("unreadable", (reply.await() as QrReadOutcome.Failure).code)
        idle(h.reader)
        assertEquals(1, source.closes.get())
    }

    @Test fun stalledOpenTimesOutKeepsCapacityAndIgnoresLateSuccess() = Harness(80).use { h ->
        val release = CountDownLatch(1)
        val opened = CountDownLatch(1)
        val source = object : Source() {
            override fun open(): InputStream {
                opened.countDown(); awaitIgnoringInterrupt(release)
                return super.open()
            }
        }
        try {
            val reply = Reply()
            h.reader.start(source, reply::receive)
            assertTrue(opened.await(1, TimeUnit.SECONDS))
            assertEquals("unreadable", (reply.await() as QrReadOutcome.Failure).code)
            assertTrue(h.reader.busy)
            assertNull(h.reader.start(Source()) { fail("Must not queue another read") })
            release.countDown()
            idle(h.reader)
            assertEquals(1, reply.count.get())
            val next = Reply()
            assertNotNull(h.reader.start(Source(), next::receive))
            assertTrue(next.await() is QrReadOutcome.Bytes)
        } finally { release.countDown() }
    }

    @Test fun stalledReadAndCancelDoNotBlockDeadlineOrDescriptorClose() = Harness(80).use { h ->
        val releaseRead = CountDownLatch(1)
        val releaseCancel = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val source = object : Source() {
            override fun open() = object : InputStream() {
                override fun read(): Int { awaitIgnoringInterrupt(releaseRead); return -1 }
            }
            override fun cancel() { awaitIgnoringInterrupt(releaseCancel) }
            override fun close() { closed.countDown() }
        }
        try {
            val reply = Reply()
            h.reader.start(source, reply::receive)
            assertEquals("unreadable", (reply.await() as QrReadOutcome.Failure).code)
            assertTrue(closed.await(1, TimeUnit.SECONDS))
            releaseRead.countDown()
            assertTrue(h.reader.busy) // even a stuck cancellation retains capacity
            releaseCancel.countDown()
            idle(h.reader)
            assertEquals(1, reply.count.get())
        } finally { releaseRead.countDown(); releaseCancel.countDown() }
    }

    @Test fun activityCancellationSuppressesReplyAndRetainsHungWorker() = Harness().use { h ->
        val release = CountDownLatch(1)
        val opened = CountDownLatch(1)
        val source = object : Source() {
            override fun open(): InputStream { opened.countDown(); awaitIgnoringInterrupt(release); return super.open() }
        }
        try {
            val reply = Reply()
            val ticket = h.reader.start(source, reply::receive)!!
            assertTrue(opened.await(1, TimeUnit.SECONDS))
            ticket.cancel(); ticket.cancel()
            assertTrue(h.reader.busy)
            assertNull(h.reader.start(Source()) { fail("Activity recreation must not bypass capacity") })
            release.countDown()
            idle(h.reader)
            assertEquals(0, reply.count.get())
            assertEquals(1, source.cancels.get())
        } finally { release.countDown() }
    }

    @Test fun stalledCloseIsCoveredByDeadline() = Harness(80).use { h ->
        val release = CountDownLatch(1)
        val source = object : Source() {
            override fun close() { awaitIgnoringInterrupt(release) }
        }
        try {
            val reply = Reply()
            h.reader.start(source, reply::receive)
            assertEquals("unreadable", (reply.await() as QrReadOutcome.Failure).code)
            assertTrue(h.reader.busy)
            release.countDown()
            idle(h.reader)
            assertEquals(1, reply.count.get())
        } finally { release.countDown() }
    }
}
