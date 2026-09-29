package com.dhanuk.ovidai

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.PixelCopy
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.webkit.ScriptHandler
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayOutputStream
import java.util.WeakHashMap
import kotlin.math.roundToInt

/**
 * Handles WebView configuration requests across the ovid/webview method channel.
 *
 * Settings apply to exactly ONE native WebView, resolved from the
 * `webViewIdentifier` the Dart side passes (AndroidWebViewController
 * .webViewIdentifier). There is no global companion static and no decor-view
 * traversal: toggling one tab can never change another tab's viewport.
 *
 * Desktop: useWideViewPort(true), loadWithOverviewMode(true) — desktop layout
 * width with the overview fit that keeps the forced viewport fully visible
 * (the old `false` left pages zoomed into the top-left at device scale).
 * Mobile: useWideViewPort(false), loadWithOverviewMode(true), NARROW_COLUMNS.
 *
 * Desktop mode also spoofs the UA *string* on the Dart side, but modern sites
 * ignore that string and read Chromium's User-Agent Client Hints instead
 * (`navigator.userAgentData.mobile`, `Sec-CH-UA-Mobile`, `Sec-CH-UA-Platform`)
 * plus JS touch probes (`navigator.maxTouchPoints`, `navigator.platform`,
 * coarse-pointer media queries). Those all stayed Android/mobile, so sites
 * like Softonic still served "you're on mobile" gates. This handler sets
 * desktop [UserAgentMetadata] (the source of the client-hint headers and
 * `navigator.userAgentData`) and installs a document-start shim that
 * neutralizes the remaining JS signals, for desktop tabs only.
 */
