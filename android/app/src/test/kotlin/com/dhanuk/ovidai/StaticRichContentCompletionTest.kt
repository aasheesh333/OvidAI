package com.dhanuk.ovidai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Native-shaped Promise completion tests; no evaluateJavascript result is
 * treated as the eventual value of an async JavaScript Promise. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class StaticRichContentCompletionTest {
    private class Harness {
        val scheduled = mutableListOf<Pair<Long, () -> Unit>>()
        val polls = mutableListOf<(String?) -> Unit>()
        val startScripts = mutableListOf<String>()
        val dimensions = mutableListOf<Pair<Double, Double>>()
        val errors = mutableListOf<String>()

        val completion = StaticRenderCompletion(
            evaluate = { script, callback ->
                if (script.contains("window.ovidStaticCompletion ===")) {
                    polls.add(callback)
                } else {
                    startScripts.add(script)
                    callback("started")
                }
            },
            schedule = { delay, task -> scheduled.add(delay to task) },
            onDimensions = { width, height -> dimensions.add(width to height) },
            onError = { errors.add(it) },
        )

        fun start() = completion.start("window.ovidRenderMermaid('flowchart LR')")
        fun timeout() = scheduled.first { it.first == 15_000L }.second.invoke()
    }

    @Test fun `async Promise completion hands dimensions to capture only after settlement`() {
        val h = Harness()
        h.start()
        assertTrue(h.dimensions.isEmpty())
        assertEquals(1, h.startScripts.size)
        assertTrue(h.startScripts.single().contains("Promise.resolve"))
        assertTrue(h.startScripts.single().contains("ovidStaticCompletion"))
        assertEquals(1, h.polls.size)

        h.polls.removeAt(0).invoke(null)
        assertTrue(h.dimensions.isEmpty())
        // An unsettled Promise schedules another inspection; no pixels yet.
        assertTrue(h.scheduled.any { it.first == 10L })
        h.scheduled.first { it.first == 10L }.second.invoke()
        h.polls.removeAt(0).invoke("[120,80]")
        assertEquals(listOf(120.0 to 80.0), h.dimensions)
        assertTrue(h.errors.isEmpty())
    }

    @Test fun `timeout cancels once and a late Promise cannot capture`() {
        val h = Harness()
        h.start()
        h.timeout()
        assertEquals(listOf("timeout"), h.errors)
        h.polls.removeAt(0).invoke("[120,80]")
        h.timeout()
        assertTrue(h.dimensions.isEmpty())
        assertEquals(listOf("timeout"), h.errors)
    }

    @Test fun `explicit cancellation disposes completion and ignores late settlement`() {
        val h = Harness()
        h.start()
        h.completion.cancel()
        assertEquals(listOf("cancelled"), h.errors)
        h.polls.removeAt(0).invoke("[120,80]")
        h.timeout()
        assertTrue(h.dimensions.isEmpty())
        assertEquals(listOf("cancelled"), h.errors)
    }

    @Test fun `invalid eventual dimensions are an error not a bitmap request`() {
        val h = Harness()
        h.start()
        h.polls.removeAt(0).invoke("[-1,-1]")
        assertEquals(listOf("render_failed"), h.errors)
        assertTrue(h.dimensions.isEmpty())
    }

    @Test fun `native SVG fence rejects CSS animation and accepts ordinary static CSS`() {
        val attacks = listOf(
            "<svg><style>@keyframes move { from { opacity: 0 } to { opacity: 1 } }</style></svg>",
            "<svg><style>rect { animation: move 1s infinite; }</style></svg>",
            "<svg><rect style=\"transition: opacity 1s\"/> </svg>",
            "<svg><rect style=\"-webkit-animation-name: move\"/> </svg>",
            "<svg><style>@-webkit-keyframes move { from { opacity: 0 } }</style></svg>",
        )
        for (attack in attacks) {
            try {
                StaticSvgPolicy.checked(attack)
                fail("active CSS was accepted: $attack")
            } catch (_: IllegalArgumentException) {
                // Expected fail-closed result.
            }
        }
        assertEquals(
            "<svg><rect style=\"fill:#fff\"/></svg>",
            StaticSvgPolicy.checked("<svg><rect style=\"fill:#fff\"/></svg>"),
        )
    }
}
