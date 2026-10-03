package com.dhanuk.ovidai

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ControlLifecycleTest {
    @Test fun stopSettlesPendingWorkAndRejectsQueuedDispatch() {
        val gate = DeviceActionCancellation()
        var cancelled = 0
        val first = gate.ticket { cancelled++ }!!
        val queued = gate.ticket { cancelled++ }!!
        gate.cancel()
        assertEquals(2, cancelled)
        assertFalse(first.isCurrent())
        assertFalse(queued.isCurrent())
        assertNull(gate.ticket {})
        gate.begin()
        assertTrue(gate.ticket {}!!.isCurrent())
        assertFalse(queued.isCurrent())
        gate.cancel()
        assertEquals(2, cancelled)
    }

    @Test fun completedWorkIsNotCancelledAgain() {
        val gate = DeviceActionCancellation()
        var cancelled = false
        val ticket = gate.ticket { cancelled = true }!!
        ticket.finish()
        gate.cancel()
        assertFalse(cancelled)
    }

    @Test fun stopReleasesGestureWaitAndLateRegistrationImmediately() {
        val gate = DeviceActionCancellation()
        val ticket = gate.ticket {}!!
        var released = 0
        ticket.whenCancelled { released++ }
        gate.cancel()
        assertEquals(1, released)
        ticket.whenCancelled { released++ }
        assertEquals(2, released)
    }

    @Test fun stoppedExecutorQueueCannotDispatchAfterRestart() {
        val gate = DeviceActionCancellation()
        val executor = Executors.newSingleThreadExecutor()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val first = gate.ticket {}!!
        val queued = gate.ticket {}!!
        try {
            val active = executor.submit {
                first.whenCancelled { release.countDown() }
                entered.countDown()
                check(release.await(2, TimeUnit.SECONDS))
            }
            check(entered.await(2, TimeUnit.SECONDS))
            val dispatch = executor.submit<Boolean> { queued.isCurrent() }
            gate.cancel()
            gate.begin()
            active.get(2, TimeUnit.SECONDS)
            assertFalse(dispatch.get(2, TimeUnit.SECONDS))
            assertTrue(gate.ticket {}!!.isCurrent())
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    private class Surface : ControlGlowSurface {
        var attached = false
        var pulsing = false
        var color = 0
        var failAttach = false
        override fun show(color: Int, animate: Boolean) {
            attached = true
            this.color = color
            pulsing = animate
            if (failAttach) error("partial window attachment")
        }
        override fun hide() { attached = false; pulsing = false }
    }

    @Test fun glowTracksWorkingApprovalErrorAndCleansUp() {
        val surface = Surface()
        val glow = ControlGlowLifecycle(surface)
        glow.update("running", true)
        assertTrue(surface.attached)
        assertTrue(surface.pulsing)
        assertEquals(0xFF34C759.toInt(), surface.color)
        glow.update("permission", true)
        assertEquals(0xFFFFB020.toInt(), surface.color)
        glow.update("error", true)
        assertEquals(0xFFFF453A.toInt(), surface.color)
        glow.update("idle", true)
        assertFalse(surface.attached)
        assertFalse(surface.pulsing)
        glow.update("running", false)
        assertTrue(surface.attached)
        assertFalse(surface.pulsing)
        glow.close()
        assertFalse(surface.attached)
        glow.update("unknown", true)
        assertFalse(surface.attached)
    }

    @Test fun partialAttachmentFailureCleansAllWindows() {
        val surface = Surface().apply { failAttach = true }
        ControlGlowLifecycle(surface).update("running", true)
        assertFalse(surface.attached)
        assertFalse(surface.pulsing)
    }
}
