package com.dhanuk.ovidai

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.annotation.TargetApi
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

internal data class HandleAllocation(val handle: Int, val nextHandle: Int)

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

@Suppress("DEPRECATION")
class OvidAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: OvidAccessibilityService? = null
            private set

        private const val MAX_NODES = 300
        private const val MAX_DEPTH = 30
    }

    private val treeGeneration = TreeReadGeneration()
    private var windowSignature = ""
    private var lastPackage = ""
    private var lastWindowId = -1
    private var previousRows = linkedMapOf<String, Map<String, Any?>>()
    private val nodesByHandle = mutableMapOf<Int, AccessibilityNodeInfo>()
    private val handlesByStableKey = mutableMapOf<String, Int>()
    private var nextHandle = 1
    private val screenshotExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ovid-device-screenshot").apply { isDaemon = true }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        treeGeneration.markDirty()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        when (event?.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            -> treeGeneration.markDirty()
        }
    }

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        resetTree()
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        resetTree()
        screenshotExecutor.shutdown()
        if (instance === this) instance = null
        super.onDestroy()
    }

    @Synchronized
    fun readScreen(forceFull: Boolean): Map<String, Any?> {
        val readGeneration = treeGeneration.beginRead(forceFull)
        if (readGeneration == null) {
            return readResult(
                status = "unchanged",
                packageName = lastPackage,
                windowId = lastWindowId,
                delta = NodeDelta(false, emptyList(), emptyList(), emptyList()),
            )
        }

        val root = try {
            rootInActiveWindow
        } catch (error: Throwable) {
            treeGeneration.abandonRead(readGeneration)
            return readError(error)
        }
        if (root == null) {
            treeGeneration.abandonRead(readGeneration)
            return readUnavailable(
                "The active window is temporarily unavailable. Retry device_read.",
            )
        }

        val rows = linkedMapOf<String, Map<String, Any?>>()
        val newNodes = mutableMapOf<Int, AccessibilityNodeInfo>()
        val newHandles = mutableMapOf<String, Int>()
        var candidateNextHandle = nextHandle
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
                    val allocation = allocateStableHandle(handlesByStableKey, rowKey, candidateNextHandle)
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
            commitTree(
                packageName = packageName,
                windowId = windowId,
                rows = rows,
                newNodes = newNodes,
                newHandles = newHandles,
                newNextHandle = candidateNextHandle,
                forceFull = forceFull,
                readGeneration = readGeneration,
            )
        } catch (error: Throwable) {
            newNodes.values.forEach { it.recycle() }
            treeGeneration.abandonRead(readGeneration)
            readError(error)
        } finally {
            root.recycle()
        }
    }

    @Synchronized
    internal fun tap(handle: Int?, x: Float?, y: Float?): DeviceActionResult {
        if (handle != null) {
            val node = nodesByHandle[handle]
                ?: return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid.")
            return if (node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                DeviceActionResult(true)
            } else {
                DeviceActionResult(false, message = "Node $handle did not accept a click action.")
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

    @Synchronized
    internal fun type(handle: Int?, text: String, submit: Boolean): DeviceActionResult {
        var root: AccessibilityNodeInfo? = null
        var focusedNode: AccessibilityNodeInfo? = null
        val node = if (handle != null) {
            nodesByHandle[handle]
                ?: return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid.")
        } else {
            root = rootInActiveWindow
                ?: return DeviceActionResult(false, "NO_FOCUS", "No active window has a focused input.")
            focusedNode = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            focusedNode
                ?: return DeviceActionResult(false, "NO_FOCUS", "No focused input is available.").also {
                    root.recycle()
                }
        }

        try {
            if (handle != null && !node.refresh()) {
                return DeviceActionResult(false, "INVALID_NODE", "Node handle $handle is no longer valid.")
            }
            if (node.isPassword) {
                return DeviceActionResult(
                    false,
                    "PASSWORD_FIELD",
                    "Ovid will not type into password fields.",
                )
            }
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

    @Synchronized
    private fun commitTree(
        packageName: String,
        windowId: Int,
        rows: LinkedHashMap<String, Map<String, Any?>>,
        newNodes: MutableMap<Int, AccessibilityNodeInfo>,
        newHandles: MutableMap<String, Int>,
        newNextHandle: Int,
        forceFull: Boolean,
        readGeneration: Long,
    ): Map<String, Any?> {
        val signature = "$packageName|$windowId"
        val delta = diffNodeRows(
            previous = previousRows,
            current = rows,
            forceFull = forceFull,
            windowChanged = signature != windowSignature,
        )

        clearNodeHandles()
        nodesByHandle.putAll(newNodes)
        handlesByStableKey.clear()
        handlesByStableKey.putAll(newHandles)
        previousRows = rows
        nextHandle = newNextHandle
        windowSignature = signature
        lastPackage = packageName
        lastWindowId = windowId
        // A newer event has a larger generation and therefore remains pending.
        treeGeneration.completeRead(readGeneration)
        return readResult("ok", packageName, windowId, delta)
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
        "package" to lastPackage,
        "window" to lastWindowId,
        "full" to false,
        "added" to emptyList<Map<String, Any?>>(),
        "changed" to emptyList<Map<String, Any?>>(),
        "removed" to emptyList<Int>(),
    )

    private fun readUnavailable(message: String): Map<String, Any?> = linkedMapOf(
        "status" to "unavailable",
        "message" to message,
        "package" to lastPackage,
        "window" to lastWindowId,
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
        clearNodeHandles()
        handlesByStableKey.clear()
        previousRows.clear()
        windowSignature = ""
        lastPackage = ""
        lastWindowId = -1
        treeGeneration.markDirty()
    }

    @Synchronized
    private fun clearNodeHandles() {
        nodesByHandle.values.forEach { node ->
            try {
                node.recycle()
            } catch (_: Throwable) {
                // Continue releasing the remaining retained nodes.
            }
        }
        nodesByHandle.clear()
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
                        result.error(
                            "SCREENSHOT_FAILED",
                            "Android screenshot failed with code $errorCode.",
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
