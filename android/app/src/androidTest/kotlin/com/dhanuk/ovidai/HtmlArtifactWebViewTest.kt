package com.dhanuk.ovidai

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.PermissionRequest
import android.widget.FrameLayout
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.ViewGroup
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.json.JSONTokener

/** Device checks for the actual Android boundary, separate from host fakes and
 * Chromium document tests. Run with a connected emulator/device. */
@Suppress("DEPRECATION")
@RunWith(AndroidJUnit4::class)
class HtmlArtifactWebViewTest {
    /** Executes the Dart-generated srcdoc/CSP wrapper in the production native
     * platform view. Never replace its clients/settings to make this pass.
     * The only observer is test-side evaluateJavascript, not a native JS bridge.
     */
    @Test fun productionViewRendersSandboxedJavascriptCounter() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        val document = instrumentation.context.assets.open("html_artifact_counter.html")
            .bufferedReader().use { it.readText().trim() }
        var platform: HtmlArtifactPlatformView? = null
        lateinit var view: WebView
        try {
            instrumentation.runOnMainSync {
                // A modern supported engine must render; no assumption/skip here.
                assertTrue("DOCUMENT_START_SCRIPT is required for the offline sandbox",
                    WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT))
                platform = HtmlArtifactPlatformView(instrumentation.targetContext, document)
                val root = platform!!.view as FrameLayout
                assertTrue("Production view fell back instead of creating its renderer", root.getChildAt(0) is WebView)
                view = root.getChildAt(0) as WebView
                activity.addContentView(root, ViewGroup.LayoutParams(-1, -1))
            }
            fun evaluate(script: String): String {
                val done = CountDownLatch(1)
                val result = AtomicReference<String>()
                instrumentation.runOnMainSync {
                    view.evaluateJavascript(script) { result.set(it); done.countDown() }
                }
                assertTrue("JS evaluation timed out", done.await(5, TimeUnit.SECONDS))
                return result.get()
            }
            val deadline = SystemClock.uptimeMillis() + 15000
            var report: JSONObject? = null
            while (SystemClock.uptimeMillis() < deadline && report == null) {
                // Opaque srcdoc cannot be read from its parent; receive only this
                // test fixture's report. Install repeatedly across initial load.
                val result = evaluate("""
                    (() => {
                      if (!window.__artifactTestObserver) {
                        window.__artifactTestObserver = true;
                        addEventListener('message', e => window.__artifactTestResult = e.data);
                      }
                      return window.__artifactTestResult ? JSON.stringify(window.__artifactTestResult) : null;
                    })()
                """.trimIndent())
                if (result != "null") report = JSONObject(JSONTokener(result).nextValue() as String)
                else SystemClock.sleep(50)
            }
            assertNotNull("Production loadData/srcdoc never executed the counter", report)
            assertEquals("1", report!!.getString("counter"))
            assertEquals("rgb(255, 0, 0)", report!!.getString("css"))
            assertEquals("undefined", report!!.getString("bridge"))
            assertEquals("undefined", report!!.getString("rtc"))
            val visible = CountDownLatch(1)
            instrumentation.runOnMainSync {
                view.postVisualStateCallback(1, object : WebView.VisualStateCallback() {
                    override fun onComplete(requestId: Long) { visible.countDown() }
                })
            }
            assertTrue("Counter DOM was never ready to draw", visible.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                assertTrue(view.width > 0 && view.height > 0)
                val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
                view.draw(Canvas(bitmap))
                var redPixels = 0
                for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                    val pixel = bitmap.getPixel(x, y)
                    if (android.graphics.Color.red(pixel) > 150 &&
                        android.graphics.Color.green(pixel) < 120 && android.graphics.Color.blue(pixel) < 120) redPixels++
                }
                bitmap.recycle()
                assertTrue("Counter text did not render red pixels", redPixels > 0)
            }
        } finally {
            instrumentation.runOnMainSync {
                platform?.let {
                    (it.view.parent as? ViewGroup)?.removeView(it.view)
                    it.dispose()
                }
                activity.finish()
            }
        }
    }

    @Test fun nativeSettingsAndDeniedRoutes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            assumeTrue(WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT))
            val platform = HtmlArtifactPlatformView(
                instrumentation.targetContext, "<p>offline</p>",
            )
            val root = platform.view as FrameLayout
            val view = root.getChildAt(0) as WebView
            val settings = view.settings
            assertTrue(settings.javaScriptEnabled)
            assertFalse(settings.allowFileAccess)
            assertFalse(settings.allowContentAccess)
            assertFalse(settings.allowFileAccessFromFileURLs)
            assertFalse(settings.allowUniversalAccessFromFileURLs)
            assertTrue(settings.blockNetworkLoads)
            assertTrue(settings.blockNetworkImage)
            assertFalse(settings.domStorageEnabled)
            assertFalse(settings.databaseEnabled)
            assertFalse(settings.javaScriptCanOpenWindowsAutomatically)
            assertEquals(WebSettings.MIXED_CONTENT_NEVER_ALLOW, settings.mixedContentMode)
            assertFalse(CookieManager.getInstance().acceptThirdPartyCookies(view))
            if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                assertTrue(WebViewCompat.getProfile(view).name.startsWith("ovid-artifact-"))
                assertFalse(WebViewCompat.getProfile(view).cookieManager.acceptCookie())
            }
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                for (url in listOf("https://example.com", "http://127.0.0.1", "file:///etc/passwd",
                    "content://settings/system", "intent://open", "javascript:alert(1)", "data:text/html,escape")) {
                    assertTrue(view.webViewClient.shouldOverrideUrlLoading(view, url))
                    assertEquals(403, view.webViewClient.shouldInterceptRequest(view, url)!!.statusCode)
                }
                var denied = false
                val permission = object : PermissionRequest() {
                    override fun getOrigin() = android.net.Uri.parse("https://example.com")
                    override fun getResources() = arrayOf(RESOURCE_VIDEO_CAPTURE, RESOURCE_AUDIO_CAPTURE)
                    override fun grant(resources: Array<String>) { fail("Native permission must not be granted") }
                    override fun deny() { denied = true }
                }
                view.webChromeClient!!.onPermissionRequest(permission)
                assertTrue(denied)
            }
            platform.dispose()
            assertEquals(0, root.childCount)
            platform.dispose() // lifecycle disposal is idempotent
        }
    }
}
