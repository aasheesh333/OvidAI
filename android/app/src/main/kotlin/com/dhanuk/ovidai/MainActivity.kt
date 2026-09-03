package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import android.content.Intent
import android.os.Build
import java.io.File
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {
    private val channelName = "ovid/native"

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                            result.error("START_FAIL", "${e.message}", null)
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
                    "agentStopHandler" -> {
                        // Dart registers the notification-Stop callback.
                        AgentNotificationBridge.stopHandler = {
                            // Invoke back into Dart on the same channel.
                            MethodChannel(
                                flutterEngine.dartExecutor.binaryMessenger,
                                channelName
                            ).invokeMethod("onAgentStop", null)
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
}
