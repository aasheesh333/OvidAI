package com.dhanuk.ovidai

import android.app.AlarmManager
import android.app.Application
import android.app.Service
import android.app.job.JobScheduler
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
import org.robolectric.shadows.ShadowAlarmManager
import org.robolectric.shadows.ShadowPowerManager

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class BackgroundRuntimeTest {
    private lateinit var app: Application
    private var boots = 0

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        BackgroundScheduleState.resume(app)
        BackgroundScheduleState.arm(app, null)
        BackgroundScheduleState.setKeepActive(app, enabled = false, master = true)
        AgentNotificationBridge.scheduleHandler = null
        boots = 0
        OvidEngineHost.factoryForTest = { boots++; true }
    }

    @After fun cleanup() {
        BackgroundScheduleState.stop(app)
        AgentNotificationBridge.scheduleHandler = null
        OvidEngineHost.factoryForTest = null
    }

    private val alarms get() = shadowOf(app.getSystemService(Context.ALARM_SERVICE) as AlarmManager)

    private fun persistNext(at: Long) {
        app.getSharedPreferences("ovid_background", Context.MODE_PRIVATE)
            .edit().putLong("next", at).commit()
    }

    private fun dropScheduledAlarm() {
        (app.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(
            alarms.nextScheduledAlarm!!.operation!!,
        )
        assertNull(alarms.nextScheduledAlarm)
    }

    @Test fun bootRearmsAlarmAndRestoresTheServiceWhenKeepActiveIsOn() {
        val at = System.currentTimeMillis() + 60_000
        persistNext(at)
        BackgroundScheduleState.setKeepActive(app, enabled = true, master = true)
        BootReceiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertEquals(at, alarms.nextScheduledAlarm?.triggerAtTime)
        val started = shadowOf(app).nextStartedService
        assertEquals(AgentForegroundService.ACTION_BOOT, started?.action)
        // The boot start never asks for the wake lock.
        assertFalse(started!!.hasExtra(AgentForegroundService.EXTRA_WAKE))
    }

    @Test fun bootWithKeepActiveOffOnlyRearms() {
        val at = System.currentTimeMillis() + 60_000
        persistNext(at)
        BootReceiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertEquals(at, alarms.nextScheduledAlarm?.triggerAtTime)
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun explicitStopSurvivesBootAndUpdate() {
        persistNext(System.currentTimeMillis() + 60_000)
        BackgroundScheduleState.setKeepActive(app, enabled = true, master = true)
        BackgroundScheduleState.stop(app)
        shadowOf(app).clearStartedServices()
        BootReceiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        BootReceiver().onReceive(app, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
        assertNull(alarms.nextScheduledAlarm)
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun appUpdateRestoresAlarmAndService() {
        val at = System.currentTimeMillis() + 120_000
        BackgroundScheduleState.arm(app, at)
        BackgroundScheduleState.setKeepActive(app, enabled = true, master = true)
        dropScheduledAlarm()
        BootReceiver().onReceive(app, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
        assertEquals(at, alarms.nextScheduledAlarm?.triggerAtTime)
        assertEquals(AgentForegroundService.ACTION_BOOT, shadowOf(app).nextStartedService?.action)
    }

    @Test fun lockedBootRearmsFromDeviceProtectedStorage() {
        val at = System.currentTimeMillis() + 90_000
        BackgroundScheduleState.arm(app, at)
        dropScheduledAlarm()
        BootReceiver().onReceive(app, Intent(BootReceiver.LOCKED_BOOT))
        assertEquals(at, alarms.nextScheduledAlarm?.triggerAtTime)
        // Nothing can run before unlock.
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun pastDeadlineIsRearmedImmediatelyForCatchUp() {
        persistNext(System.currentTimeMillis() - 3_600_000)
        BootReceiver().onReceive(app, Intent(Intent.ACTION_BOOT_COMPLETED))
        val trigger = alarms.nextScheduledAlarm!!.triggerAtTime
        val now = System.currentTimeMillis()
        assertTrue(trigger >= now - 1_000)
        assertTrue(trigger <= now + 5_000)
    }

    @Test fun exactAlarmIsUsedWhenAllowed() {
        BackgroundScheduleState.arm(app, System.currentTimeMillis() + 60_000)
        assertEquals(BackgroundScheduleState.ALARM_EXACT, BackgroundScheduleState.alarmMode(app))
        val js = app.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
        assertTrue(js.allPendingJobs.none { it.id == ScheduleFallbackJob.JOB_ID })
    }

    @Test fun alarmReceiverStartsTheServiceForTheTask() {
        ScheduleAlarmReceiver().onReceive(app, Intent())
        assertEquals(AgentForegroundService.ACTION_ALARM, shadowOf(app).nextStartedService?.action)
    }

    @Test fun alarmWithNotificationsOffWakesDartWithoutTheService() {
        var wakes = 0
        AgentNotificationBridge.scheduleHandler = { wakes++ }
        BackgroundScheduleState.setKeepActive(app, enabled = true, master = false)
        assertFalse(BackgroundScheduleState.keepActive(app))
        ScheduleAlarmReceiver().onReceive(app, Intent())
        assertEquals(1, wakes)
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun timeChangeReregistersTheAlarm() {
        val at = System.currentTimeMillis() + 300_000
        persistNext(at)
        ScheduleAlarmReceiver().onReceive(app, Intent(Intent.ACTION_TIME_CHANGED))
        assertEquals(at, alarms.nextScheduledAlarm?.triggerAtTime)
    }

    @Test fun stickyRestartBootsTheDartRuntimeHeadlessly() {
        val controller = Robolectric.buildService(AgentForegroundService::class.java).create()
        val service = controller.get()
        try {
            assertEquals(Service.START_STICKY, service.onStartCommand(null, 0, 1))
            assertEquals(1, boots)
            assertTrue(shadowOf(service).isLastForegroundNotificationAttached)
            assertTrue(AgentForegroundService.running)
        } finally {
            controller.destroy()
        }
        assertFalse(AgentForegroundService.running)
    }

    @Test fun alarmStartWakesSchedulesAndHoldsTheLockForTheTask() {
        var wakes = 0
        AgentNotificationBridge.scheduleHandler = { wakes++ }
        val controller = Robolectric.buildService(AgentForegroundService::class.java).create()
        val service = controller.get()
        try {
            val result = service.onStartCommand(Intent(AgentForegroundService.ACTION_ALARM), 0, 1)
            assertEquals(Service.START_STICKY, result)
            assertEquals(1, wakes)
            assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
            // Dart's idle update (wake=false) releases it.
            service.onStartCommand(Intent().putExtra(AgentForegroundService.EXTRA_WAKE, false), 0, 2)
            assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        } finally {
            controller.destroy()
        }
    }

    @Test fun runtimeThatCannotStartStopsInsteadOfShowingAnEmptyService() {
        OvidEngineHost.factoryForTest = { false }
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
            assertEquals(0, boots)
        } finally {
            controller.destroy()
        }
    }

    @Test fun fallbackJobFiresOnlyForADueDeadline() {
        val now = 1_000_000L
        assertTrue(ScheduleFallbackJob.isDue(now - 1, now, stopped = false))
        assertTrue(ScheduleFallbackJob.isDue(now, now, stopped = false))
        assertFalse(ScheduleFallbackJob.isDue(now + 1, now, stopped = false))
        assertFalse(ScheduleFallbackJob.isDue(0, now, stopped = false))
        assertFalse(ScheduleFallbackJob.isDue(now - 1, now, stopped = true))
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ExactAlarmFallbackTest {
    private lateinit var app: Application

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        BackgroundScheduleState.resume(app)
    }

    @After fun cleanup() {
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        BackgroundScheduleState.stop(app)
    }

    @Test fun deniedExactAlarmsFallBackToInexactPlusPeriodicJob() {
        ShadowAlarmManager.setCanScheduleExactAlarms(false)
        val at = System.currentTimeMillis() + 60_000
        BackgroundScheduleState.arm(app, at)
        assertEquals(BackgroundScheduleState.ALARM_INEXACT, BackgroundScheduleState.alarmMode(app))
        val alarms = shadowOf(app.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        assertEquals(at, alarms.nextScheduledAlarm?.triggerAtTime)
        val js = app.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
        val job = js.allPendingJobs.single { it.id == ScheduleFallbackJob.JOB_ID }
        assertTrue(job.isPeriodic)
        assertTrue(job.isPersisted)
        // Granting exact alarms later switches back and drops the job.
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        BackgroundScheduleState.arm(app, at)
        assertEquals(BackgroundScheduleState.ALARM_EXACT, BackgroundScheduleState.alarmMode(app))
        assertTrue(js.allPendingJobs.none { it.id == ScheduleFallbackJob.JOB_ID })
        // Clearing the schedule clears the safety net too.
        BackgroundScheduleState.arm(app, null)
        assertEquals(BackgroundScheduleState.ALARM_NONE, BackgroundScheduleState.alarmMode(app))
    }
}
