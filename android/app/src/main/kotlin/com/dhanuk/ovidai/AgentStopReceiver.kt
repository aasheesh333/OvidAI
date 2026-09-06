package com.dhanuk.ovidai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Notification "Stop agent" / "Exit" button → notifies Dart over the ovid/native
 * channel via static callbacks registered by AgentNotificationService / MainActivity.
 * The receiver runs on the main thread; we hop to Dart asynchronously.
 */
class AgentStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != AgentForegroundService.ACTION_STOP && action != AgentForegroundService.ACTION_EXIT) return

        val serviceIntent = Intent(context, AgentForegroundService::class.java).apply {
            this.action = action
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (_: Exception) {
            // Safely catch ForegroundServiceStartNotAllowedException on Android 12+ or SecurityException
        }

        if (action == AgentForegroundService.ACTION_STOP) {
            AgentNotificationBridge.stopHandler?.invoke()
        }
        // For ACTION_EXIT, AgentForegroundService.onStartCommand releases wake-lock,
        // tears down the service, and invokes AgentNotificationBridge.exitHandler once.
    }
}

/**
 * Static bridge: Dart registers callbacks at startup
 * (AgentNotificationService.init), the BroadcastReceiver and service call them.
 */
object AgentNotificationBridge {
    @Volatile
    var stopHandler: (() -> Unit)? = null

    @Volatile
    var exitHandler: (() -> Unit)? = null
}
