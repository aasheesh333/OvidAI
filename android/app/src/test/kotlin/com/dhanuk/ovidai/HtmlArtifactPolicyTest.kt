package com.dhanuk.ovidai

import org.junit.Assert.*
import org.junit.Test

class HtmlArtifactPolicyTest {
    @Test fun `native contract rejects URL and privilege parameters`() {
        for (args in listOf(
            null, "https://example.com", mapOf("url" to "file:///etc/passwd"),
            mapOf("document" to "<p>x</p>", "allowNetwork" to true),
            mapOf("document" to 1), mapOf("document" to " "),
        )) assertNull(HtmlArtifactPolicy.document(args))
    }

    @Test fun `native boundary enforces UTF8 byte bound before loading`() {
        assertEquals("<p>ok</p>", HtmlArtifactPolicy.document(mapOf("document" to "<p>ok</p>")))
        assertNotNull(HtmlArtifactPolicy.document(mapOf("document" to "x".repeat(524288))))
        assertNull(HtmlArtifactPolicy.document(mapOf("document" to "x".repeat(524289))))
        assertNull(HtmlArtifactPolicy.document(mapOf("document" to "é".repeat(262145))))
    }

    @Test fun `bootstrap exception is exact main frame GET and closes after loading`() {
        val policy = HtmlArtifactPolicy.Bootstrap("data:text/html;base64,PGI+b2s8L2I+")
        for (url in listOf("data:text/html;base64,PGI+b2s8L2I+#x", "data:text/html,other",
            "https://example.com", "file:///etc/passwd", "content://settings/system",
            "about:srcdoc", "data:image/svg+xml,<svg/>")) {
            assertFalse(policy.allow(url, true, "GET"))
        }
        assertFalse(policy.allow("data:text/html;base64,PGI+b2s8L2I+", false, "GET"))
        assertFalse(policy.allow("data:text/html;base64,PGI+b2s8L2I+", true, "POST"))
        assertTrue(policy.allow("data:text/html;base64,PGI+b2s8L2I+", true, "GET"))
        assertFalse(policy.allow("data:text/html;base64,PGI+b2s8L2I+", true, "GET"))
        val completed = HtmlArtifactPolicy.Bootstrap("data:text/html;base64,eA==")
        completed.finish()
        assertFalse(completed.allow("data:text/html;base64,eA==", true, "GET"))
    }

    @Test fun `inline image exception cannot become a document or external resource`() {
        val policy = HtmlArtifactPolicy.Bootstrap("data:text/html;base64,eA==")
        assertTrue(policy.allow("data:image/png;base64,iVBORw0KGgo=", false, "GET"))
        for (url in listOf("data:image/png;base64,iVBORw0KGgo=", "about:srcdoc",
            "data:text/html;base64,b3RoZXI=", "data:image/svg+xml;base64,eA==",
            "data:image/png,raw", "data:image/png;base64,broken!", "blob:opaque",
            "file:///android_asset/x.html", "https://example.com/image.png")) {
            assertFalse(policy.allow(url, true, "GET"))
        }
        assertFalse(policy.allow("data:image/png;base64,iVBORw0KGgo=", false, "POST"))
        assertFalse(policy.allow("data:image/png;base64," + "a".repeat(800000), false, "GET"))
    }
}
