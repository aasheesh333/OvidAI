package com.dhanuk.ovidai

import android.app.AlarmManager
import android.app.Application
import android.app.Service
import android.content.Context
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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class BackgroundRuntimeTest {
    private lateinit var app: Application

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        BackgroundScheduleState.resume(app)
        BackgroundScheduleState.arm(app, null)
        AgentNotificationBridge.scheduleHandler = null
    }

    @After fun cleanup() {
        BackgroundScheduleState.stop(app)
        AgentNotificationBridge.scheduleHandler = null
    }

    @Test fun bootRearmsOnlyThePersistedAlarmWithoutStartingAService() {
        val at = System.currentTimeMillis() + 60_000
        app.getSharedPreferences("ovid_background", Context.MODE_PRIVATE)
            .edit().putLong("next", at).commit()
        BootReceiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        val alarms = shadowOf(app.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        assertEquals(at, alarms.nextScheduledAlarm?.triggerAtTime)
        assertNull(shadowOf(app).nextStartedService)
        BackgroundScheduleState.stop(app)
        BootReceiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertNull(alarms.nextScheduledAlarm)
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun absentDartRuntimeDoesNotRestartANotificationOnlyService() {
        val controller = Robolectric.buildService(AgentForegroundService::class.java).create()
        val service = controller.get()
        try {
            val result = service.onStartCommand(Intent().putExtra("wake", true), 0, 1)
            assertEquals(Service.START_NOT_STICKY, result)
            assertTrue(shadowOf(service).isStoppedBySelf)
        } finally {
            controller.destroy()
        }
    }

    @Test fun explicitStopRejectsStaleServiceUpdatesEvenWithALiveRuntime() {
        AgentNotificationBridge.scheduleHandler = {}
        BackgroundScheduleState.stop(app)
        val controller = Robolectric.buildService(AgentForegroundService::class.java).create()
        val service = controller.get()
        try {
            assertEquals(Service.START_NOT_STICKY,
                service.onStartCommand(Intent().putExtra("wake", true), 0, 1))
            assertTrue(shadowOf(service).isStoppedBySelf)
            assertTrue(BackgroundScheduleState.stopped(app))
        } finally {
            controller.destroy()
        }
    }
}
