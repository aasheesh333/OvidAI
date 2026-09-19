package com.dhanuk.ovidai

import android.app.Activity
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
import java.util.WeakHashMap

/**
 * Handles WebView configuration requests across the ovid/webview method channel.
 *
 * Settings apply to exactly ONE native WebView, resolved from the
 * `webViewIdentifier` the Dart side passes (AndroidWebViewController
 * .webViewIdentifier). There is no global companion static and no decor-view
 * traversal: toggling one tab can never change another tab's viewport.
 *
 * Desktop: useWideViewPort(true), loadWithOverviewMode(false) — desktop layout
 * width without the overview auto-fit that shrinks readable content.
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
     * Document-start shim installed per WebView, keyed weakly so a discarded
     * tab cannot leak. The script persists across navigations, so it is added
     * once and only removed when the tab switches back to mobile.
     */
    private val featureShimHandlers = WeakHashMap<WebView, ScriptHandler>()

    /**
     * Forced-width viewport script per WebView, as (width, handler). A
     * document-start script applies to EVERY new document, so the desktop
     * layout survives navigation/reload — unlike a post-load DOM mutation,
     * which the fresh document wipes and which runs after the page's own
     * "is this mobile?" detection.
     */
    private val viewportHandlers = WeakHashMap<WebView, Pair<Int, ScriptHandler>>()

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
                    applyLogicalViewport(webView, logicalWidth)
                    applyUserAgentMetadata(webView, enabled)
                    applyFeatureShim(webView, enabled)
                    result.success(
                        mapOf(
                            "applied" to true,
                            "enabled" to enabled,
                            "tabId" to tabId,
                            "useWideViewPort" to enabled,
                            "loadWithOverviewMode" to !enabled,
                            "supportMultipleWindows" to true,
                            "logicalWidth" to logicalWidth
                        )
                    )
                }
            }
            else -> result.notImplemented()
        }
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

    private fun applySettings(settings: WebSettings, desktop: Boolean) {
        if (desktop) {
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = false
            settings.layoutAlgorithm = WebSettings.LayoutAlgorithm.NORMAL
        } else {
            settings.useWideViewPort = false
            settings.loadWithOverviewMode = true
            settings.layoutAlgorithm = WebSettings.LayoutAlgorithm.NARROW_COLUMNS
        }
        settings.setSupportMultipleWindows(true)
    }

    /**
     * Force the layout viewport width used for media queries (browser_resize
     * and desktop mode).
     *
     * Desktop mode pins `width=1280` so `window.innerWidth` reports a large
     * screen even when the page ships `width=device-width`. This MUST be a
     * document-start script: a post-load DOM mutation runs after the page's
     * own mobile-detection code and is wiped by every navigation, which is
     * exactly why sites kept showing "better on a large screen" after a link
     * click or reload. A null/0 width clears any previous force so a mobile
     * tab lays out at its own viewport meta again.
     */
    private fun applyLogicalViewport(webView: WebView, logicalWidth: Int?) {
        // Mobile: drop any forced width so the page's own meta wins.
        if (logicalWidth == null || logicalWidth <= 0) {
            removeViewportScript(webView)
            try {
                webView.evaluateJavascript(clearViewportScript(), null)
            } catch (_: Throwable) {}
            return
        }
        // Already forcing this exact width — the document-start script
        // persists across navigations, so there is nothing to re-install.
        val existing = viewportHandlers[webView]
        if (existing != null && existing.first == logicalWidth) return
        removeViewportScript(webView)

        val settings = webView.settings
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = false

        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            try {
                val handler = WebViewCompat.addDocumentStartJavaScript(
                    webView,
                    viewportScript(logicalWidth),
                    setOf("*")
                )
                viewportHandlers[webView] = logicalWidth to handler
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
        val handler = viewportHandlers.remove(webView)?.second ?: return
        try {
            handler.remove()
        } catch (_: Throwable) {}
    }

    /**
     * Document-start script: runs before the page's own scripts, so detection
     * sees the wide layout from the first read. Re-asserts on DOMContentLoaded
     * and load because the parser can append the page's own viewport meta
     * AFTER document-start (last meta wins in Chromium).
     */
    private fun viewportScript(width: Int): String = """
(function(){
  var W = $width;
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
     * Install the desktop feature shim at document start (desktop tabs only).
     * Runs before any page script, so detection libraries see desktop values.
     * Added once per WebView — document-start scripts survive navigations.
     */
    private fun applyFeatureShim(webView: WebView, desktop: Boolean) {
        if (!desktop) {
            removeFeatureShim(webView)
            return
        }
        if (featureShimHandlers.containsKey(webView)) return
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            return
        }
        try {
            val handler = WebViewCompat.addDocumentStartJavaScript(
                webView,
                DESKTOP_FEATURE_SHIM,
                setOf("*")
            )
            featureShimHandlers[webView] = handler
        } catch (_: Throwable) {
            // Unsupported build: client hints + UA string still apply.
        }
    }

    private fun removeFeatureShim(webView: WebView) {
        val handler = featureShimHandlers.remove(webView) ?: return
        try {
            handler.remove()
        } catch (_: Throwable) {}
    }
}

/**
 * Neutralizes the JS-level mobile signals that a spoofed UA string and
 * client hints do not cover: touch points, `navigator.platform`, the
 * `userAgentData` object, and coarse-pointer / no-hover media queries.
 * Property overrides are `configurable` and each wrapped so a hostile
 * page cannot break the shim itself. A file-level const (not a companion
 * static) keeps the handler free of global mutable state.
 */
private const val DESKTOP_FEATURE_SHIM = """
(function(){
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
})();
"""

