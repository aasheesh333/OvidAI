package com.dhanuk.ovidai

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.net.http.SslError
import android.os.Message
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.TextView
import androidx.webkit.ProfileStore
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayInputStream
import java.util.UUID

/** One isolated Android view per preview launch. Registration lives in
 * MainActivity's platform-view registry; no Ovid browser/profile is shared. */
class PreviewWebViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        PreviewPlatformView(
            context,
            PreviewPolicy.parse(args),
            MethodChannel(messenger, "ovid/studio-preview/$viewId"),
        )
}

internal enum class PreviewKind { STATIC, DEV_SERVER }

/** Parsed server launch metadata. The private upstream is never a parameter. */
internal data class PreviewPolicy(
    val previewId: String,
    val launchUrl: String,
    val kind: PreviewKind,
) {
    private val launch: Uri = Uri.parse(launchUrl)
    private val cleanPrefix = "/preview/${Uri.encode(previewId)}/"

    fun isCleanPreview(value: String?): Boolean {
        if (value == null) return false
        val uri = runCatching { Uri.parse(value) }.getOrNull() ?: return false
        return uri.toString() != launchUrl && allowed(uri, mainFrame = true, method = "GET") &&
            uri.scheme == "https"
    }

    fun allowed(uri: Uri, mainFrame: Boolean, method: String): Boolean {
        if (method != "GET" && method != "HEAD") return false
        if (uri.host.isNullOrBlank() || uri.host != launch.host) return false
        if (uri.port != -1 || !uri.userInfo.isNullOrEmpty()) return false
        val isHttps = uri.scheme == "https"
        val isDevSocket = kind == PreviewKind.DEV_SERVER && uri.scheme == "wss" && !mainFrame
        if (!isHttps && !isDevSocket) return false

        // The exchange is valid only as the exact main-frame launch. Subresources,
        // caller-provided URLs, and a different ticket never inherit that grant.
        if (mainFrame && method == "GET" && uri.toString() == launchUrl) return true
        val rawPath = uri.encodedPath ?: return false
        val path = runCatching { Uri.decode(rawPath) }.getOrNull() ?: return false
        if (!path.startsWith(cleanPrefix)) return false
        if (path.contains('\\') || path.contains('\u0000') || path.contains("//")) return false
        if (path.split('/').any { it == "." || it == ".." }) return false
        return true
    }

    companion object {
        private val idPattern = Regex("[A-Za-z0-9_-]{1,128}")

        fun parse(args: Any?): PreviewPolicy? {
            val map = args as? Map<*, *> ?: return null
            val previewId = map["previewId"] as? String ?: return null
            val launchUrl = map["launchUrl"] as? String ?: return null
            val kind = when (map["kind"] as? String) {
                "static" -> PreviewKind.STATIC
                "dev_server" -> PreviewKind.DEV_SERVER
                else -> return null
            }
            if (!idPattern.matches(previewId) || launchUrl.length > 4096) return null
            val uri = runCatching { Uri.parse(launchUrl) }.getOrNull() ?: return null
            val rawQuery = uri.encodedQuery ?: return null
            val ticket = runCatching { uri.getQueryParameter("ticket") }.getOrNull()
            if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.port != -1) return null
            if (!uri.userInfo.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) return null
            if (uri.encodedPath != "/preview/exchange") return null
            if (!rawQuery.startsWith("ticket=") || rawQuery.contains('&')) return null
            if (ticket.isNullOrEmpty() || ticket.length > 512) return null
            return PreviewPolicy(previewId, launchUrl, kind)
        }
    }
}

