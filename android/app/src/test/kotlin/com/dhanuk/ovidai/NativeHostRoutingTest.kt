package com.dhanuk.ovidai

import android.content.Intent
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class NativeHostRoutingTest {
    @After fun cleanup() {
        AgentNotificationBridge.stopHandler = null
        AgentNotificationBridge.exitHandler = null
        deviceActions.begin()
    }

    @Test fun refreshedNotificationCallbacksTargetNewHostAndCancelBeforeDart() {
        deviceActions.begin()
        var oldExit = false
        var newExit = false
        val events = mutableListOf<String>()
        bindNotificationHostCallbacks({ fail("Old host received $it") }, { oldExit = true })
        bindNotificationHostCallbacks({
            assertTrue(deviceActions.isStopped())
            events.add(it)
        }, { newExit = true })
        AgentNotificationBridge.stopHandler!!.invoke()
        assertEquals(listOf("onAgentStop"), events)
        deviceActions.begin()
        AgentNotificationBridge.exitHandler!!.invoke()
        assertEquals(listOf("onAgentStop", "onAgentExit"), events)
        assertFalse(oldExit)
        assertTrue(newExit)
    }

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
