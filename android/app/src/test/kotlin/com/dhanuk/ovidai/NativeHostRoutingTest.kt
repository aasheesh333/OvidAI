package com.dhanuk.ovidai

import android.content.Intent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class NativeHostRoutingTest {
    @Test fun sessionIntentRoutesOnceAndIgnoresBlankSession() {
        val selections = mutableListOf<String>()
        val initial = Intent().putExtra("sessionId", "session-a")
        routeSessionIntent(initial) { selections.add(it) }
        routeSessionIntent(initial) { selections.add(it) }
        routeSessionIntent(Intent().putExtra("sessionId", " ")) { selections.add(it) }
        routeSessionIntent(Intent().putExtra("sessionId", "session-b")) { selections.add(it) }
        assertEquals(listOf("session-a", "session-b"), selections)
    }
}
