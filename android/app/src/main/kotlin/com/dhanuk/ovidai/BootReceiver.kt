package com.dhanuk.ovidai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restores background operation after reboot or an app update:
 *  - LOCKED_BOOT_COMPLETED (direct boot, before unlock): re-registers the
 *    schedule alarm from device-protected storage. Nothing else can run yet.
 *  - BOOT_COMPLETED / QUICKBOOT / MY_PACKAGE_REPLACED: re-registers the alarm
 *    and, when "Keep Ovid active in background" is on, starts the foreground
 *    service, which boots the Dart runtime so due/missed schedules run.
 * The boot start never asks for the wake lock; only real agent work does.
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        const val LOCKED_BOOT = "android.intent.action.LOCKED_BOOT_COMPLETED"
        val FULL_BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action == LOCKED_BOOT) {
            try {
                BackgroundScheduleState.rearmLocked(context)
            } catch (_: Throwable) { }
            return
        }
        if (action !in FULL_BOOT_ACTIONS) return
        try {
            BackgroundScheduleState.rearm(context)
        } catch (_: Throwable) {
            BackgroundScheduleState.constraint(context, "System could not rearm scheduled tasks; reopen Ovid.")
        }
        if (BackgroundScheduleState.stopped(context)) return
        // A deadline that passed while the phone was off is re-armed 1 s in
        // the future by rearm(), so missed tasks catch up without the service.
        if (BackgroundScheduleState.keepActive(context)) {
            AgentForegroundService.startSystem(context, AgentForegroundService.ACTION_BOOT)
        }
    }
}
