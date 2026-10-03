package com.dhanuk.ovidai

/** Window ownership is separate from bubble visibility and foreground-service presence. */
internal interface ControlGlowSurface {
    fun show(color: Int, animate: Boolean)
    fun hide()
}

internal class ControlGlowLifecycle(private val surface: ControlGlowSurface) {
    fun update(state: String, animate: Boolean) {
        val color = when (state) {
            "running" -> 0xFF34C759.toInt()
            "permission" -> 0xFFFFB020.toInt()
            "error" -> 0xFFFF453A.toInt()
            else -> null
        }
        if (color == null) { close(); return }
        try {
            surface.show(color, animate)
        } catch (_: Throwable) {
            close() // Includes windows attached before a later addView failed.
        }
    }

    fun close() = surface.hide()
}
