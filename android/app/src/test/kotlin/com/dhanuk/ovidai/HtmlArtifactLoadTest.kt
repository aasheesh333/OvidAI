package com.dhanuk.ovidai

import android.net.Uri
import android.webkit.ArtifactTestResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import org.robolectric.RuntimeEnvironment
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import android.widget.FrameLayout
import java.nio.ByteBuffer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class HtmlArtifactLoadTest {
    private class HostMessenger : BinaryMessenger {
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        val events = mutableListOf<MethodCall>()
        private val codec = StandardMethodCodec.INSTANCE
        override fun send(channel: String, message: ByteBuffer?) { send(channel, message, null) }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            events.add(codec.decodeMethodCall(message))
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
        fun call(method: String): Any? {
            val request = codec.encodeMethodCall(MethodCall(method, null))
            request.flip()
            var response: Any? = null
            checkNotNull(handler).onMessage(request) { reply ->
                reply!!.flip()
                response = codec.decodeEnvelope(reply)
            }
            return response
        }
    }

    @Test fun `host starts once reports startup failure and disposal prevents resurrection`() {
        val messenger = HostMessenger()
        val platform = HtmlArtifactPlatformView(RuntimeEnvironment.getApplication(), null,
            MethodChannel(messenger, "artifact-test"))
        val root = platform.view as FrameLayout
        assertEquals(0, root.childCount) // Creation alone must not execute.
        assertEquals(mapOf("code" to "invalid_document"), messenger.call("startDocument"))
        assertEquals("loadError", messenger.events.single().method)
        assertEquals(mapOf("code" to "invalid_document"), messenger.events.single().arguments)
        messenger.call("startDocument")
        assertEquals(1, messenger.events.size)
        messenger.call("disposeDocument")
        messenger.call("startDocument")
        assertEquals(1, messenger.events.size)
        platform.dispose()
        platform.dispose()
        assertNull(messenger.handler)

        val stopped = HtmlArtifactPlatformView(RuntimeEnvironment.getApplication(), "<p>never execute</p>",
            MethodChannel(messenger, "artifact-test"))
        messenger.call("disposeDocument")
        messenger.call("startDocument")
        assertEquals(0, (stopped.view as FrameLayout).childCount)
        stopped.dispose()
    }

    private fun request(main: Boolean, url: String = "data:text/html;base64,PRIVATE") = object : WebResourceRequest {
        override fun getUrl() = Uri.parse(url)
        override fun isForMainFrame() = main
        override fun isRedirect() = false
        override fun hasGesture() = false
        override fun getMethod() = "GET"
        override fun getRequestHeaders() = emptyMap<String, String>()
    }

    @Test fun `subresource denials do not fail preview but main frame errors are sanitized`() {
        val failures = mutableListOf<Map<String, Any>>()
        val client = HtmlArtifactWebViewClient(HtmlArtifactPolicy.Bootstrap("data:text/html;base64,eA==")) {
            failures.add(it)
        }
        val view = WebView(RuntimeEnvironment.getApplication())
        val error = ArtifactTestResourceError()
        val response = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), null)
        client.onReceivedError(view, request(false), error)
        client.onReceivedHttpError(view, request(false), response)
        assertTrue(failures.isEmpty())
        client.onReceivedHttpError(view, request(true), response)
        assertEquals(mapOf("code" to "main_frame_http", "status" to 403), failures.single())
        failures.clear()
        client.onReceivedError(view, request(true), error)
        assertEquals(mapOf("code" to "main_frame_load", "errorCode" to -2), failures.single())
        failures.clear()
        @Suppress("DEPRECATION")
        client.onReceivedError(view, -6, "PRIVATE", "data:text/html;base64,PRIVATE")
        assertEquals(mapOf("code" to "main_frame_load", "errorCode" to -6), failures.single())
        view.destroy()
    }

    @Test fun `modern bootstrap is narrowly permitted but legacy callback and navigation stay denied`() {
        val url = "data:text/html;base64,eA=="
        val client = HtmlArtifactWebViewClient(HtmlArtifactPolicy.Bootstrap(url)) { fail(it.toString()) }
        val view = WebView(RuntimeEnvironment.getApplication())
        assertNull(client.shouldInterceptRequest(view, request(true, url)))
        assertEquals(403, client.shouldInterceptRequest(view, request(true, url))!!.statusCode)
        @Suppress("DEPRECATION")
        assertEquals(403, client.shouldInterceptRequest(view, url)!!.statusCode)
        assertTrue(client.shouldOverrideUrlLoading(view, request(true, url)))
        assertEquals(403, client.shouldInterceptRequest(view, request(false, "about:srcdoc"))!!.statusCode)
        view.destroy()
    }
}
