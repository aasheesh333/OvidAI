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

/** Device checks for the actual Android boundary, separate from host fakes and
 * Chromium document tests. Run with a connected emulator/device. */
@Suppress("DEPRECATION")
@RunWith(AndroidJUnit4::class)
class HtmlArtifactWebViewTest {
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
