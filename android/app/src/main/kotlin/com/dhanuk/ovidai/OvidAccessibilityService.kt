package com.dhanuk.ovidai

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.animation.ValueAnimator
import android.annotation.TargetApi
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock

internal data class HandleAllocation(val handle: Int, val nextHandle: Int)

internal fun isAccessibilityServiceConfigured(
    accessibilityEnabled: Boolean,
    enabledServicesSetting: String?,
    packageName: String,
    serviceClassName: String,
): Boolean {
    if (!accessibilityEnabled || enabledServicesSetting.isNullOrBlank()) return false
    val expectedFullName = "$packageName/$serviceClassName"
    val expectedShortName = "$packageName/${if (serviceClassName.startsWith(packageName)) serviceClassName.removePrefix(packageName) else serviceClassName}"
    val simpleClassName = serviceClassName.substringAfterLast('.')
    val expectedShortDotName = "$packageName/.$simpleClassName"
    val entries = enabledServicesSetting.split(':')
    for (entry in entries) {
        val trimmed = entry.trim()
        if (trimmed.equals(expectedFullName, ignoreCase = true) ||
            trimmed.equals(expectedShortName, ignoreCase = true) ||
            trimmed.equals(expectedShortDotName, ignoreCase = true) ||
            (trimmed.startsWith(packageName, ignoreCase = true) && trimmed.endsWith(simpleClassName, ignoreCase = true))) {
            return true
        }
    }
    return false
}

internal fun isAccessibilityServiceEnabled(context: Context): Boolean {
    if (OvidAccessibilityService.instance != null) return true

    val targetClassName = OvidAccessibilityService::class.java.name
    val simpleClassName = OvidAccessibilityService::class.java.simpleName

    // 1. Query AccessibilityManager for enabled accessibility services (check both enabled and installed)
    try {
        val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        if (am != null) {
            val enabledServices = am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            for (service in enabledServices) {
                val serviceInfo = service.resolveInfo?.serviceInfo ?: continue
                val sPkg = serviceInfo.packageName
                val sName = serviceInfo.name ?: ""
                if (sPkg == context.packageName &&
                    (sName == targetClassName ||
                     sName.endsWith(".$simpleClassName") ||
                     sName.endsWith(simpleClassName))) {
                    return true
                }
            }
        }
    } catch (_: Exception) {}

    // 2. Query Settings.Secure ENABLED_ACCESSIBILITY_SERVICES
    try {
        val accessibilityEnabled = Settings.Secure.getInt(
            context.contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0
        ) == 1
        val settingValue = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        )
        if (isAccessibilityServiceConfigured(
                accessibilityEnabled = accessibilityEnabled,
                enabledServicesSetting = settingValue,
                packageName = context.packageName,
                serviceClassName = targetClassName,
            )) {
            return true
        }
    } catch (_: Exception) {}

    return false
}

internal fun stableNodeKey(
    viewId: String,
    className: String,
    text: String,
    description: String,
    bounds: List<Int>,
): String = "$viewId|$className|$text|$description|${bounds.joinToString(",")}"

internal fun allocateStableHandle(
    handlesByStableKey: Map<String, Int>,
    stableKey: String,
    nextHandle: Int,
): HandleAllocation {
    val existing = handlesByStableKey[stableKey]
    return if (existing != null) {
        HandleAllocation(existing, nextHandle)
    } else {
        HandleAllocation(nextHandle, nextHandle + 1)
    }
}

internal data class NodeDelta(
    val full: Boolean,
    val added: List<Map<String, Any?>>,
    val changed: List<Map<String, Any?>>,
    val removed: List<Int>,
)

internal fun diffNodeRows(
    previous: LinkedHashMap<String, Map<String, Any?>>,
    current: LinkedHashMap<String, Map<String, Any?>>,
    forceFull: Boolean,
    windowChanged: Boolean,
): NodeDelta {
    if (forceFull || windowChanged) {
        return NodeDelta(
            full = true,
            added = current.values.toList(),
            changed = emptyList(),
            removed = emptyList(),
        )
    }

    val added = current
        .filterKeys { it !in previous }
        .values
        .toList()
    val changed = current
        .filter { (key, row) -> previous[key] != null && previous[key] != row }
        .values
        .toList()
    val removed = previous
        .filterKeys { it !in current }
        .values
        .mapNotNull { (it["handle"] as? Number)?.toInt() }
    return NodeDelta(false, added, changed, removed)
}

internal data class DeviceActionResult(
    val ok: Boolean,
    val code: String = "ACTION_FAILED",
    val message: String = "The accessibility action was not accepted.",
    val value: Any? = true,
)

/// How a dispatched stroke actually ended, reported by the platform's
/// `GestureResultCallback` (audit 2026-09-25). ACCEPTED-for-dispatch is NOT in
/// this set: that is the boolean `dispatchGesture` returns synchronously, and
/// treating it as success is exactly the bug — the agent would read the screen
/// before the stroke landed. Only COMPLETED means the motion finished.
internal enum class GestureOutcome { COMPLETED, CANCELLED, TIMEOUT }

internal fun passwordTypingRefusal(isPassword: Boolean): DeviceActionResult? =
    if (isPassword) {
        DeviceActionResult(false, "PASSWORD_FIELD", "Ovid will not type into password fields.")
    } else {
        null
    }

internal class TreeReadGeneration {
    private val eventGeneration = AtomicLong(1)
    private val builtGeneration = AtomicLong(0)

    fun markDirty(): Long = eventGeneration.incrementAndGet()

    fun beginRead(forceFull: Boolean): Long? {
        val currentGeneration = eventGeneration.get()
        return currentGeneration.takeIf {
            forceFull || currentGeneration != builtGeneration.get()
        }
    }

    fun completeRead(readGeneration: Long) {
        builtGeneration.set(readGeneration)
    }

    fun abandonRead(readGeneration: Long) {
        while (true) {
            val currentGeneration = eventGeneration.get()
            if (currentGeneration > readGeneration) return
            if (eventGeneration.compareAndSet(currentGeneration, currentGeneration + 1)) return
        }
    }
}

internal data class UnavailableTreeRead(
    val status: String = "unavailable",
    val packageName: String,
    val windowId: Int,
)

internal class TreeReadCache<N>(
    private val recycleNode: (N) -> Unit = {},
) {
    private val generation = TreeReadGeneration()
    var windowSignature = ""
        private set
    var packageName = ""
        private set
    var windowId = -1
        private set
    val rows = linkedMapOf<String, Map<String, Any?>>()
    val nodesByHandle = mutableMapOf<Int, N>()
    val handlesByStableKey = mutableMapOf<String, Int>()
    var nextHandle = 1
        private set

    fun markDirty(): Long = generation.markDirty()

    fun beginRead(forceFull: Boolean): Long? = generation.beginRead(forceFull)

    fun abandon(readGeneration: Long) {
        generation.abandonRead(readGeneration)
    }

    fun unavailable(readGeneration: Long): UnavailableTreeRead {
        generation.abandonRead(readGeneration)
        return UnavailableTreeRead(packageName = packageName, windowId = windowId)
    }

    fun commit(
        readGeneration: Long,
        packageName: String,
        windowId: Int,
        rows: LinkedHashMap<String, Map<String, Any?>>,
        nodes: MutableMap<Int, N>,
        handles: MutableMap<String, Int>,
        newNextHandle: Int,
        forceFull: Boolean,
    ): NodeDelta {
        val signature = "$packageName|$windowId"
        val delta = diffNodeRows(
            previous = this.rows,
            current = rows,
            forceFull = forceFull,
            windowChanged = signature != windowSignature,
        )

        recycleNodes()
        nodesByHandle.putAll(nodes)
        handlesByStableKey.clear()
        handlesByStableKey.putAll(handles)
        this.rows.clear()
        this.rows.putAll(rows)
        nextHandle = newNextHandle
        windowSignature = signature
        this.packageName = packageName
        this.windowId = windowId
        generation.completeRead(readGeneration)
        return delta
    }

    fun reset() {
        recycleNodes()
        handlesByStableKey.clear()
        rows.clear()
        windowSignature = ""
        packageName = ""
        windowId = -1
        generation.markDirty()
    }

    private fun recycleNodes() {
        nodesByHandle.values.forEach { node ->
            try {
                recycleNode(node)
            } catch (_: Throwable) {
                // Continue releasing the remaining retained nodes.
            }
        }
        nodesByHandle.clear()
    }
}

