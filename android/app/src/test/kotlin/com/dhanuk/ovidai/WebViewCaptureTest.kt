package com.dhanuk.ovidai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Geometry for the `browser_screenshot` native capture.
 *
 * Only the pure-Kotlin helpers are covered — [WebViewCapture.scaledSize] and
 * [WebViewCapture.cropRect] — because they run on a plain JVM with no device.
 * [WebViewCapture.encodePng] and [WebViewCapture.cropAndScale] need a real
 * [android.graphics.Bitmap] (and `Bitmap.compress` / `Bitmap.createBitmap`),
 * which a unit-test JVM cannot provide without Robolectric — this module does
 * not use it, so that half is exercised by the Dart suite's mocked
 * `capturePixels` contract instead.
 *
 * These cases are not cosmetic. A wrong size here fails in one of two ugly
 * ways: [android.graphics.Bitmap.createBitmap] THROWS on a zero dimension, and
 * an accidental upscale turns a phone shot into several MB of base64 that then
 * rides along in the request envelope on every following turn.
 *
 * [WebViewCapture.cropRect] carries the same weight for a different reason: the
 * capture copies the whole WINDOW (PixelCopy has no public View-source
 * overload) and then crops the WebView's own rect out of it, so an unclamped
 * rect would throw, and a zero-width one would produce a 0-pixel bitmap that
 * still encodes to a valid PNG — a capture that looks successful and shows
 * nothing.
 */
class WebViewCaptureTest {

    private fun long(w: Int, h: Int) = w.coerceAtLeast(h)

    /** `cropRect` as a List, so equality is by VALUE (a raw IntArray is not). */
    private fun rect(
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        winW: Int,
        winH: Int
    ): List<Int>? = WebViewCapture.cropRect(x, y, w, h, winW, winH)?.toList()

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

    // ── cropRect: window -> WebView rect ───────────────────────────────────

    @Test
    fun `a webview filling the window crops to the whole window`() {
        assertEquals(listOf(0, 0, 1080, 1920), rect(0, 0, 1080, 1920, 1080, 1920))
    }

    @Test
    fun `an inset webview crops to its own rect`() {
        // The usual case: a toolbar/AppBar above the WebView.
        assertEquals(listOf(0, 200, 1080, 1000), rect(0, 200, 1080, 1000, 1080, 1920))
    }

    @Test
    fun `a webview hanging off an edge is clipped, never rejected`() {
        assertEquals(listOf(0, 1000, 1080, 920), rect(0, 1000, 1080, 1000, 1080, 1920))
        assertEquals(listOf(500, 0, 580, 500), rect(500, 0, 1000, 500, 1080, 1920))
        assertEquals(listOf(0, 1820, 1080, 100), rect(0, 1820, 1080, 101, 1080, 1920))
    }

    @Test
    fun `a partially scrolled-off webview keeps the visible sliver`() {
        assertEquals(listOf(0, 0, 1080, 50), rect(0, -100, 1080, 150, 1080, 1920))
        assertEquals(listOf(0, 0, 170, 160), rect(-30, -40, 200, 200, 1080, 1920))
    }

    @Test
    fun `a fully off-screen webview is refused, not silently zero-sized`() {
        // A 0-pixel bitmap still encodes to a valid PNG, so the caller could not
        // tell an empty capture from a real one. null is the only honest answer.
        assertNull(rect(0, 1920, 1080, 100, 1080, 1920))
        assertNull(rect(1080, 0, 100, 100, 1080, 1920))
        assertNull(rect(0, -300, 1080, 200, 1080, 1920))
        assertNull(rect(-300, 0, 200, 100, 1080, 1920))
    }

    @Test
    fun `degenerate geometry is refused instead of reaching createBitmap`() {
        // Bitmap.createBitmap throws on a zero or negative dimension.
        assertNull(rect(0, 0, 0, 100, 1080, 1920))
        assertNull(rect(0, 0, -5, 100, 1080, 1920))
        assertNull(rect(0, 0, 100, 0, 1080, 1920))
        assertNull(rect(0, 0, 100, -1, 1080, 1920))
        assertNull(rect(0, 0, 100, 100, 0, 0))
        assertNull(rect(0, 0, 100, 100, -1, 1920))
    }

    @Test
    fun `an accepted rect always lies strictly inside the window`() {
        // The invariant that makes the crop safe: createBitmap(full, x, y, w, h)
        // throws unless x+w <= full.width and y+h <= full.height, and `full` is
        // exactly winW x winH.
        for (winW in listOf(1, 100, 1080)) {
            for (winH in listOf(1, 100, 1920)) {
                for (x in listOf(-120, -1, 0, 1, 1079, 1080, 1200)) {
                    for (y in listOf(-120, -1, 0, 1, 1919, 1920, 2100)) {
                        for (w in listOf(-5, 0, 1, 100, 1080, 2000)) {
                            for (h in listOf(-5, 0, 1, 100, 1920, 3000)) {
                                val r = WebViewCapture.cropRect(x, y, w, h, winW, winH)
                                    ?: continue
                                val where = "x=$x y=$y w=$w h=$h win=${winW}x$winH"
                                assertTrue(where, r[0] >= 0)
                                assertTrue(where, r[1] >= 0)
                                assertTrue(where, r[2] > 0)
                                assertTrue(where, r[3] > 0)
                                assertTrue(where, r[0] + r[2] <= winW)
                                assertTrue(where, r[1] + r[3] <= winH)
                                // It must also still OVERLAP the requested rect,
                                // i.e. the crop is the webview's pixels and not
                                // some unrelated slice of the window.
                                assertTrue(where, r[0] >= x && r[1] >= y)
                                assertTrue(where, r[0] <= x + w && r[1] <= y + h)
                            }
                        }
                    }
                }
            }
        }
    }
}
