package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.URLConnection
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener

/** Notification tap: consume the app route extra once (see OvidNotifications). */
internal fun routeNotificationIntent(intent: Intent?, openRoute: (String) -> Unit) {
    val route = intent?.getStringExtra(OvidNotifications.EXTRA_ROUTE) ?: return
    intent.removeExtra(OvidNotifications.EXTRA_ROUTE)
    if (route.isBlank() || !route.startsWith("/") || route.length > 200) return
    openRoute(route)
}

/** Consume a routed launch extra so host recreation cannot replay selection. */
internal fun routeSessionIntent(intent: Intent?, selectSession: (String) -> Unit) {
    val sessionId = intent?.getStringExtra("sessionId") ?: return
    if (sessionId.isBlank()) return
    selectSession(sessionId)
    intent.removeExtra("sessionId")
}

class MainActivity : FlutterActivity() {
    private val channelName = "ovid/native"
    private val safExportRequestCode = 7407

    // Cold start (CT-009): onCreate runs before Dart has registered its
    // `ovid/native` handler, so a pushed onOpenRoute would be lost. The
    // launch route is parked here and Dart pulls it with takePendingRoute.
    private var pendingRoute: String? = null
    private var pendingSessionId: String? = null

    private val safExportCoordinator = SafExportCoordinator<ParcelFileDescriptor, Uri> { source, destination ->
        val output = contentResolver.openOutputStream(destination, "w")
            ?: throw IllegalStateException("Destination could not be opened")
        output.use {
            FileInputStream(source.fileDescriptor).copyTo(it)
            it.flush()
        }
    }

