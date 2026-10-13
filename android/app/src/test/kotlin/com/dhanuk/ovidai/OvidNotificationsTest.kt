package com.dhanuk.ovidai

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 33])
class OvidNotificationsTest {
    private lateinit var app: Application
    private lateinit var nm: NotificationManager

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        app.getSharedPreferences("ovid_notify", Context.MODE_PRIVATE).edit().clear().commit()
        nm.notificationChannels.forEach { nm.deleteNotificationChannel(it.id) }
        nm.cancelAll()
    }

    @Test fun channelIdsEncodeChannelSoundAndVersion() {
        assertEquals("ovid_agent_updates.chime.v1", OvidNotifications.channelId("agent_updates", "chime"))
        assertEquals("ovid_scheduler_results.system.v1", OvidNotifications.channelId("scheduler_results", "system"))
        assertEquals("ovid_background_status.silent.v1", OvidNotifications.channelId("background_status", "silent"))
    }

    @Test fun ensureChannelsMigratesOffLegacyChannelsWithTheChime() {
        nm.createNotificationChannel(NotificationChannel("ovid_agent_channel", "old", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel("ovid_schedule", "old", NotificationManager.IMPORTANCE_DEFAULT))
        OvidNotifications.ensureChannels(app)
        val ids = nm.notificationChannels.map { it.id }.toSet()
        assertFalse(ids.contains("ovid_agent_channel"))
        assertFalse(ids.contains("ovid_schedule"))
        assertEquals(
            setOf("ovid_agent_updates.chime.v1", "ovid_scheduler_results.chime.v1", "ovid_background_status.silent.v1"),
            ids,
        )
        val agent = nm.getNotificationChannel("ovid_agent_updates.chime.v1")
        assertEquals(NotificationManager.IMPORTANCE_HIGH, agent.importance)
        assertTrue(agent.sound.toString().startsWith("android.resource://${app.packageName}/"))
        assertEquals(OvidNotifications.chimeUri(app), agent.sound)
        val schedule = nm.getNotificationChannel("ovid_scheduler_results.chime.v1")
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, schedule.importance)
        assertEquals(OvidNotifications.chimeUri(app), schedule.sound)
        val status = nm.getNotificationChannel("ovid_background_status.silent.v1")
        assertEquals(NotificationManager.IMPORTANCE_LOW, status.importance)
        assertNull(status.sound)
    }

    @Test fun choosingASoundReplacesTheImmutableChannel() {
        OvidNotifications.ensureChannels(app)
        OvidNotifications.configure(app, mapOf("agent_updates" to "system", "background_status" to "chime"), emptyMap())
        val ids = nm.notificationChannels.map { it.id }.toSet()
        assertFalse(ids.contains("ovid_agent_updates.chime.v1"))
        assertTrue(ids.contains("ovid_agent_updates.system.v1"))
        // The status channel can never get a sound.
        assertTrue(ids.contains("ovid_background_status.silent.v1"))
        assertEquals("system", OvidNotifications.soundFor(app, "agent_updates"))
        assertEquals("silent", OvidNotifications.soundFor(app, "background_status"))
    }

    @Test fun postHonoursPerChannelSwitchAndCarriesTheRoute() {
        assertTrue(OvidNotifications.post(app, "agent_updates", 2001, "Done", "Reply ready", "/c/abc"))
        val posted = shadowOf(nm).getNotification(2001)
        assertNotNull(posted)
        assertEquals("ovid_agent_updates.chime.v1", posted.channelId)
        val launch = shadowOf(posted.contentIntent).savedIntent
        assertEquals("/c/abc", launch.getStringExtra(OvidNotifications.EXTRA_ROUTE))

        OvidNotifications.configure(app, emptyMap(), mapOf("scheduler_results" to false))
        assertFalse(OvidNotifications.post(app, "scheduler_results", 2002, "Ran", "ok", "/schedule/abc"))
        assertNull(shadowOf(nm).getNotification(2002))
        // The status channel is reserved for the service notification.
        assertFalse(OvidNotifications.post(app, "background_status", 2003, "x", "y", null))
    }

    @Test fun notificationRouteIsConsumedOnceAndMustBeAnAppPath() {
        val routes = mutableListOf<String>()
        val tap = Intent().putExtra(OvidNotifications.EXTRA_ROUTE, "/schedule/s1")
        routeNotificationIntent(tap) { routes.add(it) }
        routeNotificationIntent(tap) { routes.add(it) }
        routeNotificationIntent(Intent().putExtra(OvidNotifications.EXTRA_ROUTE, "https://evil")) { routes.add(it) }
        routeNotificationIntent(Intent().putExtra(OvidNotifications.EXTRA_ROUTE, " ")) { routes.add(it) }
        assertEquals(listOf("/schedule/s1"), routes)
    }
}
