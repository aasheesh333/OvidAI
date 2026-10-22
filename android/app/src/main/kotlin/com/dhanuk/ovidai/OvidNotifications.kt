package com.dhanuk.ovidai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Ovid's notification channels and posting.
 *
 * Android makes a channel's sound immutable once created, so every
 * (channel, sound) pair has its own id: `ovid_<channel>.<sound>.v1`. Picking a
 * different sound deletes the old variant and creates the new one. The Dart
 * side (lib/core/background_notifications.dart) uses the same id formula.
 *
 * Channels:
 *  - agent_updates (HIGH): run finished, needs input/approval, long jobs done.
 *  - scheduler_results (DEFAULT): scheduled task succeeded/failed.
 *  - background_status (LOW, always silent): the "Ovid is active" service
 *    notification.
 *
 * Legacy channels (`ovid_agent_channel`, `ovid_schedule`) are deleted the
 * first time channels are ensured, which migrates users off them.
 */
object OvidNotifications {
    const val AGENT = "agent_updates"
    const val SCHEDULE = "scheduler_results"
    const val STATUS = "background_status"

    const val SOUND_CHIME = "chime"
    const val SOUND_SYSTEM = "system"
    const val SOUND_SILENT = "silent"
    val SOUNDS = listOf(SOUND_CHIME, SOUND_SYSTEM, SOUND_SILENT)

    const val VERSION = "v1"
    val LEGACY_CHANNEL_IDS = listOf("ovid_agent_channel", "ovid_schedule")

    /** Launch extra carrying an app route (`/c/<id>`, `/schedule/<id>`, `/`). */
    const val EXTRA_ROUTE = "route"

    data class Spec(
        val key: String,
        val name: String,
        val description: String,
        val importance: Int,
        val defaultSound: String,
    )

    val SPECS: List<Spec> = listOf(
        Spec(
            AGENT, "Agent updates",
            "When an agent run finishes, needs your input or approval, or a long job is done",
            NotificationManager.IMPORTANCE_HIGH, SOUND_CHIME,
        ),
        Spec(
            SCHEDULE, "Scheduled task results",
            "Success or failure of scheduled tasks, with a short summary",
            NotificationManager.IMPORTANCE_DEFAULT, SOUND_CHIME,
        ),
        Spec(
            STATUS, "Background status",
            "Shows while Ovid is active in the background",
            NotificationManager.IMPORTANCE_LOW, SOUND_SILENT,
        ),
    )

    fun spec(key: String): Spec = SPECS.firstOrNull { it.key == key } ?: SPECS[0]

    fun channelId(key: String, sound: String): String = "ovid_$key.$sound.$VERSION"

    private fun prefs(context: Context) =
        context.getSharedPreferences("ovid_notify", Context.MODE_PRIVATE)

    /** The status channel is always silent; the others follow the user. */
    fun soundFor(context: Context, key: String): String {
        if (key == STATUS) return SOUND_SILENT
        val stored = prefs(context).getString("sound.$key", null)
        return if (stored in SOUNDS) stored!! else spec(key).defaultSound
    }

    fun enabled(context: Context, key: String): Boolean =
        prefs(context).getBoolean("enabled.$key", true)

    fun activeChannelId(context: Context, key: String) = channelId(key, soundFor(context, key))

    fun configure(context: Context, sounds: Map<String, String>, enabled: Map<String, Boolean>) {
        val edit = prefs(context).edit()
        for ((key, sound) in sounds) if (sound in SOUNDS && key != STATUS) edit.putString("sound.$key", sound)
        for ((key, on) in enabled) edit.putBoolean("enabled.$key", on)
        edit.apply()
        ensureChannels(context)
    }

    fun chimeUri(context: Context): Uri =
        Uri.parse("android.resource://${context.packageName}/${R.raw.ovid_chime}")