class OvidWebViewHandler(
    private var activity: Activity? = null,
    private val flutterEngine: FlutterEngine? = null,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "ovid/webview")

    /**
     * Document-start shim installed per WebView, as (width, height, handler),
     * keyed weakly so a discarded tab cannot leak. The script persists
     * across navigations, so it is added once and only re-installed when the
     * forced dimensions change or removed when the tab switches to mobile.
     */
    private val featureShimHandlers =
        WeakHashMap<WebView, Triple<Int, Int, ScriptHandler>>()

    /**
     * Forced-size viewport script per WebView, as (width, height, handler). A
     * document-start script applies to EVERY new document, so the desktop
     * layout survives navigation/reload — unlike a post-load DOM mutation,
     * which the fresh document wipes and which runs after the page's own
     * "is this mobile?" detection.
     */
    private val viewportHandlers =
        WeakHashMap<WebView, Triple<Int, Int, ScriptHandler>>()

    constructor(messenger: BinaryMessenger) : this(null, null, messenger)

    fun setup(activity: Activity) {
        this.activity = activity
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setDesktopViewport" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val tabId = call.argument<Number>("tabId")?.toInt()
                val identifier = call.argument<Number>("webViewIdentifier")?.toLong()
                val logicalWidth = call.argument<Number>("logicalWidth")?.toInt()
                val logicalHeight = call.argument<Number>("logicalHeight")?.toInt()
                val userAgent = call.argument<String>("userAgent")
                val webView = resolveWebView(identifier)
                val act = activity
                if (webView == null || act == null) {
                    result.success(
                        mapOf(
                            "applied" to false,
                            "enabled" to enabled,
                            "tabId" to tabId
                        )
                    )
                    return
                }
                act.runOnUiThread {
                    applySettings(webView.settings, enabled)
                    // Re-assert the UA on every call. The desktop UA used to be
                    // set once (Dart's first-load gate), so any controller/view
                    // recreation silently reverted the tab to mobile.
                    if (!userAgent.isNullOrBlank()) {
                        try {
                            webView.settings.userAgentString = userAgent
                        } catch (_: Throwable) {}
                    }
                    applyLogicalViewport(webView, logicalWidth, logicalHeight)
                    applyUserAgentMetadata(webView, enabled)
                    applyFeatureShim(webView, enabled, logicalWidth, logicalHeight)
                    result.success(
                        mapOf(
                            "applied" to true,
                            "enabled" to enabled,
                            "tabId" to tabId,
                            "webViewFound" to true,
                            "docStartSupported" to WebViewFeature.isFeatureSupported(
                                WebViewFeature.DOCUMENT_START_SCRIPT
                            ),
                            "useWideViewPort" to enabled,
                            "loadWithOverviewMode" to enabled,
                            "supportMultipleWindows" to true,
                            "logicalWidth" to logicalWidth,
                            "logicalHeight" to logicalHeight
                        )
                    )
                }
            }
            // ── Forced-desktop repair ───────────────────────────────────
            // The Dart side verifies every page finish (documentElement.
            // clientWidth + shim markers). When the forced width did NOT
            // stick — old WebView without document-start support, a page
            // that rewrote its viewport meta, a missed apply — it calls
            // here for an immediate, in-place repair of the LIVE document:
            // settings + viewport script + feature shim, evaluated now.
            // Document-start scripts (when supported) keep covering future
            // navigations; this call fixes the document on screen.
            "repairDesktop" -> {
                val identifier = call.argument<Number>("webViewIdentifier")?.toLong()
                val logicalWidth = call.argument<Number>("logicalWidth")?.toInt()
                    ?: 1280
                val logicalHeight = call.argument<Number>("logicalHeight")?.toInt()
                    ?: 800
                val tabId = call.argument<Number>("tabId")?.toInt()
                val webView = resolveWebView(identifier)
                val act = activity
                if (webView == null || act == null) {
                    result.success(
                        mapOf(
                            "applied" to false,
                            "webViewFound" to false,
                            "tabId" to tabId
                        )
                    )
                    return
                }
                act.runOnUiThread {
                    applySettings(webView.settings, true)
                    applyLogicalViewport(webView, logicalWidth, logicalHeight)
                    applyUserAgentMetadata(webView, true)
                    applyFeatureShim(webView, true, logicalWidth, logicalHeight)
                    // Immediate repair of the live document — the
                    // document-start scripts cover the NEXT navigation, but
                    // the page on screen needs the forcing NOW.
                    try {
                        webView.evaluateJavascript(
                            viewportScript(logicalWidth) +
                                desktopFeatureShim(logicalWidth, logicalHeight),
                            null
                        )
                    } catch (_: Throwable) {}
                    result.success(
                        mapOf(
                            "applied" to true,
                            "webViewFound" to true,
                            "docStartSupported" to WebViewFeature.isFeatureSupported(
                                WebViewFeature.DOCUMENT_START_SCRIPT
                            ),
                            "tabId" to tabId,
                            "logicalWidth" to logicalWidth,
                            "logicalHeight" to logicalHeight
                        )
                    )
                }
            }
            // ── Per-session browser profiles ────────────────────────────────
            // Each chat session owns its own cookie jar / web storage so a
            // login in one session is invisible from another. See
            // OvidBrowserProfiles for the restart-sharing details.
            "profilesSupported" -> result.success(OvidBrowserProfiles.supported())

            "bindProfile" -> {
                val identifier = call.argument<Number>("webViewIdentifier")?.toLong()
                val profileName = call.argument<String>("profileName").orEmpty()
                val webView = resolveWebView(identifier)
                if (webView == null || profileName.isBlank()) {
                    result.success(
                        mapOf("applied" to false, "profile" to profileName)
                    )
                    return
                }
                onUi {
                    // Plain Boolean: the Dart caller reads `invokeMethod<bool>`.
                    result.success(OvidBrowserProfiles.bind(webView, profileName))
                }
            }

            // Profile/WebView APIs are @UiThread; every branch below hops to it
            // (onUi runs inline when no activity is attached, so the channel
            // still replies exactly once in tests).
            "listProfiles" -> onUi {
                result.success(OvidBrowserProfiles.profileNames())
            }

            "deleteProfile" -> {
                val name = call.argument<String>("profileName").orEmpty()
                onUi { result.success(OvidBrowserProfiles.delete(name)) }
            }

            "shareProfileCookies" -> {
                val profiles = call.argument<List<String>>("profiles").orEmpty()
                val urls = call.argument<List<String>>("urls").orEmpty()
                onUi {
                    result.success(
                        mapOf(
                            "copied" to OvidBrowserProfiles.shareCookies(profiles, urls),
                            "profiles" to profiles.size,
                            "urls" to urls.size
                        )
                    )
                }
            }

            "clearProfileCookies" -> {
                val profiles = call.argument<List<String>>("profiles").orEmpty()
                val urls = call.argument<List<String>>("urls").orEmpty()
                onUi {
                    result.success(OvidBrowserProfiles.clearCookies(profiles, urls))
                }
            }

            // ── Pixel capture (browser_screenshot) ──────────────────────────
            // webview_flutter exposes NO screenshot API, so the agent could
            // read a page's text and outline but never actually SEE it: layout,
            // visual login state, "did that click change the screen" were all
            // unverifiable from Dart. PixelCopy reads the WebView's own surface
            // — the same pixels the user is looking at.
            "capturePixels" -> {
                val identifier = call.argument<Number>("webViewIdentifier")?.toLong()
                val maxEdge = (call.argument<Number>("maxEdge")?.toInt()
                    ?: WebViewCapture.DEFAULT_CAPTURE_EDGE)
                    .coerceIn(64, WebViewCapture.MAX_CAPTURE_EDGE)
                val webView = resolveWebView(identifier)
                if (webView == null) {
                    result.success(
                        mapOf("captured" to false, "reason" to "no attached webview")
                    )
                    return
                }
                onUi { captureWebView(webView, maxEdge, result) }
            }

            // navigator.geolocation bridge (2026-09-29).
            //
            // webview_flutter_android exposes NO geolocation prompt: its
            // PermissionRequestConstants cover only AUDIO_CAPTURE, MIDI_SYSEX,
            // VIDEO_CAPTURE and PROTECTED_MEDIA_ID, because Android routes
            // location through
            // WebChromeClient.onGeolocationPermissionsShowPrompt — and this app
            // must NOT install its own WebChromeClient (the plugin's file
            // chooser, JS dialogs and console bridge all hang off it). So a page
            // asking for its position never got an answer at all: no error
            // callback, no timeout, just a hang. Location-gated logins looked
            // broken and browser_console had nothing to show.
            //
            // This is the POSITION SOURCE for the Dart-side shim. It reads a
            // cached fix only — never requestLocationUpdates, so serving a web
            // page cannot switch on a radio or drain the battery.
            "locationFix" -> {
                val identifier = call.argument<Number>("webViewIdentifier")?.toLong()
                val ctx: Context? = resolveWebView(identifier)?.context ?: activity
                if (ctx == null) {
                    result.success(
                        mapOf("available" to false, "reason" to "no context")
                    )
                    return
                }
                onUi { result.success(GeoFix.read(ctx)) }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Run [block] on the UI thread. WebView/Profile calls must happen there;
     * with no activity attached (unit tests, headless engine) the block runs
     * inline so the channel still replies exactly once.
     */
    private fun onUi(block: () -> Unit) {
        val act = activity
        if (act == null) block() else act.runOnUiThread(block)
    }

    /**
     * Resolve the single native WebView named by [identifier]. Returns null when
     * no identifier was sent (legacy callers / unit tests) or the WebView is not
     * attached — the caller then reports `applied: false` and touches nothing.
     */
    @Suppress("DEPRECATION")
    private fun resolveWebView(identifier: Long?): WebView? {
        if (identifier == null) return null
        val engine = flutterEngine ?: return null
        return WebViewFlutterAndroidExternalApi.getWebView(engine, identifier)
    }

    /**
     * Capture [webView] into a downscaled PNG and reply with base64 + geometry.
     *
     * Replies EXACTLY once on every path. A MethodChannel.Result that is never
     * answered leaks the Dart-side future — the tool would hang until its whole
     * budget expired — and one answered twice throws. The guard is load-bearing
     * because [PixelCopy] is asynchronous: its listener and the surrounding
     * try/catch can both fire.
     */
    private fun captureWebView(
        webView: WebView,
        maxEdge: Int,
        result: MethodChannel.Result
    ) {
        val sourceW = webView.width
        val sourceH = webView.height
        if (sourceW <= 0 || sourceH <= 0) {
            // Never laid out (tab not rendered, or backgrounded). An honest
            // failure beats a 0x0 bitmap or a silent hang.
            result.success(
                mapOf("captured" to false, "reason" to "webview not laid out")
            )
            return
        }
        val size = WebViewCapture.scaledSize(sourceW, sourceH, maxEdge)
        var bitmap: Bitmap? = null
        var answered = false
        fun reply(payload: String?, reason: String) {
            if (answered) return
            answered = true
            bitmap?.recycle()
            bitmap = null
            result.success(
                if (payload != null) {
                    mapOf(
                        "captured" to true,
                        "base64" to payload,
                        "width" to size.first,
                        "height" to size.second,
                        "sourceWidth" to sourceW,
                        "sourceHeight" to sourceH
                    )
                } else {
                    mapOf("captured" to false, "reason" to reason)
                }
            )
        }
        try {
            val target = Bitmap.createBitmap(
                size.first,
                size.second,
                Bitmap.Config.ARGB_8888
            )
            bitmap = target
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // The View-source overload is API 26+ and minSdk is 23.
                PixelCopy.request(
                    webView,
                    target,
                    { copyResult ->
                        if (copyResult == PixelCopy.SUCCESS) {
                            reply(
                                WebViewCapture.encodePng(target),
                                "png encoding failed"
                            )
                        } else {
                            reply(null, "PixelCopy failed with code $copyResult")
                        }
                    },
                    Handler(Looper.getMainLooper())
                )
            } else {
                // Pre-26 fallback. A hardware-accelerated WebView frequently
                // draws blank through draw(Canvas); encodePng returning a real
                // bitmap is still the truthful best effort on those devices.
                webView.draw(Canvas(target))
                reply(WebViewCapture.encodePng(target), "png encoding failed")
            }
        } catch (error: Throwable) {
            reply(
                null,
                "capture threw ${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    private fun applySettings(settings: WebSettings, desktop: Boolean) {
        if (desktop) {
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = true
            settings.layoutAlgorithm = WebSettings.LayoutAlgorithm.NORMAL
        } else {
            settings.useWideViewPort = false
            settings.loadWithOverviewMode = true
            settings.layoutAlgorithm = WebSettings.LayoutAlgorithm.NARROW_COLUMNS
        }
        settings.setSupportMultipleWindows(true)
    }

    /**
     * Force the layout viewport size used for media queries (browser_resize
     * and desktop mode).
     *
     * Desktop mode pins `width=1280` so `window.innerWidth` reports a large
     * screen even when the page ships `width=device-width`. This MUST be a
     * document-start script: a post-load DOM mutation runs after the page's
     * own mobile-detection code and is wiped by every navigation, which is
     * exactly why sites kept showing "better on a large screen" after a link
     * click or reload. A null/0 width clears any previous force so a mobile
     * tab lays out at its own viewport meta again. The height rides the
     * feature shim (`window.innerHeight` / `screen.*` overrides) so height
     * probes report the forced size; a null height keeps the default 800.
     */
    private fun applyLogicalViewport(
        webView: WebView,
        logicalWidth: Int?,
        logicalHeight: Int?
    ) {
        val height = if (logicalHeight != null && logicalHeight > 0) {
            logicalHeight
        } else {
            800
        }
        // Mobile: drop any forced width so the page's own meta wins.
        if (logicalWidth == null || logicalWidth <= 0) {
            removeViewportScript(webView)
            try {
                webView.evaluateJavascript(clearViewportScript(), null)
            } catch (_: Throwable) {}
            return
        }
        // Already forcing this exact size — the document-start script
        // persists across navigations, so there is nothing to re-install.
        val existing = viewportHandlers[webView]
        if (existing != null && existing.first == logicalWidth &&
            existing.second == height
        ) return
        removeViewportScript(webView)

        val settings = webView.settings
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true

        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            try {
                val handler = WebViewCompat.addDocumentStartJavaScript(
                    webView,
                    viewportScript(logicalWidth),
                    setOf("*")
                )
                viewportHandlers[webView] = Triple(logicalWidth, height, handler)
                return
            } catch (_: Throwable) {
                // Fall through to the best-effort post-load path.
            }
        }
        try {
            webView.evaluateJavascript(viewportScript(logicalWidth), null)
        } catch (_: Throwable) {}
    }

    private fun removeViewportScript(webView: WebView) {
        val handler = viewportHandlers.remove(webView)?.third ?: return
        try {
            handler.remove()
        } catch (_: Throwable) {}
    }

    /**
     * Document-start script: runs before the page's own scripts, so detection
     * sees the wide layout from the first read. Re-asserts on DOMContentLoaded
     * and load because the parser can append the page's own viewport meta
     * AFTER document-start (last meta wins in Chromium). A MutationObserver
     * keeps the forcing alive when SPAs rewrite <head> later — the Dart-side
     * verifier only calls the native repair path when this script never ran.
     * Sets window.__ovidViewportW so the Dart verifier can confirm the script
     * executed in THIS document.
     */
    private fun viewportScript(width: Int): String = """
(function(){
  var W = $width;
  window.__ovidViewportW = W;
  function apply(){
    try {
      var head = document.head || document.documentElement;
      if (!head) return;
      var m = document.querySelector('meta[name=viewport]');
      if (!m) {
        m = document.createElement('meta');
        m.setAttribute('name', 'viewport');
        head.appendChild(m);
      }
      if (m.getAttribute('content') !== 'width=' + W) {
        m.setAttribute('content', 'width=' + W);
      }
    } catch (e) {}
  }
  apply();
  document.addEventListener('DOMContentLoaded', apply, {once: true});
  window.addEventListener('load', apply, {once: true});
  try {
    var mo = new MutationObserver(function(){ apply(); });
    var target = document.head || document.documentElement;
    if (target && !window.__ovidViewportObs) {
      window.__ovidViewportObs = true;
      mo.observe(target, {childList: true, subtree: true});
    }
  } catch (e) {}
})();
"""

    private fun clearViewportScript(): String = """
(function(){
  try {
    var m = document.querySelector('meta[name=viewport]');
    if (m) m.setAttribute('content', 'width=device-width, initial-scale=1');
  } catch (e) {}
})();
"""

    /**
     * Spoof the User-Agent Client Hints metadata, the signal `Sec-CH-UA-*`
     * request headers and `navigator.userAgentData` are generated from. Setting
     * only the UA string (done on the Dart side) leaves these reporting
     * Android/mobile, which is what most modern "use a desktop browser" gates
     * actually read. Unsupported WebView builds simply keep their defaults.
     */
    private fun applyUserAgentMetadata(webView: WebView, desktop: Boolean) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) {
            return
        }
        try {
            val metadata = if (desktop) desktopMetadata() else mobileMetadata()
            WebSettingsCompat.setUserAgentMetadata(webView.settings, metadata)
        } catch (_: Throwable) {
            // Older WebView: fall back to the UA string + shim alone.
        }
    }

    private fun desktopMetadata(): UserAgentMetadata = UserAgentMetadata.Builder()
        .setBrandVersionList(
            listOf(
                brandVersion("Chromium", "128", "128.0.6613.99"),
                brandVersion("Google Chrome", "128", "128.0.6613.99"),
                brandVersion("Not?A_Brand", "24", "24.0.0.0")
            )
        )
        .setFullVersion("128.0.6613.99")
        .setPlatform("Windows")
        .setPlatformVersion("10.0.0")
        .setArchitecture("x86")
        .setModel("")
        .setMobile(false)
        .setBitness(64)
        .setWow64(false)
        .build()

    private fun mobileMetadata(): UserAgentMetadata = UserAgentMetadata.Builder()
        .setBrandVersionList(
            listOf(
                brandVersion("Chromium", "128", "128.0.6613.99"),
                brandVersion("Google Chrome", "128", "128.0.6613.99"),
                brandVersion("Not?A_Brand", "24", "24.0.0.0")
            )
        )
        .setFullVersion("128.0.6613.99")
        .setPlatform("Android")
        .setPlatformVersion("14.0.0")
        .setArchitecture("")
        .setModel("")
        .setMobile(true)
        .setBitness(0)
        .setWow64(false)
        .build()

    private fun brandVersion(
        brand: String,
        majorVersion: String,
        fullVersion: String
    ): UserAgentMetadata.BrandVersion = UserAgentMetadata.BrandVersion.Builder()
        .setBrand(brand)
        .setMajorVersion(majorVersion)
        .setFullVersion(fullVersion)
        .build()

    /**
     * Install the desktop feature shim at document start (desktop tabs only),
     * generated from the forced [width]×[height] so `window.innerWidth`,
     * `window.innerHeight` and `screen.*` report the forced size instead of
     * hardcoded 1280×800. Runs before any page script, so detection
     * libraries see desktop values. Added once per WebView — document-start
     * scripts survive navigations; when the forced size changes
     * (browser_resize) the old script is removed and re-installed.
     *
     * When the WebView build has no document-start support (old System
     * WebView), falls back to an immediate evaluateJavascript so the live
     * document still gets the overrides; the Dart verifier repairs any
     * document the fallback missed.
     */
    private fun applyFeatureShim(
        webView: WebView,
        desktop: Boolean,
        width: Int?,
        height: Int?
    ) {
        if (!desktop) {
            removeFeatureShim(webView)
            return
        }
        val w = if (width != null && width > 0) width else 1280
        val h = if (height != null && height > 0) height else 800
        val existing = featureShimHandlers[webView]
        if (existing != null && existing.first == w && existing.second == h) {
            return
        }
        removeFeatureShim(webView)
        val script = desktopFeatureShim(w, h)
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            // No document-start support: best-effort immediate install on the
            // live document instead of silently leaving mobile signals in
            // place. The Dart-side verifier re-runs this on every page finish
            // until the layout width actually sticks.
            try {
                webView.evaluateJavascript(script, null)
            } catch (_: Throwable) {}
            return
        }
        try {
            val handler = WebViewCompat.addDocumentStartJavaScript(
                webView,
                script,
                setOf("*")
            )
            featureShimHandlers[webView] = Triple(w, h, handler)
        } catch (_: Throwable) {
            // Unsupported build: client hints + UA string still apply.
        }
    }

    private fun removeFeatureShim(webView: WebView) {
        val handler = featureShimHandlers.remove(webView)?.third ?: return
        try {
            handler.remove()
        } catch (_: Throwable) {}
    }
}

