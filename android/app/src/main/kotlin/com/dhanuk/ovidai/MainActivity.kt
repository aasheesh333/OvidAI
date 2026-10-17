package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.app.ActivityManager
import android.app.PendingIntent
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
import java.util.concurrent.Executors
import java.util.zip.ZipFile
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener

/** Rebind on every host attachment: a retained Dart engine need not re-register. */
internal fun bindNotificationHostCallbacks(emit: (String) -> Unit, exitHost: () -> Unit) {
    AgentNotificationBridge.stopHandler = {
        emit("onAgentStop")
    }
    AgentNotificationBridge.exitHandler = {
        emit("onAgentExit")
        exitHost()
    }
}

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
    // The foreground service keeps the process eligible for background work;
    // retaining the engine keeps the actual Dart scheduler alive after UI close.
    // Process death still requires reopen/reconciliation, never a second engine.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(OvidEngineHost.ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    private val channelName = "ovid/native"
    private val safExportRequestCode = 7407

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

    private var webViewHandler: OvidWebViewHandler? = null

    private fun refreshNotificationCallbacks(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        // The engine is retained; the Activity is not. Exit resolves only the
        // current host and does not keep a destroyed Activity alive.
        val host = java.lang.ref.WeakReference(this)
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        bindNotificationHostCallbacks(
            emit = { method -> handler.post { channel.invokeMethod(method, null) } },
            exitHost = {
                handler.post {
                    host.get()?.let { activity ->
                        if (!activity.isDestroyed) {
                            try { activity.finishAndRemoveTask() } catch (_: Exception) { }
                        }
                    }
                }
            },
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ovid/html-artifact", HtmlArtifactViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        FlutterEngineCache.getInstance().put(OvidEngineHost.ENGINE_ID, flutterEngine)
        refreshNotificationCallbacks(flutterEngine)
        BackgroundChannel.bindRuntime(flutterEngine)
        webViewHandler = OvidWebViewHandler(
            this,
            flutterEngine,
            flutterEngine.dartExecutor.binaryMessenger
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, rawResult ->
                val result = rawResult
                // Service, alarms, notifications: shared with the headless
                // engine (BackgroundChannel) so both behave identically.
                if (BackgroundChannel.handle(applicationContext, call, result)) {
                    return@setMethodCallHandler
                }
                when (call.method) {
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
                    "getNativeLibraryDir" -> {
                        // This directory is exec-ALLOWED on Android 10+:
                        // the PackageManager labels extracted native libs
                        // with a special SELinux label that permits execve.
                        val dir = applicationInfo.nativeLibraryDir
                        if (dir != null) {
                            result.success(dir)
                        } else {
                            result.error("UNAVAILABLE", "nativeLibraryDir is null", null)
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
                    "getBackgroundHealth" -> {
                        // Pure check for background-health guidance: reports
                        // the manufacturer plus the battery-exemption state
                        // WITHOUT opening any system UI (unlike
                        // requestBatteryExemption above).
                        try {
                            val exempt = try {
                                val pm = getSystemService(POWER_SERVICE) as PowerManager
                                pm.isIgnoringBatteryOptimizations(packageName)
                            } catch (_: Exception) {
                                true
                            }
                            result.success(
                                mapOf(
                                    "manufacturer" to (Build.MANUFACTURER ?: ""),
                                    "batteryExempt" to exempt,
                                ),
                            )
                        } catch (e: Exception) {
                            result.error(
                                "HEALTH_FAILED",
                                e.message ?: "Could not read background health.",
                                null,
                            )
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
                    "agentStopHandler" -> {
                        refreshNotificationCallbacks(flutterEngine)
                        result.success(true)
                    }
                    "agentExitHandler" -> {
                        refreshNotificationCallbacks(flutterEngine)
                        result.success(true)
                    }
                    "getSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    else -> result.notImplemented()
                }
            }
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
        liveHosts++
        super.onCreate(savedInstanceState)
        routeSessionSelection(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeSessionSelection(intent)
    }

    override fun onDestroy() {
        safExportCoordinator.cleanup()
        val engine = flutterEngine
        super.onDestroy()
        // The retained engine keeps running schedules after the UI closes:
        // hand its channel back to the Activity-free background handler so
        // calls never reach this destroyed Activity.
        liveHosts = maxOf(0, liveHosts - 1)
        if (liveHosts == 0 && engine != null &&
            FlutterEngineCache.getInstance().get(OvidEngineHost.ENGINE_ID) === engine
        ) {
            BackgroundChannel.attachHeadless(applicationContext, engine)
        }
    }

    companion object {
        /// MainActivity instances between onCreate and onDestroy.
        private var liveHosts = 0
    }
}
