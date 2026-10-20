import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'diag.dart';

/// On-device text-to-speech for the vernacular voice-first mode (W9).
///
/// The app already ships on-device speech-to-text ([VoiceInputService]); the
/// reply side is deliberately just as small: the Android host exposes
/// `android.speech.tts.TextToSpeech` over the existing `ovid/native` channel.
/// No audio leaves the device and no API key is involved.
///
/// Callers treat every failure as "no audio" — the visual summary card is the
/// durable surface, so a device without a TTS engine never blocks a reply.
class VoiceReplyService {
  VoiceReplyService._();
  static final VoiceReplyService I = VoiceReplyService._();

  static const _native = MethodChannel('ovid/native');

  /// Test seam: replaces the platform channel.
  @visibleForTesting
  MethodChannel? channelOverrideForTest;

  /// Test seam: overrides availability.
  @visibleForTesting
  bool? availableOverrideForTest;

  /// Test seam: replaces [speak]; return false for "not spoken".
  @visibleForTesting
  Future<bool> Function(String text, String? localeId)? speakOverrideForTest;

  /// Test seam: replaces [stop].
  @visibleForTesting
  void Function()? stopOverrideForTest;

  MethodChannel get _channel => channelOverrideForTest ?? _native;

  /// Whether the host reported a usable TTS engine.
  Future<bool> isAvailable() async {
    final override = availableOverrideForTest;
    if (override != null) return override;
    try {
      final value = await _channel.invokeMethod<bool>('ttsAvailable');
      return value == true;
    } catch (e) {
      Diag.swallow('voice_reply.available', e);
      return false;
    }
  }

  /// Speaks [text] in [localeId] (`en-IN`, `hi-IN`, `ta-IN`). A null locale
  /// leaves the engine on the device default.
  ///
  /// Returns false when the text is empty, the engine is unavailable, or the
  /// platform call failed. Never throws.
  Future<bool> speak(String text, {String? localeId}) async {
    final body = text.trim();
    if (body.isEmpty) return false;
    final override = speakOverrideForTest;
    if (override != null) return override(body, localeId);
    try {
      final value = await _channel.invokeMethod<bool>('ttsSpeak', {
        'text': body,
        'locale': localeId,
      });
      return value == true;
    } catch (e) {
      Diag.swallow('voice_reply.speak', e);
      return false;
    }
  }

  /// Stops any in-flight utterance.
  Future<void> stop() async {
    final override = stopOverrideForTest;
    if (override != null) {
      override();
      return;
    }
    try {
      await _channel.invokeMethod<void>('ttsStop');
    } catch (e) {
      Diag.swallow('voice_reply.stop', e);
    }
  }

  /// The four voice-first languages (owner spec §3 Screen 1).
  ///
  /// Hinglish is dictated in Hindi but commonly rendered in Latin script, so
  /// it shares `hi-IN` with Hindi; [id] keeps the two labels distinct in the
  /// composer while [localeId] is what the STT/TTS engines receive.
  static const List<({String id, String label, String localeId})> languages = [
    (id: 'en', label: 'English', localeId: 'en-IN'),
    (id: 'hi', label: 'हिन्दी', localeId: 'hi-IN'),
    (id: 'hinglish', label: 'Hinglish', localeId: 'hi-IN'),
    (id: 'ta', label: 'தமிழ்', localeId: 'ta-IN'),
  ];

  /// The engine locale for a language [id] (`en`, `hi`, `hinglish`, `ta`).
  static String localeFor(String id) {
    for (final l in languages) {
      if (l.id == id) return l.localeId;
    }
    return id;
  }

  /// The composer label for a language [id].
  static String labelFor(String id) {
    for (final l in languages) {
      if (l.id == id) return l.label;
    }
    return id;
  }
}
