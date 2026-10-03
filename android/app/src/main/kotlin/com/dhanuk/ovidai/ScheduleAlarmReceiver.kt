package com.dhanuk.ovidai

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** One inexact wake-up, never an exact-alarm permission or background FGS launch. */
class ScheduleAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (BackgroundScheduleState.stopped(context)) return
        if (intent.action == Intent.ACTION_TIMEZONE_CHANGED || intent.action == Intent.ACTION_TIME_CHANGED) {
            BackgroundScheduleState.rearm(context)
            AgentNotificationBridge.scheduleHandler?.invoke()
            return
        }
        val wake = AgentNotificationBridge.scheduleHandler
        if (wake != null) {
            wake()
        } else {
            BackgroundScheduleState.constraint(context,
                "Runtime stopped by Android. Reopen Ovid to reconcile scheduled tasks.")
            BackgroundScheduleState.notifyReopen(context)
        }
    }
}

object BackgroundScheduleState {
    private fun prefs(context: Context) = context.getSharedPreferences("ovid_background", Context.MODE_PRIVATE)
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
        try { arm(context, null) } catch (_: Exception) {}
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(4101)
        context.stopService(Intent(context, AgentForegroundService::class.java))
    }
    fun resume(context: Context) {
        check(latch(context).resume()) { "Could not persist Resume" }
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
    private fun pending(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, 4101, Intent(context, ScheduleAlarmReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    fun arm(context: Context, at: Long?) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(context)
        alarms.cancel(pi)
        val deadline = if (stopped(context)) null else at
        check(prefs(context).edit().putLong("next", deadline ?: 0L).commit())
        if (deadline == null) return
        // setAndAllowWhileIdle is INEXACT, quota-limited and permitted without
        // SCHEDULE_EXACT_ALARM. Doze/OEM policies may defer it substantially.
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,
            maxOf(deadline, System.currentTimeMillis() + 1000), pi)
    }
    fun rearm(context: Context) {
        if (stopped(context)) return
        val next = prefs(context).getLong("next", 0L)
        if (next > 0) arm(context, next)
    }
    fun notifyReopen(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(
                "ovid_schedule", "Scheduled tasks", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val open = PendingIntent.getActivity(context, 4102,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getBroadcast(context, 4103,
            Intent(context, AgentStopReceiver::class.java).setAction(AgentForegroundService.ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        try {
            nm.notify(4101, NotificationCompat.Builder(context, "ovid_schedule")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Scheduled task waiting")
                .setContentText("Reopen Ovid to reconcile and run pending tasks")
                .setContentIntent(open).setAutoCancel(true)
                .addAction(0, "Stop", stop).build())
        } catch (_: SecurityException) {
            constraint(context, "Notification permission denied; reopen Ovid to resume tasks.")
        }
    }
}