/**
 * Neutralizes the JS-level mobile signals that a spoofed UA string and
 * client hints do not cover: touch points, `navigator.platform`, the
 * `userAgentData` object, and coarse-pointer / no-hover media queries.
 * Generated from the forced [width]×[height] so `window.innerWidth`,
 * `window.innerHeight` and `screen.*` report the forced size the tab asked
 * for (desktop default 1280×800, or the `browser_resize` size) instead of
 * hardcoded constants. Property overrides are `configurable` and each
 * wrapped so a hostile page cannot break the shim itself. A file-level
 * function (not a companion static) keeps the handler free of global
 * mutable state.
 */
private fun desktopFeatureShim(width: Int, height: Int): String = """
(function(){
  window.__ovidDesktopShim = true;
  try {
    Object.defineProperty(navigator, 'maxTouchPoints', {
      get: function(){ return 0; }, configurable: true
    });
  } catch (e) {}
  try {
    Object.defineProperty(navigator, 'platform', {
      get: function(){ return 'Win32'; }, configurable: true
    });
  } catch (e) {}
  try {
    Object.defineProperty(navigator, 'userAgentData', {
      get: function(){
        return {
          mobile: false,
          platform: 'Windows',
          brands: [
            {brand: 'Chromium', version: '128'},
            {brand: 'Google Chrome', version: '128'},
            {brand: 'Not?A_Brand', version: '24'}
          ],
          getHighEntropyValues: function(){
            return Promise.resolve({
              platform: 'Windows',
              platformVersion: '10.0.0',
              architecture: 'x86',
              bitness: '64',
              mobile: false,
              model: ''
            });
          }
        };
      }, configurable: true
    });
  } catch (e) {}
  try {
    var originalMatchMedia = window.matchMedia.bind(window);
    window.matchMedia = function(query){
      var list = originalMatchMedia(query);
      try {
        var q = String(query);
        var wantFine = /\(\s*(any-)?pointer\s*:\s*fine\s*\)|\(\s*(any-)?hover\s*:\s*hover\s*\)/.test(q);
        var wantCoarse = /\(\s*(any-)?pointer\s*:\s*coarse\s*\)|\(\s*(any-)?hover\s*:\s*none\s*\)/.test(q);
        if (wantFine || wantCoarse) {
          Object.defineProperty(list, 'matches', {
            get: function(){ return wantFine; }, configurable: true
          });
        }
      } catch (e) {}
      return list;
    };
  } catch (e) {}
  try {
    Object.defineProperty(window, 'innerWidth', {
      get: function(){ return $width; }, configurable: true
    });
  } catch (e) {}
  try {
    Object.defineProperty(window, 'innerHeight', {
      get: function(){ return $height; }, configurable: true
    });
  } catch (e) {}
  try {
    Object.defineProperty(screen, 'width', {
      get: function(){ return $width; }, configurable: true
    });
  } catch (e) {}
  try {
    Object.defineProperty(screen, 'availWidth', {
      get: function(){ return $width; }, configurable: true
    });
  } catch (e) {}
  try {
    Object.defineProperty(screen, 'height', {
      get: function(){ return $height; }, configurable: true
    });
  } catch (e) {}
  try {
    Object.defineProperty(screen, 'availHeight', {
      get: function(){ return $height; }, configurable: true
    });
  } catch (e) {}
})();
"""


