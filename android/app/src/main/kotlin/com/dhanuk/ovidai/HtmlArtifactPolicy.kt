package com.dhanuk.ovidai

/** The native boundary accepts only a bounded, in-memory wrapper. No URL or
 * file-loading method, JavascriptInterface, or permission toggle is exposed. */
internal object HtmlArtifactPolicy {
    // Attribute escaping can expand every source byte to an HTML entity.
    const val MAX_DOCUMENT_BYTES = 512 * 1024

    /** Only the host's exact initial loadData URL, never arbitrary data HTML.
     * Interception runs off the UI thread; completion/disposal closes the gate.
     * No about:srcdoc exception: it cannot identify the trusted frame and could
     * also describe a nested frame supplied by the artifact. CSP owns srcdoc.
     */
    class Bootstrap(private val documentUrl: String) {
        private val pending = java.util.concurrent.atomic.AtomicBoolean(true)

        fun finish() { pending.set(false) }

        fun allow(url: String, mainFrame: Boolean, method: String): Boolean {
            if (method != "GET") return false
            if (mainFrame) return url == documentUrl && pending.compareAndSet(true, false)
            // Passive raster images only. SVG/HTML/fonts and ambiguous legacy
            // callbacks receive no exception; CSP remains the frame boundary.
            if (url.length > MAX_DOCUMENT_BYTES) return false
            return RASTER_DATA.matches(url)
        }
    }

    private val RASTER_DATA = Regex("data:image/(?:png|jpeg|gif|webp);base64,[A-Za-z0-9+/]+={0,2}")

    fun document(arguments: Any?): String? {
        val args = arguments as? Map<*, *> ?: return null
        if (args.keys != setOf("document")) return null
        val document = args["document"] as? String ?: return null
        if (document.isBlank() || document.length > MAX_DOCUMENT_BYTES) return null
        if (document.toByteArray(Charsets.UTF_8).size > MAX_DOCUMENT_BYTES) return null
        return document
    }
}
