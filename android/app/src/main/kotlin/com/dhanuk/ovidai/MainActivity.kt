package com.dhanuk.ovidai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
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
import android.media.AudioAttributes
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
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.system.Os
import android.util.Log
import android.system.OsConstants
import android.system.ErrnoException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.URLConnection
import java.util.Locale
import java.util.concurrent.Executor
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

    // Voice stays on device: only transcript text crosses the Dart boundary.
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsText: String? = null
    private var ttsUtteranceId: String? = null
    // The Dart/logical id stays stable across pause/resume; the native engine
    // receives a fresh id for every synthesis so stale callbacks cannot match.
    private var ttsNativeUtteranceId: String? = null
    private var ttsRequestCounter = 0L
    private var ttsOffset = 0
    private var ttsChunkOffset = 0
    private var ttsPaused = false
    // Structured metadata only: no prompt, answer, transcript, or account text.
    private var ttsRequestedLocale: String? = null
    private var ttsResolvedLocale: String? = null
    private var speechRecognizer: OnDeviceSpeechRecognizer? = null
    private var voiceEventSink: EventChannel.EventSink? = null

    private fun emitVoiceEvent(event: Map<String, Any?>) {
        runOnUiThread { voiceEventSink?.success(event) }
    }

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
        stopTts(notify = false)
        tts?.shutdown()
        ttsReady = false
        tts = TextToSpeech(this) { status ->
            runOnUiThread { ttsReady = status == TextToSpeech.SUCCESS }
        }.also { engine ->
            engine.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            engine.setOnUtteranceProgressListener(TtsProgress())
        }
        speechRecognizer?.shutdown()
        speechRecognizer = OnDeviceSpeechRecognizer(
            this,
            Executor { command -> runOnUiThread(command) },
            ::emitVoiceEvent,
        )
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "ovid/voice_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    voiceEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    voiceEventSink = null
                }
            })
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
                    "voiceCapability" -> {
                        val locales = call.argument<List<String>>("locales")
                            ?.filter { it.isNotBlank() }
                            ?.distinct()
                            .orEmpty()
                        probeVoiceCapability(locales, result)
                    }
                    "voiceSttStart" -> {
                        val sessionId = call.argument<String>("sessionId")
                        val localeId = call.argument<String>("locale")
                        if (sessionId.isNullOrBlank()) {
                            result.success(false)
                        } else {
                            speechRecognizer?.start(
                                sessionId,
                                localeId,
                                call.argument<Number>("pauseFor")?.toInt() ?: 2000,
                                call.argument<Number>("listenFor")?.toInt() ?: 60000,
                                result,
                            ) ?: result.success(false)
                        }
                    }
                    "voiceSttStop" -> {
                        call.argument<String>("sessionId")?.let { speechRecognizer?.stop(it) }
                        result.success(null)
                    }
                    "voiceSttCancel" -> {
                        speechRecognizer?.cancel(call.argument<String>("sessionId"))
                        result.success(null)
                    }
                    "ttsAvailable" -> {
                        result.success(ttsReady && tts?.voices.orEmpty().any(::isOfflineVoice))
                    }
                    "ttsSpeak" -> startTts(call, result)
                    "ttsPause" -> result.success(pauseTts(call.argument<String>("utteranceId")))
                    "ttsResume" -> result.success(resumeTts(call.argument<String>("utteranceId")))
                    "ttsStop" -> {
                        stopTts()
                        result.success(null)
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

    private fun probeVoiceCapability(locales: List<String>, result: MethodChannel.Result) {
        val requested = locales.ifEmpty { listOf("en-IN", "hi-IN", "pa-IN", "ta-IN") }
        val ttsLocales = requested.associateWith { offlineVoice(tts, it) != null }
        val recognizer = speechRecognizer
        if (recognizer == null) {
            result.success(mapOf("stt" to false, "tts" to false, "locales" to emptyMap<String, Any>()))
            return
        }
        recognizer.probe(requested) { sttProbe ->
            runOnUiThread {
                val sttLocales = sttProbe["locales"] as? Map<*, *> ?: emptyMap<String, Any>()
                val support = requested.associateWith { locale ->
                    val stt = (sttLocales[locale] as? Map<*, *>)?.get("stt") == true
                    mapOf("stt" to stt, "tts" to (ttsLocales[locale] == true))
                }
                val stt = support.values.any { it["stt"] == true }
                val tts = ttsReady && support.values.any { it["tts"] == true }
                result.success(
                    mapOf(
                        "stt" to stt,
                        "tts" to tts,
                        "locales" to support,
                        "reason" to if (stt || tts) {
                            null
                        } else {
                            "On-device voice needs Android 13 and downloaded speech and playback languages."
                        },
                    ),
                )
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun isOfflineVoice(voice: Voice): Boolean =
        !voice.isNetworkConnectionRequired &&
            !voice.features.contains(TextToSpeech.Engine.KEY_FEATURE_NETWORK_SYNTHESIS) &&
            !voice.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)

    private fun offlineVoice(engine: TextToSpeech?, localeId: String?): Voice? {
        if (engine == null || !ttsReady) return null
        val voices = engine.voices.orEmpty().filter(::isOfflineVoice)
        if (localeId.isNullOrBlank()) {
            return engine.voice?.takeIf(::isOfflineVoice) ?: voices.firstOrNull()
        }
        val requested = Locale.forLanguageTag(localeId.replace('_', '-'))
        return voices.firstOrNull { voice ->
            val locale = voice.locale
            locale.language.equals(requested.language, ignoreCase = true) &&
                (requested.country.isEmpty() || locale.country.equals(requested.country, ignoreCase = true))
        }
    }

    private fun evidenceToken(value: String?): String {
        if (value.isNullOrBlank()) return "default"
        return if (Regex("[A-Za-z0-9_.:-]{1,96}").matches(value)) value else "withheld"
    }

    private fun emitTtsEvidence(
        event: String,
        logicalId: String,
        nativeId: String,
    ) {
        // App-authored utterance timing only, not independent player provenance.
        // No hidden/SystemApi UID/session data is queried or inferred.
        Log.i(
            "OvidTtsEvidence",
            "v3 event=$event logical=${evidenceToken(logicalId)} " +
                "native=${evidenceToken(nativeId)} " +
                "requested=${evidenceToken(ttsRequestedLocale)} " +
                "resolved=${evidenceToken(ttsResolvedLocale)} " +
                "epochMs=${System.currentTimeMillis()}",
        )
    }

    private fun ttsResult(utteranceId: String, locale: String?, accepted: Boolean): Map<String, Any?> =
        mapOf(
            "accepted" to accepted,
            "utteranceId" to utteranceId,
            "locale" to locale,
        )

    private fun startTts(call: MethodCall, result: MethodChannel.Result) {
        val engine = tts
        val text = call.argument<String>("text")
        val utteranceId = call.argument<String>("utteranceId")
        if (engine == null || !ttsReady || text.isNullOrBlank() || utteranceId.isNullOrBlank()) {
            result.success(ttsResult(utteranceId.orEmpty(), null, false))
            return
        }
        val voice = offlineVoice(engine, call.argument<String>("locale"))
        if (voice == null) {
            result.success(ttsResult(utteranceId, null, false))
            return
        }
        val offset = (call.argument<Number>("offset")?.toInt() ?: 0).coerceIn(0, text.length)
        if (offset >= text.length) {
            result.success(ttsResult(utteranceId, null, false))
            return
        }
        stopTts(notify = false)
        if (engine.setVoice(voice) != TextToSpeech.SUCCESS) {
            result.success(ttsResult(utteranceId, null, false))
            return
        }
        ttsText = text
        ttsUtteranceId = utteranceId
        ttsNativeUtteranceId = "$utteranceId:synthesis-${++ttsRequestCounter}"
        ttsRequestedLocale = call.argument<String>("locale")
        ttsResolvedLocale = voice.locale.toLanguageTag()
        ttsOffset = offset
        ttsChunkOffset = offset
        ttsPaused = false
        val accepted = engine.speak(
            text.substring(offset),
            TextToSpeech.QUEUE_FLUSH,
            null,
            ttsNativeUtteranceId,
        ) == TextToSpeech.SUCCESS
        if (accepted) {
            emitTtsEvidence("accepted", utteranceId, ttsNativeUtteranceId.orEmpty())
        } else {
            clearTtsState()
        }
        result.success(ttsResult(utteranceId, voice.locale.toLanguageTag(), accepted))
    }

    private fun pauseTts(utteranceId: String?): Boolean {
        val engine = tts ?: return false
        if (utteranceId == null || utteranceId != ttsUtteranceId || ttsPaused) return false
        ttsPaused = true
        if (engine.stop() != TextToSpeech.SUCCESS) {
            ttsPaused = false
            return false
        }
        emitVoiceEvent(ttsEvent("paused", utteranceId))
        return true
    }

    private fun resumeTts(utteranceId: String?): Boolean {
        val engine = tts ?: return false
        val text = ttsText ?: return false
        if (utteranceId == null || utteranceId != ttsUtteranceId || !ttsPaused) return false
        val offset = ttsOffset.coerceIn(0, text.length)
        if (offset >= text.length) return false
        ttsNativeUtteranceId = "$utteranceId:synthesis-${++ttsRequestCounter}"
        ttsChunkOffset = offset
        ttsPaused = false
        val accepted = engine.speak(
            text.substring(offset),
            TextToSpeech.QUEUE_FLUSH,
            null,
            ttsNativeUtteranceId,
        ) == TextToSpeech.SUCCESS
        if (!accepted) ttsPaused = true
        return accepted
    }

    private fun ttsEvent(type: String, utteranceId: String): MutableMap<String, Any?> =
        mutableMapOf(
            "source" to "tts",
            "type" to type,
            "utteranceId" to ttsUtteranceId,
            "locale" to tts?.voice?.locale?.toLanguageTag(),
        )

    private fun clearTtsState() {
        ttsText = null
        ttsUtteranceId = null
        ttsNativeUtteranceId = null
        ttsOffset = 0
        ttsChunkOffset = 0
        ttsPaused = false
        ttsRequestedLocale = null
        ttsResolvedLocale = null
    }

    private fun stopTts(notify: Boolean = true) {
        val utteranceId = ttsUtteranceId
        // Invalidate before stopping: callbacks posted by stop() must find no
        // matching request even when they arrive on another binder thread.
        clearTtsState()
        tts?.stop()
        if (notify && utteranceId != null) {
            emitVoiceEvent(
                mapOf(
                    "source" to "tts",
                    "type" to "stopped",
                    "utteranceId" to utteranceId,
                ),
            )
        }
    }

    @Suppress("OVERRIDE_DEPRECATION")
    private inner class TtsProgress : UtteranceProgressListener() {
        // TextToSpeech may invoke any of these on a binder/engine thread. All
        // identity checks and state reads/writes are serialized on the activity
        // main thread; no callback mutates playback state on its arrival thread.
        override fun onStart(utteranceId: String) {
            runOnUiThread {
                if (utteranceId == ttsNativeUtteranceId && !ttsPaused) {
                    val logicalId = ttsUtteranceId ?: return@runOnUiThread
                    emitTtsEvidence("start", logicalId, utteranceId)
                    emitVoiceEvent(ttsEvent("start", utteranceId))
                }
            }
        }

        override fun onRangeStart(utteranceId: String, start: Int, end: Int, frame: Int) {
            runOnUiThread {
                if (utteranceId != ttsNativeUtteranceId || ttsPaused) return@runOnUiThread
                val absoluteStart = ttsChunkOffset + start
                ttsOffset = maxOf(ttsOffset, absoluteStart)
                emitVoiceEvent(
                    ttsEvent("progress", utteranceId).apply {
                        put("start", absoluteStart)
                        put("end", ttsChunkOffset + end)
                    },
                )
            }
        }

        override fun onDone(utteranceId: String) {
            runOnUiThread {
                if (utteranceId != ttsNativeUtteranceId || ttsPaused) return@runOnUiThread
                val logicalId = ttsUtteranceId ?: return@runOnUiThread
                ttsOffset = ttsText?.length ?: ttsOffset
                emitTtsEvidence("done", logicalId, utteranceId)
                emitVoiceEvent(ttsEvent("done", utteranceId))
                clearTtsState()
            }
        }

        override fun onStop(utteranceId: String, interrupted: Boolean) {
            runOnUiThread {
                if (utteranceId != ttsNativeUtteranceId || ttsPaused) return@runOnUiThread
                emitVoiceEvent(ttsEvent("stopped", utteranceId))
                clearTtsState()
            }
        }

        override fun onError(utteranceId: String) {
            runOnUiThread {
                if (utteranceId != ttsNativeUtteranceId || ttsPaused) return@runOnUiThread
                emitVoiceEvent(ttsEvent("error", utteranceId))
                clearTtsState()
            }
        }

        override fun onError(utteranceId: String, errorCode: Int) = onError(utteranceId)
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
            "notificationsEnabled" -> result.success(
                OvidNotifications.notificationsEnabled(app),
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

    override fun onStart() {
        super.onStart()
        // This only re-arms the fence. A fresh explicit user start is still
        // required; no pending recognition is resumed here.
        speechRecognizer?.setForeground(true)
    }

    override fun onStop() {
        // Dictation is foreground-only. Invalidate even before a native
        // session exists (capability/permission awaits may still be pending).
        speechRecognizer?.setForeground(false)
        super.onStop()
    }

    override fun onDestroy() {
        safExportCoordinator.cleanup()
        speechRecognizer?.shutdown()
        speechRecognizer = null
        stopTts(notify = false)
        tts?.shutdown()
        tts = null
        ttsReady = false
        voiceEventSink = null
        super.onDestroy()
    }
}