/**
 * Pure capture helpers, split out of [OvidWebViewHandler] so the downscale
 * geometry is unit-testable on the JVM — no device, Activity or real WebView.
 */
internal object WebViewCapture {
    /**
     * Long-edge cap for a capture when the caller does not send one.
     *
     * Lives here rather than as a class-level static on [OvidWebViewHandler]:
     * this file deliberately keeps NO such statics (per-tab browser state is
     * addressed by `webViewIdentifier`, never by process-global mutable fields),
     * and the capture geometry belongs with the capture helpers where the JVM
     * unit tests can reach it.
     */
    const val DEFAULT_CAPTURE_EDGE = 1280

    /** Hard ceiling, so a caller cannot ask for a multi-megapixel bitmap. */
    const val MAX_CAPTURE_EDGE = 4096

    /**
     * Downscale ([w], [h]) so the LONG edge is at most [maxEdge], preserving the
     * aspect ratio and never UPSCALING. Degenerate input collapses to 1x1 rather
     * than throwing, because [Bitmap.createBitmap] rejects a zero dimension.
     *
     * The downscale is not cosmetic: a 1440x3200 device shot is several MB of
     * base64 for a model that only needs to read the layout, and a vision part
     * rides along in the request envelope on every following turn.
     */
    fun scaledSize(w: Int, h: Int, maxEdge: Int): Pair<Int, Int> {
        if (w <= 0 || h <= 0) return Pair(1, 1)
        val long = w.coerceAtLeast(h)
        val edge = if (maxEdge > 0) maxEdge else long
        if (long <= edge) return Pair(w, h)
        val ratio = edge.toDouble() / long.toDouble()
        val scaledW = (w * ratio).roundToInt().coerceAtLeast(1)
        val scaledH = (h * ratio).roundToInt().coerceAtLeast(1)
        return Pair(scaledW, scaledH)
    }

