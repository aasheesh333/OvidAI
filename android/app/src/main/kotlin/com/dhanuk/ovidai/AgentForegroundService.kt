package com.dhanuk.ovidai

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock

/**
 * Foreground service that keeps Ovid alive in the background: while an agent
 * run is in flight, while a scheduled task runs, and (when "Keep Ovid active
 * in background" is on, the default) as a low-importance "Ovid is active"
 * presence so schedules fire on time.
 *
 * Started from Dart via the ovid/native channel, by the schedule alarm
 * (ACTION_ALARM), and after reboot/app update (ACTION_BOOT). It is
 * START_STICKY: when Android kills the process it is restarted, and every
 * start boots the Dart runtime headlessly if it is gone (OvidEngineHost), so
 * a restarted service is a restarted agent, not an empty notification.
 *
 * Holds a bounded PARTIAL WakeLock during active work. Android/OEM policy can
 * still delay networking, terminate the process, or refuse a foreground start.
 *
 * Notification actions:
 *  - ACTION_STOP → broadcasts "ovid.agent.STOP" (AgentService listens,
 *    cancels the active run; identical to tapping Stop in the chat UI).
 *
 * Failures are reported to Dart and stop the service. A notification alone
 * cannot restore the agent runtime; process death is reconciled on reopen.
 * Explicit Stop/Exit persist a latch that all starts and alarms respect.
 */
class AgentForegroundService : Service() {

    companion object {
        /// Legacy channel id, deleted by OvidNotifications.ensureChannels.
        const val LEGACY_CHANNEL_ID = "ovid_agent_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.dhanuk.ovidai.AGENT_STOP"
        const val ACTION_EXIT = "com.dhanuk.ovidai.AGENT_EXIT"
        const val ACTION_ALARM = "com.dhanuk.ovidai.SCHEDULE_ALARM"
        const val ACTION_BOOT = "com.dhanuk.ovidai.BOOT_RESTORE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val DEFAULT_TITLE = "Ovid is active"
        const val DEFAULT_TEXT = "Ready for scheduled tasks and agent runs"

        /// True between a successful startForeground and onDestroy.
        @Volatile
        var running = false
            private set

        /// System-initiated start (boot/update restore, alarm). Never carries
        /// EXTRA_WAKE: only the alarm path asks for the lock, inside the service.
        fun startSystem(context: Context, action: String) {
            try {
                BackgroundChannel.startService(
                    context,
                    Intent(context, AgentForegroundService::class.java).setAction(action),
                )
            } catch (e: Exception) {
                BackgroundScheduleState.constraint(context, "Android refused to restart Ovid in the background: ${e.message}")
            }
        }

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

    /// Whether the current live runtime justifies holding the wake lock.
    private var wantWakeLock = false
    private var lastTitle: String = DEFAULT_TITLE
    private var lastText: String = DEFAULT_TEXT

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (BackgroundScheduleState.stopped(this)) {
            stopSelf()
            return
        }
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
            BackgroundScheduleState.stop(this)
            // ACTION_EXIT: stops foreground service completely, releases wake-lock, triggers exit bridge.
            releaseWakeLock()
            removeForegroundNotification()
            stopSelf()
            AgentNotificationBridge.exitHandler?.invoke()
            return START_NOT_STICKY
        }
        if (action == ACTION_STOP) {
            BackgroundScheduleState.stop(this)
            wantWakeLock = false
            releaseWakeLock()
            removeForegroundNotification()
            stopSelf()
            AgentNotificationBridge.stopHandler?.invoke()
            return START_NOT_STICKY
        }
        if (BackgroundScheduleState.stopped(this)) {
            // Explicit Stop/Exit is a latch: no restart, alarm or update undoes it.
            releaseWakeLock()
            stopSelf()
            return START_NOT_STICKY
        }
        // Null intent = START_STICKY restart after Android killed the process.
        // Every start (re)boots the Dart runtime if it is gone, so schedules
        // and runs continue instead of showing an empty notification.
        if (!OvidEngineHost.ensure(this)) {
            if (action == ACTION_ALARM) BackgroundScheduleState.notifyReopen(this)
            releaseWakeLock()
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
        val text = intent?.getStringExtra(EXTRA_TEXT)
            ?: if (action == ACTION_ALARM) "Running a scheduled task…" else lastText
        // A null intent (START_STICKY restart) carries no extra: keep whatever
        // state we already had rather than dropping the lock mid-run.
        intent?.let { wantWakeLock = it.getBooleanExtra(EXTRA_WAKE, wantWakeLock) }
        // A due task is about to run; Dart's idle update releases the lock.
        if (action == ACTION_ALARM) wantWakeLock = true
        lastTitle = title
        lastText = text
        try {
            startForeground(NOTIFICATION_ID, buildNotification(title, text))
        } catch (e: Exception) {
            BackgroundScheduleState.constraint(this, "Foreground service unavailable: ${e.message}")
            // Still let a live runtime run the due task without the service.
            if (action == ACTION_ALARM) AgentNotificationBridge.scheduleHandler?.invoke()
            releaseWakeLock()
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        // Hold the CPU awake only while agent work is in flight; an idle
        // "Ovid is active" service must not (see EXTRA_WAKE).
        if (wantWakeLock) acquireWakeLock() else releaseWakeLock()
        if (action == ACTION_ALARM) AgentNotificationBridge.scheduleHandler?.invoke()
        return START_STICKY
    }

    private fun acquireWakeLock() {
        try {
            val now = SystemClock.elapsedRealtime()
            if (wakeLock?.isHeld == true) {
                // Refresh the bounded lock on active-work updates. This does
                // not exempt the process from Android/OEM runtime restrictions.
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

    /// Android 15+ (targetSdk 35+): a dataSync foreground service may run at
    /// most 6 hours per 24 hours. The system calls this when the budget is
    /// spent; the service must stop within seconds or the app crashes with
    /// ForegroundServiceDidNotStopInTimeException. Same path as Stop.
    override fun onTimeout(startId: Int, fgsType: Int) {
        BackgroundScheduleState.constraint(this, "Android's background time limit was reached; reopen Ovid to continue.")
        wantWakeLock = false
        releaseWakeLock()
        removeForegroundNotification()
        stopSelf()
        AgentNotificationBridge.stopHandler?.invoke()
    }

    override fun onDestroy() {
        running = false
        releaseWakeLock()
        try {
            removeForegroundNotification()
        } catch (_: Exception) {}
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun removeForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        // Stop action → the app's Dart receiver cancels the run.
        val stopPi = PendingIntent.getBroadcast(
            this, 1,
            Intent(this, AgentStopReceiver::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Exit action → stops the foreground service and cancels agent run.
        val exitPi = PendingIntent.getBroadcast(
            this, 2,
            Intent(this, AgentStopReceiver::class.java).setAction(ACTION_EXIT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Low-importance, silent "background status" channel (no chime).
        return OvidNotifications.statusNotification(this, title, text, stopPi, exitPi)
    }
}
