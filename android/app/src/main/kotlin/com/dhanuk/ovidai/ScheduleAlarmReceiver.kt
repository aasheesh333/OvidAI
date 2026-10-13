package com.dhanuk.ovidai

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Schedule wake-ups. The alarm is exact (setExactAndAllowWhileIdle) whenever
 * Android allows it, else inexact plus a periodic JobScheduler safety net
 * (see [ScheduleFallbackJob]). Time/zone changes re-register the alarm.
 */
class ScheduleAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (BackgroundScheduleState.stopped(context)) return
        if (intent.action == Intent.ACTION_TIMEZONE_CHANGED || intent.action == Intent.ACTION_TIME_CHANGED) {
            BackgroundScheduleState.rearm(context)
            AgentNotificationBridge.scheduleHandler?.invoke()
            return
        }
        BackgroundScheduleState.fire(context)
    }
}

object BackgroundScheduleState {
    const val ALARM_EXACT = "exact"
    const val ALARM_INEXACT = "inexact"
    const val ALARM_NONE = "none"
    private const val REOPEN_ID = 4101

    private fun prefs(context: Context) = context.getSharedPreferences("ovid_background", Context.MODE_PRIVATE)

    /**
     * Device-protected mirror of the few values LOCKED_BOOT_COMPLETED needs
     * (before the user unlocks, credential storage is unreadable).
     */
    private fun bootPrefs(context: Context): SharedPreferences {
        val storage = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else context
        return storage.getSharedPreferences("ovid_background_boot", Context.MODE_PRIVATE)
    }

    private fun mirror(context: Context, edit: SharedPreferences.Editor.() -> Unit) {
        try { bootPrefs(context).edit().apply(edit).apply() } catch (_: Exception) { }
    }

    private var stopLatch: BackgroundStopLatch? = null
    private fun latch(context: Context): BackgroundStopLatch {
        val store = prefs(context.applicationContext)
        return stopLatch ?: BackgroundStopLatch(
            { store.getBoolean("stopped", false) },
            { value -> store.edit().putBoolean("stopped", value).commit() },
        ).also { stopLatch = it }
    }
    fun stopped(context: Context) = !latch(context).mayRun()
    fun stop(context: Context) {
        // commit before callbacks/service teardown: a stale tick cannot undo Stop.
        if (!latch(context).stop()) constraint(context, "Could not persist Stop; storage unavailable.")
        mirror(context) { putBoolean("stopped", true) }
        try { arm(context, null) } catch (_: Exception) {}
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(REOPEN_ID)
        context.stopService(Intent(context, AgentForegroundService::class.java))
    }
    fun resume(context: Context) {
        check(latch(context).resume()) { "Could not persist Resume" }
        mirror(context) { putBoolean("stopped", false) }
        prefs(context).edit().remove("constraint").apply()
    }
    fun constraint(context: Context, message: String?) {
        prefs(context).edit().putString("constraint", message).apply()
        if (message != null) AgentNotificationBridge.constraintHandler?.invoke(message)
    }
    fun state(context: Context): Map<String, Any?> = mapOf(
        "stopped" to stopped(context),
        "constraint" to (if (!NotificationManagerCompat.from(context).areNotificationsEnabled())
            "Notifications are denied; background activity may not be visible."
            else prefs(context).getString("constraint", null)),
    )

    /** "Keep Ovid active in background", as last reported by Dart. */
    fun keepActive(context: Context): Boolean =
        prefs(context).getBoolean("keep_active", false) && notificationsAllowed(context)

    /** The app's notification master switch (OFF = no service notification). */
    fun notificationsAllowed(context: Context): Boolean = prefs(context).getBoolean("notify_master", true)

    fun setKeepActive(context: Context, enabled: Boolean, master: Boolean) {
        prefs(context).edit().putBoolean("keep_active", enabled).putBoolean("notify_master", master).apply()
        mirror(context) { putBoolean("keep_active", enabled && master) }
    }

    fun alarmMode(context: Context): String = prefs(context).getString("alarm_mode", ALARM_NONE) ?: ALARM_NONE

    fun nextDeadline(context: Context): Long = prefs(context).getLong("next", 0L)

