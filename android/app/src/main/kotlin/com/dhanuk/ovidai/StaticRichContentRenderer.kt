package com.dhanuk.ovidai

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.view.View
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
import androidx.webkit.ProfileStore
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.StringReader
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Offscreen static-pixel renderer. It is a FlutterPlugin so the host can
 * register it without putting any rich document in an AndroidView. Nothing in
 * this class adds a Javascript interface or accepts an Ovid credential.
 */
class StaticRichContentRenderer : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private val sessions = mutableMapOf<String, RenderSession>()
    private val cancelledRequestIds = mutableSetOf<String>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        sessions.values.toList().forEach { it.cancel("detached") }
        sessions.clear()
        cancelledRequestIds.clear()
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val appContext = context
        if (appContext == null) {
            result.error("detached", "Static renderer is unavailable", null)
            return
        }
        if (call.method == "cancelRenderPng") {
            handleCancellation(call, result)
            return
        }
        val kind = when (call.method) {
            "renderMermaidPng" -> RenderKind.MERMAID
            "renderSvgPng" -> RenderKind.SVG
            else -> {
                result.notImplemented()
                return
            }
        }
        val key = if (kind == RenderKind.MERMAID) "source" else "svg"
        val source = call.argument<String>(key)
        val requestId = call.argument<String>("requestId")
            ?.takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
        val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 15_000L)
            .coerceIn(1L, 20_000L)
        val maximum = if (kind == RenderKind.MERMAID) 256 * 1024 else 1024 * 1024
        if (source.isNullOrBlank() || source.length > maximum ||
            sessions.containsKey(requestId) || cancelledRequestIds.contains(requestId)
        ) {
            result.error("invalid_input", "Static input is invalid", null)
            return
        }
        val start: () -> Unit = {
            if (!cancelledRequestIds.remove(requestId) && !sessions.containsKey(requestId)) {
                try {
                    val safe = if (kind == RenderKind.SVG) StaticSvgPolicy.checked(source) else source
                    RenderSession(appContext, requestId, kind, safe, timeoutMs, result).also {
                        sessions[requestId] = it
                        it.start()
                    }
                } catch (_: Exception) {
                    result.error("invalid_input", "Static input is invalid", null)
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) start() else {
            Handler(Looper.getMainLooper()).post(start)
        }
    }

    /** Binding-free cancellation boundary, so every reply can be tested with
     * the production MethodCall/Result shape without starting FlutterJNI. */
    internal fun handleCancellation(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("requestId")
        if (id.isNullOrBlank()) {
            result.error("invalid_input", "A render request id is required", null)
            return
        }
        result.success(acknowledgeCancellation(id))
    }

    /** Cancellation always replies with a boolean outcome, never PNG bytes.
     * Unknown/already-completed ids are fenced too, making cancellation safe
     * to repeat after a timeout, disposal or a completed render. */
    private fun acknowledgeCancellation(id: String): Boolean {
        cancelledRequestIds.add(id)
        while (cancelledRequestIds.size > 64) {
            cancelledRequestIds.remove(cancelledRequestIds.first())
        }
        sessions.remove(id)?.cancel("cancelled")
        return true
    }

    private enum class RenderKind { MERMAID, SVG }

    /** One disposable profile/WebView per render. No profile is ever shared. */
    private inner class RenderSession(
        private val appContext: Context,
        private val requestId: String,
        private val kind: RenderKind,
        private val source: String,
        private val timeoutMs: Long,
        private val result: MethodChannel.Result,
    ) {
        private val handler = Handler(Looper.getMainLooper())
        private var view: WebView? = null
        private var profileName: String? = null
        private var networkGuard: ScriptHandler? = null
        private var bootstrapUrl: String? = null
        private var completion: StaticRenderCompletion? = null
        private var completed = false
        private var pageStarted = false

        private val timeout = Runnable { fail("timeout") }

        fun start() {
            if (completed) return
            handler.postDelayed(timeout, timeoutMs)
            try {
                val mermaid = if (kind == RenderKind.MERMAID) {
                    appContext.assets.open("flutter_assets/$MERMAID_ASSET")
                        .bufferedReader().use { it.readText() }
                } else {
                    ""
                }
                val document = staticDocument(mermaid)
                val encoded = android.util.Base64.encodeToString(
                    document.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP,
                )
                bootstrapUrl = "data:text/html;base64,$encoded"

                val webView = WebView(appContext)
                view = webView
                check(WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT))
                check(WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE))
                val profile = "ovid-static-${UUID.randomUUID()}"
                profileName = profile
                WebViewCompat.setProfile(webView, profile)
                WebViewCompat.getProfile(webView).cookieManager.setAcceptCookie(false)
                networkGuard = WebViewCompat.addDocumentStartJavaScript(
                    webView, NETWORK_DENIAL_SCRIPT, setOf("*"),
                )
                configure(webView)
                webView.loadData(encoded, "text/html", "base64")
            } catch (_: Exception) {
                fail("unsupported_renderer")
            }
        }

        @SuppressLint("SetJavaScriptEnabled")
        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        private fun configure(webView: WebView) {
            webView.settings.apply {
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
                setSupportMultipleWindows(false)
                mediaPlaybackRequiresUserGesture = true
                cacheMode = WebSettings.LOAD_NO_CACHE
                saveFormData = false
            }
            CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false)
            for (name in listOf("searchBoxJavaBridge_", "accessibility", "accessibilityTraversal")) {
                webView.removeJavascriptInterface(name)
            }
            webView.setDownloadListener { _, _, _, _, _ -> }
            webView.isLongClickable = false
            webView.isFocusable = false
            webView.isFocusableInTouchMode = false
            webView.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            webView.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
                override fun shouldOverrideUrlLoading(view: WebView, url: String) = true

                override fun shouldInterceptRequest(
                    view: WebView,
                    request: WebResourceRequest,
                ): WebResourceResponse? {
                    val root = request.isForMainFrame && request.method == "GET" &&
                        request.url.toString() == bootstrapUrl
                    return if (root) null else denied()
                }

                override fun shouldInterceptRequest(view: WebView, url: String) = denied()

                override fun onPageFinished(view: WebView, url: String) {
                    if (url == bootstrapUrl && !pageStarted && !completed) {
                        pageStarted = true
                        render(view)
                    }
                }

                override fun onReceivedError(
                    view: WebView,
                    request: WebResourceRequest,
                    error: WebResourceError,
                ) {
                    if (request.isForMainFrame) fail("main_frame_load")
                }

                override fun onReceivedError(
                    view: WebView,
                    errorCode: Int,
                    description: String,
                    failingUrl: String,
                ) = fail("main_frame_load")

                override fun onReceivedHttpError(
                    view: WebView,
                    request: WebResourceRequest,
                    response: WebResourceResponse,
                ) {
                    if (request.isForMainFrame) fail("main_frame_http")
                }

                override fun onReceivedSslError(
                    view: WebView,
                    handler: SslErrorHandler,
                    error: SslError,
                ) = handler.cancel()

                override fun onRenderProcessGone(
                    view: WebView,
                    detail: android.webkit.RenderProcessGoneDetail,
                ): Boolean {
                    fail("renderer_gone")
                    return true
                }
            }
            webView.webChromeClient = object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest) = request.deny()

                override fun onGeolocationPermissionsShowPrompt(
                    origin: String,
                    callback: GeolocationPermissions.Callback,
                ) = callback.invoke(origin, false, false)

                override fun onShowFileChooser(
                    view: WebView,
                    callback: ValueCallback<Array<android.net.Uri>>,
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
            }
        }

        private fun render(webView: WebView) {
            if (completed || completion != null) return
            val quoted = JSONObject.quote(source)
            val function = if (kind == RenderKind.MERMAID) {
                "ovidRenderMermaid"
            } else {
                "ovidShowSvg"
            }
            completion = StaticRenderCompletion(
                evaluate = { script, callback ->
                    val activeView = view
                    if (completed || activeView == null) {
                        callback(null)
                    } else {
                        activeView.evaluateJavascript(script, callback)
                    }
                },
                schedule = { delay, task ->
                    if (!completed) handler.postDelayed(task, delay)
                },
                onDimensions = { width, height ->
                    val activeView = view
                    if (!completed && activeView != null) {
                        capture(activeView, width, height)
                    }
                },
                onError = ::fail,
            ).also { it.start("window.$function($quoted)") }
        }

        private fun capture(webView: WebView, width: Double, height: Double) {
            val scale = min(
                1.0,
                min(
                    min(4096.0 / width, 4096.0 / height),
                    sqrt(8_000_000.0 / (width * height)),
                ),
            )
            val cssWidth = ceil(width).toInt()
            val cssHeight = ceil(height).toInt()
            val pixelWidth = (width * scale).roundToInt().coerceAtLeast(1)
            val pixelHeight = (height * scale).roundToInt().coerceAtLeast(1)
            webView.measure(
                View.MeasureSpec.makeMeasureSpec(cssWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(cssHeight, View.MeasureSpec.EXACTLY),
            )
            webView.layout(0, 0, cssWidth, cssHeight)
            val bitmap = Bitmap.createBitmap(pixelWidth, pixelHeight, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.scale(scale.toFloat(), scale.toFloat())
            webView.draw(canvas)
            val output = ByteArrayOutputStream()
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            bitmap.recycle()
            finish(output.toByteArray())
        }

        fun fail(code: String) {
            if (completed) return
            completed = true
            cleanup()
            result.error(code, "Static content could not be rendered", null)
        }

        fun cancel(code: String = "cancelled") {
            if (completed) return
            completed = true
            completion?.cancel()
            cleanup()
            result.error(code, "Static content could not be rendered", null)
        }

        private fun finish(bytes: ByteArray) {
            if (completed) return
            completed = true
            cleanup()
            result.success(bytes)
        }

        private fun cleanup() {
            handler.removeCallbacks(timeout)
            completion?.dispose()
            completion = null
            if (sessions[requestId] === this) sessions.remove(requestId)
            val webView = view ?: return
            view = null
            webView.stopLoading()
            webView.settings.javaScriptEnabled = false
            webView.removeAllViews()
            networkGuard?.remove()
            networkGuard = null
            webView.destroy()
            profileName?.let {
                // Delete only this render's fresh profile. Never clear or read
                // the default profile's cookies/credentials.
                try { ProfileStore.getInstance().deleteProfile(it) } catch (_: Exception) { }
            }
            profileName = null
        }
    }

    companion object {
        private const val CHANNEL = "ovid/static-rich-content"
        private const val MERMAID_ASSET = "assets/vendor/mermaid.min.js"

        private fun denied() = WebResourceResponse(
            "text/plain", "UTF-8", 403, "Blocked", emptyMap(),
            ByteArrayInputStream(ByteArray(0)),
        )

        private fun staticDocument(mermaid: String): String {
            // A literal closing-script sequence in a vendored bundle must not
            // terminate the inline script element.
            val library = mermaid.replace(Regex("(?i)</script"), "<\\/script")
            return """<!doctype html><html><head><meta charset="utf-8">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'; sandbox allow-scripts">
                <style>html,body{margin:0;padding:0;background:transparent}#stage{display:inline-block}</style>
                <script>$library</script></head><body><div id="stage"></div>
                <script>
                (() => {
                  const forbidden = new Set(['script','foreignobject','iframe','object','embed','link','meta','handler','animate','animatemotion','animatetransform','set','a','audio','video']);
                  const normalize = value => String(value).replace(/\/\*[\s\S]*?\*\//g, '').toLowerCase().replace(/[\u0000-\u0020\u007f]+/g, '');
                  const safeReference = value => {
                    const v = normalize(value);
                    return /^#[a-z0-9_.:-]+$/.test(v) || /^data:image\/(png|jpeg|gif|webp);base64,[a-z0-9+/]+={0,2}$/.test(v);
                  };
                  const unsafeCss = value => {
                    const v = normalize(value);
                    if (/@(?:-[a-z]+-)?keyframes/.test(v) || /(?:^|[;{])(?:-[a-z]+-)?(?:animation|transition)(?:-[a-z]+)?:/.test(v)) return true;
                    if (v.includes('\\') || /@import|expression\(|javascript:|data:text|data:image\/svg|https:|http:|file:|content:/.test(v)) return true;
                    const withoutLocal = v.replace(/url\((?:'|")?#[a-z0-9_.:-]+(?:'|")?\)/g, '');
                    return withoutLocal.includes('url(');
                  };
                  const validate = source => {
                    const doc = new DOMParser().parseFromString(source, 'image/svg+xml');
                    const root = doc.documentElement;
                    if (!root || root.localName.toLowerCase() !== 'svg' || doc.querySelector('parsererror')) throw new Error('invalid');
                    for (const element of [root, ...root.querySelectorAll('*')]) {
                      if (forbidden.has(element.localName.toLowerCase()) || element.prefix) throw new Error('invalid');
                      for (const attribute of element.attributes) {
                        const name = attribute.name.toLowerCase();
                        if (name.startsWith('on') || unsafeCss(attribute.value)) throw new Error('invalid');
                        if (/(^|:)(href|src|data|poster|action|formaction)$/.test(name) && !safeReference(attribute.value)) throw new Error('invalid');
                        if (name === 'xmlns' && attribute.value !== 'http://www.w3.org/2000/svg') throw new Error('invalid');
                        if (name === 'xmlns:xlink' && attribute.value !== 'http://www.w3.org/1999/xlink') throw new Error('invalid');
                      }
                      if (element.localName.toLowerCase() === 'style' && unsafeCss(element.textContent)) throw new Error('invalid');
                    }
                    return root;
                  };
                  const show = source => {
                    const parsed = validate(source);
                    const stage = document.getElementById('stage');
                    stage.replaceChildren(document.importNode(parsed, true));
                    const svg = stage.firstElementChild;
                    const box = svg.getBBox();
                    const width = Math.ceil(Math.max(1, box.width));
                    const height = Math.ceil(Math.max(1, box.height));
                    if (width > 16384 || height > 16384) return [-1,-1];
                    svg.setAttribute('viewBox', box.x + ' ' + box.y + ' ' + Math.max(1,box.width) + ' ' + Math.max(1,box.height));
                    svg.setAttribute('width', String(width));
                    svg.setAttribute('height', String(height));
                    svg.style.maxWidth = 'none';
                    return [width,height];
                  };
                  window.ovidShowSvg = source => { try { return show(source); } catch (_) { return [-1,-1]; } };
                  window.ovidRenderMermaid = async source => {
                    try {
                      if (typeof mermaid === 'undefined') return [-1,-1];
                      mermaid.initialize({startOnLoad:false,securityLevel:'strict',deterministicIds:true,deterministicIDSeed:'ovid-static',suppressErrorRendering:true,flowchart:{htmlLabels:false},maxTextSize:100000});
                      await mermaid.parse(source);
                      const rendered = await mermaid.render('ovidStatic', source);
                      return show(rendered.svg);
                    } catch (_) { return [-1,-1]; }
                  };
                })();
                </script></body></html>""".trimIndent()
        }

        private const val NETWORK_DENIAL_SCRIPT = """
            for (const name of ['fetch','XMLHttpRequest','WebSocket','EventSource',
                'RTCPeerConnection','webkitRTCPeerConnection','mozRTCPeerConnection',
                'RTCDataChannel','WebTransport']) {
                try { Object.defineProperty(globalThis, name, {
                    value: undefined, writable: false, configurable: false
                }); } catch (_) { }
            }
            try { if (navigator) navigator.sendBeacon = () => false; } catch (_) { }
        """
    }
}

