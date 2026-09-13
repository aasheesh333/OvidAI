package com.dhanuk.ovidai

import android.content.Context
import android.os.Build
import android.os.Debug
import java.io.File

object SecurityCheck {

    private val KNOWN_ROOT_PATHS = arrayOf(
        "/system/app/Superuser.apk",
        "/sbin/su",
        "/system/bin/su",
        "/system/xbin/su",
        "/data/local/xbin/su",
        "/data/local/bin/su",
        "/system/sd/xbin/su",
        "/system/bin/failsafe/su",
        "/data/local/su",
        "/su/bin/su",
        "/system/xbin/daemonsu",
        "/system/etc/init.d/99SuperSUDaemon",
        "/system/bin/.ext/.su",
        "/system/etc/.has_su_daemon",
    )

    private val KNOWN_HOOK_PACKAGES = arrayOf(
        "de.robv.android.xposed.installer",
        "com.saurik.substrate",
        "org.meowcat.edxposed.manager",
        "top.canyie.magiskdual",
        "com.topjohnwu.magisk",
    )

    fun isRooted(): Boolean {
        // Check build tags
        val buildTags = Build.TAGS
        if (buildTags != null && buildTags.contains("test-keys")) {
            return true
        }

        // Check known su paths
        for (path in KNOWN_ROOT_PATHS) {
            try {
                if (File(path).exists()) return true
            } catch (_: Exception) {}
        }

        // Check which su
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("which", "su"))
            val exitCode = process.waitFor()
            exitCode == 0
        } catch (_: Exception) {
            false
        }
    }

    fun isDebuggerAttached(): Boolean {
        return Debug.isDebuggerConnected() || Debug.waitingForDebugger()
    }

    fun isHookingFrameworkPresent(context: Context): Boolean {
        // Check for Frida server default port / named pipe
        try {
            val fridaPaths = arrayOf(
                "/data/local/tmp/frida-server",
                "/data/local/tmp/re.frida.server",
            )
            for (fp in fridaPaths) {
                if (File(fp).exists()) return true
            }
        } catch (_: Exception) {}

        // Check for Xposed in stack trace
        try {
            throw Exception("DetectHook")
        } catch (e: Exception) {
            for (stackTraceElement in e.stackTrace) {
                val cls = stackTraceElement.className
                if (cls.contains("de.robv.android.xposed.XposedBridge") ||
                    cls.contains("com.android.internal.os.ZygoteInit") &&
                    stackTraceElement.methodName.contains("xposed")) {
                    return true
                }
            }
        }

        // Check hook packages
        val pm = context.packageManager
        for (pkg in KNOWN_HOOK_PACKAGES) {
            try {
                pm.getPackageInfo(pkg, 0)
                return true
            } catch (_: Exception) {}
        }

        return false
    }

    fun getDeviceSecuritySummary(context: Context): Map<String, Boolean> {
        return mapOf(
            "isRooted" to isRooted(),
            "isDebuggerAttached" to isDebuggerAttached(),
            "isHookingFrameworkPresent" to isHookingFrameworkPresent(context),
        )
    }
}
