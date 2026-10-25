import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'diag.dart';
import 'voice_capability.dart';

@immutable
class VoiceListenOptions {
  const VoiceListenOptions({
    required this.partialResults,
    required this.cancelOnError,
    required this.localeId,
    required this.pauseFor,
    required this.listenFor,
  });

  final bool partialResults;
  final bool cancelOnError;
  final String? localeId;
  final Duration pauseFor;
  final Duration listenFor;
}

/// Press-to-talk over Android's explicitly on-device SpeechRecognizer.
///
/// The native host verifies that the requested locale is downloaded before it
/// opens the microphone. Only transcript strings come back to Dart; there is
/// no audio buffer, server recognizer or network-capable STT plugin here.
class VoiceInputService {
  VoiceInputService({
    VoiceCapability? capability,
    MethodChannel? channel,
    Stream<Map<String, Object?>>? nativeEvents,
    Future<bool> Function()? microphonePermission,
  }) : _capability = capability ?? VoiceCapability(channel: channel),
       _channel = channel ?? const MethodChannel('ovid/native'),
       _nativeEvents = nativeEvents ?? VoiceNativeEvents.shared,
       // Public constructor name is retained for embedders and tests.
       // ignore: prefer_initializing_formals
       _microphonePermission = microphonePermission;

  static final VoiceInputService I = VoiceInputService();

  /// Existing widget test seams. They never select a production recognizer.
  bool? availabilityOverrideForTest;
  void Function(void Function(String text, bool isFinal) onResult)?
  startOverrideForTest;
  void Function()? stopOverrideForTest;
  void Function()? cancelOverrideForTest;
  Future<bool> Function()? ensureMicrophonePermissionForTest;

  final VoiceCapability _capability;
  final MethodChannel _channel;
  final Stream<Map<String, Object?>> _nativeEvents;
  final Future<bool> Function()? _microphonePermission;
  final StreamController<void> _lifecycleCancellations =
      StreamController<void>.broadcast();

  void _ensureNativeEventSubscription() {
    // Lazy so constructing the singleton before Flutter binding is harmless,
    // but always active before a real locale/capability/permission await.
    _eventSubscription ??= _nativeEvents.listen(_handleNativeEvent);
  }

  /// Native lifecycle cancellation is separate from a final transcript or an
  /// explicit user stop. The native mic is already closed when this emits.
  Stream<void> get lifecycleCancellations {
    _ensureNativeEventSubscription();
    return _lifecycleCancellations.stream;
  }

  bool _listening = false;
  bool get isListening => _listening;

  static const defaultPauseFor = Duration(seconds: 2);
  static const defaultListenFor = Duration(seconds: 60);

  Timer? _silenceTimer;
  StreamSubscription<Map<String, Object?>>? _eventSubscription;
  int _sessionCounter = 0;
  int _startOperationCounter = 0;
  int _lifecycleGeneration = 0;
  bool _foreground = true;
  String? _activeSession;
  void Function(String text, bool isFinal)? _onResult;

