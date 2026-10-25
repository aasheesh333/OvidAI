package com.dhanuk.ovidai

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executor

/** Android's explicitly on-device recognizer, with downloaded-locale checks. */
internal class OnDeviceSpeechRecognizer(
    private val context: Context,
    private val executor: Executor,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val recognizers = mutableSetOf<SpeechRecognizer>()
    private var activeSession: String? = null
    private var activeRecognizer: SpeechRecognizer? = null
    private var pendingStart: MethodChannel.Result? = null
    private var shutdown = false
    private var foreground = true
    private var lifecycleGeneration = 0L

    /** Foreground transitions fence both new starts and delayed locale probes. */
    fun setForeground(value: Boolean) {
        if (value) {
            if (foreground) return
            foreground = true
            lifecycleGeneration++
            emit(
                mapOf(
                    "source" to "stt",
                    "type" to "foreground",
                    "generation" to lifecycleGeneration,
                ),
            )
            return
        }
        foreground = false
        lifecycleGeneration++
        // Emit even with no activeSession: Dart may still be awaiting a
        // capability or permission result and must invalidate that operation.
        cancel(null, notifyCancellation = true)
    }

    fun probe(locales: List<String>, complete: (Map<String, Any?>) -> Unit) {
        if (!canUseOnDevice()) {
            complete(
                mapOf(
                    "stt" to false,
                    "locales" to locales.associateWith { mapOf("stt" to false) },
                    "reason" to "On-device recognition needs Android 13 and a downloaded speech language.",
                ),
            )
            return
        }
        val recognizer = newRecognizer() ?: run {
            complete(mapOf("stt" to false, "locales" to emptyMap<String, Any>()))
            return
        }
        val support = linkedMapOf<String, Boolean>()
        fun finish() {
            recognizers.remove(recognizer)
            recognizer.destroy()
            complete(
                mapOf(
                    "stt" to support.values.any { it },
                    "locales" to locales.associateWith {
                        mapOf("stt" to (support[it] == true))
                    },
                ),
            )
        }
        fun next(index: Int) {
            if (shutdown) return
            if (index >= locales.size) {
                finish()
                return
            }
            val locale = locales[index]
            isDownloaded(recognizer, locale) { downloaded ->
                support[locale] = downloaded
                next(index + 1)
            }
        }
        next(0)
    }

    fun start(
        sessionId: String,
        localeId: String?,
        pauseForMs: Int,
        listenForMs: Int,
        result: MethodChannel.Result,
    ) {
        if (!foreground || shutdown || !canUseOnDevice() || localeId.isNullOrBlank() ||
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(false)
            return
        }
        val requestGeneration = lifecycleGeneration
        cancel(null)
        val recognizer = newRecognizer() ?: run {
            result.success(false)
            return
        }
        activeSession = sessionId
        activeRecognizer = recognizer
        pendingStart = result
        isDownloaded(recognizer, localeId) { downloaded ->
            if (!foreground || lifecycleGeneration != requestGeneration ||
                activeSession != sessionId || activeRecognizer !== recognizer || shutdown
            ) {
                finishStart(false)
                return@isDownloaded
            }
            if (!downloaded) {
                cancel(sessionId)
                return@isDownloaded
            }
            recognizer.setRecognitionListener(Listener(sessionId, recognizer))
            try {
                // Only the already verified on-device recognizer receives mic
                // audio. EXTRA_PREFER_OFFLINE is defence in depth, not a cloud
                // fallback: no generic SpeechRecognizer is ever constructed.
                recognizer.startListening(
                    recognitionIntent(localeId).apply {
                        putExtra(
                            RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                            pauseForMs.coerceAtLeast(1).toLong(),
                        )
                    },
                )
                handler.postDelayed({ stop(sessionId) }, listenForMs.coerceAtLeast(1).toLong())
                finishStart(true)
            } catch (_: Exception) {
                cancel(sessionId)
            }
        }
    }

    fun stop(sessionId: String) {
        if (activeSession != sessionId) return
        try {
            activeRecognizer?.stopListening()
        } catch (_: Exception) {
            cancel(sessionId)
        }
    }

    fun cancel(sessionId: String?, notifyCancellation: Boolean = false) {
        if (sessionId != null && activeSession != sessionId) return
        val cancelledSession = activeSession
        activeSession = null
        handler.removeCallbacksAndMessages(null)
        activeRecognizer?.let { recognizer ->
            runCatching { recognizer.cancel() }
            recognizers.remove(recognizer)
            runCatching { recognizer.destroy() }
        }
        activeRecognizer = null
        if (notifyCancellation) {
            // The microphone is already closed (or was never opened). Dart
            // must invalidate pending work even when sessionId is null.
            emit(
                mapOf(
                    "source" to "stt",
                    "type" to "cancelled",
                    "sessionId" to cancelledSession,
                    "generation" to lifecycleGeneration,
                ),
            )
        }
        finishStart(false)
    }

    fun shutdown() {
        if (shutdown) return
        cancel(null)
        shutdown = true
        for (recognizer in recognizers) runCatching { recognizer.destroy() }
        recognizers.clear()
    }

    private fun finishStart(started: Boolean) {
        val result = pendingStart ?: return
        pendingStart = null
        result.success(started)
    }

    private fun canUseOnDevice(): Boolean =
        !shutdown && Build.VERSION.SDK_INT >= 33 &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    private fun newRecognizer(): SpeechRecognizer? {
        if (!canUseOnDevice()) return null
        return try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also {
                recognizers.add(it)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun isDownloaded(
        recognizer: SpeechRecognizer,
        localeId: String,
        callback: (Boolean) -> Unit,
    ) {
        var completed = false
        fun complete(supported: Boolean) {
            if (completed) return
            completed = true
            callback(supported)
        }
        try {
            recognizer.checkRecognitionSupport(
                recognitionIntent(localeId),
                executor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(recognitionSupport: RecognitionSupport) {
                        complete(isInstalled(recognitionSupport, localeId))
                    }

                    override fun onError(error: Int) {
                        complete(false)
                    }
                },
            )
        } catch (_: Exception) {
            complete(false)
        }
    }

    private fun isInstalled(support: RecognitionSupport, localeId: String): Boolean {
        val requested = Locale.forLanguageTag(localeId)
        fun matches(tag: String): Boolean {
            val candidate = Locale.forLanguageTag(tag.replace('_', '-'))
            if (!candidate.language.equals(requested.language, ignoreCase = true)) return false
            return requested.country.isEmpty() || candidate.country.equals(requested.country, ignoreCase = true)
        }
        // Downloaded and supported are both required. Online language lists are
        // deliberately never consulted.
        return support.supportedOnDeviceLanguages.any(::matches) &&
            support.installedOnDeviceLanguages.any(::matches)
    }

    private fun recognitionIntent(localeId: String): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, localeId)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, localeId)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_SECURE, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }

    private inner class Listener(
        private val sessionId: String,
        private val recognizer: SpeechRecognizer,
    ) : RecognitionListener {
        private fun transcript(results: Bundle?, final: Boolean) {
            if (activeSession != sessionId || activeRecognizer !== recognizer) return
            val alternatives = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            val text = alternatives?.firstOrNull().orEmpty()
            emit(
                mapOf(
                    "source" to "stt",
                    "type" to "result",
                    "sessionId" to sessionId,
                    "text" to text,
                    "final" to final,
                ),
            )
            if (final) cleanupAfterResult(sessionId, recognizer)
        }

        override fun onPartialResults(partialResults: Bundle?) = transcript(partialResults, false)
        override fun onResults(results: Bundle?) = transcript(results, true)

        override fun onError(error: Int) {
            if (activeSession != sessionId || activeRecognizer !== recognizer) return
            emit(mapOf("source" to "stt", "type" to "error", "sessionId" to sessionId))
            cleanupAfterResult(sessionId, recognizer)
        }

        override fun onEndOfSpeech() {
            // Keep the session alive for onResults; the mic has already ended.
        }

        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit
        override fun onSegmentResults(segmentResults: Bundle) = Unit
        override fun onEndOfSegmentedSession() = Unit
        override fun onLanguageDetection(results: Bundle) = Unit
    }

    private fun cleanupAfterResult(sessionId: String, recognizer: SpeechRecognizer) {
        if (activeSession != sessionId || activeRecognizer !== recognizer) return
        activeSession = null
        activeRecognizer = null
        handler.removeCallbacksAndMessages(null)
        finishStart(false)
        recognizers.remove(recognizer)
        runCatching { recognizer.destroy() }
    }
}
