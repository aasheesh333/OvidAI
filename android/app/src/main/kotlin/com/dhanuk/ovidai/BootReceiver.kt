package com.dhanuk.ovidai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Rearms a permitted inexact alarm after reboot. Boot cannot restore the Dart
 * runtime: a due alarm offers reopen rather than pretending an agent is alive.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        try {
            BackgroundScheduleState.rearm(context)
        } catch (_: Throwable) {
            BackgroundScheduleState.constraint(context, "System could not rearm scheduled tasks; reopen Ovid.")
        }
    }
}
