package com.dhanuk.ovidai

import android.app.Application
import android.app.Service
import android.content.Intent
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowPowerManager

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [23, 24, 26])
class AgentForegroundServiceCompatibilityTest {
    private lateinit var app: Application

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        BackgroundScheduleState.resume(app)
        AgentNotificationBridge.scheduleHandler = {}
    }

    @After fun cleanup() {
        BackgroundScheduleState.stop(app)
        AgentNotificationBridge.scheduleHandler = null
        AgentNotificationBridge.stopHandler = null
        AgentNotificationBridge.exitHandler = null
    }

    @Test fun stopRemovesNotificationReleasesWakeLockAndNotifiesRuntime() {
        verifyAction(AgentForegroundService.ACTION_STOP)
    }

    @Test fun exitRemovesNotificationReleasesWakeLockAndNotifiesRuntime() {
        verifyAction(AgentForegroundService.ACTION_EXIT)
    }

    private fun verifyAction(action: String) {
        val controller = Robolectric.buildService(AgentForegroundService::class.java).create()
        val service = controller.get()
        var stops = 0
        var exits = 0
        AgentNotificationBridge.stopHandler = { stops++ }
        AgentNotificationBridge.exitHandler = { exits++ }
        try {
            service.onStartCommand(Intent().putExtra(AgentForegroundService.EXTRA_WAKE, true), 0, 1)
            val wakeLock = ShadowPowerManager.getLatestWakeLock()
            assertTrue(wakeLock.isHeld)
            assertTrue(shadowOf(service).isLastForegroundNotificationAttached)

            assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(action), 0, 2))

            assertTrue(BackgroundScheduleState.stopped(app))
            assertFalse(wakeLock.isHeld)
            assertTrue(shadowOf(service).isStoppedBySelf)
            assertTrue(shadowOf(service).isForegroundStopped)
            assertTrue(shadowOf(service).notificationShouldRemoved)
            assertFalse(shadowOf(service).isLastForegroundNotificationAttached)
            assertEquals(if (action == AgentForegroundService.ACTION_STOP) 1 else 0, stops)
            assertEquals(if (action == AgentForegroundService.ACTION_EXIT) 1 else 0, exits)
        } finally {
            controller.destroy()
        }
    }

    @Test fun destructionRemovesNotificationAndReleasesWakeLock() {
        val controller = Robolectric.buildService(AgentForegroundService::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent().putExtra(AgentForegroundService.EXTRA_WAKE, true), 0, 1)
        val wakeLock = ShadowPowerManager.getLatestWakeLock()
        assertTrue(wakeLock.isHeld)
        controller.destroy()
        assertFalse(wakeLock.isHeld)
        assertTrue(shadowOf(service).isForegroundStopped)
        assertTrue(shadowOf(service).notificationShouldRemoved)
        assertFalse(shadowOf(service).isLastForegroundNotificationAttached)
    }
}
