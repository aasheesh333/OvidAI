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
}
