package com.dhanuk.ovidai

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Geometry for the `browser_screenshot` native capture.
 *
 * Only [WebViewCapture.scaledSize] is covered: it is pure Kotlin, so it runs on
 * the JVM with no device. [WebViewCapture.encodePng] needs a real
 * [android.graphics.Bitmap] (and `Bitmap.compress`), which a unit-test JVM
 * cannot provide without Robolectric — this module does not use it, so that
 * half is exercised by the Dart suite's mocked `capturePixels` contract instead.
 *
 * These cases are not cosmetic. A wrong size here fails in one of two ugly
 * ways: [android.graphics.Bitmap.createBitmap] THROWS on a zero dimension, and
 * an accidental upscale turns a phone shot into several MB of base64 that then
 * rides along in the request envelope on every following turn.
 */
class WebViewCaptureTest {

    private fun long(w: Int, h: Int) = w.coerceAtLeast(h)

    @Test
    fun `never upscales - a small view stays exactly as it is`() {
        // A 1080x1920 capture asked for a 4096 cap must come back untouched.
        assertEquals(Pair(1080, 1920), WebViewCapture.scaledSize(1080, 1920, 4096))
    }

    @Test
    fun `an exact fit is returned unchanged`() {
        assertEquals(Pair(1280, 720), WebViewCapture.scaledSize(1280, 720, 1280))
    }

    @Test
    fun `downscale preserves the aspect ratio - portrait`() {
        assertEquals(Pair(720, 1280), WebViewCapture.scaledSize(1080, 1920, 1280))
    }

    @Test
    fun `downscale preserves the aspect ratio - landscape`() {
        assertEquals(Pair(1280, 720), WebViewCapture.scaledSize(1920, 1080, 1280))
    }

    @Test
    fun `a square stays square`() {
        assertEquals(Pair(1000, 1000), WebViewCapture.scaledSize(2000, 2000, 1000))
    }

    @Test
    fun `the long edge lands exactly on the cap`() {
        for (pair in listOf(
            Triple(1440, 3200, 1280),
            Triple(2560, 1440, 1024),
            Triple(3000, 1000, 900),
            Triple(777, 1999, 640)
        )) {
            val out = WebViewCapture.scaledSize(pair.first, pair.second, pair.third)
            assertEquals(
                "long edge should equal the cap for ${pair.first}x${pair.second}",
                pair.third,
                long(out.first, out.second)
            )
        }
    }

    @Test
    fun `an extreme aspect ratio never collapses a dimension to zero`() {
        // ratio 0.25 would round the 1px side to 0 — and createBitmap(0, n)
        // throws. coerceAtLeast(1) is what keeps a pathological page capturable.
        assertEquals(Pair(1, 1000), WebViewCapture.scaledSize(1, 4000, 1000))
        assertEquals(Pair(1000, 1), WebViewCapture.scaledSize(4000, 1, 1000))
    }

    @Test
    fun `degenerate input collapses to 1x1 instead of throwing`() {
        // A WebView that is not laid out yet reports 0x0; the caller refuses
        // first, but the helper must not be the thing that crashes.
        assertEquals(Pair(1, 1), WebViewCapture.scaledSize(0, 0, 1280))
        assertEquals(Pair(1, 1), WebViewCapture.scaledSize(0, 800, 1280))
        assertEquals(Pair(1, 1), WebViewCapture.scaledSize(800, 0, 1280))
        assertEquals(Pair(1, 1), WebViewCapture.scaledSize(-5, -9, 1280))
    }

    @Test
    fun `a non-positive cap means no cap at all`() {
        // The Dart side omits maxEdge unless the caller asked for one, but a
        // 0 or negative value must not be read as "scale to nothing".
        assertEquals(Pair(1080, 1920), WebViewCapture.scaledSize(1080, 1920, 0))
        assertEquals(Pair(1080, 1920), WebViewCapture.scaledSize(1080, 1920, -1))
    }
}