  Future<bool> ensureMicrophonePermission() async {
    final override = ensureMicrophonePermissionForTest;
    if (override != null) return override();
    final injected = _microphonePermission;
    if (injected != null) return injected();
    try {
      var status = await Permission.microphone.status;
      if (status.isGranted) return true;
      status = await Permission.microphone.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isAvailable() async {
    final override = availabilityOverrideForTest;
    if (override != null) return override;
    _ensureNativeEventSubscription();
    try {
      final availability = await _capability.probe();
      return availability.enabled && availability.stt;
    } catch (_) {
      return false;
    }
  }

  /// Locale availability is checked before requesting microphone permission.
  Future<bool> isLocaleAvailable(String localeId) async {
    final override = availabilityOverrideForTest;
    if (override != null) return override;
    _ensureNativeEventSubscription();
    try {
      final availability = await _capability.probe();
      return availability.enabled &&
          availability.stt &&
          availability.supportsStt(localeId);
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  VoiceListenOptions listenOptionsForTest({
    Duration? pauseFor,
    Duration? listenFor,
    String? localeId,
  }) => VoiceListenOptions(
    partialResults: true,
    cancelOnError: true,
    localeId: localeId,
    pauseFor: pauseFor ?? defaultPauseFor,
    listenFor: listenFor ?? defaultListenFor,
  );

  bool _startIsCurrent(int operation, int generation) =>
      operation == _startOperationCounter &&
      generation == _lifecycleGeneration &&
      _foreground;

  Future<bool> start(
    void Function(String text, bool isFinal) onResult, {
    String? localeId,
    Duration? pauseFor,
    Duration? listenFor,
    Duration? silenceStop,
  }) async {
    if (_listening || !_foreground || availabilityOverrideForTest == false) {
      return false;
    }
    final operation = ++_startOperationCounter;
    final generation = _lifecycleGeneration;
    final silenceWindow = silenceStop ?? pauseFor ?? defaultPauseFor;
    final testStart = startOverrideForTest;
    if (testStart == null) _ensureNativeEventSubscription();

    if (testStart == null && availabilityOverrideForTest == null) {
      final available = await _capability.probe();
      if (!_startIsCurrent(operation, generation)) return false;
      if (!available.enabled || !available.stt) return false;
      if (localeId != null && !available.supportsStt(localeId)) return false;
    }

    final permitted = await ensureMicrophonePermission();
    if (!_startIsCurrent(operation, generation) || !permitted) return false;

    if (testStart != null) {
      final sessionId = 'test-${++_sessionCounter}';
      _activeSession = sessionId;
      _onResult = onResult;
      _listening = true;
      _pokeSilenceWatchdog(silenceWindow);
      testStart((text, isFinal) {
        if (_activeSession != sessionId) return;
        _pokeSilenceWatchdog(silenceWindow);
        onResult(text, isFinal);
      });
      return true;
    }

    final sessionId = 'stt-${++_sessionCounter}';
    _activeSession = sessionId;
    _onResult = onResult;
    _listening = true;
    _pokeSilenceWatchdog(silenceWindow);
    try {
      final options = listenOptionsForTest(
        pauseFor: pauseFor,
        listenFor: listenFor,
        localeId: localeId,
      );
      final started = await _channel.invokeMethod<bool>('voiceSttStart', {
        'sessionId': sessionId,
        'locale': localeId,
        'pauseFor': options.pauseFor.inMilliseconds,
        'listenFor': options.listenFor.inMilliseconds,
        'onDevice': true,
      });
      if (started != true ||
          !_startIsCurrent(operation, generation) ||
          _activeSession != sessionId) {
        if (_activeSession == sessionId) _clearSession();
        // A native start that raced lifecycle cancellation is immediately
        // closed. The native foreground fence normally makes this unnecessary.
        await _cancelNative(sessionId);
        return false;
      }
      return true;
    } catch (error) {
      Diag.swallow('voice_input.start', error);
      if (_activeSession == sessionId) _clearSession();
      await _cancelNative(sessionId);
      return false;
    }
  }

  void _handleNativeEvent(Map<String, Object?> event) {
    if (event['source'] != 'stt') return;
    final type = event['type'];
    if (type == 'cancelled') {
      final nativeGeneration = event['generation'];
      _lifecycleGeneration = nativeGeneration is num
          ? nativeGeneration.toInt()
          : _lifecycleGeneration + 1;
      _foreground = false;
      _clearSession();
      // This is intentionally not session-scoped: onStop also invalidates
      // locale/capability/permission awaits before activeSession is assigned.
      _lifecycleCancellations.add(null);
      return;
    }
    if (type == 'foreground') {
      final nativeGeneration = event['generation'];
      if (nativeGeneration is num) {
        _lifecycleGeneration = nativeGeneration.toInt();
      }
      _foreground = true;
      return;
    }
    final sessionId = _activeSession;
    if (sessionId == null || event['sessionId'] != sessionId) return;
    final callback = _onResult;
    switch (type) {
      case 'result':
        final text = event['text'];
        if (callback != null && text is String) {
          callback(text, event['final'] == true);
        }
        if (event['final'] == true) {
          _listening = false;
          _silenceTimer?.cancel();
          _activeSession = null;
          _onResult = null;
        }
      case 'end':
      case 'error':
        if (_activeSession == sessionId) _clearSession();
    }
  }

  void _pokeSilenceWatchdog(Duration window) {
    _silenceTimer?.cancel();
    if (!_listening) return;
    _silenceTimer = Timer(window, () {
      if (_listening) unawaited(stop());
    });
  }

  Future<void> stop() async {
    _silenceTimer?.cancel();
    _listening = false;
    final testStop = stopOverrideForTest;
    if (testStop != null) {
      _activeSession = null;
      _onResult = null;
      testStop();
      return;
    }
    final sessionId = _activeSession;
    if (sessionId == null) return;
    try {
      // stopListening still accepts the final transcript; unlike cancel, the
      // active session remains valid until that result or an end event arrives.
      await _channel.invokeMethod<void>('voiceSttStop', {
        'sessionId': sessionId,
      });
    } catch (error) {
      Diag.swallow('voice_input.stop', error);
      if (_activeSession == sessionId) _clearSession();
    }
  }

  Future<void> cancel() async {
    ++_startOperationCounter;
    _silenceTimer?.cancel();
    _listening = false;
    final sessionId = _activeSession;
    _activeSession = null;
    _onResult = null;

    final testCancel = cancelOverrideForTest ?? stopOverrideForTest;
    if (testCancel != null) {
      testCancel();
      return;
    }
    if (sessionId != null) await _cancelNative(sessionId);
  }

  Future<void> _cancelNative(String sessionId) async {
    try {
      await _channel.invokeMethod<void>('voiceSttCancel', {
        'sessionId': sessionId,
      });
    } catch (error) {
      Diag.swallow('voice_input.cancel', error);
    }
  }

  void _clearSession() {
    _silenceTimer?.cancel();
    _listening = false;
    _activeSession = null;
    _onResult = null;
  }
}
