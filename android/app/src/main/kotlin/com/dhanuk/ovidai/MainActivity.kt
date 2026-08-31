package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import android.os.Build
import java.io.File
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {
    private val channelName = "ovid/native"

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
                    "readBootstrapPayload" -> {
                        // The sandbox bootstrap zip ships as
                        // lib/<abi>/libovid_bootstrap.so INSIDE the APK.
                        // With extractNativeLibs=false (Flutter default for
                        // minSdk >= 23) the PackageManager never extracts it
                        // to nativeLibraryDir — but we don't need it to: the
                        // payload IS a plain zip, readable straight out of
                        // the installed APK.  This avoids doubling storage
                        // (no extracted copy alongside the APK copy).
                        try {
                            val apkPath = applicationInfo.sourceDir
                            val zip = ZipFile(apkPath)
                            // Pick the payload matching the device's REAL ABI
                            // (first entry in SUPPORTED_ABIS). Falling back to
                            // arm64 on an x86_64 device must never happen —
                            // that was the 'Permission denied' exec fault.
                            var entry = Build.SUPPORTED_ABIS
                                .map { zip.getEntry("lib/$it/libovid_bootstrap.so") }
                                .firstOrNull { it != null }
                            if (entry == null) entry = zip.getEntry("lib/arm64-v8a/libovid_bootstrap.so")
                            if (entry == null) {
                                zip.close()
                                result.error("MISSING", "no libovid_bootstrap.so in APK", null)
                            } else {
                                val bytes = zip.getInputStream(entry).readBytes()
                                zip.close()
                                result.success(bytes)
                            }
                        } catch (e: Exception) {
                            result.error("READ_FAIL", "bootstrap read failed: ${e.message}", null)
                        }
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