@Suppress("DEPRECATION")
class OvidAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: OvidAccessibilityService? = null
            private set

        // Overlay run-state colours, pushed from Dart as deviceOverlayState.
        const val OVERLAY_IDLE = "idle"
        const val OVERLAY_RUNNING = "running"
        const val OVERLAY_PERMISSION = "permission"
        const val OVERLAY_ERROR = "error"

        private const val MAX_NODES = 300

        /// Keyboard nodes admitted per read, on top of the app tree.
        private const val IME_NODE_BUDGET = 80
        private const val MAX_DEPTH = 30

        /// Upper bound on waiting for a dispatched stroke to report
        /// completion (audit 2026-09-25). Generous enough for a slow drag or
        /// pinch on a loaded device, short enough that a callback the platform
        /// never delivers cannot wedge the run — on expiry we report an honest
        /// timeout instead of hanging or claiming success.
        private const val GESTURE_TIMEOUT_MS = 3000L

        /// Native→Dart bridge for overlay events. Set by MainActivity, which
        /// owns the FlutterEngine: ("deviceOverlayText", text) on send,
        /// ("deviceOverlayStop", null) on X with an empty field.
        var overlayEventListener: ((method: String, argument: String?) -> Unit)? = null
    }

    private val treeCache = TreeReadCache<AccessibilityNodeInfo> { it.recycle() }
    private val screenshotExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ovid-device-screenshot").apply { isDaemon = true }
    }

    // ── Gesture completion plumbing (audit 2026-09-25) ──────────────────────
    // `dispatchGesture` must be invoked on the main thread, and Android also
    // delivers its `GestureResultCallback` there. So the wait for completion
    // can never happen on the main thread: MainActivity hands every gesture to
    // a single-thread background executor, that thread blocks on the latch
    // below, and the main looper stays free to run the callback that releases
    // it. mainHandler is where we post the dispatch and where the callback
    // lands; gestureLock serializes strokes so a second dispatch cannot overlap
    // one still animating (which the platform would reject).
    private val mainHandler = Handler(Looper.getMainLooper())
    private val gestureLock = ReentrantLock()

    // ── Floating control overlay ────────────────────────────────────────
    // TYPE_ACCESSIBILITY_OVERLAY: creatable from an accessibility service with
    // no manifest permission, alive exactly while the service is bound. Hiding
    // removes the window outright, so no invisible touch target can survive.
    //
    // REDESIGN (2026-09-25, owner request). The old overlay was a permanently
    // expanded dark pill that could only be moved by a small 2×3-dot handle, and
    // `updateViewLayout` was handed raw touch coordinates — dragging past an
    // edge lost the window off-screen with no way back short of killing the run.
    // It is now:
    //
    //   • a small WHITE CIRCLE, draggable from anywhere on itself to ANY
    //     position, and clamped inside the real display bounds on every move,
    //     on expand, and on configuration change — it can never be hidden
    //     off-device;
    //   • tap expands the steering box (Stop · text field · mic · green send);
    //   • four NON-TOUCHABLE corner glows report run state at a glance —
    //     green = running, amber = waiting on a permission, red = error.
    private var overlayView: View? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var overlayInput: EditText? = null
    private var overlaySendButton: ImageButton? = null
    private var overlayMicButton: ImageButton? = null
    private var overlayCircle: View? = null
    private var overlayBox: View? = null
    private var overlayExpanded = false
    private val cornerGlow by lazy { ControlGlowLifecycle(ControlCornerGlow(this)) }
    @Volatile
    private var overlayState: String = OVERLAY_IDLE

    @Synchronized
    internal fun showOverlay(): DeviceActionResult {
        if (deviceActions.isStopped()) return DeviceActionResult(true)
        if (overlayView != null) return DeviceActionResult(true)
        val windowManager = getSystemService(WINDOW_SERVICE) as? WindowManager
            ?: return DeviceActionResult(false, "UNAVAILABLE", "Window manager is unavailable.")
        return try {
            val density = resources.displayMetrics.density
            val root = overlayRoot(windowManager, density)
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                x = (16 * density).toInt()
                y = (200 * density).toInt()
            }
            windowManager.addView(root, params)
            overlayView = root
            overlayParams = params
            // Clamp once laid out: the window size is unknown until then.
            root.post { clampOverlayIntoDisplay() }
            DeviceActionResult(true)
        } catch (error: WindowManager.BadTokenException) {
            removeOverlayNow()
            DeviceActionResult(false, "UNAVAILABLE", "Overlay window was refused: " + error.message)
        } catch (error: Throwable) {
            removeOverlayNow()
            DeviceActionResult(false, "UNAVAILABLE", "Overlay could not be shown: " + error.message)
        }
    }

    @Synchronized
    internal fun hideOverlay(): DeviceActionResult {
        val view = overlayView ?: return DeviceActionResult(true)
        (getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager)
            ?.hideSoftInputFromWindow(overlayInput?.windowToken, 0)
        clearOverlayRefs()
        return try {
            val windowManager = getSystemService(WINDOW_SERVICE) as? WindowManager
            windowManager?.removeView(view)
            DeviceActionResult(true)
        } catch (_: Throwable) {
            // Hidden state is what matters: refs are already cleared, so no
            // invisible touch target can survive. Never crash a hide.
            DeviceActionResult(true)
        }
    }

    internal fun isOverlayVisible(): Boolean = overlayView != null

    private fun clearOverlayRefs() {
        overlayView = null
        overlayParams = null
        overlayInput = null
        overlaySendButton = null
        overlayMicButton = null
        overlayCircle = null
        overlayBox = null
        overlayExpanded = false
    }

    /// Keeps the window wholly inside the real display bounds.
    ///
    /// This is the fix for "the circle disappears off my screen": raw touch
    /// coordinates were being written straight into the layout params, so any
    /// drag past an edge parked the window where no finger could reach it again.
    /// Clamping on every move, on expand and on rotation means every part of it
    /// stays touchable.
    private fun clampOverlayIntoDisplay() {
        val params = overlayParams ?: return
        val view = overlayView ?: return
        val wm = getSystemService(WINDOW_SERVICE) as? WindowManager ?: return
        val size = displaySize(wm)
        if (size.x <= 0 || size.y <= 0) return
        val w = if (view.width > 0) view.width else params.width.coerceAtLeast(0)
        val h = if (view.height > 0) view.height else params.height.coerceAtLeast(0)
        val maxX = (size.x - w).coerceAtLeast(0)
        val maxY = (size.y - h).coerceAtLeast(0)
        val nx = params.x.coerceIn(0, maxX)
        val ny = params.y.coerceIn(0, maxY)
        if (nx == params.x && ny == params.y) return
        params.x = nx
        params.y = ny
        try {
            wm.updateViewLayout(view, params)
        } catch (_: Throwable) {
            // A racing hide must not crash the drag.
        }
    }

    private fun displaySize(wm: WindowManager): Point {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val b = wm.currentWindowMetrics.bounds
                Point(b.width(), b.height())
            } else {
                val metrics = android.util.DisplayMetrics()
                @Suppress("DEPRECATION")
                wm.defaultDisplay.getRealMetrics(metrics)
                Point(metrics.widthPixels, metrics.heightPixels)
            }
        } catch (_: Throwable) {
            val m = resources.displayMetrics
            Point(m.widthPixels, m.heightPixels)
        }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // Rotation/resplit changes the display bounds: re-clamp so a circle that
        // was legitimately at the bottom-right is not left off-screen.
        clampOverlayIntoDisplay()
    }

    /// Overlay send seam: non-blank text goes to Dart as deviceOverlayText,
    /// then the field is cleared (which re-disables the green send button).
    internal fun onOverlaySend(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        overlayEventListener?.invoke("deviceOverlayText", trimmed)
        overlayInput?.text?.clear()
    }

    /// Overlay stop seam: a hard stop for the run (long-press on the circle).
    internal fun onOverlayStop() {
        stopControlNow()
        overlayEventListener?.invoke("deviceOverlayStop", null)
    }

    internal fun stopControlNow() {
        deviceActions.cancel()
        overlayState = OVERLAY_IDLE
        cornerGlow.close()
        hideOverlay()
    }

    /// Overlay mic seam: ask Dart to toggle on-device dictation.
    internal fun onOverlayMic() {
        overlayEventListener?.invoke("deviceOverlayMic", null)
    }

    /// Push recognized dictation text into the overlay field (from Dart).
    internal fun setOverlayInputText(text: String) {
        val input = overlayInput ?: return
        if (!overlayExpanded) setOverlayExpanded(true)
        input.setText(text)
        input.setSelection(text.length)
    }

    /// Reflect the dictation listening state on the mic button.
    internal fun setOverlayMicListening(listening: Boolean) {
        val button = overlayMicButton ?: return
        button.imageTintList = ColorStateList.valueOf(
            if (listening) 0xFF1FA05F.toInt() else 0xFF6E6E6E.toInt(),
        )
        button.contentDescription = if (listening) "Stop dictation" else "Dictate"
    }

    /// Show the AI's pending question as the overlay input hint.
    internal fun setOverlayPrompt(prompt: String) {
        overlayInput?.hint = prompt
    }

    /// Only the screen corners report status; the floating circle stays plain.
    internal fun setOverlayState(state: String) {
        if (state != OVERLAY_IDLE && deviceActions.isStopped()) return
        overlayState = state
        cornerGlow.update(state, animationsEnabled())
        overlayCircle?.contentDescription = "Ovid — $state. Tap to steer; long press to stop"
    }

    private fun animationsEnabled(): Boolean {
        val accessibility = getSystemService(ACCESSIBILITY_SERVICE) as? AccessibilityManager
        if (accessibility?.isTouchExplorationEnabled == true) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ValueAnimator.areAnimatorsEnabled()
        } else {
            Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
        }
    }

    /// Compatibility with the existing Dart live flag. No bubble animation.
    internal fun setOverlayLive(live: Boolean) {
        if (!live) cornerGlow.close()
        else cornerGlow.update(overlayState, animationsEnabled())
    }

    private fun removeOverlayNow() {
        cornerGlow.close()
        hideOverlay()
    }

    /// Circle + box in one window; exactly one is visible at a time.
    private fun overlayRoot(
        windowManager: WindowManager,
        density: Float,
    ): FrameLayout {
        val root = FrameLayout(this)
        val circle = overlayCircleView(windowManager, root, density)
        root.addView(circle, FrameLayout.LayoutParams(
            (48 * density).toInt(), (48 * density).toInt()))
        overlayCircle = circle
        val box = overlayBoxView(windowManager, root, density)
        box.visibility = View.GONE
        root.addView(box, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        overlayBox = box
        return root
    }

    private fun setOverlayExpanded(expand: Boolean) {
        if (overlayExpanded == expand) return
        overlayExpanded = expand
        overlayCircle?.visibility = if (expand) View.GONE else View.VISIBLE
        overlayBox?.visibility = if (expand) View.VISIBLE else View.GONE
        if (!expand) {
            overlayInput?.clearFocus()
            val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
            imm?.hideSoftInputFromWindow(overlayInput?.windowToken, 0)
        }
        // The window is a different size now, so the old position may be
        // off-display: re-clamp once the new size is measured.
        overlayView?.post { clampOverlayIntoDisplay() }
    }

    /// The small white circle. Drag anywhere on it to move; tap to expand;
    /// long-press to hard-stop the run.
    private fun overlayCircleView(
        windowManager: WindowManager,
        root: View,
        density: Float,
    ): View {
        val bg = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(0xFFFFFFFF.toInt())
        }
        val circle = View(this).apply {
            background = bg
            elevation = 6 * density
            contentDescription = "Ovid — drag to move, tap to steer"
        }
        // A small mark so it reads as Ovid rather than a stray dot.
        circle.setOnTouchListener(overlayDragTouchListener(windowManager, root, density) {
            setOverlayExpanded(true)
        })
        circle.setOnLongClickListener {
            onOverlayStop()
            true
        }
        return circle
    }

    /// Touch handler that both drags the window and recognises a tap.
    ///
    /// Coordinates are clamped as they are written, so the window follows the
    /// finger but can never be parked off-display. A tap is a DOWN/UP pair that
    /// never moved more than the touch slop and never exceeded the tap timeout —
    /// that distinction is what lets the same surface be both handle and button.
    private fun overlayDragTouchListener(
        windowManager: WindowManager,
        root: View,
        density: Float,
        onTap: () -> Unit,
    ): View.OnTouchListener {
        val slop = (10 * density)
        val tapTimeout = ViewConfiguration.getLongPressTimeout()
        return View.OnTouchListener { _, event ->
            val params = overlayParams ?: return@OnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    dragOrigin = intArrayOf(
                        params.x - event.rawX.toInt(),
                        params.y - event.rawY.toInt(),
                        event.eventTime.toInt(),
                    )
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val origin = dragOrigin ?: return@OnTouchListener true
                    var nx = event.rawX.toInt() + origin[0]
                    var ny = event.rawY.toInt() + origin[1]
                    val size = displaySize(windowManager)
                    val w = if (root.width > 0) root.width else (48 * density).toInt()
                    val h = if (root.height > 0) root.height else (48 * density).toInt()
                    if (size.x > 0) nx = nx.coerceIn(0, (size.x - w).coerceAtLeast(0))
                    if (size.y > 0) ny = ny.coerceIn(0, (size.y - h).coerceAtLeast(0))
                    params.x = nx
                    params.y = ny
                    try {
                        windowManager.updateViewLayout(root, params)
                    } catch (_: Throwable) { }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val origin = dragOrigin
                    dragOrigin = null
                    if (origin != null) {
                        val moved = Math.hypot(
                            (event.rawX.toInt() + origin[0] - params.x).toDouble(),
                            (event.rawY.toInt() + origin[1] - params.y).toDouble(),
                        )
                        val quick = event.eventTime - origin[2].toLong() < tapTimeout
                        if (moved <= slop && quick) onTap()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    dragOrigin = null
                    true
                }
                else -> false
            }
        }
    }

    private var dragOrigin: IntArray? = null

    /// The expanded steering box: simple white, cross · text · mic · green send.
    private fun overlayBoxView(
        windowManager: WindowManager,
        root: View,
        density: Float,
    ): LinearLayout {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val pad = (10 * density).toInt()
            setPadding(pad, (8 * density).toInt(), pad, (8 * density).toInt())
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(0xFFFFFFFF.toInt())
                setStroke((1 * density).toInt(), 0x22000000)
                cornerRadius = 24 * density
            }
            elevation = 8 * density
        }
        // Stop is immediate, including when the text field contains a draft.
        val close = ImageButton(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                (44 * density).toInt(), (44 * density).toInt())
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = null
            contentDescription = "Stop Control"
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            imageTintList = ColorStateList.valueOf(0xFF6E6E6E.toInt())
            setOnClickListener { onOverlayStop() }
        }
        box.addView(close)

        val input = EditText(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                leftMargin = (6 * density).toInt()
                rightMargin = (6 * density).toInt()
            }
            minEms = 7
            maxLines = 1
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_SEND
            hint = "Steer Ovid…"
            setHintTextColor(0xFF9A9A9A.toInt())
            setTextColor(0xFF1A1A1A.toInt())
            background = null
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_SEND ||
                    actionId == EditorInfo.IME_ACTION_DONE
                ) {
                    onOverlaySend(text?.toString().orEmpty())
                    clearFocus()
                    val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.hideSoftInputFromWindow(windowToken, 0)
                    true
                } else {
                    false
                }
            }
            setOnFocusChangeListener { v, hasFocus ->
                val params = overlayParams
                val wm = getSystemService(WINDOW_SERVICE) as? WindowManager
                if (hasFocus) {
                    if (params != null && wm != null && (params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE) != 0) {
                        params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
                        overlayView?.let { wm.updateViewLayout(it, params) }
                    }
                    val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.showSoftInput(v, InputMethodManager.SHOW_IMPLICIT)
                } else {
                    if (params != null && wm != null && (params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE) == 0) {
                        params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        overlayView?.let { wm.updateViewLayout(it, params) }
                    }
                }
            }
        }
        box.addView(input)
        overlayInput = input

        val mic = ImageButton(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                (44 * density).toInt(), (44 * density).toInt())
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = null
            contentDescription = "Dictate"
            setImageResource(android.R.drawable.ic_btn_speak_now)
            imageTintList = ColorStateList.valueOf(0xFF6E6E6E.toInt())
            setOnClickListener { onOverlayMic() }
        }
        box.addView(mic)
        overlayMicButton = mic

        // Green send: only armed while there is text, so an accidental tap can
        // never fire an empty message.
        val send = ImageButton(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                (44 * density).toInt(), (44 * density).toInt()).apply {
                leftMargin = (4 * density).toInt()
            }
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFFE4E4E4.toInt())
            }
            contentDescription = "Send"
            setImageResource(android.R.drawable.ic_menu_send)
            imageTintList = ColorStateList.valueOf(0xFF9A9A9A.toInt())
            isEnabled = false
            setOnClickListener {
                val current = overlayInput?.text?.toString().orEmpty()
                if (current.isBlank()) return@setOnClickListener
                onOverlaySend(current)
                overlayInput?.clearFocus()
                val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
                imm?.hideSoftInputFromWindow(overlayInput?.windowToken, 0)
            }
        }
        box.addView(send)
        overlaySendButton = send

        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                val button = overlaySendButton ?: return
                val armed = !s.isNullOrBlank()
                button.isEnabled = armed
                (button.background as? GradientDrawable)?.setColor(
                    if (armed) 0xFF1FA05F.toInt() else 0xFFE4E4E4.toInt())
                button.imageTintList = ColorStateList.valueOf(
                    if (armed) 0xFFFFFFFF.toInt() else 0xFF9A9A9A.toInt())
            }
        })
        return box
    }

    override fun onServiceConnected() {
        // Bind first: even if the service-info update below throws, the
        // instance must be visible so device calls stop reporting
        // "connecting" instead of wedging until a manual toggle.
        instance = this
        super.onServiceConnected()
        try {
            treeCache.markDirty()
            val info = serviceInfo ?: AccessibilityServiceInfo()
            info.flags = info.flags or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.notificationTimeout = 50
            serviceInfo = info
        } catch (_: Throwable) {
            // A bad service-info update must never kill the bind: the
            // service stays usable with manifest defaults.
        }
    }

    override fun onRebind(intent: Intent?) {
        // A rebind (no fresh onServiceConnected) must also publish the
        // instance, or every device call would report "connecting" forever.
        instance = this
        try {
            treeCache.markDirty()
        } catch (_: Throwable) {}
        super.onRebind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        when (event?.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            -> treeCache.markDirty()
        }
    }

    override fun onInterrupt() { onOverlayStop() }

    override fun onUnbind(intent: Intent?): Boolean {
        onOverlayStop()
        removeOverlayNow()
        resetTree()
        if (instance === this) instance = null
        // Return true so the framework calls onRebind() (which re-publishes
        // `instance`) when the system rebinds without destroying us. The
        // default AccessibilityService.onUnbind() returns false, which left
        // the existing onRebind handler as dead code.
        return true
    }

    override fun onDestroy() {
        onOverlayStop()
        removeOverlayNow()
        resetTree()
        // Drain cancelled capture closures so their finally blocks recycle bitmaps.
        screenshotExecutor.shutdown()
        if (instance === this) instance = null
        super.onDestroy()
    }

    /**
     * Resolves the target root accessibility node for screen reading and interaction.
     *
     * Priority:
     * 1. The active window, when it belongs to a third-party app (driving
     *    other apps — unchanged fast path).
     * 2. The focused APPLICATION window, when the active window is stale or
     *    null: a focused third-party app wins; otherwise our own MainActivity
     *    wins (the user is looking at Ovid itself and asked about its screen).
     * 3. Legacy fallbacks: top-most non-Ovid application window, then any
     *    interactive non-Ovid non-overlay window, then whatever is active.
     *
     * Our floating overlay (TYPE_ACCESSIBILITY_OVERLAY) is never returned:
     * reading it would feed the agent its own input box instead of the
     * screen. Our MainActivity (TYPE_APPLICATION, Ovid package) IS readable.
     */
    /// Root of the on-screen keyboard, if one is showing.
    ///
    /// Deliberately skips Ovid's own overlay window and any IME belonging to this
    /// package, so the agent is never handed its own input box.
    private fun imeRoot(): AccessibilityNodeInfo? {
        return try {
            val list = windows ?: return null
            val myPkg = packageName
            for (w in list) {
                if (w.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
                val r = try { w.root } catch (_: Throwable) { null } ?: continue
                if (r.packageName?.toString() == myPkg) {
                    r.recycle()
                    continue
                }
                return r
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    /// The foreground package WITHOUT walking the tree.
    ///
    /// Every device action used to pay for a full `readScreen` first, purely to
    /// confirm which app is in front (the sensitive-target guard). On an animated
    /// screen the node cache is dirty on every content-change event, so that
    /// verification was a 300-node binder walk on the main thread before each
    /// tap — the single biggest avoidable cost in Control mode. Reading one
    /// node's package is enough for the guard.
    internal fun foregroundPackage(): String? {
        return try {
            val active = rootInActiveWindow ?: return null
            try {
                active.packageName?.toString()
            } finally {
                active.recycle()
            }
        } catch (_: Throwable) {
            null
        }
    }

    internal fun findTargetRootNode(): AccessibilityNodeInfo? {
        var active = try {
            rootInActiveWindow
        } catch (_: Throwable) {
            null
        }
        val myPkg = packageName
        // Fast path unchanged: driving a third-party app.
        if (active != null && active.packageName?.toString() != myPkg) {
            return active
        }

        // Active window is null, stale, or belongs to Ovid (overlay/app);
        // resolve through the focused APPLICATION window.
        try {
            val windowList = windows
            if (windowList != null && windowList.isNotEmpty()) {
                val activeWindowId = try {
                    active?.windowId
                } catch (_: Throwable) {
                    null
                }
                // Our own MainActivity window, kept aside: returned only when
                // no third-party app window is focused. Never the overlay
                // (overlay windows are TYPE_ACCESSIBILITY_OVERLAY, filtered
                // by the type check below).
                var ownAppRoot: AccessibilityNodeInfo? = null
                for (w in windowList) {
                    if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                    val focusedOrActive =
                        w.isFocused || (activeWindowId != null && w.id == activeWindowId)
                    if (!focusedOrActive) continue
                    val wRoot = w.root ?: continue
                    val pkg = wRoot.packageName?.toString().orEmpty()
                    if (pkg.isEmpty()) {
                        wRoot.recycle()
                        continue
                    }
                    if (pkg != myPkg) {
                        active?.recycle()
                        return wRoot
                    }
                    if (ownAppRoot == null) {
                        ownAppRoot = wRoot
                    } else {
                        wRoot.recycle()
                    }
                }
                if (ownAppRoot != null) {
                    active?.recycle()
                    return ownAppRoot
                }
                // First pass: find the focused or active APPLICATION window that is not Ovid
                for (w in windowList) {
                    if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                    val wRoot = w.root ?: continue
                    val pkg = wRoot.packageName?.toString().orEmpty()
                    if (pkg.isNotEmpty() && pkg != myPkg) {
                        active?.recycle()
                        return wRoot
                    }
                    wRoot.recycle()
                }
                // Second pass: any interactive window that is not Ovid and not TYPE_ACCESSIBILITY_OVERLAY
                for (w in windowList) {
                    if (w.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) continue
                    val wRoot = w.root ?: continue
                    val pkg = wRoot.packageName?.toString().orEmpty()
                    if (pkg.isNotEmpty() && pkg != myPkg) {
                        active?.recycle()
                        return wRoot
                    }
                    wRoot.recycle()
                }
            }
        } catch (_: Throwable) {}

        return active
    }

    @Synchronized
    fun readScreen(forceFull: Boolean): Map<String, Any?> {
        val readGeneration = treeCache.beginRead(forceFull)
        if (readGeneration == null) {
            return readResult(
                status = "unchanged",
                packageName = treeCache.packageName,
                windowId = treeCache.windowId,
                delta = NodeDelta(false, emptyList(), emptyList(), emptyList()),
            )
        }

        val root = try {
            findTargetRootNode()
        } catch (error: Throwable) {
            treeCache.abandon(readGeneration)
            return readError(error)
        }
        if (root == null) {
            val unavailable = treeCache.unavailable(readGeneration)
            return readUnavailable(
                "The active window is temporarily unavailable. Retry device_read.",
                unavailable,
            )
        }

        val rows = linkedMapOf<String, Map<String, Any?>>()
        val newNodes = mutableMapOf<Int, AccessibilityNodeInfo>()
        val newHandles = mutableMapOf<String, Int>()
        var candidateNextHandle = treeCache.nextHandle
        // Node budget for this walk. Raised only for the app tree, then lowered
        // before the keyboard so 40-80 key nodes cannot crowd out the screen the
        // agent is actually driving.
        var softCap = MAX_NODES
        val packageName = root.packageName?.toString().orEmpty()
        val windowId = root.windowId

        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > MAX_DEPTH || rows.size >= softCap) return

            val bounds = Rect()
            node.getBoundsInScreen(bounds)
            if (node.isVisibleToUser && bounds.width() > 0 && bounds.height() > 0) {
                val viewId = node.viewIdResourceName.orEmpty()
                val fullClassName = node.className?.toString().orEmpty()
                val text = node.text?.toString().orEmpty()
                val description = node.contentDescription?.toString().orEmpty()
                val boundsList = listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)
                val stableKey = stableNodeKey(
                    viewId = viewId,
                    className = fullClassName,
                    text = text,
                    description = description,
                    bounds = boundsList,
                )
                val rowKey = uniqueRowKey(stableKey, rows)
                run {
                    val allocation = allocateStableHandle(
                        treeCache.handlesByStableKey,
                        rowKey,
                        candidateNextHandle,
                    )
                    candidateNextHandle = allocation.nextHandle
                    val row = linkedMapOf<String, Any?>(
                        "handle" to allocation.handle,
                        "class" to fullClassName.substringAfterLast('.'),
                        "text" to text,
                        "description" to description,
                        "viewId" to viewId,
                        "bounds" to boundsList,
                        "clickable" to node.isClickable,
                        "editable" to node.isEditable,
                        "scrollable" to node.isScrollable,
                        "password" to node.isPassword,
                        "checked" to node.isChecked,
                        "focused" to node.isFocused,
                    )
                    rows[rowKey] = row
                    newHandles[rowKey] = allocation.handle
                    newNodes[allocation.handle] = AccessibilityNodeInfo.obtain(node)
                }
            }

            if (depth == MAX_DEPTH || rows.size >= softCap) return
            for (index in 0 until node.childCount) {
                if (rows.size >= softCap) break
                val child = node.getChild(index) ?: continue
                try {
                    visit(child, depth + 1)
                } finally {
                    child.recycle()
                }
            }
        }

        return try {
            visit(root, 0)
            // THE SOFT KEYBOARD (2026-09-25, owner report: "the agent cannot see
            // the keyboard"). It lives in a SEPARATE window of type
            // TYPE_INPUT_METHOD owned by another process, so it is never part of
            // the app window's node tree — and findTargetRootNode() returns a
            // single root, so the keys, the candidate bar and the action-key
            // label ("Search" vs "Enter" vs "Go") were all invisible. Coordinate
            // taps into the keyboard were therefore blind guesses.
            //
            // Budget-capped on purpose: keyboards expose 40-80 key nodes, and
            // letting them crowd out the app's own tree would trade one blindness
            // for another. The app tree is visited first, so it keeps priority.
            val ime = imeRoot()
            if (ime != null) {
                try {
                    softCap = (rows.size + IME_NODE_BUDGET).coerceAtMost(MAX_NODES)
                    visit(ime, 0)
                } finally {
                    softCap = MAX_NODES
                    ime.recycle()
                }
            }
            val delta = treeCache.commit(
                readGeneration = readGeneration,
                packageName = packageName,
                windowId = windowId,
                rows = rows,
                nodes = newNodes,
                handles = newHandles,
                newNextHandle = candidateNextHandle,
                forceFull = forceFull,
            )
            readResult("ok", packageName, windowId, delta)
        } catch (error: Throwable) {
            newNodes.values.forEach { it.recycle() }
            treeCache.abandon(readGeneration)
            readError(error)
        } finally {
            root.recycle()
        }
    }

    /// Dispatch one gesture and block until the platform reports it COMPLETED,
    /// CANCELLED, or the bounded wait expires (audit 2026-09-25).
    ///
    /// THREADING — read before changing. This MUST be called from a background
    /// thread, never the platform (main) thread. `dispatchGesture` is posted to
    /// [mainHandler] and its `GestureResultCallback` is delivered on that same
    /// main thread; the caller here then blocks on [CountDownLatch.await]. If
    /// this ran ON the main thread, the await would freeze the looper that has
    /// to deliver the callback, so the latch could only ever escape via the
    /// timeout — a self-deadlock plus an ANR. MainActivity therefore routes
    /// every gesture through a single-thread executor, which both keeps the wait
    /// off main and serializes gestures. [dispatch] is the primitive's actual
    /// `service.dispatchGesture(gesture, callback, handler)` call, kept at the
    /// call site so each gesture remains exactly one dispatch.
    ///
    /// @param notAcceptedMessage the honest failure text for the caller's
    ///   gesture when the platform refuses the dispatch outright.
    @TargetApi(Build.VERSION_CODES.N)
    internal fun runGesture(
        notAcceptedMessage: String,
        dispatch: (AccessibilityService.GestureResultCallback, Handler) -> Boolean,
    ): DeviceActionResult {
        val ticket = deviceActions.current.get()
        if (ticket != null && !ticket.isCurrent()) {
            return DeviceActionResult(false, "CANCELLED", "Control stopped.")
        }
        // Serialize: a second stroke dispatched while the previous is still
        // animating is rejected by the platform (dispatchGesture returns false),
        // which surfaced as a bogus "did not accept" error for a valid gesture.
        // Wait for the in-flight one instead — bounded, so a wedged gesture can
        // never starve the next forever.
        var acquired = false
        try {
            acquired = gestureLock.tryLock(GESTURE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        if (!acquired) {
            return DeviceActionResult(
                false,
                "GESTURE_BUSY",
                "Another gesture was still running; this one was not dispatched. Retry.",
            )
        }
        try {
            val latch = CountDownLatch(1)
            ticket?.whenCancelled { latch.countDown() }
            val outcome = AtomicReference(GestureOutcome.TIMEOUT)
            val accepted = AtomicBoolean(false)
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    outcome.set(GestureOutcome.COMPLETED)
                    latch.countDown()
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    outcome.set(GestureOutcome.CANCELLED)
                    latch.countDown()
                }
            }
            // Post the dispatch to the main thread (where it belongs) and let
            // this background thread wait. A refused dispatch never fires the
            // callback, so release the latch there rather than burn the timeout.
            mainHandler.post {
                if (ticket != null && !ticket.isCurrent()) {
                    latch.countDown()
                    return@post
                }
                val ok = try {
                    dispatch(callback, mainHandler)
                } catch (_: Throwable) {
                    false
                }
                accepted.set(ok)
                if (!ok) latch.countDown()
            }
            val signalled = latch.await(GESTURE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            if (ticket != null && !ticket.isCurrent()) {
                return DeviceActionResult(false, "CANCELLED", "Control stopped.")
            }
            if (!signalled) {
                return DeviceActionResult(
                    false,
                    "GESTURE_TIMEOUT",
                    "The gesture did not report completion within " +
                        "${GESTURE_TIMEOUT_MS}ms; the screen may not have settled.",
                )
            }
            if (!accepted.get()) {
                return DeviceActionResult(false, message = notAcceptedMessage)
            }
            return when (outcome.get()) {
                GestureOutcome.COMPLETED -> DeviceActionResult(true)
                GestureOutcome.CANCELLED -> DeviceActionResult(
                    false,
                    message = "Android cancelled the gesture before it completed.",
                )
                GestureOutcome.TIMEOUT -> DeviceActionResult(
                    false,
                    "GESTURE_TIMEOUT",
                    "The gesture did not report completion within " +
                        "${GESTURE_TIMEOUT_MS}ms; the screen may not have settled.",
                )
            }
        } finally {
            gestureLock.unlock()
        }
    }

    internal fun tap(handle: Int?, x: Float?, y: Float?): DeviceActionResult {
        if (handle != null) return tapNode(handle)
        if (x == null || y == null || !x.isFinite() || !y.isFinite()) {
            return DeviceActionResult(false, "BAD_ARGS", "Tap requires a node handle or finite x/y coordinates.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Gesture taps require Android 7.0 or newer.")
        }
        // Coordinate stroke: dispatched and awaited off the service monitor (see
        // runGesture) so the completion wait can never block readScreen.
        return Api24Actions.tap(this, x, y)
    }

    /// Node-handle tap: ACTION_CLICK on the node or the nearest clickable
    /// ancestor. Fast and reads the shared tree cache, so it keeps the service
    /// monitor — and is deliberately separate from the coordinate path above,
    /// which must never hold the monitor while it blocks (audit 2026-09-25).
    @Synchronized
    private fun tapNode(handle: Int): DeviceActionResult {
        val node = treeCache.nodesByHandle[handle]
            ?: return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
        if (!node.refresh()) {
            return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
        }
        if (node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
            return DeviceActionResult(true)
        }
        // Ancestor-click fallback: the tapped row is often a non-clickable
        // container, so walk up to 3 ancestors attempting ACTION_CLICK on
        // clickable ones.
        var ancestor: AccessibilityNodeInfo? = try {
            node.parent
        } catch (_: Throwable) {
            null
        }
        var level = 0
        while (ancestor != null && level < 3) {
            level++
            val current = ancestor
            var clickedName: String? = null
            try {
                if (current.isClickable &&
                    current.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                ) {
                    clickedName = current.className?.toString()?.substringAfterLast('.') ?: "node"
                }
            } finally {
                ancestor = try {
                    current.parent
                } catch (_: Throwable) {
                    null
                }
                try {
                    current.recycle()
                } catch (_: Throwable) {
                    // The framework owns the node; keep walking.
                }
            }
            if (clickedName != null) {
                // Success return: the finally above already prefetched
                // the next ancestor into `ancestor`, which no later walk
                // consumes — recycle it here so one node per success
                // does not leak.
                try {
                    ancestor?.recycle()
                } catch (_: Throwable) {
                    // The framework owns the node; the click landed.
                }
                ancestor = null
                return DeviceActionResult(true, value = "Clicked ancestor $level ($clickedName).")
            }
        }
        return if (level > 0) {
            DeviceActionResult(false, message = "Node $handle did not accept a click action; all $level ancestor(s) refused.")
        } else {
            DeviceActionResult(false, message = "Node $handle did not accept a click action and has no clickable ancestor.")
        }
    }

    internal fun clampLongPressDuration(durationMs: Long?): Long =
        (durationMs ?: 600L).coerceIn(200L, 3000L)

    internal fun longPress(
        handle: Int?,
        x: Float?,
        y: Float?,
        durationMs: Long?,
    ): DeviceActionResult {
        if (handle != null) return longPressNode(handle)
        if (x == null || y == null || !x.isFinite() || !y.isFinite()) {
            return DeviceActionResult(false, "BAD_ARGS", "Long-press requires a node handle or finite x/y coordinates.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Long-press gestures require Android 7.0 or newer.")
        }
        val duration = clampLongPressDuration(durationMs)
        return Api24Actions.longPress(this, x, y, duration)
    }

    /// Node-handle long-press via ACTION_LONG_CLICK. Kept under the service
    /// monitor and separate from the coordinate stroke, which blocks on
    /// completion and must not hold it (audit 2026-09-25).
    @Synchronized
    private fun longPressNode(handle: Int): DeviceActionResult {
        val node = treeCache.nodesByHandle[handle]
            ?: return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
        if (!node.refresh()) {
            return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
        }
        return if (node.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)) {
            DeviceActionResult(true)
        } else {
            DeviceActionResult(false, message = "Node $handle did not accept a long-click action.")
        }
    }

    @Synchronized
    internal fun scrollNode(handle: Int?, direction: String?): DeviceActionResult {
        if (handle == null) {
            return DeviceActionResult(false, "BAD_ARGS", "Scroll requires a node handle.")
        }
        val requested = direction?.lowercase()
            ?: return DeviceActionResult(false, "BAD_ARGS", "Scroll requires a direction: forward|backward|up|down|left|right.")
        if (requested !in setOf("forward", "backward", "up", "down", "left", "right")) {
            return DeviceActionResult(false, "BAD_ARGS", "Unknown scroll direction: $direction. Use forward|backward|up|down|left|right.")
        }
        val node = treeCache.nodesByHandle[handle]
            ?: return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
        if (!node.refresh()) {
            return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
        }
        if (!node.isScrollable) {
            return DeviceActionResult(false, "NOT_SCROLLABLE", "Node $handle is not scrollable.")
        }
        // Directional scroll actions (up/down/left/right) exist from API 23
        // (M). Below that floor, fall back to forward/backward and name the
        // fallback in the result.
        val resolvedAction: Int
        var fallback: String? = null
        when (requested) {
            "forward" -> resolvedAction = AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            "backward" -> resolvedAction = AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            else -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                    fallback = if (requested == "up" || requested == "left") "backward" else "forward"
                    resolvedAction = if (fallback == "backward") {
                        AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                    } else {
                        AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                    }
                } else {
                    resolvedAction = when (requested) {
                        "up" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.id
                        "down" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.id
                        "left" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id
                        else -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id
                    }
                }
            }
        }
        return if (node.performAction(resolvedAction)) {
            val usedFallback = fallback
            if (usedFallback != null) {
                DeviceActionResult(true, value = "Scrolled $requested via $usedFallback fallback (below API 23).")
            } else {
                DeviceActionResult(true)
            }
        } else {
            DeviceActionResult(false, message = "Node $handle did not accept a scroll action.")
        }
    }

    @Synchronized
    internal fun type(handle: Int?, text: String, submit: Boolean): DeviceActionResult {
        var root: AccessibilityNodeInfo? = null
        var focusedNode: AccessibilityNodeInfo? = null
        val node = if (handle != null) {
            treeCache.nodesByHandle[handle]
                ?: return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
        } else {
            root = findTargetRootNode()
                ?: return DeviceActionResult(false, "NO_FOCUS", "No active window has a focused input.")
            focusedNode = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            focusedNode
                ?: return DeviceActionResult(false, "NO_FOCUS", "No focused input is available.").also {
                    root.recycle()
                }
        }

        try {
            if (handle != null && !node.refresh()) {
                return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid. Re-read the screen with device_read and retry.")
            }
            passwordTypingRefusal(node.isPassword)?.let { return it }
            if (!node.isEditable) {
                return DeviceActionResult(false, "NOT_EDITABLE", "The selected node is not editable.")
            }
            val arguments = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                return DeviceActionResult(false, message = "The selected input did not accept text.")
            }

            var submitted = false
            var submitMessage = ""
            if (submit) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    submitted = Api30Actions.submit(node)
                    if (!submitted) submitMessage = "Text was entered, but the input did not accept IME Enter."
                } else {
                    submitMessage = "Text was entered, but IME Enter requires Android 11 or newer."
                }
            }
            return DeviceActionResult(
                ok = true,
                value = mapOf(
                    "typed" to true,
                    "submitted" to submitted,
                    "message" to submitMessage,
                ),
            )
        } finally {
            focusedNode?.recycle()
            root?.recycle()
        }
    }

    internal fun swipe(
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
    ): DeviceActionResult {
        if (!listOf(fromX, fromY, toX, toY).all { it.isFinite() } || durationMs <= 0) {
            return DeviceActionResult(false, "BAD_ARGS", "Swipe coordinates must be finite and duration must be positive.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Swipe gestures require Android 7.0 or newer.")
        }
        return Api24Actions.swipe(this, fromX, fromY, toX, toY, durationMs)
    }

    /// Double / triple tap at a point, or a multi-click on a node's centre.
    ///
    /// Sent as ONE gesture with N timed strokes: two separate dispatches arrive
    /// as two unrelated touches, so `onDoubleClick` handlers, map zoom and
    /// text-selection handles all ignored them.
    internal fun multiTap(
        x: Float,
        y: Float,
        count: Int,
        intervalMs: Long,
    ): DeviceActionResult {
        if (!x.isFinite() || !y.isFinite()) {
            return DeviceActionResult(false, "BAD_ARGS", "Multi-tap coordinates must be finite.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Multi-tap gestures require Android 7.0 or newer.")
        }
        return Api24Actions.multiTap(this, x, y, count, intervalMs)
    }

    /// Long-press-then-move drag: icons, selection handles, reorder rows,
    /// sliders. `holdMs` presses and holds at the origin before moving, which is
    /// what makes a drag start rather than a fling.
    internal fun drag(
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        holdMs: Long,
        durationMs: Long,
    ): DeviceActionResult {
        if (!listOf(fromX, fromY, toX, toY).all { it.isFinite() } || durationMs <= 0) {
            return DeviceActionResult(false, "BAD_ARGS", "Drag coordinates must be finite and duration must be positive.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Drag gestures require Android 7.0 or newer.")
        }
        return Api24Actions.drag(this, fromX, fromY, toX, toY, holdMs, durationMs)
    }

    /// Two-finger pinch (zoom out) or spread (zoom in) about a centre point.
    internal fun pinch(
        centerX: Float,
        centerY: Float,
        fromRadius: Float,
        toRadius: Float,
        durationMs: Long,
    ): DeviceActionResult {
        if (!listOf(centerX, centerY, fromRadius, toRadius).all { it.isFinite() } ||
            fromRadius <= 0f || toRadius <= 0f || durationMs <= 0
        ) {
            return DeviceActionResult(false, "BAD_ARGS", "Pinch needs a finite centre and positive radii/duration.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Pinch gestures require Android 7.0 or newer.")
        }
        return Api24Actions.pinch(this, centerX, centerY, fromRadius, toRadius, durationMs)
    }

    /// Two-finger swipe in one direction — the gesture a scrollable list, web
    /// page or launcher expects where one finger means something else (back
    /// swipe, carousel page, drawer).
    internal fun twoFingerSwipe(
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
        separation: Float,
    ): DeviceActionResult {
        if (!listOf(fromX, fromY, toX, toY).all { it.isFinite() } || durationMs <= 0) {
            return DeviceActionResult(false, "BAD_ARGS", "Two-finger swipe coordinates must be finite and duration positive.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Two-finger swipes require Android 7.0 or newer.")
        }
        return Api24Actions.twoFingerSwipe(this, fromX, fromY, toX, toY, durationMs, separation)
    }

    @Synchronized
    internal fun pressKey(key: String): DeviceActionResult {
        // Closed vocabulary: Android denies INJECT_EVENTS to apps, so only
        // keys with a real accessibility/audio mechanism are supported.
        return when (key) {
            "enter" -> pressEnterOnFocusedInput()
            "volume_up", "volume_down", "volume_mute" -> adjustVolume(key)
            "media_play_pause", "media_next", "media_previous" -> dispatchMediaKey(key)
            else -> DeviceActionResult(
                false,
                "BAD_KEY",
                "Unknown key: $key. Android does not allow apps to inject arbitrary keycodes; " +
                    "use enter|volume_up|volume_down|volume_mute|media_play_pause|media_next|media_previous.",
            )
        }
    }

    private fun pressEnterOnFocusedInput(): DeviceActionResult {
        val root = findTargetRootNode()
            ?: return DeviceActionResult(false, "NO_FOCUS", "No active window has a focused input.")
        try {
            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: return DeviceActionResult(false, "NO_FOCUS", "No focused input is available.")
            try {
                if (!focused.refresh()) {
                    return DeviceActionResult(false, "INVALID_NODE", "The focused input is no longer valid. Re-read the screen with device_read and retry.")
                }
                if (!focused.isEditable) {
                    return DeviceActionResult(false, "NOT_EDITABLE", "The focused node is not editable.")
                }
                // Shared IME-enter path with device_type submit.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    return if (Api30Actions.submit(focused)) {
                        DeviceActionResult(true)
                    } else {
                        DeviceActionResult(false, message = "The focused input did not accept IME Enter.")
                    }
                }
                return DeviceActionResult(false, "UNSUPPORTED", "IME Enter requires Android 11 or newer.")
            } finally {
                focused.recycle()
            }
        } finally {
            root.recycle()
        }
    }

    private fun adjustVolume(key: String): DeviceActionResult {
        val audio = getSystemService(AUDIO_SERVICE) as? AudioManager
            ?: return DeviceActionResult(false, message = "Audio service is unavailable.")
        return try {
            if (key == "volume_mute" && Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                @Suppress("DEPRECATION")
                audio.setStreamMute(AudioManager.STREAM_MUSIC, true)
            } else {
                val direction = when (key) {
                    "volume_up" -> AudioManager.ADJUST_RAISE
                    "volume_down" -> AudioManager.ADJUST_LOWER
                    else -> AudioManager.ADJUST_MUTE
                }
                audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)
            }
            DeviceActionResult(true)
        } catch (error: SecurityException) {
            DeviceActionResult(false, message = "Android refused the volume key: ${error.message}")
        }
    }

    private fun dispatchMediaKey(key: String): DeviceActionResult {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            return DeviceActionResult(false, "UNSUPPORTED", "Media keys require Android 5.0 or newer.")
        }
        val keyCode = when (key) {
            "media_play_pause" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "media_next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            else -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
        }
        val audio = getSystemService(AUDIO_SERVICE) as? AudioManager
            ?: return DeviceActionResult(false, message = "Audio service is unavailable.")
        return try {
            audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
            DeviceActionResult(true)
        } catch (error: SecurityException) {
            DeviceActionResult(false, message = "Android refused the media key: ${error.message}")
        }
    }

    @Synchronized
    internal fun systemNav(action: String): DeviceActionResult {
        val globalAction = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            else -> return DeviceActionResult(false, "BAD_ARGS", "Unknown system navigation action: $action")
        }
        return if (performGlobalAction(globalAction)) {
            DeviceActionResult(true)
        } else {
            DeviceActionResult(false, message = "Android did not accept the $action action.")
        }
    }

    fun takeScreen(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error("UNSUPPORTED", "Screenshots require Android 11 or newer.", null)
            return
        }
        Api30Actions.takeScreenshot(this, result, screenshotExecutor)
    }

    private fun readResult(
        status: String,
        packageName: String,
        windowId: Int,
        delta: NodeDelta,
    ): Map<String, Any?> = linkedMapOf(
        "status" to status,
        "package" to packageName,
        "window" to windowId,
        "full" to delta.full,
        "added" to delta.added,
        "changed" to delta.changed,
        "removed" to delta.removed,
    )

    private fun readError(error: Throwable): Map<String, Any?> = linkedMapOf(
        "status" to "error",
        "message" to (error.message ?: error.javaClass.simpleName),
        "package" to treeCache.packageName,
        "window" to treeCache.windowId,
        "full" to false,
        "added" to emptyList<Map<String, Any?>>(),
        "changed" to emptyList<Map<String, Any?>>(),
        "removed" to emptyList<Int>(),
    )

    private fun readUnavailable(
        message: String,
        unavailable: UnavailableTreeRead,
    ): Map<String, Any?> = linkedMapOf(
        "status" to "unavailable",
        "message" to message,
        "package" to unavailable.packageName,
        "window" to unavailable.windowId,
        "full" to false,
        "added" to emptyList<Map<String, Any?>>(),
        "changed" to emptyList<Map<String, Any?>>(),
        "removed" to emptyList<Int>(),
    )

    private fun uniqueRowKey(
        stableKey: String,
        rows: Map<String, Map<String, Any?>>,
    ): String {
        if (stableKey !in rows) return stableKey
        var occurrence = 2
        while ("$stableKey#$occurrence" in rows) occurrence++
        return "$stableKey#$occurrence"
    }

    @Synchronized
    private fun resetTree() {
        treeCache.reset()
    }
}