/**
 * One-shot completion coordinator for synchronous and Promise-based rendering.
 * evaluateJavascript observes only an immediate start/inspection result; an
 * eventual Mermaid Promise is explicitly stored, polled, and handed to pixels.
 */
internal class StaticRenderCompletion(
    private val evaluate: (String, (String?) -> Unit) -> Unit,
    private val schedule: (Long, () -> Unit) -> Unit,
    private val onDimensions: (Double, Double) -> Unit,
    private val onError: (String) -> Unit,
) {
    private var disposed = false
    private var settled = false

    fun start(request: String) {
        if (disposed || settled) return
        schedule(15_000L) {
            if (!disposed && !settled) {
                disposed = true
                onError("timeout")
            }
        }
        evaluate(
            "Promise.resolve($request).then(value => {" +
                "window.ovidStaticCompletion=value;" +
            "}).catch(error => {" +
                "window.ovidStaticCompletion={error:String(error && error.message || error)};" +
            "});window.ovidStaticStarted;",
        ) {
            if (!disposed) poll()
        }
    }

    private fun poll() {
        if (disposed || settled) return
        evaluate(
            "typeof window.ovidStaticCompletion === 'undefined' ? null : window.ovidStaticCompletion;",
        ) { raw ->
            if (disposed || settled) return@evaluate
            when (raw) {
                null, "null", "undefined" -> schedule(10L) { poll() }
                else -> complete(raw)
            }
        }
    }

    private fun complete(raw: String) {
        if (disposed || settled) return
        try {
            val value = JSONArray(raw)
            check(value.length() == 2)
            val width = value.getDouble(0)
            val height = value.getDouble(1)
            check(width > 0 && height > 0 && width <= 16_384 && height <= 16_384)
            settled = true
            disposed = true
            onDimensions(width, height)
        } catch (_: Exception) {
            if (!disposed) {
                disposed = true
                onError("render_failed")
            }
        }
    }

    fun cancel() {
        if (disposed) return
        disposed = true
        onError("cancelled")
    }

    fun dispose() {
        disposed = true
    }
}

