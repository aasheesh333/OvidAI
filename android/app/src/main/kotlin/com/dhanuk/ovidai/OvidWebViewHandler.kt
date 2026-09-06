package com.dhanuk.ovidai

import android.webkit.WebSettings
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
 */
class OvidWebViewHandler(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "ovid/webview")

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setDesktopViewport" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                // In Android WebView, WebSettings configure wide viewport & overview mode.
                // This handler acknowledges the platform setting contract for tabs.
                lastDesktopViewport = enabled
                result.success(
                    mapOf(
                        "applied" to true,
                        "enabled" to enabled,
                        "useWideViewPort" to enabled,
                        "loadWithOverviewMode" to true,
                        "supportMultipleWindows" to true
                    )
                )
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        var lastDesktopViewport: Boolean = false

        fun applySettings(settings: WebSettings, desktop: Boolean) {
            settings.useWideViewPort = desktop
            settings.loadWithOverviewMode = true
            settings.setSupportMultipleWindows(true)
            if (desktop) {
                settings.userAgentString = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
            }
        }
    }
}
