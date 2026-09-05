package com.dhanuk.ovidai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Notification "Stop agent" button → notifies Dart over the ovid/native
 * channel via a static callback registered by AgentNotificationService.
 * The receiver runs on the main thread; we hop to Dart asynchronously.
 */
class AgentStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != AgentForegroundService.ACTION_STOP && action != AgentForegroundService.ACTION_EXIT) return
        val handler = AgentNotificationBridge.stopHandler
        val service = context.startService(
            Intent(context, AgentForegroundService::class.java).apply {
                this.action = action
            }
        )
        // Let Dart know the user tapped Stop or Exit (cancels the active run).
        handler?.invoke()
    }
}

/**
 * Tiny static bridge: Dart registers a callback at startup
 * (AgentNotificationService.init), the BroadcastReceiver calls it.
 */
object AgentNotificationBridge {
    @Volatile
    var stopHandler: (() -> Unit)? = null
}
