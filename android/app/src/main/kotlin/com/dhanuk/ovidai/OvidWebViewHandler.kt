package com.dhanuk.ovidai

import android.app.Activity
import android.webkit.WebSettings
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

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
 * Mobile: platform defaults (useWideViewPort(false), loadWithOverviewMode(true)).
 */
class OvidWebViewHandler(
    private var activity: Activity? = null,
    private val flutterEngine: FlutterEngine? = null,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "ovid/webview")

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
                val identifier = call.argument<Number>("webViewIdentifier")?.toLong()
                val webView = resolveWebView(identifier)
                val act = activity
                if (webView == null || act == null) {
                    result.success(mapOf("applied" to false, "enabled" to enabled))
                    return
                }
                act.runOnUiThread {
                    applySettings(webView.settings, enabled)
                    result.success(
                        mapOf(
                            "applied" to true,
                            "enabled" to enabled,
                            "useWideViewPort" to enabled,
                            "loadWithOverviewMode" to !enabled,
                            "supportMultipleWindows" to true
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
}
