package com.dhanuk.ovidai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Restarts the agent foreground service after a reboot when the user has
 * keep-alive enabled. Best-effort: Android 12+ restricts background FGS
 * starts, and some OEM ROMs block boot receivers entirely — the service is
 * re-asserted when the app is next opened regardless.
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
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        // Flutter prefixes SharedPreferences keys with "flutter.".
        if (!prefs.getBoolean("flutter.ovid_keep_alive", true)) return
        try {
            val service = Intent(context, AgentForegroundService::class.java).apply {
                putExtra(AgentForegroundService.EXTRA_TITLE, "Ovid AI")
                putExtra(AgentForegroundService.EXTRA_TEXT, "Ready & listening")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (_: Throwable) {
            // Background FGS start refused by the OS — nothing to do here.
        }
    }
}
