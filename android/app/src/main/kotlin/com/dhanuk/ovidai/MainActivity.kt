package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {
    private val channelName = "ovid/native"
    private val safExportRequestCode = 7407
    private val screenCaptureRequestCode = 7408

    /// Pending screenshot result while the OS screen-capture consent dialog
    /// (pre-Android-11 MediaProjection route) is on screen. Single-flight:
    /// a second capture attempt while one is pending gets SCREENSHOT_BUSY.
    private var pendingScreenshotResult: MethodChannel.Result? = null
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

    /// True when our own process is currently the foreground app. Used to
    /// verify a self-launch actually landed: Android 10+ background-start
    /// restrictions can swallow startActivity without throwing.
    private fun isAppForegroundedNow(): Boolean {
        return try {
            val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
            val processes = am.runningAppProcesses ?: return false
            processes.any {
                it.processName == packageName &&
                    it.importance ==
                        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun deviceService(result: MethodChannel.Result): OvidAccessibilityService? {
        val service = OvidAccessibilityService.instance
        if (service != null) return service
        if (!isAccessibilityServiceEnabled(this)) {
            result.error(
                "SERVICE_DISABLED",
                "Control mode needs the Ovid accessibility service. Enable it in Settings > Accessibility > Ovid.",
                null,
            )
            return null
        }
        // Enabled in settings but not yet bound — typical right after the app
        // process restarts, while the OS rebinds asynchronously. NEVER block
        // the main thread waiting here: onServiceConnected is delivered on
        // this same thread, so waiting would starve the very bind being
        // waited on (and risk an ANR), leaving the service permanently
        // "gone" until the user toggles it. Answer immediately; the Dart
        // side retries with backoff while the bind lands.
        result.error(
            "SERVICE_CONNECTING",
            "Ovid accessibility service is still connecting after app restart. Retrying automatically — no need to toggle it off and on.",
            null,
        )
        return null
    }

    /// Pre-Android-11 screenshot route: MediaProjection needs a one-time OS
    /// consent dialog, so the MethodChannel result is parked until
    /// onActivityResult delivers the grant/denial. Same cache-file success
    /// contract as the accessibility-service path.
    private fun requestLegacyScreenshot(result: MethodChannel.Result) {
        try {
            if (pendingScreenshotResult != null) {
                result.error(
                    "SCREENSHOT_BUSY",
                    "Another screenshot capture is already in progress.",
                    null,
                )
                return
            }
            val manager =
                getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
            if (manager == null) {
                result.error(
                    "SCREENSHOT_FAILED",
                    "Screen capture is unavailable on this device.",
                    null,
                )
                return
            }
            pendingScreenshotResult = result
            try {
                startActivityForResult(
                    manager.createScreenCaptureIntent(),
                    screenCaptureRequestCode,
                )
            } catch (e: Exception) {
                pendingScreenshotResult = null
                result.error(
                    "SCREENSHOT_FAILED",
                    "Could not request screen-capture permission: ${e.message}",
                    null,
                )
            }
        } catch (e: Exception) {
            result.error(
                "SCREENSHOT_FAILED",
                e.message ?: "Screenshot could not be started.",
                null,
            )
        }
    }

    /// Drains one MediaProjection frame into the shared device-captures
    /// cache. Runs off the main thread; always releases the virtual
    /// display, projection, and reader, and always settles the result.
    private fun captureLegacyScreenshot(
        result: MethodChannel.Result,
        resultCode: Int,
        data: Intent,
    ) {
        Thread {
            var projection: MediaProjection? = null
            var virtualDisplay: VirtualDisplay? = null
            var reader: ImageReader? = null
            var bitmap: Bitmap? = null
            try {
                val manager =
                    getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                projection = manager.getMediaProjection(resultCode, data)
                val metrics = resources.displayMetrics
                val width = metrics.widthPixels
                val height = metrics.heightPixels
                reader = ImageReader.newInstance(
                    width, height, PixelFormat.RGBA_8888, 2,
                )
                virtualDisplay = projection.createVirtualDisplay(
                    "ovid-capture",
                    width, height, metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    reader.surface, null, null,
                )
                var image = reader.acquireLatestImage()
                val deadline = SystemClock.uptimeMillis() + 3000
                while (image == null && SystemClock.uptimeMillis() < deadline) {
                    SystemClock.sleep(100)
                    image = reader.acquireLatestImage()
                }
                val frame = image
                    ?: throw IllegalStateException("No screen frame arrived.")
                try {
                    val planes = frame.planes
                    val buffer = planes[0].buffer
                    val pixelStride = planes[0].pixelStride
                    val rowStride = planes[0].rowStride
                    val rowPadding = rowStride - pixelStride * width
                    var raw = Bitmap.createBitmap(
                        width + rowPadding / pixelStride,
                        height,
                        Bitmap.Config.ARGB_8888,
                    )
                    raw.copyPixelsFromBuffer(buffer)
                    bitmap = if (rowPadding > 0) {
                        val cropped = Bitmap.createBitmap(raw, 0, 0, width, height)
                        raw.recycle()
                        cropped
                    } else {
                        raw
                    }
                    val directory = File(cacheDir, "device-captures")
                    if (!directory.exists() && !directory.mkdirs()) {
                        throw IllegalStateException("Could not create screenshot cache")
                    }
                    val file = File(directory, "screen-${System.currentTimeMillis()}.png")
                    FileOutputStream(file).use { output ->
                        if (!bitmap!!.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                            throw IllegalStateException("Could not encode screenshot")
                        }
                    }
                    val path = file.absolutePath
                    runOnUiThread { result.success(path) }
                } finally {
                    try {
                        frame.close()
                    } catch (_: Exception) {}
                }
            } catch (e: Throwable) {
                runOnUiThread {
                    result.error(
                        "SCREENSHOT_FAILED",
                        e.message ?: "Screenshot could not be captured.",
                        null,
                    )
                }
            } finally {
                try {
                    bitmap?.recycle()
                } catch (_: Exception) {}
                try {
                    virtualDisplay?.release()
                } catch (_: Exception) {}
                try {
                    projection?.stop()
                } catch (_: Exception) {}
                try {
                    reader?.close()
                } catch (_: Exception) {}
            }
        }.start()
    }

    private fun completeDeviceAction(
        result: MethodChannel.Result,
        action: DeviceActionResult,
    ) {
        if (action.ok) {
            result.success(action.value)
        } else {
            result.error(action.code, action.message, null)
        }
    }

    /// Copy a screenshot into the agent workspace without ever clobbering or
    /// following a symlink. The destination directory is pinned by descriptor
    /// with `O_NOFOLLOW`, and the destination file is created relative to that
    /// pinned directory descriptor via `/proc/self/fd/<dirFd>/<fileName>` with
    /// `O_CREAT or O_EXCL or O_NOFOLLOW`. This prevents parent-directory TOCTOU
    /// replacement races and leaf symlink traversal. Bytes are written through
    /// that exclusively-opened descriptor. A failed copy is removed only after
    /// confirming that the directory entry still matches the created inode, so
    /// an unowned replacement file is never deleted.
    private fun copyDeviceScreenshot(
        sourcePath: String,
        directoryPath: String,
        fileName: String,
    ): String {
        require(File(fileName).name == fileName && fileName != "." && fileName != "..") {
            "Invalid screenshot filename."
        }
        val directory = File(directoryPath)
        require(directory.canonicalPath == directory.absolutePath) {
            "Screenshot directory is not a canonical directory."
        }

        // Pin directory descriptor with O_NOFOLLOW to prevent parent symlink substitution.
        val dirFd = Os.open(
            directoryPath,
            OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
            0,
        )
        try {
            require(OsConstants.S_ISDIR(Os.fstat(dirFd).st_mode)) {
                "Screenshot directory is not a directory."
            }
            val pfd = ParcelFileDescriptor.dup(dirFd)
            try {
                val procDestPath = "/proc/self/fd/${pfd.fd}/$fileName"
                val sourceFd = Os.open(
                    sourcePath,
                    OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
                    0,
                )
                try {
                    require(OsConstants.S_ISREG(Os.fstat(sourceFd).st_mode)) {
                        "Screenshot source is not a regular file."
                    }
                    val destinationFd = Os.open(
                        procDestPath,
                        OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
                            OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
                        384, // 0600
                    )
                    var copied = false
                    val destStat = Os.fstat(destinationFd)
                    try {
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val read = Os.read(sourceFd, buffer, 0, buffer.size)
                            if (read <= 0) break
                            var written = 0
                            while (written < read) {
                                written += Os.write(destinationFd, buffer, written, read - written)
                            }
                        }
                        Os.fsync(destinationFd)
                        copied = true
                    } finally {
                        if (!copied) {
                            runCatching {
                                val checkStat = Os.lstat(procDestPath)
                                if (checkStat.st_dev == destStat.st_dev && checkStat.st_ino == destStat.st_ino) {
                                    Os.remove(procDestPath)
                                }
                            }
                        }
                        runCatching { Os.close(destinationFd) }
                    }
                } finally {
                    runCatching { Os.close(sourceFd) }
                }
            } finally {
                runCatching { pfd.close() }
            }
        } finally {
            runCatching { Os.close(dirFd) }
        }
        return File(directory, fileName).absolutePath
    }

    /// The ABI the PackageManager chose for THIS install — the last path
    /// segment of nativeLibraryDir (…/lib/arm64, …/lib/arm, …). This is
    /// the ISA of the running process; Build.SUPPORTED_ABIS is only the
    /// device's capability list and can disagree (wrong-split sideload).
    private fun processAbi(): String? {
        val dir = applicationInfo.nativeLibraryDir ?: return null
        return when (dir.trimEnd('/').substringAfterLast('/')) {
            "arm64" -> "arm64-v8a"
            "arm" -> "armeabi-v7a"
            "x86_64" -> "x86_64"
            "x86" -> "x86"
            else -> null
        }
    }

    /// Payload entry name for a process ABI.
    private fun payloadNameFor(abi: String?): String? = when (abi) {
        "arm64-v8a" -> "arm64-v8a"
        "armeabi-v7a", "armeabi" -> "armeabi-v7a"
        "x86_64" -> "x86_64"
        "x86" -> "x86"
        else -> null
    }

    /// ISA family — payload fallback never crosses families.
    private fun abiFamily(abi: String): String = when {
        abi.startsWith("arm64") -> "arm64"
        abi.startsWith("armeabi") || abi.startsWith("armv7") || abi == "arm" -> "arm32"
        abi.startsWith("x86_64") -> "x64"
        abi.startsWith("x86") -> "x32"
        else -> "unknown"
    }

    private var webViewHandler: OvidWebViewHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        webViewHandler = OvidWebViewHandler(
            this,
            flutterEngine,
            flutterEngine.dartExecutor.binaryMessenger
        )
        // Overlay events (send/stop) flow service → Dart on this channel.
        OvidAccessibilityService.overlayEventListener = { method, argument ->
            runOnUiThread {
                try {
                    MethodChannel(
                        flutterEngine.dartExecutor.binaryMessenger,
                        channelName
                    ).invokeMethod(method, argument)
                } catch (_: Exception) {
                    // Dart gone (teardown race): the tap already happened.
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                    "agentServiceStart" -> {
                        // Foreground service: keeps the app alive while the
                        // agent works. Args: title, text (notification copy).
                        try {
                            val intent = Intent(this, AgentForegroundService::class.java)
                            intent.putExtra(
                                AgentForegroundService.EXTRA_TITLE,
                                call.argument<String>("title") ?: "Ovid AI"
                            )
                            intent.putExtra(
                                AgentForegroundService.EXTRA_TEXT,
                                call.argument<String>("text") ?: "Agent is working…"
                            )
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                                e.javaClass.name.contains("ForegroundServiceStartNotAllowedException")) {
                                "FGS_BACKGROUND_DENIED"
                            } else {
                                "START_FAIL"
                            }
                            result.error(code, "${e.message}", null)
                        }
                    }
                    "agentServiceUpdate" -> {
                        try {
                            val intent = Intent(this, AgentForegroundService::class.java)
                            intent.putExtra(
                                AgentForegroundService.EXTRA_TITLE,
                                call.argument<String>("title") ?: "Ovid AI"
                            )
                            intent.putExtra(
                                AgentForegroundService.EXTRA_TEXT,
                                call.argument<String>("text") ?: "Agent is working…"
                            )
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("UPDATE_FAIL", "${e.message}", null)
                        }
                    }
                    "agentServiceStop" -> {
                        try {
                            stopService(Intent(this, AgentForegroundService::class.java))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("STOP_FAIL", "${e.message}", null)
                        }
                    }
                    "deviceServiceEnabled" -> {
                        result.success(isAccessibilityServiceEnabled(this))
                    }
                    "getSecurityStatus" -> {
                        result.success(SecurityCheck.getDeviceSecuritySummary(this))
                    }
                    "deviceOpenAccessibilitySettings" -> {
                        try {
                            val component = ComponentName(this, OvidAccessibilityService::class.java)
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    putExtra(":settings:fragment_args_key", component.flattenToString())
                                }
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_FAILED", "Could not open Accessibility settings: ${e.message}", null)
                        }
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
                    "deviceOpenApp" -> {
                        val packageName = call.argument<String>("package")
                        val sessionId = call.argument<String>("sessionId")
                        if (packageName.isNullOrBlank()) {
                            result.error("BAD_ARGS", "deviceOpenApp requires package name.", null)
                        } else {
                            try {
                                val targetPkg = packageName.trim()
                                val isSelf = targetPkg == "com.dhanuk.ovidai" || targetPkg == this.packageName
                                val launchIntent = if (isSelf) {
                                    Intent(this, MainActivity::class.java).apply {
                                        if (!sessionId.isNullOrBlank()) {
                                            putExtra("sessionId", sessionId)
                                        }
                                        addFlags(
                                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                                Intent.FLAG_ACTIVITY_NEW_TASK or
                                                Intent.FLAG_ACTIVITY_SINGLE_TOP
                                        )
                                    }
                                } else {
                                    packageManager.getLaunchIntentForPackage(targetPkg)?.apply {
                                        addFlags(
                                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                                        )
                                    }
                                }

                                if (launchIntent != null) {
                                    if (isSelf) {
                                        // Request the launch, then VERIFY Ovid actually
                                        // reaches the foreground: Android 10+
                                        // background-start restrictions can swallow
                                        // startActivity without throwing, which used
                                        // to report success while the user stayed in
                                        // the other app. Poll off the channel thread
                                        // (never block it), retry once, and report
                                        // LAUNCH_BLOCKED when it never lands so Dart
                                        // can say so instead of going silent.
                                        try {
                                            startActivity(launchIntent)
                                        } catch (_: Throwable) {
                                            try {
                                                val pi = PendingIntent.getActivity(
                                                    this,
                                                    0,
                                                    launchIntent,
                                                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                                                )
                                                pi.send()
                                            } catch (_: Throwable) {}
                                        }
                                        Thread {
                                            val deadline =
                                                android.os.SystemClock.uptimeMillis() + 3500
                                            var retried = false
                                            var landed = isAppForegroundedNow()
                                            while (!landed &&
                                                android.os.SystemClock.uptimeMillis() < deadline
                                            ) {
                                                android.os.SystemClock.sleep(250)
                                                if (!retried) {
                                                    try {
                                                        startActivity(launchIntent)
                                                    } catch (_: Throwable) {}
                                                    retried = true
                                                }
                                                landed = isAppForegroundedNow()
                                            }
                                            runOnUiThread {
                                                if (landed) {
                                                    result.success(true)
                                                } else {
                                                    result.error(
                                                        "LAUNCH_BLOCKED",
                                                        "Ovid could not come to the foreground (the system blocked the launch).",
                                                        null,
                                                    )
                                                }
                                            }
                                        }.start()
                                        return@setMethodCallHandler
                                    } else {
                                        val service = OvidAccessibilityService.instance
                                        if (service != null) {
                                            service.startActivity(launchIntent)
                                        } else {
                                            startActivity(launchIntent)
                                        }
                                    }
                                    result.success(true)
                                } else {
                                    result.error("APP_NOT_FOUND", "App $packageName has no launch intent or is not installed.", null)
                                }
                            } catch (e: Exception) {
                                // Permanent fix for MIUI / OEM background start restrictions:
                                // Fall back to PendingIntent send which bypasses background activity start checks.
                                try {
                                    val targetPkg = packageName.trim()
                                    val fallbackIntent = packageManager.getLaunchIntentForPackage(targetPkg)
                                    if (fallbackIntent != null) {
                                        fallbackIntent.addFlags(
                                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                                        )
                                        val pi = PendingIntent.getActivity(
                                            this,
                                            0,
                                            fallbackIntent,
                                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                                        )
                                        pi.send()
                                        result.success(true)
                                        return@setMethodCallHandler
                                    }
                                } catch (_: Throwable) {}
                                result.error("LAUNCH_FAILED", "Could not launch app $packageName: ${e.message}", null)
                            }
                        }
                    }
                    "deviceRead" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val forceFull = call.argument<Boolean>("full") == true ||
                            call.argument<String>("mode") == "full"
                        result.success(service.readScreen(forceFull))
                    }
                    "deviceTap" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val handle = call.argument<Number>("node")?.toInt()
                            ?: call.argument<Number>("handle")?.toInt()
                        val x = call.argument<Number>("x")?.toFloat()
                        val y = call.argument<Number>("y")?.toFloat()
                        completeDeviceAction(result, service.tap(handle, x, y))
                    }
                    "deviceType" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("BAD_ARGS", "deviceType requires text.", null)
                        } else {
                            val handle = call.argument<Number>("node")?.toInt()
                                ?: call.argument<Number>("handle")?.toInt()
                            completeDeviceAction(
                                result,
                                service.type(
                                    handle = handle,
                                    text = text,
                                    submit = call.argument<Boolean>("submit") == true,
                                ),
                            )
                        }
                    }
                    "deviceSwipe" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val fromX = call.argument<Number>("from_x")?.toFloat()
                        val fromY = call.argument<Number>("from_y")?.toFloat()
                        val toX = call.argument<Number>("to_x")?.toFloat()
                        val toY = call.argument<Number>("to_y")?.toFloat()
                        if (fromX == null || fromY == null || toX == null || toY == null) {
                            result.error("BAD_ARGS", "deviceSwipe requires from_x, from_y, to_x, and to_y.", null)
                        } else {
                            completeDeviceAction(
                                result,
                                service.swipe(
                                    fromX,
                                    fromY,
                                    toX,
                                    toY,
                                    call.argument<Number>("duration_ms")?.toLong() ?: 500L,
                                ),
                            )
                        }
                    }
                    "deviceSystemNav" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val action = call.argument<String>("action")
                        if (action == null) {
                            result.error("BAD_ARGS", "deviceSystemNav requires an action.", null)
                        } else {
                            completeDeviceAction(result, service.systemNav(action))
                        }
                    }
                    "deviceLongPress" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val handle = call.argument<Number>("node")?.toInt()
                            ?: call.argument<Number>("handle")?.toInt()
                        val x = call.argument<Number>("x")?.toFloat()
                        val y = call.argument<Number>("y")?.toFloat()
                        completeDeviceAction(
                            result,
                            service.longPress(
                                handle = handle,
                                x = x,
                                y = y,
                                durationMs = call.argument<Number>("duration_ms")?.toLong()
                                    ?: call.argument<Number>("durationMs")?.toLong(),
                            ),
                        )
                    }
                    "deviceScroll" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val direction = call.argument<String>("direction")
                        if (direction == null) {
                            result.error("BAD_ARGS", "deviceScroll requires a direction.", null)
                        } else {
                            val handle = call.argument<Number>("node")?.toInt()
                                ?: call.argument<Number>("handle")?.toInt()
                            completeDeviceAction(
                                result,
                                service.scrollNode(handle, direction),
                            )
                        }
                    }
                    "deviceKey" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        val key = call.argument<String>("key")
                        if (key == null) {
                            result.error("BAD_ARGS", "deviceKey requires key.", null)
                        } else {
                            completeDeviceAction(result, service.pressKey(key))
                        }
                    }
                    "deviceScreenshot" -> {
                        // Android 11+ uses the accessibility-service capture;
                        // older releases go through the MediaProjection consent
                        // flow below (same cache-file success contract).
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            val service =
                                deviceService(result) ?: return@setMethodCallHandler
                            service.takeScreen(result)
                        } else {
                            requestLegacyScreenshot(result)
                        }
                    }
                    "deviceOverlayShow" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        completeDeviceAction(result, service.showOverlay())
                    }
                    "deviceOverlayHide" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        completeDeviceAction(result, service.hideOverlay())
                    }
                    "deviceOverlaySetText" -> {
                        OvidAccessibilityService.instance
                            ?.setOverlayInputText(call.argument<String>("text").orEmpty())
                        result.success(true)
                    }
                    "deviceOverlayMicListening" -> {
                        OvidAccessibilityService.instance
                            ?.setOverlayMicListening(call.argument<Boolean>("listening") == true)
                        result.success(true)
                    }
                    "deviceOverlaySetPrompt" -> {
                        OvidAccessibilityService.instance
                            ?.setOverlayPrompt(call.argument<String>("prompt").orEmpty())
                        result.success(true)
                    }
                    "deviceOverlayLive" -> {
                        OvidAccessibilityService.instance
                            ?.setOverlayLive(call.argument<Boolean>("live") == true)
                        result.success(true)
                    }
                    "requestBatteryExemption" -> {
                        try {
                            val pm = getSystemService(POWER_SERVICE) as PowerManager
                            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                                result.success(true)
                            } else {
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")
                                )
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
                    "deviceCopyScreenshot" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val directoryPath = call.argument<String>("directoryPath")
                        val fileName = call.argument<String>("fileName")
                        if (sourcePath.isNullOrBlank() || directoryPath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("BAD_ARGS", "Screenshot copy requires sourcePath, directoryPath, and fileName.", null)
                        } else {
                            try {
                                result.success(copyDeviceScreenshot(sourcePath, directoryPath, fileName))
                            } catch (error: ErrnoException) {
                                val code = if (error.errno == OsConstants.EEXIST) "DEST_EXISTS" else "COPY_FAILED"
                                result.error(code, "Could not copy screenshot: ${error.message}", error.errno)
                            } catch (error: Throwable) {
                                result.error("COPY_FAILED", "Could not copy screenshot: ${error.message}", null)
                            }
                        }
                    }
                    "shareFile" -> {
                        val filePath = call.argument<String>("filePath")
                        val title = call.argument<String>("title") ?: "Share"
                        if (filePath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "shareFile requires filePath.", null)
                        } else {
                            try {
                                val file = File(filePath)
                                if (!file.exists()) {
                                    result.error("FILE_NOT_FOUND", "File does not exist: $filePath", null)
                                } else {
                                    val uri = androidx.core.content.FileProvider.getUriForFile(
                                        this,
                                        "${applicationContext.packageName}.fileprovider",
                                        file
                                    )
                                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                                        type = URLConnection.guessContentTypeFromName(file.name) ?: "*/*"
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    val chooser = Intent.createChooser(shareIntent, title).apply {
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(chooser)
                                    result.success(true)
                                }
                            } catch (e: Exception) {
                                result.error("SHARE_FAILED", "Could not share file: ${e.message}", null)
                            }
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
                        // Dart registers the notification-Stop callback.
                        AgentNotificationBridge.stopHandler = {
                            // Invoke back into Dart on the same channel.
                            runOnUiThread {
                                MethodChannel(
                                    flutterEngine.dartExecutor.binaryMessenger,
                                    channelName
                                ).invokeMethod("onAgentStop", null)
                            }
                        }
                        result.success(true)
                    }
                    "agentExitHandler" -> {
                        // Dart registers the notification-Exit callback.
                        AgentNotificationBridge.exitHandler = {
                            runOnUiThread {
                                MethodChannel(
                                    flutterEngine.dartExecutor.binaryMessenger,
                                    channelName
                                ).invokeMethod("onAgentExit", null)
                                try {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                        finishAndRemoveTask()
                                    } else {
                                        finish()
                                    }
                                } catch (_: Exception) {}
                            }
                        }
                        result.success(true)
                    }
                    "readBootstrapPayload" -> {
                        // The sandbox bootstrap zip ships as
                        // lib/<abi>/libovid_bootstrap.so INSIDE the APK.
                        // With extractNativeLibs=false (Flutter default for
                        // minSdk >= 23) the PackageManager never extracts it
                        // to nativeLibraryDir — but we don't need it to: the
                        // payload IS a plain zip, readable straight out of
                        // the installed APK.  This avoids doubling storage
                        // (no extracted copy alongside the APK copy).
                        //
                        // ABI selection: the RUNNING PROCESS's ABI is the
                        // only truth — the last segment of
                        // nativeLibraryDir (…/lib/arm64) is the ABI the
                        // PackageManager chose for THIS install.
                        // Build.SUPPORTED_ABIS lists device CAPABILITY
                        // (arm64 first on every modern phone), so picking
                        // by it hands a 32-bit process (wrong-split
                        // sideload) an arm64 payload → the kernel refuses
                        // the exec with EACCES and the sanity check dies
                        // with "Permission denied" AFTER a full extraction.
                        try {
                            val apkPath = applicationInfo.sourceDir
                            val zip = ZipFile(apkPath)
                            val processAbi = processAbi()
                            // Exact match for the process ABI first…
                            var entry = payloadNameFor(processAbi)
                                ?.let { zip.getEntry("lib/$it/libovid_bootstrap.so") }
                            // …then same-ISA-family fallback ONLY. Never
                            // cross families: a 32-bit process cannot run
                            // an arm64 payload and vice versa.
                            if (entry == null) {
                                entry = Build.SUPPORTED_ABIS
                                    .filter { abiFamily(it) == abiFamily(processAbi ?: "") }
                                    .map { zip.getEntry("lib/$it/libovid_bootstrap.so") }
                                    .firstOrNull { it != null }
                            }
                            if (entry == null) {
                                val available = zip.entries().asSequence()
                                    .filter { it.name.startsWith("lib/") && it.name.endsWith("/libovid_bootstrap.so") }
                                    .map { it.name.split('/')[1] }
                                    .toList()
                                    .joinToString()
                                zip.close()
                                result.error(
                                    "MISSING",
                                    "No sandbox payload for this install's ABI " +
                                        "(process: ${processAbi ?: "unknown"}; " +
                                        "APK has payloads for: $available). " +
                                        "Install the APK build that matches this device.",
                                    null
                                )
                            } else {
                                val bytes = zip.getInputStream(entry).readBytes()
                                val abi = entry.name.split('/')[1]
                                zip.close()
                                result.success(mapOf("bytes" to bytes, "abi" to abi))
                            }
                        } catch (e: Exception) {
                            result.error("READ_FAIL", "bootstrap read failed: ${e.message}", null)
                        }
                    }
                    "getProcessAbi" -> {
                        // The ABI this app process is actually running as.
                        result.success(processAbi() ?: Build.SUPPORTED_ABIS.firstOrNull())
                    }
                    "getSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    "isDataExecAllowed" -> {
                        // Probe: write a tiny script in app data and try to
                        // exec it via /system/bin/sh. If it works, the W^X
                        // restriction is not enforced on this device/ROM.
                        // Android 6-9 (API < 29): restriction doesn't exist
                        // — always allowed, but we probe anyway for ROMs
                        // with custom SELinux policies (MIUI etc.).
                        val script = File(applicationInfo.dataDir, "ovid_exec_probe.sh")
                        script.writeText("#!/system/bin/sh\nexit 0\n")
                        script.setExecutable(true)
                        val pb = ProcessBuilder("/system/bin/sh", script.absolutePath)
                        pb.redirectErrorStream(true)
                        val rc = try {
                            pb.start().waitFor()
                        } catch (e: Exception) {
                            42
                        }
                        script.delete()
                        result.success(rc == 0)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == screenCaptureRequestCode) {
            val pending = pendingScreenshotResult
            pendingScreenshotResult = null
            if (pending == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            if (resultCode != Activity.RESULT_OK || data == null) {
                pending.error(
                    "SCREENSHOT_DENIED",
                    "Screen-capture permission was denied.",
                    null,
                )
                return
            }
            captureLegacyScreenshot(pending, resultCode, data)
            return
        }
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val sid = intent.getStringExtra("sessionId")
        if (!sid.isNullOrBlank()) {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, channelName).invokeMethod("onSelectSession", sid)
            }
        }
    }

    override fun onDestroy() {
        OvidAccessibilityService.overlayEventListener = null
        safExportCoordinator.cleanup()
        super.onDestroy()
    }
}