    private fun openPinnedSource(sourcePath: String): ParcelFileDescriptor {
        val descriptor = Os.open(
            sourcePath,
            OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
            0,
        )
        return try {
            ParcelFileDescriptor.dup(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }

    private fun channelResult(result: MethodChannel.Result) = object : SafExportResult {
        override fun success(exported: Boolean) {
            runOnUiThread { result.success(exported) }
        }

        override fun error(code: String, message: String) {
            runOnUiThread { result.error(code, message, null) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ovid/html-artifact", HtmlArtifactViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        val nativeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        nativeChannel
            .setMethodCallHandler { call, rawResult ->
                val result = rawResult
                if (handleNativeBackground(call, result)) {
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "takePendingRoute" -> {
                        val route = pendingRoute
                            ?: pendingSessionId?.let { "/c/$it" }
                        pendingRoute = null
                        pendingSessionId = null
                        result.success(route)
                    }
                    "getInstallReferrer" -> {
                        val referrer = InstallReferrerClient.newBuilder(this).build()
                        var completed = false
                        fun complete(value: String?) {
                            if (completed) return
                            completed = true
                            runCatching { referrer.endConnection() }
                            result.success(value)
                        }
                        try {
                            referrer.startConnection(object : InstallReferrerStateListener {
                                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                                    if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
                                        try {
                                            complete(referrer.installReferrer.installReferrer)
                                        } catch (_: Exception) {
                                            complete(null)
                                        }
                                    } else {
                                        complete(null)
                                    }
                                }

                                override fun onInstallReferrerServiceDisconnected() {
                                    complete(null)
                                }
                            })
                        } catch (_: Exception) {
                            complete(null)
                        }
                    }
                    "getSecurityStatus" -> {
                        result.success(SecurityCheck.getDeviceSecuritySummary(this))
                    }
                    "deviceOpenSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_FAILED", "Could not open Settings: ${e.message}", null)
                        }
                    }
                    "requestBatteryExemption" -> {
                        try {
                            val pm = getSystemService(POWER_SERVICE) as PowerManager
                            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                                result.success(true)
                            } else {
                                // Play builds do not declare
                                // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS (not an
                                // approvable core use); without it the direct
                                // request dialog is unavailable, so open the
                                // system battery-optimization list instead.
                                val declared = packageManager
                                    .getPackageInfo(packageName, android.content.pm.PackageManager.GET_PERMISSIONS)
                                    .requestedPermissions.orEmpty()
                                    .contains(android.Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                val intent = if (declared) {
                                    Intent(
                                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                        Uri.parse("package:$packageName")
                                    )
                                } else {
                                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                }
                                startActivity(intent)
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "openAutoStartSettings" -> {
                        // OEM autostart whitelists (Xiaomi/Oppo/Vivo/OnePlus/
                        // Huawei/Samsung/Asus/Lenovo/Nokia) are the #1 reason
                        // Ovid is swiped-killed in the background: the
                        // battery exemption alone does not stop those ROMs.
                        // Try each known component; fall back to the app's
                        // system details page (always resolvable).
                        try {
                            val targets = listOf(
                                ComponentName(
                                    "com.miui.securitycenter",
                                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                                ),
                                ComponentName(
                                    "com.coloros.safecenter",
                                    "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                                ),
                                ComponentName(
                                    "com.oppo.safe",
                                    "com.oppo.safe.permission.startup.StartupAppListActivity"
                                ),
                                ComponentName(
                                    "com.vivo.permissionmanager",
                                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
                                ),
                                ComponentName(
                                    "com.oneplus.security",
                                    "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
                                ),
                                ComponentName(
                                    "com.huawei.systemmanager",
                                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                                ),
                                ComponentName(
                                    "com.samsung.android.lool",
                                    "com.samsung.android.sm.ui.battery.BatteryActivity"
                                ),
                                ComponentName(
                                    "com.asus.mobilemanager",
                                    "com.asus.mobilemanager.autostart.AutoStartActivity"
                                ),
                                ComponentName(
                                    "com.lenovo.security",
                                    "com.lenovo.security.purebackground.PureBackgroundActivity"
                                ),
                                ComponentName(
                                    "com.nokia.mid",
                                    "com.nokia.mid.MidActivity"
                                ),
                            )
                            var opened = false
                            for (component in targets) {
                                try {
                                    val intent = Intent().apply {
                                        setComponent(component)
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    if (intent.resolveActivity(packageManager) != null) {
                                        startActivity(intent)
                                        opened = true
                                        break
                                    }
                                } catch (_: Exception) {
                                }
                            }
                            if (!opened) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.parse("package:$packageName")
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "shareText" -> {
                        val text = call.argument<String>("text")
                        if (text.isNullOrBlank()) {
                            result.error("BAD_ARGS", "shareText requires text.", null)
                        } else {
                            try {
                                startActivity(NativeShare.chooser(NativeShare.textIntent(text), call.argument<String>("title") ?: "Share"))
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("SHARE_FAILED", "Could not open sharing: ${e.message}", null)
                            }
                        }
                    }
                    "shareTranscript" -> {
                        val text = call.argument<String>("text")
                        if (text.isNullOrBlank()) {
                            result.error("BAD_ARGS", "shareTranscript requires text.", null)
                        } else {
                            Thread {
                                try {
                                    val intent = NativeShare.transcriptIntent(this, text, call.argument<String>("fileName") ?: "ovid-chat.txt")
                                    runOnUiThread {
                                        try {
                                            startActivity(NativeShare.chooser(intent, call.argument<String>("title") ?: "Share chat"))
                                            result.success(true)
                                        } catch (e: Exception) {
                                            result.error("SHARE_FAILED", "Could not open sharing: ${e.message}", null)
                                        }
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("SHARE_FAILED", "Could not prepare transcript: ${e.message}", null) }
                                }
                            }.start()
                        }
                    }
                    "openFile" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "openFile requires filePath.", null)
                        } else {
                            Thread {
                                try {
                                    val intent = NativeShare.viewIntent(this, filePath, call.argument<String>("mime"))
                                    runOnUiThread {
                                        try {
                                            startActivity(intent)
                                            result.success(true)
                                        } catch (e: android.content.ActivityNotFoundException) {
                                            result.success(false)
                                        } catch (e: Exception) {
                                            result.error("OPEN_FAILED", "Could not open file: ${e.message}", null)
                                        }
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("OPEN_FAILED", "Could not prepare file: ${e.message}", null) }
                                }
                            }.start()
                        }
                    }
                    "shareFile" -> {
                        val filePath = call.argument<String>("filePath")
                        val title = call.argument<String>("title") ?: "Share"
                        if (filePath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "shareFile requires filePath.", null)
                        } else {
                            Thread {
                                try {
                                    val intent = NativeShare.fileIntent(this, filePath)
                                    runOnUiThread {
                                        try {
                                            startActivity(NativeShare.chooser(intent, title))
                                            result.success(true)
                                        } catch (e: Exception) {
                                            result.error("SHARE_FAILED", "Could not open sharing: ${e.message}", null)
                                        }
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("SHARE_FAILED", "Could not prepare file: ${e.message}", null) }
                                }
                            }.start()
                        }
                    }
                    "safExportFile" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val requestedName = call.argument<String>("fileName")
                        if (sourcePath.isNullOrBlank() || requestedName.isNullOrBlank()) {
                            result.error("BAD_ARGS", "Missing sourcePath or fileName", null)
                        } else {
                            try {
                                val source = openPinnedSource(sourcePath)
                                if (!safExportCoordinator.begin(source, channelResult(result))) {
                                    return@setMethodCallHandler
                                }
                                val fileName = File(requestedName).name
                                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = URLConnection.guessContentTypeFromName(fileName)
                                        ?: "application/octet-stream"
                                    putExtra(Intent.EXTRA_TITLE, fileName)
                                }
                                try {
                                    startActivityForResult(intent, safExportRequestCode)
                                } catch (e: Exception) {
                                    safExportCoordinator.fail(
                                        "LAUNCH_FAILED",
                                        "Could not open file destination: ${e.message}",
                                    )
                                }
                            } catch (e: Exception) {
                                result.error("NOT_FOUND", "Source file could not be opened: ${e.message}", null)
                            }
                        }
                    }
                    "getSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Alarm + notification subset of the `ovid/native` channel. */
    private fun handleNativeBackground(call: MethodCall, result: MethodChannel.Result): Boolean {
        val app = applicationContext
        when (call.method) {
            "timeZoneId" -> result.success(java.util.TimeZone.getDefault().id)
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
                launchIntent(
                    OvidNotifications.channelSettingsIntent(
                        app, call.argument<String>("channel") ?: OvidNotifications.AGENT,
                    ),
                ),
            )
            "notifyOpenAppSettings" -> result.success(
                launchIntent(OvidNotifications.appNotificationSettingsIntent(app)),
            )
            else -> return false
        }
        return true
    }

    private fun launchIntent(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != safExportRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null) {
            safExportCoordinator.complete(null)
            return
        }

        Thread {
            safExportCoordinator.complete(destination)
        }.start()
    }

    private fun routeSessionSelection(intent: Intent?) {
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            routeSessionIntent(intent) { sid ->
                MethodChannel(messenger, channelName).invokeMethod("onSelectSession", sid)
            }
            routeNotificationIntent(intent) { route ->
                MethodChannel(messenger, channelName).invokeMethod("onOpenRoute", route)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Dart is not listening yet: park the launch route for takePendingRoute.
        routeSessionIntent(intent) { sid -> pendingSessionId = sid }
        routeNotificationIntent(intent) { route -> pendingRoute = route }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeSessionSelection(intent)
    }

    override fun onDestroy() {
        safExportCoordinator.cleanup()
        super.onDestroy()
    }
}
