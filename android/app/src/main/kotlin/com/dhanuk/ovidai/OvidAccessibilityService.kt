package com.dhanuk.ovidai

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.animation.Animator
import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.annotation.TargetApi
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

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

        private const val MAX_NODES = 300
        private const val MAX_DEPTH = 30

        /// Native→Dart bridge for overlay events. Set by MainActivity, which
        /// owns the FlutterEngine: ("deviceOverlayText", text) on send,
        /// ("deviceOverlayStop", null) on X with an empty field.
        var overlayEventListener: ((method: String, argument: String?) -> Unit)? = null
    }

    private val treeCache = TreeReadCache<AccessibilityNodeInfo> { it.recycle() }
    private val screenshotExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ovid-device-screenshot").apply { isDaemon = true }
    }

    // ── Floating control overlay (spec §5.1) ──────────────────────────
    // TYPE_ACCESSIBILITY_OVERLAY: creatable from an accessibility service
    // with no manifest permission, alive exactly while the service is bound.
    // Hidden removes the window outright (no invisible touch target).
    private var overlayView: View? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var overlayInput: EditText? = null
    private var overlayActionButton: ImageButton? = null
    private var overlayMicButton: ImageButton? = null
    private var overlayLiveDot: View? = null
    private var overlayLiveAnimator: ValueAnimator? = null
    private var overlayActionPulse: Animator? = null

    @Synchronized
    internal fun showOverlay(): DeviceActionResult {
        if (overlayView != null) return DeviceActionResult(true)
        val windowManager = getSystemService(WINDOW_SERVICE) as? WindowManager
            ?: return DeviceActionResult(false, "UNAVAILABLE", "Window manager is unavailable.")
        return try {
            val density = resources.displayMetrics.density
            val container = overlayContainer(windowManager, density)
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                x = (24 * density).toInt()
                y = (160 * density).toInt()
            }
            windowManager.addView(container, params)
            overlayView = container
            overlayParams = params
            DeviceActionResult(true)
        } catch (error: WindowManager.BadTokenException) {
            DeviceActionResult(false, "UNAVAILABLE", "Overlay window was refused: " + error.message)
        } catch (error: Throwable) {
        overlayView = null
        overlayParams = null
        overlayInput = null
        overlayActionButton = null
        overlayMicButton = null
        overlayLiveDot = null
            DeviceActionResult(false, "UNAVAILABLE", "Overlay could not be shown: " + error.message)
        }
    }

    @Synchronized
    internal fun hideOverlay(): DeviceActionResult {
        val view = overlayView ?: return DeviceActionResult(true)
        // Stop the live pulse first: no animator may outlive the window.
        stopOverlayLivePulse()
        overlayView = null
        overlayParams = null
        overlayInput = null
        overlayActionButton = null
        overlayMicButton = null
        overlayLiveDot = null
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

    /// Overlay send seam: non-blank text goes to Dart as deviceOverlayText,
    /// then the field is cleared (which morphs the button back to X).
    internal fun onOverlaySend(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        overlayEventListener?.invoke("deviceOverlayText", trimmed)
        overlayInput?.text?.clear()
    }

    /// Overlay X seam: an empty field is a hard stop for the run.
    internal fun onOverlayStop() {
        overlayEventListener?.invoke("deviceOverlayStop", null)
    }

    /// Overlay mic seam: ask Dart to toggle on-device dictation.
    internal fun onOverlayMic() {
        overlayEventListener?.invoke("deviceOverlayMic", null)
    }

    /// Push recognized dictation text into the overlay field (from Dart).
    internal fun setOverlayInputText(text: String) {
        val input = overlayInput ?: return
        input.setText(text)
        input.setSelection(text.length)
    }

    /// Reflect the dictation listening state on the mic button.
    internal fun setOverlayMicListening(listening: Boolean) {
        val button = overlayMicButton ?: return
        button.imageTintList = ColorStateList.valueOf(
            if (listening) 0xFF4DA3FF.toInt() else 0xFFB0B0B0.toInt(),
        )
        button.contentDescription = if (listening) "Stop dictation" else "Dictate"
    }

    /// Show the AI's pending question as the overlay input hint.
    internal fun setOverlayPrompt(prompt: String) {
        overlayInput?.hint = prompt
    }

    /// Live indicator: while a Control run is active the overlay breathes —
    /// a small status dot fades in and pulses, and the X/send button gets a
    /// very light scale pop, so the user can tell Ovid is live at a glance.
    /// Safe with no window (records nothing, touches nothing).
    internal fun setOverlayLive(live: Boolean) {
        val button = overlayActionButton ?: return
        stopOverlayLivePulse()
        if (!live) return
        // Status dot: 8dp green circle, alpha breathing 0.35↔1.0.
        overlayLiveDot?.let {
            it.visibility = View.VISIBLE
            it.alpha = 1f
        }
        overlayLiveAnimator = ValueAnimator.ofFloat(0.35f, 1f).apply {
            duration = 1200
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener { anim ->
                overlayLiveDot?.alpha = anim.animatedValue as Float
            }
            start()
        }
        // X pop: deliberately subtle — 1.0↔1.08 scale, 1.0↔0.85 alpha.
        val scaleX = ObjectAnimator.ofFloat(button, "scaleX", 1f, 1.08f).apply {
            duration = 1400
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
        }
        val scaleY = ObjectAnimator.ofFloat(button, "scaleY", 1f, 1.08f).apply {
            duration = 1400
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
        }
        val fade = ObjectAnimator.ofFloat(button, "alpha", 1f, 0.85f).apply {
            duration = 1400
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
        }
        overlayActionPulse = AnimatorSet().apply {
            playTogether(scaleX, scaleY, fade)
            start()
        }
    }

    private fun stopOverlayLivePulse() {
        overlayLiveAnimator?.cancel()
        overlayLiveAnimator = null
        overlayActionPulse?.cancel()
        overlayActionPulse = null
        overlayLiveDot?.let {
            it.visibility = View.GONE
            it.alpha = 1f
        }
        overlayActionButton?.let {
            it.scaleX = 1f
            it.scaleY = 1f
            it.alpha = 1f
        }
    }

    private fun removeOverlayNow() {
        val view = overlayView ?: return
        stopOverlayLivePulse()
        overlayView = null
        overlayParams = null
        overlayInput = null
        overlayActionButton = null
        overlayMicButton = null
        overlayLiveDot = null
        try {
            val windowManager = getSystemService(WINDOW_SERVICE) as? WindowManager
            windowManager?.removeView(view)
        } catch (_: Throwable) {
            // Tearing down: nothing left to report to.
        }
    }

    private fun overlayContainer(
        windowManager: WindowManager,
        density: Float,
    ): LinearLayout {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val pad = (10 * density).toInt()
            setPadding(pad, (8 * density).toInt(), pad, (8 * density).toInt())
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                // See-through so the content behind stays legible while the
                // user is being steered (alpha 0xB3 ≈ 70%).
                setColor(0xB31A1A1A.toInt())
                setStroke((1 * density).toInt(), 0x33FFFFFF)
                cornerRadius = 22 * density
            }
            elevation = 8 * density
        }
        // Live status dot: 8dp green circle at the leading edge, shown only
        // while a Control run is active (pulsed by setOverlayLive).
        val dotSize = (8 * density).toInt()
        val liveDot = View(this).apply {
            layoutParams = LinearLayout.LayoutParams(dotSize, dotSize).apply {
                leftMargin = (2 * density).toInt()
                rightMargin = (2 * density).toInt()
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFF4CAF50.toInt())
            }
            visibility = View.GONE
            contentDescription = "Ovid live"
        }
        container.addView(liveDot)
        overlayLiveDot = liveDot
        container.addView(overlayDragHandle(windowManager, container, density))
        val input = EditText(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f,
            ).apply {
                leftMargin = (8 * density).toInt()
                rightMargin = (8 * density).toInt()
            }
            minEms = 8
            maxLines = 1
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_SEND
            hint = "Steer Ovid…"
            setHintTextColor(0xFF9A9A9A.toInt())
            setTextColor(0xFFFFFFFF.toInt())
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
        container.addView(input)
        overlayInput = input
        // Mic: toggles on-device dictation through Dart. Kept just left of
        // the X/send action.
        val mic = ImageButton(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                (44 * density).toInt(),
                (44 * density).toInt(),
            )
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = null
            contentDescription = "Dictate"
            setImageResource(android.R.drawable.ic_btn_speak_now)
            imageTintList = ColorStateList.valueOf(0xFFB0B0B0.toInt())
            setOnClickListener { onOverlayMic() }
        }
        container.addView(mic)
        overlayMicButton = mic
        val action = ImageButton(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                (44 * density).toInt(),
                (44 * density).toInt(),
            )
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = null
            contentDescription = "Stop"
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            imageTintList = ColorStateList.valueOf(0xFFB0B0B0.toInt())
            setOnClickListener {
                val current = overlayInput?.text?.toString().orEmpty()
                if (current.isBlank()) {
                    onOverlayStop()
                } else {
                    onOverlaySend(current)
                    overlayInput?.clearFocus()
                    val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.hideSoftInputFromWindow(overlayInput?.windowToken, 0)
                }
            }
        }
        container.addView(action)
        overlayActionButton = action
        // X ⇄ send morph: any non-blank text shows a colored send arrow,
        // a blank field shows the X again.
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(
                s: CharSequence?,
                start: Int,
                count: Int,
                after: Int,
            ) = Unit
            override fun onTextChanged(
                s: CharSequence?,
                start: Int,
                before: Int,
                count: Int,
            ) = Unit
            override fun afterTextChanged(s: Editable?) {
                val button = overlayActionButton ?: return
                if (!s.isNullOrBlank()) {
                    button.setImageResource(android.R.drawable.ic_menu_send)
                    button.imageTintList = ColorStateList.valueOf(0xFF4DA3FF.toInt())
                    button.contentDescription = "Send"
                } else {
                    button.setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                    button.imageTintList = ColorStateList.valueOf(0xFFB0B0B0.toInt())
                    button.contentDescription = "Stop"
                }
            }
        })
        return container
    }

    /// 2×3 dot drag handle (2 columns × 3 rows of plain dot Views, no
    /// assets): touch-drag moves the window through updateViewLayout.
    private fun overlayDragHandle(
        windowManager: WindowManager,
        container: View,
        density: Float,
    ): LinearLayout {
        val handle = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            contentDescription = "Drag to move"
        }
        val dot = (4 * density).toInt().coerceAtLeast(2)
        val gap = (3 * density).toInt()
        repeat(2) {
            val column = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
            }
            repeat(3) {
                val dotView = View(this).apply {
                    layoutParams = LinearLayout.LayoutParams(dot, dot).apply {
                        setMargins(gap, gap, gap, gap)
                    }
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(0xFF8A8A8A.toInt())
                    }
                }
                column.addView(dotView)
            }
            handle.addView(column)
        }
        handle.setOnTouchListener { touched, event ->
            val params = overlayParams
            if (params == null) {
                false
            } else when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    touched.tag = intArrayOf(
                        params.x - event.rawX.toInt(),
                        params.y - event.rawY.toInt(),
                    )
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val offset = touched.tag as? IntArray
                    if (offset != null && offset.size == 2) {
                        params.x = event.rawX.toInt() + offset[0]
                        params.y = event.rawY.toInt() + offset[1]
                        try {
                            windowManager.updateViewLayout(container, params)
                        } catch (_: Throwable) {
                            // A racing hide must not crash the drag.
                        }
                    }
                    true
                }
                else -> false
            }
        }
        return handle
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        treeCache.markDirty()
        val info = serviceInfo ?: AccessibilityServiceInfo()
        info.flags = info.flags or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
        info.notificationTimeout = 50
        serviceInfo = info
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        when (event?.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            -> treeCache.markDirty()
        }
    }

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        removeOverlayNow()
        resetTree()
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        removeOverlayNow()
        resetTree()
        screenshotExecutor.shutdown()
        if (instance === this) instance = null
        super.onDestroy()
    }

    /**
     * Resolves the target root accessibility node for screen reading and interaction.
     * If rootInActiveWindow points to our own overlay or is unavailable, we inspect
     * on-screen interactive windows to find the top-most non-Ovid application window.
     */
    internal fun findTargetRootNode(): AccessibilityNodeInfo? {
        var active = try {
            rootInActiveWindow
        } catch (_: Throwable) {
            null
        }
        val myPkg = packageName
        // If active node is our own overlay or app, do not treat it as the target third-party app
        if (active != null && active.packageName?.toString() != myPkg) {
            return active
        }

        // Active window is null or belongs to Ovid (overlay/app); search interactive windows.
        try {
            val windowList = windows
            if (windowList != null && windowList.isNotEmpty()) {
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
        val packageName = root.packageName?.toString().orEmpty()
        val windowId = root.windowId

        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > MAX_DEPTH || rows.size >= MAX_NODES) return

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

            if (depth == MAX_DEPTH || rows.size >= MAX_NODES) return
            for (index in 0 until node.childCount) {
                if (rows.size >= MAX_NODES) break
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

    @Synchronized
    internal fun tap(handle: Int?, x: Float?, y: Float?): DeviceActionResult {
        if (handle != null) {
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
        if (x == null || y == null || !x.isFinite() || !y.isFinite()) {
            return DeviceActionResult(false, "BAD_ARGS", "Tap requires a node handle or finite x/y coordinates.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Gesture taps require Android 7.0 or newer.")
        }
        return if (Api24Actions.tap(this, x, y)) {
            DeviceActionResult(true)
        } else {
            DeviceActionResult(false, message = "Android did not accept the tap gesture.")
        }
    }

    internal fun clampLongPressDuration(durationMs: Long?): Long =
        (durationMs ?: 600L).coerceIn(200L, 3000L)

    @Synchronized
    internal fun longPress(
        handle: Int?,
        x: Float?,
        y: Float?,
        durationMs: Long?,
    ): DeviceActionResult {
        if (handle != null) {
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
        if (x == null || y == null || !x.isFinite() || !y.isFinite()) {
            return DeviceActionResult(false, "BAD_ARGS", "Long-press requires a node handle or finite x/y coordinates.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return DeviceActionResult(false, "UNSUPPORTED", "Long-press gestures require Android 7.0 or newer.")
        }
        val duration = clampLongPressDuration(durationMs)
        return if (Api24Actions.longPress(this, x, y, duration)) {
            DeviceActionResult(true)
        } else {
            DeviceActionResult(false, message = "Android did not accept the long-press gesture.")
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

    @Synchronized
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
        return if (Api24Actions.swipe(this, fromX, fromY, toX, toY, durationMs)) {
            DeviceActionResult(true)
        } else {
            DeviceActionResult(false, message = "Android did not accept the swipe gesture.")
        }
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
    fun tap(service: AccessibilityService, x: Float, y: Float): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
            .build()
        return service.dispatchGesture(gesture, null, null)
    }

    fun swipe(
        service: AccessibilityService,
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
    ): Boolean {
        val path = Path().apply {
            moveTo(fromX, fromY)
            lineTo(toX, toY)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        return service.dispatchGesture(gesture, null, null)
    }

    fun longPress(
        service: AccessibilityService,
        x: Float,
        y: Float,
        durationMs: Long,
    ): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        return service.dispatchGesture(gesture, null, null)
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
