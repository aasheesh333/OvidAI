package com.dhanuk.ovidai

import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class StudioPreviewRegistrationTest {
    /** FlutterEngine needs libflutter.so, so the additive registration contract
     * is pinned at its only production composition site. The real preview
     * factory/lifecycle is exercised separately below. */
    @Test fun `configure registers rich artifact and preview once without replacing voice channels`() {
        val source = listOf(
            File("src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt"),
            File("app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt"),
        ).first { it.isFile }.readText()
        val configure = Regex(
            "override fun configureFlutterEngine[\\s\\S]*?\\n    }",
        ).find(source)?.value ?: error("configureFlutterEngine is missing")

        fun count(token: String) = Regex(Regex.escape(token)).findAll(configure).count()
        assertEquals(1, count("registerStaticRichContentRenderer(flutterEngine.plugins)"))
        assertEquals(1, count("\"ovid/html-artifact\""))
        assertEquals(1, count("\"ovid/studio-preview\""))
        assertEquals(1, count("PreviewWebViewFactory(flutterEngine.dartExecutor.binaryMessenger)"))
        assertEquals(1, count("OnDeviceSpeechRecognizer("))
        assertEquals(1, count("\"ovid/voice_events\""))
        assertEquals(1, count("MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)"))

        val static = configure.indexOf("registerStaticRichContentRenderer(flutterEngine.plugins)")
        val artifact = configure.indexOf("\"ovid/html-artifact\"")
        val preview = configure.indexOf("\"ovid/studio-preview\"")
        val voice = configure.indexOf("stopTts(notify = false)")
        assertTrue(static >= 0 && static < artifact)
        assertTrue(artifact < preview)
        assertTrue(preview < voice)
    }

    /** Uses the real factory and MethodChannel lifecycle with an invalid launch,
     * so no public preview backend or network is needed. */
    @Test fun `preview disposal clears handler and prevents restart`() {
        val messenger = HostMessenger()
        val platform = PreviewWebViewFactory(messenger).create(
            RuntimeEnvironment.getApplication(),
            42,
            null,
        )
        val root = platform.view as FrameLayout
        assertEquals(0, root.childCount)

        messenger.call("startPreview")
        assertEquals(1, root.childCount)
        assertEquals(listOf("loadError"), messenger.events.map { it.method })
        messenger.call("disposePreview")
        assertEquals(0, root.childCount)

        val eventCount = messenger.events.size
        messenger.call("startPreview")
        assertEquals(eventCount, messenger.events.size)
        platform.dispose()
        platform.dispose()
        assertNull(messenger.handler)
        assertEquals(0, root.childCount)
    }

    private class HostMessenger : BinaryMessenger {
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        val events = mutableListOf<MethodCall>()
        private val codec = StandardMethodCodec.INSTANCE

        override fun send(channel: String, message: ByteBuffer?) {
            send(channel, message, null)
        }

        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) {
            message!!.flip()
            events.add(codec.decodeMethodCall(message))
            callback?.reply(null)
        }

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) {
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
}
