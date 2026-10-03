package com.dhanuk.ovidai

/** Service updates and alarm/boot ticks may read this latch, never clear it. */
class BackgroundStopLatch(
    private val readStopped: () -> Boolean,
    private val writeStopped: (Boolean) -> Boolean,
) {
    private var stoppedInMemory = false
    fun mayRun(): Boolean = !stoppedInMemory && !readStopped()
    fun stop(): Boolean {
        stoppedInMemory = true
        return writeStopped(true)
    }
    fun resume(): Boolean {
        if (!writeStopped(false)) return false
        stoppedInMemory = false
        return true
    }
}
