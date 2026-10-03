package com.dhanuk.ovidai

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.webkit.WebView
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.LooperMode
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowLegacyCanvas

@RunWith(RobolectricTestRunner::class)
@LooperMode(LooperMode.Mode.PAUSED)
@Config(sdk = [23, 24, 26], shadows = [CaptureCanvasShadow::class, RejectedPixelCopyShadow::class])
class WebViewCaptureCompatibilityTest {
    private val controller = Robolectric.buildActivity(Activity::class.java)
    private lateinit var activity: Activity
    private lateinit var webView: RecordingWebView
    private lateinit var handler: OvidWebViewHandler

    @Before fun setup() {
        activity = controller.setup().visible().get()
        webView = RecordingWebView(activity)
        activity.setContentView(webView, FrameLayout.LayoutParams(400, 800))
        activity.window.decorView.layout(0, 0, 600, 1000)
        webView.layout(0, 0, 400, 800)
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        handler = OvidWebViewHandler(activity, null, NoopMessenger())
        RejectedPixelCopyShadow.requests = 0
        assertTrue(webView.isAttachedToWindow)
        assertTrue(webView.isShown)
    }

    @After fun cleanup() {
        webView.destroy()
        controller.pause().stop().destroy()
    }

    @Test
    @Config(sdk = [23, 24])
    fun legacyCaptureScalesTheWholeViewIntoMaxEdgeAndRestoresLayer() {
        val result = capture(200)
        assertEquals(result.toString(), true, result["captured"])
        assertEquals(100, result["width"])
        assertEquals(200, result["height"])
        assertEquals(400, result["sourceWidth"])
        assertEquals(800, result["sourceHeight"])
        assertTrue((result["base64"] as String).isNotEmpty())
        assertEquals(result.toString(), 1, webView.draws)
        assertEquals(0.25f, webView.scaleXAtDraw, 0.0001f)
        assertEquals(0.25f, webView.scaleYAtDraw, 0.0001f)
        assertEquals(View.LAYER_TYPE_SOFTWARE, webView.layerAtDraw)
        assertEquals(View.LAYER_TYPE_HARDWARE, webView.layerType)
        assertEquals(0, RejectedPixelCopyShadow.requests)
    }

    @Test
    @Config(sdk = [23, 24])
    fun failingSoftwareDrawRestoresLayerAndReturnsOneFailure() {
        webView.failDraw = true
        val result = capture(200)
        assertEquals(false, result["captured"])
        assertEquals(result.toString(), 1, webView.draws)
        assertEquals(View.LAYER_TYPE_HARDWARE, webView.layerType)
    }

    @Test
    @Config(sdk = [26])
    fun api26UsesWindowPixelCopyAndDoesNotSoftwareCaptureAfterRejection() {
        val result = capture(200)
        assertEquals(result.toString(), 1, RejectedPixelCopyShadow.requests)
        assertEquals(false, result["captured"])
        assertTrue((result["reason"] as String).contains("PixelCopy failed"))
        assertEquals(0, webView.draws)
        assertEquals(View.LAYER_TYPE_HARDWARE, webView.layerType)
    }

    @Test fun secureWindowNeverFallsBackToSoftwareCapture() {
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val result = capture(200)
        assertEquals(false, result["captured"])
        assertNull(result["base64"])
        assertEquals(0, webView.draws)
        assertEquals(View.LAYER_TYPE_HARDWARE, webView.layerType)
    }

    private fun capture(maxEdge: Int): Map<*, *> {
        // The host WebView provider does not implement setFrame/layout.
        webView.left = 0
        webView.top = 0
        webView.right = 400
        webView.bottom = 800
        assertEquals(400, webView.width)
        assertEquals(800, webView.height)
        val result = CaptureResult()
        // Exercise the capture implementation without a Flutter engine/native
        // platform-view registry; WebView, Activity and lifecycle are real.
        OvidWebViewHandler::class.java.getDeclaredMethod(
            "captureWebView", WebView::class.java, Int::class.javaPrimitiveType,
            MethodChannel.Result::class.java
        ).apply { isAccessible = true }.invoke(handler, webView, maxEdge, result)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("capture must reply exactly once", 1, result.replies)
        return result.value as Map<*, *>
    }

    private class CaptureResult : MethodChannel.Result {
        var replies = 0
        var value: Any? = null
        override fun success(result: Any?) { replies++; value = result }
        override fun error(code: String, message: String?, details: Any?) = fail("$code: $message")
        override fun notImplemented() = fail("capture not implemented")
    }

    private class NoopMessenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
    }

    private class RecordingWebView(context: Context) : WebView(context) {
        var draws = 0
        var failDraw = false
        var scaleXAtDraw = 1f
        var scaleYAtDraw = 1f
        var layerAtDraw = View.LAYER_TYPE_NONE
        override fun draw(canvas: Canvas) {
            draws++
            val shadow = Shadow.extract<CaptureCanvasShadow>(canvas)
            scaleXAtDraw = shadow.captureScaleX
            scaleYAtDraw = shadow.captureScaleY
            layerAtDraw = layerType
            if (failDraw) error("draw rejected")
        }
    }
}

// Legacy Robolectric graphics cannot rasterize WebView content or expose the
// canvas matrix. Record the transform delivered to draw at that boundary.
@Implements(Canvas::class)
class CaptureCanvasShadow : ShadowLegacyCanvas() {
    var captureScaleX = 1f
    var captureScaleY = 1f
    @Implementation override fun scale(sx: Float, sy: Float) {
        captureScaleX *= sx
        captureScaleY *= sy
        super.scale(sx, sy)
    }
}

// No compositor in host tests. Model a platform rejection to verify that the
// API26 Window path is selected and never bypassed by a software retry.
@Implements(PixelCopy::class, minSdk = 26)
class RejectedPixelCopyShadow {
    companion object {
        var requests = 0
        @JvmStatic @Implementation(minSdk = 26)
        fun request(window: Window, bitmap: Bitmap, listener: PixelCopy.OnPixelCopyFinishedListener, handler: Handler) {
            requests++
            handler.post { listener.onPixelCopyFinished(PixelCopy.ERROR_SOURCE_INVALID) }
        }
    }
}
