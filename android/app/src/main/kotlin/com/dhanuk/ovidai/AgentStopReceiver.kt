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
        if (intent.action != AgentForegroundService.ACTION_STOP) return
        val handler = AgentNotificationBridge.stopHandler
        val service = context.startService(
            Intent(context, AgentForegroundService::class.java).apply {
                action = AgentForegroundService.ACTION_STOP
            }
        )
        // Let Dart know the user tapped Stop (cancels the active run).
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
