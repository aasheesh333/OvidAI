package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import java.io.File

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
                    "isDataExecAllowed" -> {
                        // Probe: write a tiny script in app data and try to
                        // exec it via /system/bin/sh. If it works, the W^X
                        // restriction is not enforced on this device/ROM.
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
