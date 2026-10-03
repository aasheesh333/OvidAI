package com.dhanuk.ovidai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Notification "Stop agent" / "Exit" button → notifies Dart over the ovid/native
 * channel via static callbacks registered by AgentNotificationService / MainActivity.
 * The receiver runs on the main thread; we hop to Dart asynchronously.
 */
class AgentStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != AgentForegroundService.ACTION_STOP && action != AgentForegroundService.ACTION_EXIT) return

        BackgroundScheduleState.stop(context)
        if (action == AgentForegroundService.ACTION_STOP) {
            AgentNotificationBridge.stopHandler?.invoke()
        } else {
            AgentNotificationBridge.exitHandler?.invoke()
        }
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

    @Volatile
    var scheduleHandler: (() -> Unit)? = null

    @Volatile
    var constraintHandler: ((String) -> Unit)? = null
}