@TargetApi(Build.VERSION_CODES.N)
private object Api24Actions {
    fun tap(service: OvidAccessibilityService, x: Float, y: Float): DeviceActionResult {
        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
            .build()
        return service.runGesture("Android did not accept the tap gesture.") { callback, handler ->
            service.dispatchGesture(gesture, callback, handler)
        }
    }

    fun swipe(
        service: OvidAccessibilityService,
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
    ): DeviceActionResult {
        val path = Path().apply {
            moveTo(fromX, fromY)
            lineTo(toX, toY)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        return service.runGesture("Android did not accept the swipe gesture.") { callback, handler ->
            service.dispatchGesture(gesture, callback, handler)
        }
    }

    fun longPress(
        service: OvidAccessibilityService,
        x: Float,
        y: Float,
        durationMs: Long,
    ): DeviceActionResult {
        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        return service.runGesture("Android did not accept the long-press gesture.") { callback, handler ->
            service.dispatchGesture(gesture, callback, handler)
        }
    }

    /// Double / triple tap: N short strokes at the SAME point, spaced inside the
    /// platform double-tap timeout so the target app recognises the multi-click
    /// rather than N independent taps.
    ///
    /// A plain `tap` twice in a row never worked: two separate
    /// `dispatchGesture` calls arrive as two unrelated touches, so galleries,
    /// maps, text-selection handles and every `onDoubleClick` handler ignored
    /// them.
    fun multiTap(
        service: OvidAccessibilityService,
        x: Float,
        y: Float,
        count: Int,
        intervalMs: Long,
    ): DeviceActionResult {
        val times = count.coerceIn(2, 4)
        val gap = intervalMs.coerceIn(40L, 300L)
        val path = Path().apply { moveTo(x, y) }
        val builder = GestureDescription.Builder()
        for (i in 0 until times) {
            builder.addStroke(
                GestureDescription.StrokeDescription(path, i * gap, 45L),
            )
        }
        return service.runGesture("Android did not accept the multi-tap gesture.") { callback, handler ->
            service.dispatchGesture(builder.build(), callback, handler)
        }
    }

    /// Drag: optional hold at the origin (so long-press-then-drag works, which
    /// is how icons, selection handles and reorder rows are picked up), then a
    /// move to the destination.
    ///
    /// `continueStroke` is API 26+; below that the hold and the move are sent as
    /// two parallel-timed strokes in one gesture, which is close enough for a
    /// drag and still a single touch sequence.
    fun drag(
        service: OvidAccessibilityService,
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        holdMs: Long,
        durationMs: Long,
    ): DeviceActionResult {
        val move = Path().apply {
            moveTo(fromX, fromY)
            lineTo(toX, toY)
        }
        val builder = GestureDescription.Builder()
        val hold = holdMs.coerceAtLeast(0L)
        if (hold > 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val holdPath = Path().apply { moveTo(fromX, fromY) }
            val first = GestureDescription.StrokeDescription(holdPath, 0, hold, true)
            builder.addStroke(first)
            builder.addStroke(first.continueStroke(move, 0, durationMs, false))
        } else if (hold > 0) {
            val holdPath = Path().apply { moveTo(fromX, fromY) }
            builder.addStroke(GestureDescription.StrokeDescription(holdPath, 0, hold))
            builder.addStroke(
                GestureDescription.StrokeDescription(move, hold, durationMs),
            )
        } else {
            builder.addStroke(GestureDescription.StrokeDescription(move, 0, durationMs))
        }
        return service.runGesture("Android did not accept the drag gesture.") { callback, handler ->
            service.dispatchGesture(builder.build(), callback, handler)
        }
    }

    /// Pinch / spread: two fingers moving symmetrically about a centre. Used for
    /// map zoom, image zoom and any two-finger scaler.
    fun pinch(
        service: OvidAccessibilityService,
        centerX: Float,
        centerY: Float,
        fromRadius: Float,
        toRadius: Float,
        durationMs: Long,
    ): DeviceActionResult {
        val a = Path().apply {
            moveTo(centerX - fromRadius, centerY)
            lineTo(centerX - toRadius, centerY)
        }
        val b = Path().apply {
            moveTo(centerX + fromRadius, centerY)
            lineTo(centerX + toRadius, centerY)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(a, 0, durationMs))
            .addStroke(GestureDescription.StrokeDescription(b, 0, durationMs))
            .build()
        return service.runGesture("Android did not accept the pinch gesture.") { callback, handler ->
            service.dispatchGesture(gesture, callback, handler)
        }
    }

    /// Two-finger swipe in the same direction: the gesture scrollable lists,
    /// web pages and some launchers require where a one-finger swipe is taken as
    /// something else (a back swipe, a carousel page, a drawer).
    fun twoFingerSwipe(
        service: OvidAccessibilityService,
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
        separation: Float,
    ): DeviceActionResult {
        val half = separation / 2f
        val a = Path().apply {
            moveTo(fromX - half, fromY)
            lineTo(toX - half, toY)
        }
        val b = Path().apply {
            moveTo(fromX + half, fromY)
            lineTo(toX + half, toY)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(a, 0, durationMs))
            .addStroke(GestureDescription.StrokeDescription(b, 0, durationMs))
            .build()
        return service.runGesture("Android did not accept the two-finger swipe.") { callback, handler ->
            service.dispatchGesture(gesture, callback, handler)
        }
    }
}

@TargetApi(Build.VERSION_CODES.R)
private object Api30Actions {
    fun submit(node: AccessibilityNodeInfo): Boolean =
        node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)

