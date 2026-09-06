package com.dhanuk.ovidai

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebSettings
import android.webkit.WebView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles WebView configuration requests across the ovid/webview method channel.
 *
 * Configures real desktop layout viewport semantics on Android WebView:
 *  - setUseWideViewPort(true): viewport meta tag support and 1280 layout viewport
 *  - setLoadWithOverviewMode(true): zoom out page to fit layout viewport
 *  - setSupportMultipleWindows(true): popup/window.open parity
 *  - layoutAlgorithm: NORMAL (desktop) vs NARROW_COLUMNS (mobile)
 */
class OvidWebViewHandler(
    private var activity: Activity? = null,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "ovid/webview")

    constructor(messenger: BinaryMessenger) : this(null, messenger)

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
                desktopEnabled = enabled
                lastDesktopViewport = enabled

                val act = activity
                if (act != null) {
                    act.runOnUiThread {
                        val decorView = act.window?.decorView as? ViewGroup
                        if (decorView != null) {
                            traverseAndApply(decorView, enabled)
                        }
                    }
                }

                result.success(
                    mapOf(
                        "applied" to true,
                        "enabled" to enabled,
                        "useWideViewPort" to enabled,
                        "loadWithOverviewMode" to enabled,
                        "supportMultipleWindows" to enabled
                    )
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun traverseAndApply(view: View, enabled: Boolean) {
        if (view is WebView) {
            applyToWebView(view, enabled)
        } else if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                traverseAndApply(view.getChildAt(i), enabled)
            }
        }
    }

    companion object {
        var desktopEnabled: Boolean = false

        var lastDesktopViewport: Boolean
            get() = desktopEnabled
            set(value) {
                desktopEnabled = value
            }

        private var WebSettings.supportMultipleWindows: Boolean
            get() = supportMultipleWindows()
            set(value) {
                setSupportMultipleWindows(value)
            }

        fun applyToWebView(webView: WebView, enabled: Boolean = desktopEnabled) {
            val settings = webView.settings
            settings.useWideViewPort = enabled
            settings.loadWithOverviewMode = enabled
            settings.supportMultipleWindows = enabled
            settings.layoutAlgorithm = if (enabled) {
                WebSettings.LayoutAlgorithm.NORMAL
            } else {
                WebSettings.LayoutAlgorithm.NARROW_COLUMNS
            }
        }

        fun applySettings(settings: WebSettings, desktop: Boolean) {
            settings.useWideViewPort = desktop
            settings.loadWithOverviewMode = desktop
            settings.supportMultipleWindows = desktop
            settings.layoutAlgorithm = if (desktop) {
                WebSettings.LayoutAlgorithm.NORMAL
            } else {
                WebSettings.LayoutAlgorithm.NARROW_COLUMNS
            }
            if (desktop) {
                settings.userAgentString =
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
            }
        }
    }
}