/** Native repeat of the Dart fence: no other channel client can bypass it. */
internal object StaticSvgPolicy {
    private const val SVG_NS = "http://www.w3.org/2000/svg"
    private val elements = setOf(
        "svg", "g", "defs", "symbol", "use", "path", "rect", "circle",
        "ellipse", "line", "polyline", "polygon", "text", "tspan", "textPath",
        "title", "desc", "style", "clipPath", "mask", "pattern", "marker",
        "linearGradient", "radialGradient", "stop", "image",
    )
    private val urlAttributes = setOf("href", "src", "data", "poster", "action", "formaction")

    fun checked(source: String): String {
        if (source.contains("<?") || Regex("<!\\s*(DOCTYPE|ENTITY)", RegexOption.IGNORE_CASE).containsMatchIn(source)) {
            throw IllegalArgumentException("active declaration")
        }
        val parser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
        parser.setInput(StringReader(source))
        var rootSeen = false
        var styleDepth = 0
        val style = StringBuilder()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.DOCDECL, XmlPullParser.PROCESSING_INSTRUCTION ->
                    throw IllegalArgumentException("active declaration")
                XmlPullParser.START_TAG -> {
                    val name = parser.name
                    if (!rootSeen && name != "svg") throw IllegalArgumentException("not svg")
                    rootSeen = true
                    if (!parser.prefix.isNullOrEmpty() || name !in elements) {
                        throw IllegalArgumentException("active element")
                    }
                    for (index in 0 until parser.attributeCount) {
                        val attribute = parser.getAttributeName(index)
                        val lower = attribute.lowercase()
                        val value = parser.getAttributeValue(index)
                        if (!parser.getAttributePrefix(index).isNullOrEmpty() || lower.startsWith("on")) {
                            throw IllegalArgumentException("active attribute")
                        }
                        if (lower == "xmlns" && value != SVG_NS) {
                            throw IllegalArgumentException("foreign namespace")
                        }
                        if (lower in urlAttributes && !safeReference(value)) {
                            throw IllegalArgumentException("external reference")
                        }
                        if (lower == "style" &&
                            (value.contains('\\') || activeMotion(value))
                        ) {
                            throw IllegalArgumentException("active css motion")
                        }
                        if (active(value)) throw IllegalArgumentException("active attribute")
                    }
                    if (name == "style") {
                        styleDepth++
                        style.clear()
                    }
                }
                XmlPullParser.TEXT, XmlPullParser.CDSECT -> if (styleDepth > 0) style.append(parser.text)
                XmlPullParser.END_TAG -> if (parser.name == "style" && styleDepth > 0) {
                    val css = style.toString()
                    if (css.contains('\\') || activeMotion(css, stylesheet = true) ||
                        active(css, styleContent = true)
                    ) {
                        throw IllegalArgumentException("active css")
                    }
                    styleDepth--
                }
            }
            event = parser.next()
        }
        if (!rootSeen) throw IllegalArgumentException("not svg")
        return source
    }

    private fun safeReference(raw: String): Boolean {
        val value = raw.replace(Regex("[\\x00-\\x20\\x7f]+"), "").lowercase()
        if (Regex("^#[^\\s<>\"']+$").matches(value)) return true
        return Regex("^data:image/(png|jpeg|gif|webp);base64,[a-z0-9+/]+={0,2}$").matches(value)
    }

    private fun activeMotion(raw: String, stylesheet: Boolean = false): Boolean {
        val value = raw
            .replace(Regex("/\\*[\\s\\S]*?\\*/"), "")
            .replace(Regex("[\\x00-\\x20\\x7f]+"), "")
            .lowercase()
        if (stylesheet && Regex("@(?:-[a-z]+-)?keyframes").containsMatchIn(value)) {
            return true
        }
        return Regex("(?:^|[;{])(?:-[a-z]+-)?(?:animation|transition)(?:-[a-z]+)?:")
            .containsMatchIn(value)
    }

    private fun active(raw: String, styleContent: Boolean = false): Boolean {
        var value = raw.replace(Regex("/\\*[\\s\\S]*?\\*/"), "")
        value = value.replace(Regex("\\\\(?:([0-9a-fA-F]{1,6})[\\t\\n\\r ]?|(.))"), "")
        value = value.replace(Regex("[\\x00-\\x20\\x7f]+"), "").lowercase()
        if (value.contains("url(") || value.contains("@import") ||
            value.contains("expression(") || value.contains("javascript:") ||
            value.contains("data:text/") || value.contains("data:image/svg") ||
            value.contains("https:") || value.contains("http:") ||
            value.contains("file:") || value.contains("content:")
        ) return true
        return styleContent && value.contains("//")
    }
}