    /** Creates the active variant of every channel and deletes stale ones. */
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for (legacy in LEGACY_CHANNEL_IDS) {
            try { nm.deleteNotificationChannel(legacy) } catch (_: Exception) { }
        }
        for (spec in SPECS) {
            val sound = soundFor(context, spec.key)
            for (other in SOUNDS) {
                if (other != sound) {
                    try { nm.deleteNotificationChannel(channelId(spec.key, other)) } catch (_: Exception) { }
                }
            }
            val id = channelId(spec.key, sound)
            if (nm.getNotificationChannel(id) != null) continue
            val channel = NotificationChannel(id, spec.name, spec.importance).apply {
                description = spec.description
                when (sound) {
                    SOUND_CHIME -> setSound(
                        chimeUri(context),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    SOUND_SILENT -> {
                        setSound(null, null)
                        enableVibration(false)
                    }
                    else -> { /* system default notification sound */ }
                }
                if (spec.key == STATUS) setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun legacyPriority(key: String) = when (spec(key).importance) {
        NotificationManager.IMPORTANCE_HIGH -> NotificationCompat.PRIORITY_HIGH
        NotificationManager.IMPORTANCE_LOW -> NotificationCompat.PRIORITY_LOW
        else -> NotificationCompat.PRIORITY_DEFAULT
    }

    /** Pre-O devices have no channels: apply sound/priority per notification. */
    private fun applyLegacySound(context: Context, builder: NotificationCompat.Builder, key: String) {
        builder.priority = legacyPriority(key)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) return
        when (soundFor(context, key)) {
            SOUND_CHIME -> builder.setSound(chimeUri(context))
            SOUND_SYSTEM -> builder.setDefaults(NotificationCompat.DEFAULT_SOUND)
            else -> builder.setSilent(true)
        }
    }

    fun openAppIntent(context: Context, route: String?, requestCode: Int): PendingIntent {
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_NEW_TASK
            if (!route.isNullOrBlank()) putExtra(EXTRA_ROUTE, route)
        }
        return PendingIntent.getActivity(
            context, requestCode, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * Posts one user-facing notification. Returns false when the user turned
     * the channel off in Ovid, Android blocks notifications, or posting fails.
     */
    fun post(
        context: Context,
        key: String,
        id: Int,
        title: String,
        body: String,
        route: String?,
    ): Boolean {
        if (key == STATUS || !enabled(context, key)) return false
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        ensureChannels(context)
        val builder = NotificationCompat.Builder(context, activeChannelId(context, key))
            .setSmallIcon(R.drawable.ic_stat_ovid)
            .setColor(0xFFE5484D.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(context, route, 20_000 + (id and 0xFFFF)))
            .setCategory(
                if (key == SCHEDULE) NotificationCompat.CATEGORY_REMINDER
                else NotificationCompat.CATEGORY_MESSAGE,
            )
        applyLegacySound(context, builder, key)
        return try {
            NotificationManagerCompat.from(context).notify(id, builder.build())
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun cancel(context: Context, id: Int) {
        NotificationManagerCompat.from(context).cancel(id)
    }

    /**
     * Whether Android will actually show this app's notifications.
     *
     * `areNotificationsEnabled` covers both POST_NOTIFICATIONS (API 33+) and
     * the app-level switch the user can turn off later in system settings,
     * where the grant itself still reads as granted. The Dart settings screen
     * uses this so it never claims notifications work when they cannot arrive.
     */
    fun notificationsEnabled(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled()

    /** Low-importance, silent ongoing notification for the foreground service. */
    fun statusNotification(
        context: Context,
        title: String,
        text: String,
        stop: PendingIntent,
        exit: PendingIntent,
    ): Notification {
        ensureChannels(context)
        val builder = NotificationCompat.Builder(context, activeChannelId(context, STATUS))
            .setSmallIcon(R.drawable.ic_stat_ovid)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setContentIntent(openAppIntent(context, null, 0))
            .addAction(0, "Stop", stop)
            .addAction(0, "Exit", exit)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        return builder.build()
    }

    /** Android's own settings page for one channel (or the app's page pre-O). */
    fun channelSettingsIntent(context: Context, key: String): Intent {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ensureChannels(context)
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, activeChannelId(context, key))
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        }
        return intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    fun appNotificationSettingsIntent(context: Context): Intent {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        }
        return intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
