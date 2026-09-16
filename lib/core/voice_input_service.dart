import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// P5 (2026-09-13): on-device speech-to-text for the composer and the
/// control overlay. Wraps `speech_to_text` behind a small, testable seam so
/// widgets never touch the plugin directly.
class VoiceInputService {
  VoiceInputService._();
  static final VoiceInputService I = VoiceInputService._();

  /// Test seam: when set, the service reports available and routes
  /// start/stop through these callbacks instead of the real plugin.
  bool? availabilityOverrideForTest;
  void Function(void Function(String text, bool isFinal) onResult)?
  startOverrideForTest;
  void Function()? stopOverrideForTest;

  SpeechToText? _speech;
  bool _listening = false;
  bool get isListening => _listening;

  /// Client-side silence watchdog (ChatGPT-like end-of-speech): the
  /// platform does not always honor [pauseFor], so when no result at all
  /// has arrived for the silence window the service stops itself — the
  /// platform answers stop() with a final result, which flows into the
  /// normal auto-send path. Re-armed on every result; cancelled by
  /// stop()/cancel().
  Timer? _silenceTimer;

  /// Test seam: overrides the microphone permission request.
  Future<bool> Function()? ensureMicrophonePermissionForTest;

  /// Explicitly request the microphone permission. The overlay only exists
  /// while the app is backgrounded, where the STT plugin's implicit
  /// permission prompt never surfaces — so callers (overlay mic, composer)
  /// must ask first instead of relying on `initialize()`.
  Future<bool> ensureMicrophonePermission() async {
    final override = ensureMicrophonePermissionForTest;
    if (override != null) return override();
    try {
      var status = await Permission.microphone.status;
      if (status.isGranted) return true;
      status = await Permission.microphone.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  SpeechToText get _plugin => _speech ??= SpeechToText();

  /// Whether speech recognition is available on this device. False when the
  /// plugin reports unsupported or the user has not granted permission.
  Future<bool> isAvailable() async {
    if (availabilityOverrideForTest != null) {
      return availabilityOverrideForTest!;
    }
    try {
      return await _plugin.initialize();
    } catch (_) {
      return false;
    }
  }

  /// Default silence auto-stop (user stops speaking) and session cap.
  /// ChatGPT-like end-of-speech: ~2s of silence finalizes dictation.
  static const defaultPauseFor = Duration(seconds: 2);
  static const defaultListenFor = Duration(seconds: 60);

  /// Listen options for a press-to-talk session. Visible for tests so the
  /// silence auto-stop and cap stay pinned.
  @visibleForTesting
  SpeechListenOptions listenOptionsForTest({
    Duration? pauseFor,
    Duration? listenFor,
    String? localeId,
  }) => SpeechListenOptions(
    partialResults: true,
    cancelOnError: true,
    listenMode: ListenMode.dictation,
    localeId: localeId,
    pauseFor: pauseFor ?? defaultPauseFor,
    listenFor: listenFor ?? defaultListenFor,
  );

  /// Start listening. [onResult] receives partial and final transcripts.
  /// Listening auto-stops on silence ([pauseFor], enforced by the
  /// [silenceStop] watchdog as well as the platform) or at [listenFor].
  /// Returns false when unavailable or already listening.
  Future<bool> start(
    void Function(String text, bool isFinal) onResult, {
    String? localeId,
    Duration? pauseFor,
    Duration? listenFor,
    Duration? silenceStop,
  }) async {
    if (_listening) return false;
    final silenceWindow = silenceStop ?? pauseFor ?? defaultPauseFor;
    void guarded(String text, bool isFinal) {
      _pokeSilenceWatchdog(silenceWindow);
      onResult(text, isFinal);
    }

    if (startOverrideForTest != null) {
      _listening = true;
      _pokeSilenceWatchdog(silenceWindow);
      startOverrideForTest!(guarded);
      return true;
    }
    try {
      final ok = await _plugin.initialize();
      if (!ok) return false;
      _listening = true;
      _pokeSilenceWatchdog(silenceWindow);
      await _plugin.listen(
        onResult: (r) => guarded(r.recognizedWords, r.finalResult),
        listenOptions: listenOptionsForTest(
          pauseFor: pauseFor,
          listenFor: listenFor,
          localeId: localeId,
        ),
      );
      return true;
    } catch (_) {
      _silenceTimer?.cancel();
      _listening = false;
      return false;
    }
  }

  void _pokeSilenceWatchdog(Duration window) {
    _silenceTimer?.cancel();
    if (!_listening) return;
    _silenceTimer = Timer(window, () {
      if (!_listening) return;
      // Silence outlasted the window: stop() prompts the platform for
      // its final result, which auto-sends through the normal path.
      unawaited(stop());
    });
  }

  Future<void> stop() async {
    _silenceTimer?.cancel();
    if (stopOverrideForTest != null) {
      _listening = false;
      stopOverrideForTest!();
      return;
    }
    try {
      await _plugin.stop();
    } catch (_) {}
    _listening = false;
  }

  Future<void> cancel() async {
    _silenceTimer?.cancel();
    if (stopOverrideForTest != null) {
      _listening = false;
      stopOverrideForTest!();
      return;
    }
    try {
      await _plugin.cancel();
    } catch (_) {}
    _listening = false;
  }
}
