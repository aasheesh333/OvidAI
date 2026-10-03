package com.dhanuk.ovidai

import org.junit.Assert.*
import org.junit.Test

class BackgroundStopLatchTest {
    @Test fun stopSurvivesReconstructionAndRepeatedServiceTicks() {
        var disk = false
        fun latch() = BackgroundStopLatch({ disk }, { value -> disk = value; true })
        val first = latch()
        assertTrue(first.mayRun())
        first.stop()
        val restarted = latch()
        repeat(20) { assertFalse(restarted.mayRun()) }
        restarted.resume()
        assertTrue(latch().mayRun())
    }

    @Test fun failedStopWriteStillBlocksThisProcess() {
        val latch = BackgroundStopLatch({ false }, { false })
        assertFalse(latch.stop())
        assertFalse(latch.mayRun())
        assertFalse(latch.resume())
        assertFalse(latch.mayRun())
    }
}
