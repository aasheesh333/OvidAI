package com.dhanuk.ovidai

import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The background subset of the `ovid/native` channel: service, alarms,
 * notifications and background-reliability status. MainActivity delegates
 * these methods here; a headless engine (no Activity) gets only these, so
 * schedules and notifications work identically with or without the UI.
 */
object BackgroundChannel {
    const val CHANNEL = "ovid/native"

    val METHODS = setOf(
        "backgroundState", "backgroundStop", "backgroundResume", "scheduleAlarm",
        "agentServiceStart", "agentServiceUpdate", "agentServiceStop",
        "notifyConfigure", "notifyPost", "notifyCancel", "notifyOpenChannelSettings",
        "notifyOpenAppSettings", "bgSetKeepActive", "bgStatus", "bgRequestExactAlarm",
    )

    /** Points schedule wakes and constraint reports at [engine]'s Dart side. */
    fun bindRuntime(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        val main = Handler(Looper.getMainLooper())
        AgentNotificationBridge.scheduleHandler = {
            main.post { channel.invokeMethod("onScheduleWake", null) }
        }
        AgentNotificationBridge.constraintHandler = { message ->
            main.post { channel.invokeMethod("onBackgroundConstraint", message) }
        }
    }

    /** Handler for an engine with no Activity (booted by the service/alarm). */
    fun attachHeadless(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        val main = Handler(Looper.getMainLooper())
        bindRuntime(engine)
        bindNotificationHostCallbacks(
            emit = { method -> main.post { channel.invokeMethod(method, null) } },
            exitHost = { },
        )
        channel.setMethodCallHandler { call, result ->
            when {
                handle(app, call, result) -> Unit
                call.method == "agentStopHandler" || call.method == "agentExitHandler" ->
                    result.success(true)
                call.method == "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }
    }

    private fun serviceIntent(context: Context, call: MethodCall) =
        Intent(context, AgentForegroundService::class.java).apply {
            putExtra(AgentForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "Ovid AI")
            putExtra(AgentForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "Agent is working…")
            // Hold the partial wake lock only while a run is actually in
            // flight. Absent/false → the service releases it (idle presence
            // must not keep the CPU awake). See AgentForegroundService.EXTRA_WAKE.
            putExtra(AgentForegroundService.EXTRA_WAKE, call.argument<String>("wake") == "true")
        }

    fun exactAlarmsAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return try { alarms.canScheduleExactAlarms() } catch (_: Exception) { false }
    }

    fun batteryExempt(context: Context): Boolean = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        pm.isIgnoringBatteryOptimizations(context.packageName)
    } catch (_: Exception) {
        false
    }

    fun status(context: Context): Map<String, Any?> = mapOf(
        "sdk" to Build.VERSION.SDK_INT,
        "targetSdk" to context.applicationInfo.targetSdkVersion,
        "manufacturer" to (Build.MANUFACTURER ?: ""),
        "brand" to (Build.BRAND ?: ""),
        "notificationsEnabled" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
        "batteryExempt" to batteryExempt(context),
        "exactAlarmsAllowed" to exactAlarmsAllowed(context),
        "alarmMode" to BackgroundScheduleState.alarmMode(context),
        "keepActive" to BackgroundScheduleState.keepActive(context),
        "serviceRunning" to AgentForegroundService.running,
        "runtimeAlive" to OvidEngineHost.isAlive(),
    )

    /** Returns true when [call] was one of [METHODS] (and was answered). */
    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result): Boolean {
        val app = context.applicationContext
        when (call.method) {
            "backgroundState" -> result.success(BackgroundScheduleState.state(app))
            "backgroundStop" -> {
                BackgroundScheduleState.stop(app)
                result.success(true)
            }
            "backgroundResume" -> {
                // Only the app's explicit Resume action clears the latch.
                BackgroundScheduleState.resume(app)
                result.success(true)
            }
            "scheduleAlarm" -> try {
                BackgroundScheduleState.arm(app, call.argument<Number>("at")?.toLong())
                result.success(true)
            } catch (e: Exception) {
                BackgroundScheduleState.constraint(app, "Alarm unavailable: ${e.message}")
                result.error("ALARM_UNAVAILABLE", e.message, null)
            }
            "agentServiceStart" -> {
                if (BackgroundScheduleState.stopped(app)) {
                    result.success(false)
                } else {
                    // Foreground service: keeps the app alive while the agent works.
                    try {
                        startService(app, serviceIntent(app, call))
                        result.success(true)
                    } catch (e: Exception) {
                        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                            e.javaClass.name.contains("ForegroundServiceStartNotAllowedException")
                        ) "FGS_BACKGROUND_DENIED" else "START_FAIL"
                        result.error(code, "${e.message}", null)
                    }
                }
            }
            "agentServiceUpdate" -> {
                if (BackgroundScheduleState.stopped(app)) {
                    result.success(false)
                } else {
                    try {
                        startService(app, serviceIntent(app, call))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("UPDATE_FAIL", "${e.message}", null)
                    }
                }
            }
            "agentServiceStop" -> try {
                app.stopService(Intent(app, AgentForegroundService::class.java))
                result.success(true)
            } catch (e: Exception) {
                result.error("STOP_FAIL", "${e.message}", null)
            }
            "notifyConfigure" -> {
                val sounds = call.argument<Map<String, String>>("sounds") ?: emptyMap()
                val enabled = call.argument<Map<String, Boolean>>("enabled") ?: emptyMap()
                OvidNotifications.configure(app, sounds, enabled)
                result.success(true)
            }
            "notifyPost" -> result.success(
                OvidNotifications.post(
                    app,
                    call.argument<String>("channel") ?: OvidNotifications.AGENT,
                    call.argument<Number>("id")?.toInt() ?: 2000,
                    call.argument<String>("title") ?: "Ovid",
                    call.argument<String>("body") ?: "",
                    call.argument<String>("route"),
                ),
            )
            "notifyCancel" -> {
                call.argument<Number>("id")?.toInt()?.let { OvidNotifications.cancel(app, it) }
                result.success(true)
            }
            "notifyOpenChannelSettings" -> result.success(
                launch(app, OvidNotifications.channelSettingsIntent(
                    app, call.argument<String>("channel") ?: OvidNotifications.AGENT,
                )),
            )
            "notifyOpenAppSettings" -> result.success(
                launch(app, OvidNotifications.appNotificationSettingsIntent(app)),
            )
            "bgSetKeepActive" -> {
                BackgroundScheduleState.setKeepActive(
                    app,
                    call.argument<Boolean>("enabled") ?: false,
                    call.argument<Boolean>("master") ?: true,
                )
                result.success(true)
            }
            "bgStatus" -> result.success(status(app))
            "bgRequestExactAlarm" -> {
                if (exactAlarmsAllowed(app) || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                    result.success(true)
                } else {
                    // Opens "Alarms & reminders" for Ovid; the grant arrives
                    // asynchronously, so the card re-reads bgStatus on resume.
                    launch(
                        app,
                        Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${app.packageName}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(false)
                }
            }
            else -> return false
        }
        return true
    }

    fun startService(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun launch(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }
}
