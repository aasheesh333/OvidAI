package com.dhanuk.ovidai

import android.annotation.SuppressLint
import android.content.Context
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
import android.webkit.WebResourceRequest
import android.webkit.WebResourceError
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
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayInputStream
import java.util.UUID

/** Separate from OvidWebViewHandler: no registration in the browser controller
 * registry, no Ovid native/JS channel, no shared-profile switching/clearing.
 * Android's cookie manager is process-global on older WebViews, so use an
 * opaque loadData origin and sandboxed srcdoc (no allow-same-origin), with
 * network blocked at both CSP and native boundaries. Never clear auth cookies.
 */
class HtmlArtifactViewFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        HtmlArtifactPlatformView(context, HtmlArtifactPolicy.document(args),
            MethodChannel(messenger, "ovid/html-artifact/$viewId"))
}

internal class HtmlArtifactPlatformView(context: Context, document: String?, private val lifecycle: MethodChannel? = null) : PlatformView {
    private val root = FrameLayout(context)
    private var webView: WebView? = null
    private var profileName: String? = null
    private var networkGuard: ScriptHandler? = null
    private var pendingDocument = document
    private var started = false
    private var disposed = false
    private var failure: Map<String, Any>? = null
    private var bootstrap: HtmlArtifactPolicy.Bootstrap? = null

    init {
        // Flutter-host-only lifecycle control; never injected into JavaScript.
        // startDocument starts only the immutable creation parameter, once.
        // Subscription precedes startup, so synchronous failure cannot be lost.
        lifecycle?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDocument" -> { startDocument(); result.success(failure) }
                "disposeDocument" -> { disposeDocument(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        if (lifecycle == null) startDocument()
    }

    private fun startDocument() {
        if (started || disposed) return
        started = true
        val document = pendingDocument
        pendingDocument = null
        if (document == null) {
            fail(mapOf("code" to "invalid_document"))
        } else {
            try {
                val view = WebView(root.context)
                webView = view
                // WebRTC can use sockets outside CSP's connect-src. Install a
                // non-replaceable guard in EVERY frame before any page script.
                // Older engines without this hook fail closed to source view.
                check(WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT))
                if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                    val name = "ovid-artifact-${UUID.randomUUID()}"
                    WebViewCompat.setProfile(view, name)
                    profileName = name
                    WebViewCompat.getProfile(view).cookieManager.setAcceptCookie(false)
                }
                networkGuard = WebViewCompat.addDocumentStartJavaScript(view, """
                    for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection',
                        'mozRTCPeerConnection', 'RTCDataChannel', 'WebTransport']) {
                        Object.defineProperty(globalThis, name, {
                            value: undefined, writable: false, configurable: false
                        });
                    }
                """.trimIndent(), setOf("*"))
                // loadData uses an opaque data: origin, not an HTTPS base URL.
                // Base64 also prevents fragment/%/encoding truncation.
                val encoded = android.util.Base64.encodeToString(
                    document.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP,
                )
                bootstrap = HtmlArtifactPolicy.Bootstrap("data:text/html;base64,$encoded")
                configure(view)
                root.addView(view, FrameLayout.LayoutParams(-1, -1))
                view.loadData(encoded, "text/html", "base64")
            } catch (_: Exception) {
                fail(mapOf("code" to "unsupported_renderer"))
            }
        }
    }

    private fun fail(error: Map<String, Any>) {
        if (disposed || failure != null) return
        failure = error
        disposeWebView()
        fallback("Artifact preview unavailable. Retry or use View source.")
        lifecycle?.invokeMethod("loadError", error)
    }

    private fun disposeDocument() {
        disposed = true
        pendingDocument = null
        disposeWebView()
    }

    private fun fallback(message: String) {
        root.removeAllViews()
        root.addView(TextView(root.context).apply {
            text = message
            setPadding(24, 24, 24, 24)
        })
    }

    @SuppressLint("SetJavaScriptEnabled")
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    private fun configure(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
            blockNetworkLoads = true
            blockNetworkImage = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            domStorageEnabled = false
            databaseEnabled = false
            setGeolocationEnabled(false)
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(true) // onCreateWindow always refuses.
            mediaPlaybackRequiresUserGesture = true
            cacheMode = WebSettings.LOAD_NO_CACHE
            saveFormData = false
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        // Remove the legacy system interfaces too; never addJavascriptInterface.
        for (name in listOf("searchBoxJavaBridge_", "accessibility", "accessibilityTraversal")) {
            view.removeJavascriptInterface(name)
        }
        view.setDownloadListener { _, _, _, _, _ -> /* downloads denied */ }
        view.isLongClickable = false
        view.setOnLongClickListener { true } // no link/image external-open menu
        view.webViewClient = HtmlArtifactWebViewClient(checkNotNull(bootstrap), ::fail)
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) = request.deny()
            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) {
                callback.invoke(origin, false, false)
            }
            override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<android.net.Uri>>, params: FileChooserParams): Boolean {
                callback.onReceiveValue(null)
                return true
            }
            override fun onCreateWindow(view: WebView, dialog: Boolean, gesture: Boolean, result: Message) = false
            override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
                result.cancel()
                return true
            }
            override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean {
                result.cancel()
                return true
            }
            override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String, result: android.webkit.JsPromptResult): Boolean {
                result.cancel()
                return true
            }
        }
    }

    private fun disposeWebView() {
        bootstrap?.finish()
        val view = webView ?: return
        webView = null
        (view.parent as? ViewGroup)?.removeView(view)
        view.stopLoading()
        view.settings.javaScriptEnabled = false
        view.onPause()
        view.removeAllViews()
        networkGuard?.remove()
        networkGuard = null
        view.destroy()
        profileName?.let { name ->
            // The only profile deleted here was created for this view. Never
            // clear the default/browser profile or its authentication cookies.
            try { ProfileStore.getInstance().deleteProfile(name) } catch (_: Exception) { }
        }
        profileName = null
    }

    override fun getView(): View = root
    override fun dispose() {
        lifecycle?.setMethodCallHandler(null)
        disposeDocument()
    }
}

/** WebViewClient documents that data: may reach interception. This conditional
 * compatibility gate is not evidence that a particular engine intercepts the
 * root loadData URL. All network/file/content requests and navigations fail closed.
 */
@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
internal class HtmlArtifactWebViewClient(
    private val bootstrap: HtmlArtifactPolicy.Bootstrap,
    private val failure: (Map<String, Any>) -> Unit,
) : WebViewClient() {
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
    override fun shouldOverrideUrlLoading(view: WebView, url: String) = true
    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
        if (bootstrap.allow(request.url.toString(), request.isForMainFrame, request.method)) null else denied()
    // No frame identity on the legacy callback: never grant a document exception.
    override fun shouldInterceptRequest(view: WebView, url: String) = denied()
    override fun onPageFinished(view: WebView, url: String) { bootstrap.finish() }
    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
        if (request.isForMainFrame) failure(mapOf("code" to "main_frame_load", "errorCode" to error.errorCode))
    }
    override fun onReceivedError(view: WebView, errorCode: Int, description: String, failingUrl: String) {
        failure(mapOf("code" to "main_frame_load", "errorCode" to errorCode))
    }
    override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
        if (request.isForMainFrame) failure(mapOf("code" to "main_frame_http", "status" to response.statusCode))
    }
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) { handler.cancel() }
    override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
        failure(mapOf("code" to "renderer_gone"))
        return true
    }
    private fun denied() = WebResourceResponse(
        "text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)),
    )
}
