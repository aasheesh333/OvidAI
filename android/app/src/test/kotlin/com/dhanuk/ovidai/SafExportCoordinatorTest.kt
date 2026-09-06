package com.dhanuk.ovidai

import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafExportCoordinatorTest {
    private class Source : Closeable {
        val closeCount = AtomicInteger()
        val closed: Boolean get() = closeCount.get() > 0

        override fun close() {
            closeCount.incrementAndGet()
        }
    }

    private class Result : SafExportResult {
        var success: Boolean? = null
        var errorCode: String? = null

        override fun success(exported: Boolean) {
            success = exported
        }

        override fun error(code: String, message: String) {
            errorCode = code
        }
    }

    @Test
    fun nullDestinationClosesSourceAndReportsCancellation() {
        val coordinator = SafExportCoordinator<Source, String> { _, _ -> }
        val source = Source()
        val result = Result()

        assertTrue(coordinator.begin(source, result))
        coordinator.complete(null)

        assertTrue(source.closed)
        assertEquals(false, result.success)
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun cancelClosesSourceAndReportsCancellation() {
        val coordinator = SafExportCoordinator<Source, String> { _, _ -> }
        val source = Source()
        val result = Result()

        assertTrue(coordinator.begin(source, result))
        coordinator.cancel()

        assertTrue(source.closed)
        assertEquals(false, result.success)
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun busyRejectsAndClosesSecondSource() {
        val coordinator = SafExportCoordinator<Source, String> { _, _ -> }
        val first = Source()
        val second = Source()
        val firstResult = Result()
        val secondResult = Result()

        assertTrue(coordinator.begin(first, firstResult))
        assertFalse(coordinator.begin(second, secondResult))

        assertFalse(first.closed)
        assertTrue(second.closed)
        assertEquals("BUSY", secondResult.errorCode)
        coordinator.complete(null)
    }

    @Test
    fun copyFailureClosesSourceAndReportsError() {
        val coordinator = SafExportCoordinator<Source, String> { _, _ ->
            throw IllegalStateException("disk full")
        }
        val source = Source()
        val result = Result()

        assertTrue(coordinator.begin(source, result))
        coordinator.complete("destination")

        assertTrue(source.closed)
        assertEquals("COPY_FAILED", result.errorCode)
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun fatalCopyFailureStillClosesSourceAndReleasesCoordinator() {
        val coordinator = SafExportCoordinator<Source, String> { _, _ ->
            throw AssertionError("fatal copy failure")
        }
        val source = Source()
        val result = Result()

        assertTrue(coordinator.begin(source, result))
        try {
            coordinator.complete("destination")
        } catch (_: AssertionError) {
            // Fatal failures propagate after resource cleanup.
        }

        assertEquals(1, source.closeCount.get())
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun closeFailureAfterCopyStillReportsSuccessfulExport() {
        val source = object : Closeable {
            override fun close() {
                throw IllegalStateException("close failed")
            }
        }
        val result = Result()
        val coordinator = SafExportCoordinator<Closeable, String> { _, _ -> }

        assertTrue(coordinator.begin(source, result))
        coordinator.complete("destination")

        assertEquals(true, result.success)
        assertEquals(null, result.errorCode)
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun successfulCopyUsesPinnedSourceThenClosesIt() {
        var copiedSource: Source? = null
        var copiedDestination: String? = null
        val coordinator = SafExportCoordinator<Source, String> { source, destination ->
            copiedSource = source
            copiedDestination = destination
        }
        val source = Source()
        val result = Result()

        assertTrue(coordinator.begin(source, result))
        coordinator.complete("destination")

        assertEquals(source, copiedSource)
        assertEquals("destination", copiedDestination)
        assertTrue(source.closed)
        assertEquals(true, result.success)
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun cleanupClosesPendingSourceAndReportsLifecycleFailure() {
        val coordinator = SafExportCoordinator<Source, String> { _, _ -> }
        val source = Source()
        val result = Result()

        assertTrue(coordinator.begin(source, result))
        coordinator.cleanup()

        assertTrue(source.closed)
        assertEquals("ACTIVITY_DESTROYED", result.errorCode)
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun exportRemainsBusyUntilCopyAndResultComplete() {
        val copyStarted = CountDownLatch(1)
        val releaseCopy = CountDownLatch(1)
        val coordinator = SafExportCoordinator<Source, String> { _, _ ->
            copyStarted.countDown()
            assertTrue(releaseCopy.await(5, TimeUnit.SECONDS))
        }
        val first = Source()
        val second = Source()
        val firstResult = Result()
        val secondResult = Result()

        assertTrue(coordinator.begin(first, firstResult))
        val executor = Executors.newSingleThreadExecutor()
        try {
            val completion = executor.submit { coordinator.complete("destination") }
            assertTrue(copyStarted.await(5, TimeUnit.SECONDS))

            assertFalse(coordinator.begin(second, secondResult))
            assertTrue(second.closed)
            assertEquals("BUSY", secondResult.errorCode)

            releaseCopy.countDown()
            completion.get(5, TimeUnit.SECONDS)
        } finally {
            releaseCopy.countDown()
            executor.shutdownNow()
        }

        assertEquals(1, first.closeCount.get())
        assertEquals(true, firstResult.success)
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun successCallbackFailureDoesNotInvokeErrorCallback() {
        val source = Source()
        var successCalls = 0
        var errorCalls = 0
        val result = object : SafExportResult {
            override fun success(exported: Boolean) {
                successCalls++
                throw IllegalStateException("detached result")
            }

            override fun error(code: String, message: String) {
                errorCalls++
            }
        }
        val coordinator = SafExportCoordinator<Source, String> { _, _ -> }

        assertTrue(coordinator.begin(source, result))
        try {
            coordinator.complete("destination")
        } catch (_: IllegalStateException) {
            // Callback failures belong to the channel and must not become copy failures.
        }

        assertEquals(1, successCalls)
        assertEquals(0, errorCalls)
        assertEquals(1, source.closeCount.get())
        assertFalse(coordinator.hasPending)
    }

    @Test
    fun concurrentTerminalCallsResolveAndCloseExactlyOnce() {
        val source = Source()
        val callbackCount = AtomicInteger()
        val result = object : SafExportResult {
            override fun success(exported: Boolean) {
                callbackCount.incrementAndGet()
            }

            override fun error(code: String, message: String) {
                callbackCount.incrementAndGet()
            }
        }
        val coordinator = SafExportCoordinator<Source, String> { _, _ -> }
        assertTrue(coordinator.begin(source, result))
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(4)

        try {
            val completions = listOf(
                executor.submit { start.await(); coordinator.complete("destination") },
                executor.submit { start.await(); coordinator.cancel() },
                executor.submit { start.await(); coordinator.fail("FAILED", "failed") },
                executor.submit { start.await(); coordinator.cleanup() },
            )
            start.countDown()
            completions.forEach { it.get(5, TimeUnit.SECONDS) }
        } finally {
            executor.shutdownNow()
        }

        assertEquals(1, callbackCount.get())
        assertEquals(1, source.closeCount.get())
        assertFalse(coordinator.hasPending)
    }
}
