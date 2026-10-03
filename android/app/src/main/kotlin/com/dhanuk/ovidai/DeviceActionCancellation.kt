package com.dhanuk.ovidai

/** Shared by the activity, accessibility service and notification Stop path. */
internal class DeviceActionCancellation {
    private var generation = 0L
    private var stopped = false
    private val pending = mutableSetOf<Ticket>()
    val current = ThreadLocal<Ticket?>()
    @Synchronized fun isStopped(): Boolean = stopped

    inner class Ticket internal constructor(
        private val epoch: Long,
        private val onCancel: () -> Unit,
    ) {
        private var releaseWait: (() -> Unit)? = null
        fun isCurrent(): Boolean = synchronized(this@DeviceActionCancellation) {
            !stopped && epoch == generation
        }
        fun finish() { synchronized(this@DeviceActionCancellation) { pending.remove(this) } }
        fun whenCancelled(release: () -> Unit) {
            val cancelled = synchronized(this@DeviceActionCancellation) {
                if (isCurrent()) { releaseWait = release; false } else true
            }
            if (cancelled) release()
        }
        internal fun cancel() {
            val release = synchronized(this@DeviceActionCancellation) {
                releaseWait.also { releaseWait = null }
            }
            release?.invoke()
            onCancel()
        }
    }

    @Synchronized fun ticket(onCancel: () -> Unit): Ticket? {
        if (stopped) return null
        return Ticket(generation, onCancel).also { pending.add(it) }
    }

    fun cancel() {
        val tickets = synchronized(this) {
            stopped = true
            generation++
            pending.toList().also { pending.clear() }
        }
        tickets.forEach { it.cancel() }
    }

    fun begin() {
        cancel()
        synchronized(this) { stopped = false }
    }
}

internal val deviceActions = DeviceActionCancellation()
