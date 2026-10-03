package com.dhanuk.ovidai

/** The native boundary accepts only a bounded, in-memory wrapper. No URL or
 * file-loading method, JavascriptInterface, or permission toggle is exposed. */
internal object HtmlArtifactPolicy {
    // Attribute escaping can expand every source byte to an HTML entity.
    const val MAX_DOCUMENT_BYTES = 512 * 1024

    fun document(arguments: Any?): String? {
        val args = arguments as? Map<*, *> ?: return null
        if (args.keys != setOf("document")) return null
        val document = args["document"] as? String ?: return null
        if (document.isBlank() || document.length > MAX_DOCUMENT_BYTES) return null
        if (document.toByteArray(Charsets.UTF_8).size > MAX_DOCUMENT_BYTES) return null
        return document
    }
}
