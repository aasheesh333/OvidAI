import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/voice_capability.dart';
import '../../../core/voice_input_service.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The language saved in Settings, installed by the shell so this library has
/// no `core/state.dart` import and can compile for web.
String v2SavedVoiceLanguage = '';

/// Seam over [VoiceInputService] so the composer can be tested with a fake.
abstract interface class V2VoiceCancellationEvents {
  Stream<void> get lifecycleCancellations;
}

abstract class V2VoiceService {
  Future<bool> isAvailable();

  Future<bool> ensureMicrophonePermission();

  Future<bool> start(
    void Function(String text, bool isFinal) onResult, {
    String? localeId,
  });

  Future<void> stop();

  Future<void> cancel();
}

/// Production adapter around the on-device STT singleton.
class V2PlatformVoiceService
    implements V2VoiceService, V2VoiceCancellationEvents {
  const V2PlatformVoiceService();

  static const V2PlatformVoiceService instance = V2PlatformVoiceService();

  VoiceInputService get _service => VoiceInputService.I;

  @override
  Stream<void> get lifecycleCancellations => _service.lifecycleCancellations;

  @override
  Future<bool> isAvailable() => _service.isAvailable();

  @override
  Future<bool> ensureMicrophonePermission() =>
      _service.ensureMicrophonePermission();

  Future<bool> isLocaleAvailable(String localeId) =>
      _service.isLocaleAvailable(localeId);

  @override
  Future<bool> start(
    void Function(String text, bool isFinal) onResult, {
    String? localeId,
  }) => _service.start(onResult, localeId: localeId);

  @override
  Future<void> stop() => _service.stop();

  @override
  Future<void> cancel() => _service.cancel();
}

extension V2VoiceServiceOnDevice on V2VoiceService {
  Future<bool> supportsLocale(String localeId) {
    final service = this;
    if (service is V2PlatformVoiceService) {
      return service.isLocaleAvailable(localeId);
    }
    return isAvailable();
  }
}

/// STT locales for the four voice-first languages.
///
/// Hinglish is dictated in Hindi but rendered in Latin script, so it shares
/// `hi-IN`; [id] keeps the labels distinct in the UI.
abstract final class V2VoiceLocales {
  static const List<({String id, String label, String localeId})> languages = [
    (id: 'en', label: 'English', localeId: 'en-IN'),
    (id: 'hi', label: 'हिन्दी', localeId: 'hi-IN'),
    (id: 'hinglish', label: 'Hinglish', localeId: 'hi-IN'),
    (id: 'pa', label: 'ਪੰਜਾਬੀ', localeId: 'pa-IN'),
    (id: 'ta', label: 'தமிழ்', localeId: 'ta-IN'),
  ];

  /// The STT locale for a language id. Unknown ids fall back to English.
  static String localeFor(String id) {
    final wanted = id.trim().toLowerCase();
    for (final language in languages) {
      if (language.id == wanted) return language.localeId;
    }
    return 'en-IN';
  }

  static String labelFor(String id) {
    final wanted = id.trim().toLowerCase();
    for (final language in languages) {
      if (language.id == wanted) return language.label;
    }
    return 'English';
  }

  /// The dictation language the composer starts with: the language saved in
  /// Settings when there is one, otherwise the device language mapped to a
  /// supported id.
  static String deviceLanguage() {
    final saved = v2SavedVoiceLanguage;
    if (saved.isNotEmpty) return saved;
    final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode
        .toLowerCase();
    return switch (code) {
      'hi' => 'hi',
      'pa' => 'pa',
      'ta' => 'ta',
      _ => 'en',
    };
  }
}

/// Drives one press-to-talk session and exposes its state to the composer.
///
/// Partial transcripts are appended to the draft as they arrive; a final
/// result stops the service but leaves the text for review. Tapping the mic
/// again, or sending, stops it early.
class V2VoiceDictation extends ChangeNotifier {
  V2VoiceDictation({V2VoiceService? service, required this.localeId})
    : _service = service ?? V2PlatformVoiceService.instance {
    final service = _service;
    if (service is V2VoiceCancellationEvents) {
      _cancellationSubscription = (service as V2VoiceCancellationEvents)
          .lifecycleCancellations
          .listen((_) => _handleLifecycleCancellation());
    }
  }

  final V2VoiceService _service;
  StreamSubscription<void>? _cancellationSubscription;
  int _generation = 0;

  /// STT locale passed to the engine (`hi-IN`, `pa-IN`, `ta-IN`, `en-IN`).
  final String localeId;

  /// Called with the full draft text while dictating.
  void Function(String text)? onTranscript;

  bool _listening = false;
  bool _busy = false;
  bool _disposed = false;
  bool _acceptResults = false;
  String _base = '';
  String? _error;

  bool get listening => _listening;
  String? get error => _error;

  static const String permissionDeniedMessage =
      'Microphone access is off. Allow it in Settings to use voice input.';
  static const String unavailableMessage = kOvidVoiceUnavailableMessage;
  static const String failedMessage = 'Voice input could not start. Try again.';

  /// Starts dictation, or stops it when already listening.
  Future<void> toggle(String currentText) async {
    if (_busy) return;
    if (_listening) {
      await stop();
      return;
    }
    final generation = _generation;
    _busy = true;
    _error = null;
    _notify();
    try {
      final supported = await _service.supportsLocale(localeId);
      if (_disposed || generation != _generation) return;
      if (!supported) {
        _error = unavailableMessage;
        return;
      }
      final permitted = await _service.ensureMicrophonePermission();
      if (_disposed || generation != _generation) return;
      if (!permitted) {
        _error = permissionDeniedMessage;
        return;
      }
      _base = currentText.trimRight();
      _acceptResults = true;
      final started = await _service.start(_handleResult, localeId: localeId);
      if (_disposed || generation != _generation) {
        if (started) await _service.cancel();
        return;
      }
      _listening = started;
      if (!started) {
        _acceptResults = false;
        _error = failedMessage;
      }
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _acceptResults = false;
      _listening = false;
      _error = failedMessage;
    } finally {
      if (!_disposed && generation == _generation) {
        _busy = false;
        _notify();
      }
    }
  }

  void _handleResult(String text, bool isFinal) {
    if (!_acceptResults || _disposed) return;
    final heard = text.trim();
    if (heard.isNotEmpty) {
      onTranscript?.call(_base.isEmpty ? heard : '$_base $heard');
    }
    if (isFinal) unawaited(_finish());
  }

  void _handleLifecycleCancellation() {
    if (_disposed) return;
    ++_generation;
    _acceptResults = false;
    _listening = false;
    _busy = false;
    _notify();
  }

  Future<void> _finish() async {
    if (!_listening) return;
    try {
      await _service.stop();
    } catch (_) {
      // Stopping is best effort; the transcript is already in the draft.
    }
    _acceptResults = false;
    _listening = false;
    _notify();
  }

  /// Stops dictation, keeping whatever text was recognized.
  Future<void> stop() async {
    if (!_listening) return;
    try {
      await _service.stop();
    } catch (_) {
      // Best effort.
    }
    _listening = false;
    _notify();
  }

  /// Stops dictation and discards the platform's final callback.
  Future<void> cancel() async {
    ++_generation;
    _acceptResults = false;
    _listening = false;
    try {
      await _service.cancel();
    } catch (_) {
      // Best effort.
    }
    _notify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    final cancelInFlight = _busy || _listening;
    ++_generation;
    _acceptResults = false;
    _disposed = true;
    unawaited(_cancellationSubscription?.cancel());
    if (cancelInFlight) unawaited(_service.cancel());
    super.dispose();
  }
}
