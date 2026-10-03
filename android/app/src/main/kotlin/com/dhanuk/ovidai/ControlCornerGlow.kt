package com.dhanuk.ovidai

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/** Four small radial gradients: no full-screen buffer and no touch interception. */
internal class ControlCornerGlow(private val context: Context) : ControlGlowSurface {
    private val windows = mutableListOf<View>()
    private var pulse: ValueAnimator? = null
    private var pulsing = false

    override fun show(color: Int, animate: Boolean) {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val size = (80 * context.resources.displayMetrics.density).toInt()
        val corners = listOf(
            Triple(Gravity.TOP or Gravity.LEFT, 0f, 0f),
            Triple(Gravity.TOP or Gravity.RIGHT, 1f, 0f),
            Triple(Gravity.BOTTOM or Gravity.LEFT, 0f, 1f),
            Triple(Gravity.BOTTOM or Gravity.RIGHT, 1f, 1f),
        )
        if (windows.isEmpty()) {
            for ((gravity, _, _) in corners) {
                val view = View(context).apply {
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }
                // Record before addView so a partial attachment can be removed.
                windows.add(view)
                wm.addView(view, WindowManager.LayoutParams(
                    size, size, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT,
                ).apply {
                    this.gravity = gravity
                })
            }
        }
        for ((index, view) in windows.withIndex()) {
            view.background = GradientDrawable().apply {
                gradientType = GradientDrawable.RADIAL_GRADIENT
                gradientRadius = size.toFloat()
                setGradientCenter(corners[index].second, corners[index].third)
                colors = intArrayOf((color and 0xFFFFFF) or 0x88000000.toInt(), 0)
            }
        }
        if (animate == pulsing) return
        pulse?.cancel()
        pulse = null
        pulsing = animate
        windows.forEach { it.alpha = 1f }
        if (animate) {
            pulse = ValueAnimator.ofFloat(0.45f, 1f).apply {
                duration = 1600
                repeatCount = ValueAnimator.INFINITE
                repeatMode = ValueAnimator.REVERSE
                addUpdateListener { value ->
                    windows.forEach { it.alpha = value.animatedValue as Float }
                }
                start()
            }
        }
    }

    override fun hide() {
        pulse?.cancel()
        pulse = null
        pulsing = false
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        for (view in windows) {
            try { wm?.removeViewImmediate(view) } catch (_: Throwable) { }
        }
        windows.clear()
    }
}