internal class PreviewPlatformView(
    context: Context,
    private val policy: PreviewPolicy?,
    private val lifecycle: MethodChannel?,
) : PlatformView {
    private val root = FrameLayout(context)
    private var webView: WebView? = null
    private var profileName: String? = null
    private var networkGuard: ScriptHandler? = null
    private var started = false
    private var disposed = false
    private var failed = false

    init {
        lifecycle?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startPreview" -> {
                    startPreview()
                    result.success(if (failed) mapOf("code" to "preview_load_failed") else null)
                }
                "disposePreview" -> {
                    disposePreview()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startPreview() {
        if (started || disposed) return
        started = true
        val launch = policy ?: run {
            fail("invalid_launch")
            return
        }
        try {
            // A dedicated cookie jar is mandatory. Falling back to Android's
            // process-global profile could expose Ovid or another preview's
            // cookies, so unsupported engines fail closed.
            check(WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE))
            val view = WebView(root.context)
            webView = view
            val profile = "ovid-preview-${UUID.randomUUID()}"
            WebViewCompat.setProfile(view, profile)
            profileName = profile
            val cookieManager = WebViewCompat.getProfile(view).cookieManager
            cookieManager.setAcceptCookie(true)
            cookieManager.setAcceptThirdPartyCookies(view, false)
            if (launch.kind == PreviewKind.DEV_SERVER) {
                // CSP does not cover every WebRTC/WebTransport stack. Dev
                // content gets JavaScript, but no side channel around the
                // same-preview native request policy; unsupported engines
                // fail closed instead of silently allowing that bypass.
                check(WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT))
                networkGuard = WebViewCompat.addDocumentStartJavaScript(view, """
                    for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection',
                        'mozRTCPeerConnection', 'RTCDataChannel', 'WebTransport']) {
                        Object.defineProperty(globalThis, name, {
                            value: undefined, writable: false, configurable: false
                        });
                    }
                """.trimIndent(), setOf("*"))
            }
            configure(view, launch)
            root.addView(view, FrameLayout.LayoutParams(-1, -1))
            // No headers map: neither Ovid Authorization nor an Ovid cookie can
            // enter this request. The exchange itself sets the scoped cookie.
            view.loadUrl(launch.launchUrl)
        } catch (_: Exception) {
            fail("unsupported_renderer")
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    private fun configure(view: WebView, launch: PreviewPolicy) {
        view.settings.apply {
            when (launch.kind) {
                PreviewKind.STATIC -> javaScriptEnabled = false
                PreviewKind.DEV_SERVER -> javaScriptEnabled = true
            }
            allowFileAccess = false
            allowContentAccess = false
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
            blockNetworkLoads = false
            blockNetworkImage = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            domStorageEnabled = launch.kind == PreviewKind.DEV_SERVER
            databaseEnabled = false
            setGeolocationEnabled(false)
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(true)
            mediaPlaybackRequiresUserGesture = true
            cacheMode = WebSettings.LOAD_NO_CACHE
            saveFormData = false
        }
        // Keep the explicit global-manager call as a defence on engines where
        // per-profile third-party cookie policy is inherited from the view.
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        for (name in listOf("searchBoxJavaBridge_", "accessibility", "accessibilityTraversal")) {
            view.removeJavascriptInterface(name)
        }
        view.setDownloadListener { _, _, _, _, _ -> }
        view.isLongClickable = false
        view.setOnLongClickListener { true }
        view.webViewClient = PreviewWebViewClient(launch, ::loaded, ::fail)
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) = request.deny()
            override fun onGeolocationPermissionsShowPrompt(
                origin: String,
                callback: GeolocationPermissions.Callback,
            ) = callback.invoke(origin, false, false)

            override fun onShowFileChooser(
                view: WebView,
                callback: ValueCallback<Array<Uri>>,
                params: FileChooserParams,
            ): Boolean {
                callback.onReceiveValue(null)
                return true
            }

            override fun onCreateWindow(
                view: WebView,
                dialog: Boolean,
                gesture: Boolean,
                result: Message,
            ) = false

            override fun onJsAlert(
                view: WebView,
                url: String,
                message: String,
                result: JsResult,
            ): Boolean {
                result.cancel()
                return true
            }

            override fun onJsConfirm(
                view: WebView,
                url: String,
                message: String,
                result: JsResult,
            ): Boolean {
                result.cancel()
                return true
            }

            override fun onJsPrompt(
                view: WebView,
                url: String,
                message: String,
                defaultValue: String,
                result: android.webkit.JsPromptResult,
            ): Boolean {
                result.cancel()
                return true
            }
        }
    }

    private fun loaded() {
        if (disposed || failed) return
        // The 303 exchange must not remain in WebView history with its ticket.
        webView?.clearHistory()
        lifecycle?.invokeMethod("loadComplete", null)
    }

    private fun fail(code: String) {
        if (disposed || failed) return
        failed = true
        disposeWebView()
        root.removeAllViews()
        root.addView(TextView(root.context).apply {
            text = "Preview unavailable."
            setPadding(24, 24, 24, 24)
        })
        lifecycle?.invokeMethod("loadError", mapOf("code" to code))
    }

    private fun disposeWebView() {
        val view = webView ?: return
        webView = null
        (view.parent as? ViewGroup)?.removeView(view)
        view.stopLoading()
        view.settings.javaScriptEnabled = false
        view.onPause()
        view.clearHistory()
        view.clearCache(true)
        view.removeAllViews()
        networkGuard?.remove()
        networkGuard = null
        view.destroy()
        profileName?.let { name ->
            // Delete only this view's profile and its scoped preview cookie.
            // Never clear the default profile or Ovid authentication state.
            try { ProfileStore.getInstance().deleteProfile(name) } catch (_: Exception) { }
        }
        profileName = null
    }

    private fun disposePreview() {
        if (disposed) return
        disposed = true
        disposeWebView()
        root.removeAllViews()
    }

    override fun getView(): View = root

    override fun dispose() {
        lifecycle?.setMethodCallHandler(null)
        disposePreview()
    }
}

@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
internal class PreviewWebViewClient(
    private val policy: PreviewPolicy,
    private val loaded: () -> Unit,
    private val failed: (String) -> Unit,
) : WebViewClient() {
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
        !policy.allowed(request.url, request.isForMainFrame, request.method)

    // No main-frame identity is available here, so legacy navigations fail closed.
    override fun shouldOverrideUrlLoading(view: WebView, url: String) = true

    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? = if (
        policy.allowed(request.url, request.isForMainFrame, request.method)
    ) null else denied()

    override fun shouldInterceptRequest(view: WebView, url: String) = denied()

    override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
        // Server redirects do not reliably pass through shouldOverrideUrlLoading.
        // Recheck every main-frame destination, including a redirected exchange.
        if (!policy.allowed(Uri.parse(url), mainFrame = true, method = "GET")) {
            view.stopLoading()
            failed("preview_denied")
        }
    }

    override fun onPageFinished(view: WebView, url: String) {
        if (policy.isCleanPreview(url)) loaded()
    }

    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        if (request.isForMainFrame) failed("preview_load_failed")
    }

    override fun onReceivedError(
        view: WebView,
        errorCode: Int,
        description: String,
        failingUrl: String,
    ) = failed("preview_load_failed")

    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        response: WebResourceResponse,
    ) {
        if (request.isForMainFrame) failed("preview_denied")
    }

    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
        handler.cancel()
        failed("preview_denied")
    }

    override fun onRenderProcessGone(
        view: WebView,
        detail: android.webkit.RenderProcessGoneDetail,
    ): Boolean {
        failed("renderer_gone")
        return true
    }

    private fun denied() = WebResourceResponse(
        "text/plain",
        "UTF-8",
        403,
        "Blocked",
        emptyMap(),
        ByteArrayInputStream(ByteArray(0)),
    )
}