    fun takeScreenshot(
        service: OvidAccessibilityService,
        result: MethodChannel.Result,
        screenshotExecutor: Executor,
    ) {
        try {
            service.takeScreenshot(
                Display.DEFAULT_DISPLAY,
                service.mainExecutor,
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(screenshot: AccessibilityService.ScreenshotResult) {
                        val buffer = screenshot.hardwareBuffer
                        if ((result as? CancelableDeviceResult)?.ticket?.isCurrent() == false) {
                            buffer.close()
                            return
                        }
                        var hardwareBitmap: Bitmap? = null
                        var writableBitmap: Bitmap? = null
                        try {
                            hardwareBitmap = Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace)
                                ?: throw IllegalStateException("Screenshot bitmap was unavailable")
                            writableBitmap = hardwareBitmap.copy(Bitmap.Config.ARGB_8888, false)
                                ?: throw IllegalStateException("Screenshot bitmap could not be copied")
                        } catch (error: Throwable) {
                            postScreenshotError(service, result, error)
                        } finally {
                            hardwareBitmap?.recycle()
                            buffer.close()
                        }

                        val bitmap = writableBitmap ?: return
                        try {
                            screenshotExecutor.execute {
                                try {
                                    if ((result as? CancelableDeviceResult)?.ticket?.isCurrent() == false) {
                                        return@execute
                                    }
                                    val directory = File(service.cacheDir, "device-captures")
                                    if (!directory.exists() && !directory.mkdirs()) {
                                        throw IllegalStateException("Could not create screenshot cache")
                                    }
                                    val file = File(directory, "screen-${System.currentTimeMillis()}.png")
                                    FileOutputStream(file).use { output ->
                                        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                                            throw IllegalStateException("Could not encode screenshot")
                                        }
                                    }
                                    service.mainExecutor.execute { result.success(file.absolutePath) }
                                } catch (error: Throwable) {
                                    postScreenshotError(service, result, error)
                                } finally {
                                    bitmap.recycle()
                                }
                            }
                        } catch (error: Throwable) {
                            bitmap.recycle()
                            postScreenshotError(service, result, error)
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        // TakeScreenshotCallback defines only INTERNAL_ERROR
                        // and INVALID_DISPLAY; anything else is future-proofed
                        // through the else branch rather than a named constant
                        // that may not exist on this compile SDK.
                        val reason = when (errorCode) {
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_INVALID_DISPLAY ->
                                "invalid display"
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERNAL_ERROR ->
                                "internal error"
                            else -> "error code $errorCode"
                        }
                        result.error(
                            "SCREENSHOT_FAILED",
                            "Android screenshot failed: $reason.",
                            errorCode,
                        )
                    }
                },
            )
        } catch (error: Throwable) {
            result.error(
                "SCREENSHOT_FAILED",
                error.message ?: "Screenshot could not be started.",
                null,
            )
        }
    }

    private fun postScreenshotError(
        service: OvidAccessibilityService,
        result: MethodChannel.Result,
        error: Throwable,
    ) {
        service.mainExecutor.execute {
            result.error(
                "SCREENSHOT_FAILED",
                error.message ?: "Screenshot could not be saved.",
                null,
            )
        }
    }
}
