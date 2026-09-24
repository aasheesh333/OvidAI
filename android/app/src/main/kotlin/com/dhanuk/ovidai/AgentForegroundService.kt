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
import android.os.SystemClock
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
 * Hardened: any failure inside startForeground is caught instead of
 * crashing the whole app (previously a missing manifest permission
 * crashed the process on every agent message) — and the service stays
 * STICKY so the system restarts it rather than letting the agent die in
 * the background. Only the explicit Exit action stops it for good.
 */
class AgentForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "ovid_agent_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.dhanuk.ovidai.AGENT_STOP"
        const val ACTION_EXIT = "com.dhanuk.ovidai.AGENT_EXIT"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        /// True only while an agent run is actually in flight. The Dart side
        /// sends it on every start/update so the service knows whether the
        /// partial wake lock is justified.
        ///
        /// BATTERY / PLAY POLICY (2026-09-24): this used to be implicit — ANY
        /// startForegroundService call acquired a renewable 6-hour
        /// PARTIAL_WAKE_LOCK, including the idle "Ready & Listening" update and
        /// the BootReceiver start. That held the CPU awake all night on every
        /// device with keep-alive on (the default) while no agent work existed,
        /// and a permanently-running specialUse FGS with no task is a Play
        /// policy exposure. The lock is now tied to real work.
        const val EXTRA_WAKE = "wake"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wakeLockAcquiredAt: Long = 0L

    /// Whether the current state justifies holding the wake lock. Survives a
    /// START_STICKY restart with a null intent.
    private var wantWakeLock = false
    private var lastTitle: String = "Ovid AI"
    private var lastText: String = "Agent is working…"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Recents survival: swiping Ovid from recent apps must NOT stop foreground service.
        // Re-assert the notification, and the wake-lock ONLY if a run is
        // actually in flight (see EXTRA_WAKE) — an idle service must not hold
        // the CPU awake.
        try {
            if (wantWakeLock) acquireWakeLock()
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
            // No run is in flight any more, so the wake lock goes too.
            wantWakeLock = false
            releaseWakeLock()
            lastText = "Agent stopped"
            try {
                startForeground(NOTIFICATION_ID, buildNotification(lastTitle, lastText))
            } catch (_: Exception) {}
            return START_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: lastText
        // A null intent (START_STICKY restart) carries no extra: keep whatever
        // state we already had rather than dropping the lock mid-run.
        intent?.let { wantWakeLock = it.getBooleanExtra(EXTRA_WAKE, wantWakeLock) }
        lastTitle = title
        lastText = text
        try {
            startForeground(NOTIFICATION_ID, buildNotification(title, text))
        } catch (e: Exception) {
            // Permission denial / notification-policy failure must NEVER
            // crash the app — the agent run continues without the
            // keep-alive notification. Stay STICKY (never NOT_STICKY here)
            // so the system restarts the service — with a null intent we
            // re-foreground below from the last title/text — instead of
            // letting the agent die in the background. Only the explicit
            // ACTION_EXIT path below is allowed to be NOT_STICKY.
            releaseWakeLock()
            return START_STICKY
        }
        // Hold the CPU awake only while an agent run is in flight; an idle
        // "Ready & Listening" service must not (see EXTRA_WAKE).
        if (wantWakeLock) acquireWakeLock() else releaseWakeLock()
        // STICKY: if the system kills us under memory pressure, restart —
        // the Dart side re-syncs notification state on the next event.
        return START_STICKY
    }

    private fun acquireWakeLock() {
        try {
            val now = SystemClock.elapsedRealtime()
            if (wakeLock?.isHeld == true) {
                // 6h ceiling: refresh before expiry so 24/7 runs never
                // silently lose the lock (and Doze never throttles them).
                if (now - wakeLockAcquiredAt < 5 * 60 * 60 * 1000L) return
                releaseWakeLock()
            }
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ovid:agent_run").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
            wakeLockAcquiredAt = now
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        wakeLock = null
        wakeLockAcquiredAt = 0L
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
