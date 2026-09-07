package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import java.io.File
import java.io.FileInputStream
import java.net.URLConnection
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {
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

    private fun deviceService(result: MethodChannel.Result): OvidAccessibilityService? {
        val service = OvidAccessibilityService.instance
        if (service == null) {
            result.error(
                "SERVICE_DISABLED",
                "Control mode needs the Ovid accessibility service. Enable it in Settings > Accessibility > Ovid.",
                null,
            )
        }
        return service
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
    /// following a symlink. `O_CREAT or O_EXCL or O_NOFOLLOW` makes the create
    /// atomic: the destination must not exist, and the final path component is
    /// never resolved through a link. The copy is then written through that
    /// exclusively-opened descriptor, so nothing can substitute the file
    /// between the create and the write. A failed copy is unlinked, so a
    /// partial screenshot never survives to be read back.
    ///
    /// `Os.openat`/`Os.unlinkat`/`O_DIRECTORY` are not public SDK API, so the
    /// directory cannot be pinned by descriptor here; the Dart caller
    /// canonicalises the workspace and re-verifies containment of the result.
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
        // lstat, not isDirectory(): a symlink to a directory must not pass.
        require(OsConstants.S_ISDIR(Os.lstat(directoryPath).st_mode)) {
            "Screenshot directory is not a directory."
        }

        val destinationPath = File(directory, fileName).absolutePath
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
                destinationPath,
                OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
                    OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
                384, // 0600
            )
            var copied = false
            try {
                // Explicit read/write loop rather than FileInputStream/
                // FileOutputStream(FileDescriptor): those wrappers' fd
                // ownership is an unspecified libcore detail, and we must
                // close each descriptor exactly once so the failure path can
                // still unlink the destination. Os.write may be short.
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
                runCatching { Os.close(destinationFd) }
                if (!copied) runCatching { Os.remove(destinationPath) }
            }
        } finally {
            runCatching { Os.close(sourceFd) }
        }
        return destinationPath
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
        webViewHandler = OvidWebViewHandler(this, flutterEngine.dartExecutor.binaryMessenger)
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
                        result.success(OvidAccessibilityService.instance != null)
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
                    "deviceScreenshot" -> {
                        val service = deviceService(result) ?: return@setMethodCallHandler
                        service.takeScreen(result)
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

    override fun onDestroy() {
        safExportCoordinator.cleanup()
        super.onDestroy()
    }
}
