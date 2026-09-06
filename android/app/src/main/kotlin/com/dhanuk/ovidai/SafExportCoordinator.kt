package com.dhanuk.ovidai

import java.io.Closeable

interface SafExportResult {
    fun success(exported: Boolean)
    fun error(code: String, message: String)
}

class SafExportCoordinator<S : Closeable, D>(
    private val copy: (S, D) -> Unit,
) {
    private data class Pending<S>(
        val source: S,
        val result: SafExportResult,
        var completing: Boolean = false,
    )

    private var pending: Pending<S>? = null

    val hasPending: Boolean
        @Synchronized get() = pending != null

    fun begin(source: S, result: SafExportResult): Boolean {
        val accepted = synchronized(this) {
            if (pending == null) {
                pending = Pending(source, result)
                true
            } else {
                false
            }
        }
        if (!accepted) {
            closeQuietly(source)
            result.error("BUSY", "Another file export is already open")
            return false
        }
        return true
    }

    fun complete(destination: D?) {
        val current = claimPending() ?: return
        try {
            var failure: Exception? = null
            try {
                if (destination != null) {
                    copy(current.source, destination)
                }
            } catch (e: Exception) {
                failure = e
            } finally {
                closeQuietly(current.source)
            }
            val error = failure
            if (error == null) {
                current.result.success(destination != null)
            } else {
                current.result.error("COPY_FAILED", "File export failed: ${error.message}")
            }
        } finally {
            releasePending(current)
        }
    }

    fun fail(code: String, message: String) {
        val current = claimPending() ?: return
        closeQuietly(current.source)
        try {
            current.result.error(code, message)
        } finally {
            releasePending(current)
        }
    }

    fun cancel() {
        complete(null)
    }

    fun cleanup() {
        fail("ACTIVITY_DESTROYED", "File export was interrupted")
    }

    @Synchronized
    private fun claimPending(): Pending<S>? {
        val current = pending ?: return null
        if (current.completing) return null
        current.completing = true
        return current
    }

    @Synchronized
    private fun releasePending(current: Pending<S>) {
        if (pending === current) pending = null
    }

    private fun closeQuietly(source: S) {
        try {
            source.close()
        } catch (_: Exception) {
            // The result still has to resolve exactly once when close reports an error.
        }
    }
}
