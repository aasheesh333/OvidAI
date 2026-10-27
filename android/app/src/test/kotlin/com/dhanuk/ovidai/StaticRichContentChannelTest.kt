package com.dhanuk.ovidai

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the production cancellation MethodCall/Result contract. */
class StaticRichContentChannelTest {
    @Test fun `cancel returns a boolean outcome and never image bytes`() {
        val renderer = StaticRichContentRenderer()
        val success = mutableListOf<Any?>()
        val errors = mutableListOf<String>()

        renderer.handleCancellation(
            MethodCall("cancelRenderPng", mapOf("requestId" to "request-1")),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    success.add(result)
                }

                override fun error(code: String, message: String?, details: Any?) {
                    errors.add(code)
                }

                override fun notImplemented() {
                    errors.add("notImplemented")
                }
            },
        )

        assertTrue(errors.isEmpty())
        assertEquals(listOf<Any?>(true), success)
        assertTrue(success.single() is Boolean)
        assertFalse(success.single() is ByteArray)
    }
}
