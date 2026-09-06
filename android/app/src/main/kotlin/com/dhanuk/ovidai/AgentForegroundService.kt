package com.dhanuk.ovidai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the app alive while the AI agent works
 * (DSH "always-on personal assistant" parity).
 *
 * Started from Dart via the ovid/native method channel when an agent run
 * starts; stopped when the run finishes or the user taps Stop.
 *
 * Holds a PARTIAL WakeLock for the run's duration so Doze/device-idle
 * can't throttle CPU/network mid-task (hours-long runs).
 *
 * Notification actions:
 *  - ACTION_STOP → broadcasts "ovid.agent.STOP" (AgentService listens,
 *    cancels the active run; identical to tapping Stop in the chat UI).
 *
 * Hardened: any failure inside startForeground is caught and the service
 * stops itself instead of crashing the whole app (previously a missing
 * manifest permission crashed the process on every agent message).
 */
class AgentForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "ovid_agent_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.dhanuk.ovidai.AGENT_STOP"
        const val ACTION_EXIT = "com.dhanuk.ovidai.AGENT_EXIT"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var lastTitle: String = "Ovid AI"
    private var lastText: String = "Agent is working…"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Recents survival: swiping Ovid from recent apps must NOT stop foreground service.
        // Re-assert notification and partial wake-lock so background tasks continue uninterrupted.
        try {
            acquireWakeLock()
            startForeground(NOTIFICATION_ID, buildNotification(lastTitle, lastText))
        } catch (_: Exception) {}
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_EXIT) {
            // ACTION_EXIT: stops foreground service completely, releases wake-lock, triggers exit bridge.
            releaseWakeLock()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            AgentNotificationBridge.exitHandler?.invoke()
            return START_NOT_STICKY
        }
        if (action == ACTION_STOP) {
            // ACTION_STOP: cancels running agent jobs, but keeps foreground service running if configured or if tasks remain.
            // Dart onAgentStop cancels active runs. We update notification copy without calling stopSelf().
            lastText = "Agent stopped"
            try {
                startForeground(NOTIFICATION_ID, buildNotification(lastTitle, lastText))
            } catch (_: Exception) {}
            return START_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: lastText
        lastTitle = title
        lastText = text
        try {
            startForeground(NOTIFICATION_ID, buildNotification(title, text))
        } catch (e: Exception) {
            // Permission denial / notification-policy failure must NEVER
            // crash the app — the agent run continues without the
            // keep-alive notification.
            releaseWakeLock()
            stopSelf()
            return START_NOT_STICKY
        }
        acquireWakeLock()
        // STICKY: if the system kills us under memory pressure, restart —
        // the Dart side re-syncs notification state on the next event.
        return START_STICKY
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ovid:agent_run").apply {
                // 6h ceiling; the service re-acquires on update ticks.
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        wakeLock = null
    }

    override fun onDestroy() {
        releaseWakeLock()
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun buildNotification(title: String, text: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Agent activity",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when the AI agent is working in the background"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }

        // Tap → open the app (singleTop relaunch of MainActivity).
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Stop action → the app's Dart receiver cancels the run.
        val stopPi = PendingIntent.getBroadcast(
            this, 1,
            Intent(ACTION_STOP).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Exit action → stops the foreground service and cancels agent run.
        val exitPi = PendingIntent.getBroadcast(
            this, 2,
            Intent(ACTION_EXIT).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(contentPi)
            .addAction(0, "Stop", stopPi)
            .addAction(0, "Exit", exitPi)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