    private fun pending(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, REOPEN_ID, Intent(context, ScheduleAlarmReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** Registers the next schedule wake-up ([at] epoch ms; null clears it). */
    fun arm(context: Context, at: Long?) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(context)
        alarms.cancel(pi)
        val deadline = if (stopped(context)) null else at
        check(prefs(context).edit().putLong("next", deadline ?: 0L).commit())
        mirror(context) { putLong("next", deadline ?: 0L) }
        if (deadline == null) {
            prefs(context).edit().putString("alarm_mode", ALARM_NONE).apply()
            ScheduleFallbackJob.cancel(context)
            return
        }
        armAt(context, alarms, pi, deadline, BackgroundChannel.exactAlarmsAllowed(context))
    }

    private fun armAt(context: Context, alarms: AlarmManager, pi: PendingIntent, deadline: Long, exact: Boolean) {
        val trigger = maxOf(deadline, System.currentTimeMillis() + 1000)
        val mode = if (exact) {
            try {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                ALARM_EXACT
            } catch (_: SecurityException) {
                // Exact-alarm access revoked between the check and the call.
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                ALARM_INEXACT
            }
        } else {
            // Inexact and quota-limited; Doze/OEM policy may defer it, so a
            // periodic job re-checks the deadline as a safety net.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
            ALARM_INEXACT
        }
        prefs(context).edit().putString("alarm_mode", mode).apply()
        if (mode == ALARM_EXACT) ScheduleFallbackJob.cancel(context) else ScheduleFallbackJob.ensure(context)
    }

    fun rearm(context: Context) {
        if (stopped(context)) return
        val next = nextDeadline(context)
        if (next > 0) arm(context, next)
    }

    /** LOCKED_BOOT_COMPLETED: re-register from device-protected storage only. */
    fun rearmLocked(context: Context) {
        val boot = try { bootPrefs(context) } catch (_: Exception) { return }
        if (boot.getBoolean("stopped", false)) return
        val next = boot.getLong("next", 0L)
        if (next <= 0) return
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val trigger = maxOf(next, System.currentTimeMillis() + 1000)
        if (BackgroundChannel.exactAlarmsAllowed(context)) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pending(context))
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pending(context))
        }
    }

    /**
     * A schedule deadline arrived. Start the foreground service, which boots
     * the Dart runtime if Android killed it and then runs due tasks. If the
     * user turned notifications off entirely, wake Dart without the service.
     */
    fun fire(context: Context) {
        if (stopped(context)) return
        if (!notificationsAllowed(context)) {
            val wake = AgentNotificationBridge.scheduleHandler
            if (wake != null) wake() else if (!OvidEngineHost.ensure(context)) notifyReopen(context)
            return
        }
        try {
            BackgroundChannel.startService(
                context,
                Intent(context, AgentForegroundService::class.java)
                    .setAction(AgentForegroundService.ACTION_ALARM),
            )
        } catch (e: Exception) {
            constraint(context, "Android refused to start Ovid for a scheduled task: ${e.message}")
            val wake = AgentNotificationBridge.scheduleHandler
            if (wake != null) wake() else notifyReopen(context)
        }
    }

    /** Last resort when no runtime can start: ask the user to open Ovid. */
    fun notifyReopen(context: Context) {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        OvidNotifications.ensureChannels(context)
        val stop = PendingIntent.getBroadcast(context, 4103,
            Intent(context, AgentStopReceiver::class.java).setAction(AgentForegroundService.ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(REOPEN_ID, NotificationCompat.Builder(
                context, OvidNotifications.activeChannelId(context, OvidNotifications.SCHEDULE))
                .setSmallIcon(R.drawable.ic_stat_ovid)
                .setContentTitle("Scheduled task waiting")
                .setContentText("Open Ovid to run pending tasks")
                .setContentIntent(OvidNotifications.openAppIntent(context, null, 4102))
                .setAutoCancel(true)
                .addAction(0, "Stop", stop).build())
        } catch (_: SecurityException) {
            constraint(context, "Notification permission denied; reopen Ovid to resume tasks.")
        }
    }
}