    /** PNG-encode [bitmap] as unwrapped base64, or null when encoding fails. */
    fun encodePng(bitmap: Bitmap): String? {
        return try {
            val out = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) return null
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        } catch (_: Throwable) {
            null
        }
    }
}

/**
 * Cached device position for the browser's `navigator.geolocation` shim.
 *
 * Last-known ONLY, by design: [LocationManager.getLastKnownLocation] hands back
 * what the system already has, so serving a web page can never switch on GPS or
 * hold a radio awake. Permission is re-checked here as well as in Dart — Dart
 * owns the user-facing dialog, but a web page must never widen what Ovid itself
 * was granted, and this layer is the one JS cannot reach around.
 *
 * `Context.checkSelfPermission` is API 23+, which is this module's minSdk, so no
 * androidx.core dependency is pulled in just for this.
 */
internal object GeoFix {
    /** Providers asked for a cached fix, best-effort, in preference order. */
    private val providers = listOf(
        LocationManager.GPS_PROVIDER,
        LocationManager.NETWORK_PROVIDER,
        LocationManager.PASSIVE_PROVIDER
    )

    fun read(context: Context): Map<String, Any?> {
        val app = context.applicationContext
        val fine = app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = app.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (fine != PackageManager.PERMISSION_GRANTED &&
            coarse != PackageManager.PERMISSION_GRANTED
        ) {
            return mapOf("available" to false, "reason" to "permission")
        }
        val lm = try {
            app.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        } catch (_: Throwable) {
            null
        }
        if (lm == null) {
            return mapOf("available" to false, "reason" to "no location service")
        }
        val fixes = providers.map { provider ->
            try {
                lm.getLastKnownLocation(provider)
            } catch (_: Throwable) {
                // A provider can be missing (no SIM, no Google Play services) or
                // switched off; survivable while another one still answers.
                null
            }
        }
        val idx = newestIndex(fixes.map { it?.time })
        val fix = if (idx < 0) null else fixes[idx]
        if (fix == null) return mapOf("available" to false, "reason" to "no fix")
        return mapOf(
            "available" to true,
            "lat" to fix.latitude,
            "lon" to fix.longitude,
            "accuracy" to fix.accuracy.toDouble(),
            // Clamped: a device clock behind the fix timestamp (or a provider
            // stamping in the future) would otherwise report a negative age, and
            // the page shim subtracts this from Date.now().
            "ageMs" to (System.currentTimeMillis() - fix.time).coerceAtLeast(0L)
        )
    }

    /**
     * Index of the newest entry in [times] (epoch millis, null = that provider
     * had no fix), or -1 when none is usable.
     *
     * Split out because [read] needs a Context and a LocationManager, neither of
     * which exists on a unit-test JVM — and this is the part worth pinning:
     * picking the OLDEST fix would silently serve a stale position to a login
     * flow that is checking "is this device where the user says it is".
     */
    fun newestIndex(times: List<Long?>): Int {
        var best = -1
        var bestTime = Long.MIN_VALUE
        for (i in times.indices) {
            val t = times[i] ?: continue
            if (t > bestTime) {
                bestTime = t
                best = i
            }
        }
        return best
    }
}

