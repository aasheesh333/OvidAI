package com.dhanuk.ovidai

import android.content.Context
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.ImageButton
import android.widget.TextView
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class OverlayInteractionTest {
    private lateinit var service: OvidAccessibilityService
    private lateinit var circle: View
    private val events = mutableListOf<String>()

    @Before fun showOverlay() {
        deviceActions.begin()
        service = Robolectric.buildService(OvidAccessibilityService::class.java).create().get()
        OvidAccessibilityService.overlayEventListener = { method, _ -> events.add(method) }
        assertTrue(service.showOverlay().ok)
        circle = field("overlayCircle")
        shadowOf(Looper.getMainLooper()).idle()
    }

    @After fun cleanup() {
        OvidAccessibilityService.overlayEventListener = null
        service.onDestroy()
        deviceActions.begin()
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> field(name: String): T = service.javaClass.getDeclaredField(name).let {
        it.isAccessible = true
        it.get(service) as T
    }

    private fun touch(action: Int, x: Float = 30f, y: Float = 210f) {
        val time = SystemClock.uptimeMillis()
        MotionEvent.obtain(time, time, action, x, y, 0).let {
            circle.dispatchTouchEvent(it)
            it.recycle()
        }
    }

    private fun views(view: View): List<View> = listOf(view) +
        if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) }
        else emptyList()

    @Test fun accessibilityClickExpandsSteeringBox() {
        assertTrue(circle.performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, null))
        assertEquals(View.GONE, circle.visibility)
        assertEquals(View.VISIBLE, field<View>("overlayBox").visibility)
    }

    @Test fun dragReleaseDoesNotExpandEvenAfterReturningToOriginalPointer() {
        touch(MotionEvent.ACTION_DOWN)
        touch(MotionEvent.ACTION_MOVE, 150f, 260f)
        touch(MotionEvent.ACTION_MOVE)
        touch(MotionEvent.ACTION_UP)
        assertEquals(View.VISIBLE, circle.visibility)
        assertTrue(events.isEmpty())
    }

    @Test fun longPressStopsBeforeReleaseAndCancelsNativeTicketsBeforeEvent() {
        var cancelled = false
        val ticket = deviceActions.ticket { cancelled = true }!!
        OvidAccessibilityService.overlayEventListener = { method, _ ->
            assertTrue(cancelled)
            assertFalse(ticket.isCurrent())
            events.add(method)
        }
        touch(MotionEvent.ACTION_DOWN)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ViewConfiguration.getLongPressTimeout().toLong() + 1))
        assertEquals(listOf("deviceOverlayStop"), events)
        assertFalse(service.isOverlayVisible())
        touch(MotionEvent.ACTION_UP)
        assertEquals(1, events.size)
    }

    @Test fun cancelledTouchCannotLaterStopOrExpand() {
        touch(MotionEvent.ACTION_DOWN)
        touch(MotionEvent.ACTION_CANCEL)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertTrue(service.isOverlayVisible())
        assertEquals(View.VISIBLE, circle.visibility)
        assertTrue(events.isEmpty())
    }

    @Test fun hiddenOverlayCannotDeliverPendingLongPress() {
        touch(MotionEvent.ACTION_DOWN)
        service.hideOverlay()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertFalse(deviceActions.isStopped())
        assertTrue(events.isEmpty())
    }

    @Test fun dragToDisplayEdgeStaysReachableAndDoesNotBecomeClick() {
        touch(MotionEvent.ACTION_DOWN)
        touch(MotionEvent.ACTION_MOVE, -500f, -500f)
        touch(MotionEvent.ACTION_UP, -500f, -500f)
        val params = field<WindowManager.LayoutParams>("overlayParams")
        assertEquals(0, params.x)
        assertEquals(0, params.y)
        assertEquals(View.VISIBLE, circle.visibility)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertTrue(events.isEmpty())
    }

    @Test fun quickTapExpandsWithoutStopping() {
        touch(MotionEvent.ACTION_DOWN)
        touch(MotionEvent.ACTION_UP)
        assertEquals(View.GONE, circle.visibility)
        assertEquals(View.VISIBLE, field<View>("overlayBox").visibility)
        assertFalse(deviceActions.isStopped())
        assertTrue(events.isEmpty())
    }

    @Test fun expansionAndConfigurationChangeReclampMeasuredWindow() {
        val root = field<View>("overlayView")
        val params = field<WindowManager.LayoutParams>("overlayParams")
        val metrics = service.resources.displayMetrics
        // Model the newly measured box at a position valid only for a circle.
        root.layout(0, 0, metrics.widthPixels / 2, metrics.heightPixels / 2)
        params.x = metrics.widthPixels - 1
        params.y = metrics.heightPixels - 1
        circle.performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(params.x <= metrics.widthPixels - root.width)
        assertTrue(params.y <= metrics.heightPixels - root.height)

        params.x = metrics.widthPixels + 100
        params.y = metrics.heightPixels + 100
        service.onConfigurationChanged(service.resources.configuration)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(params.x <= metrics.widthPixels - root.width)
        assertTrue(params.y <= metrics.heightPixels - root.height)
    }

    @Test fun sendOnlyArmsForNonblankDraftAndClearsAfterEmittingText() {
        circle.performClick()
        val send = field<ImageButton>("overlaySendButton")
        val input = field<EditText>("overlayInput")
        assertFalse(send.isEnabled)
        service.setOverlayInputText("   ")
        assertFalse(send.isEnabled)
        service.onOverlaySend("   ")
        assertTrue(events.isEmpty())

        val sent = mutableListOf<String?>()
        OvidAccessibilityService.overlayEventListener = { method, text ->
            events.add(method)
            sent.add(text)
        }
        service.setOverlayInputText("  steer left  ")
        assertTrue(send.isEnabled)
        send.performClick()
        assertEquals(listOf("deviceOverlayText"), events)
        assertEquals(listOf("steer left"), sent)
        assertEquals("", input.text.toString())
        assertFalse(send.isEnabled)
        assertFalse(deviceActions.isStopped())
    }

    @Test fun minimizePreservesDraftAndWorkAndRestoresNonFocusableWindow() {
        service.setOverlayInputText("keep this draft")
        val input = field<EditText>("overlayInput")
        input.requestFocus()
        val ticket = deviceActions.ticket {}!!
        val minimize = views(field("overlayBox")).filterIsInstance<TextView>()
            .firstOrNull { it.text.toString() == "Minimize" }
        assertNotNull("Expanded overlay needs an explicit Minimize control", minimize)
        minimize!!.performClick()
        assertEquals("keep this draft", input.text.toString())
        assertTrue(ticket.isCurrent())
        assertTrue(events.isEmpty())
        assertFalse(input.hasFocus())
        assertEquals(View.VISIBLE, circle.visibility)
        assertTrue(field<WindowManager.LayoutParams>("overlayParams").flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE != 0)
        assertFalse(shadowOf(service.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).isSoftInputVisible)
        circle.performClick()
        assertEquals(View.VISIBLE, field<View>("overlayBox").visibility)
        assertEquals("keep this draft", input.text.toString())
    }

    @Test fun explicitStopCancelsWithDraftStillPresent() {
        service.setOverlayInputText("unfinished")
        val stop = views(field("overlayBox")).filterIsInstance<TextView>()
            .firstOrNull { it.text.toString() == "Stop Ovid" }
        assertNotNull("Expanded overlay needs an explicit Stop Ovid control", stop)
        stop!!.performClick()
        assertTrue(deviceActions.isStopped())
        assertFalse(service.isOverlayVisible())
        assertEquals(listOf("deviceOverlayStop"), events)
    }
}
