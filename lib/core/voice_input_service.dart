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

  /// Start listening. [onResult] receives partial and final transcripts.
  /// Returns false when unavailable or already listening.
  Future<bool> start(
    void Function(String text, bool isFinal) onResult, {
    String? localeId,
  }) async {
    if (_listening) return false;
    if (startOverrideForTest != null) {
      _listening = true;
      startOverrideForTest!(onResult);
      return true;
    }
    try {
      final ok = await _plugin.initialize();
      if (!ok) return false;
      _listening = true;
      await _plugin.listen(
        onResult: (r) => onResult(r.recognizedWords, r.finalResult),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          localeId: localeId,
        ),
      );
      return true;
    } catch (_) {
      _listening = false;
      return false;
    }
  }

  Future<void> stop() async {
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
