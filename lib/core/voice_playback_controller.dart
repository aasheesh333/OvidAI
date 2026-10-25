import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_cache_store.dart';
import 'voice_capability.dart';
import 'voice_reply_service.dart';

const String kVoicePlaybackUnavailableMessage =
    'On-device playback cannot use this language on this device.';

enum VoicePlaybackPhase {
  idle,
  starting,
  playing,
  paused,
  stopped,
  completed,
  unavailable,
}

@immutable
class VoicePlaybackState {
  const VoicePlaybackState({
    this.phase = VoicePlaybackPhase.idle,
    this.messageId,
    this.text,
    this.localeId,
    this.acceptedLocaleId,
    this.utteranceId,
    this.spokenCharacters = 0,
    this.totalCharacters = 0,
    this.reason,
  });

  final VoicePlaybackPhase phase;
  final String? messageId;
  final String? text;
  final String? localeId;
  final String? acceptedLocaleId;
  final String? utteranceId;
  final int spokenCharacters;
  final int totalCharacters;
  final String? reason;

  bool get playing => phase == VoicePlaybackPhase.playing;
  bool get paused => phase == VoicePlaybackPhase.paused;
  double get progress => totalCharacters <= 0
      ? 0
      : (spokenCharacters / totalCharacters).clamp(0, 1);

  VoicePlaybackState copyWith({
    VoicePlaybackPhase? phase,
    String? messageId,
    String? text,
    String? localeId,
    String? acceptedLocaleId,
    String? utteranceId,
    int? spokenCharacters,
    int? totalCharacters,
    String? reason,
    bool clearAcceptedLocale = false,
    bool clearReason = false,
  }) => VoicePlaybackState(
    phase: phase ?? this.phase,
    messageId: messageId ?? this.messageId,
    text: text ?? this.text,
    localeId: localeId ?? this.localeId,
    acceptedLocaleId: clearAcceptedLocale
        ? null
        : acceptedLocaleId ?? this.acceptedLocaleId,
    utteranceId: utteranceId ?? this.utteranceId,
    spokenCharacters: spokenCharacters ?? this.spokenCharacters,
    totalCharacters: totalCharacters ?? this.totalCharacters,
    reason: clearReason ? null : reason ?? this.reason,
  );
}

/// User-activated playback of one exact final assistant answer.
///
/// State changes come from native acceptance and utterance callbacks, not a
/// timer or an estimated summary length. Every instance is immutable.
class VoicePlaybackController extends ChangeNotifier {
  VoicePlaybackController({
    VoicePlaybackEngine? engine,
    VoiceCacheStore? cache,
    this.releaseEnabled = kOvidVoiceEnabled,
  }) : _engine = engine ?? VoiceReplyService.I,
       // Public constructor name is retained for embedders and tests.
       // ignore: prefer_initializing_formals
       _cache = cache {
    _subscription = _engine.utteranceEvents.listen(_handleEvent);
  }

  final VoicePlaybackEngine _engine;
  final VoiceCacheStore? _cache;
  final bool releaseEnabled;
  late final StreamSubscription<VoiceUtteranceEvent> _subscription;

  VoicePlaybackState _state = const VoicePlaybackState();
  VoicePlaybackState get state => _state;

  String? _activeUtteranceId;
  int _generation = 0;
  int _utteranceCounter = 0;
  bool _disposed = false;
  bool _resumeInFlight = false;

  Future<void> play({
    required String messageId,
    required String text,
    String? localeId,
  }) async {
    if (!releaseEnabled) {
      _setState(
        VoicePlaybackState(
          phase: VoicePlaybackPhase.unavailable,
          messageId: messageId,
          text: text,
          localeId: localeId,
          totalCharacters: text.length,
          reason: kOvidVoiceUnavailableMessage,
        ),
      );
      return;
    }
    if (messageId.isEmpty || text.trim().isEmpty) {
      _setState(
        VoicePlaybackState(
          phase: VoicePlaybackPhase.unavailable,
          messageId: messageId,
          text: text,
          localeId: localeId,
          totalCharacters: text.length,
          reason: kVoicePlaybackUnavailableMessage,
        ),
      );
      return;
    }

    final generation = ++_generation;
    _resumeInFlight = false;
    if (_activeUtteranceId != null) await _engine.stop();
    if (_disposed || generation != _generation) return;
    _activeUtteranceId = null;
    final utteranceId = 'ovid-answer-${++_utteranceCounter}';
    _setState(
      VoicePlaybackState(
        phase: VoicePlaybackPhase.starting,
        messageId: messageId,
        text: text,
        localeId: localeId,
        utteranceId: utteranceId,
        totalCharacters: text.length,
      ),
    );
    final cached = await _cache?.positionFor(messageId);
    if (_disposed || generation != _generation) return;
    final offset = cached != null && cached >= 0 && cached < text.length
        ? cached
        : 0;
    _activeUtteranceId = utteranceId;
    final accepted = await _engine.startUtterance(
      utteranceId: utteranceId,
      text: text,
      localeId: localeId,
      offset: offset,
    );
    if (_disposed || generation != _generation) return;
    if (accepted == null || accepted.utteranceId != utteranceId) {
      _activeUtteranceId = null;
      _setState(
        _state.copyWith(
          phase: VoicePlaybackPhase.unavailable,
          reason: kVoicePlaybackUnavailableMessage,
          clearAcceptedLocale: true,
        ),
      );
      return;
    }
    _setState(
      _state.copyWith(
        acceptedLocaleId: accepted.localeId,
        spokenCharacters: offset,
        clearReason: true,
      ),
    );
  }

  Future<void> pause() async {
    final id = _activeUtteranceId;
    if (id == null ||
        (_state.phase != VoicePlaybackPhase.starting &&
            _state.phase != VoicePlaybackPhase.playing)) {
      return;
    }
    final generation = _generation;
    final messageId = _state.messageId;
    _resumeInFlight = false;
    if (!await _engine.pauseUtterance(id)) return;
    if (_disposed || generation != _generation || _activeUtteranceId != id) {
      return;
    }
    final spokenCharacters = _state.spokenCharacters;
    _setState(_state.copyWith(phase: VoicePlaybackPhase.paused));
    if (_disposed || generation != _generation) return;
    if (messageId != null) {
      await _cache?.savePosition(
        messageId: messageId,
        character: spokenCharacters,
      );
    }
  }

  Future<void> resume() async {
    final id = _activeUtteranceId;
    if (id == null || _state.phase != VoicePlaybackPhase.paused) return;
    final generation = _generation;
    _resumeInFlight = true;
    final resumed = await _engine.resumeUtterance(id);
    if (_disposed || generation != _generation || !_resumeInFlight) return;
    _resumeInFlight = false;
    if (!resumed) return;
    if (generation == _generation &&
        _activeUtteranceId == id &&
        _state.phase != VoicePlaybackPhase.playing) {
      _setState(_state.copyWith(phase: VoicePlaybackPhase.starting));
    }
  }

  Future<void> stop() async {
    final hadUtterance = _activeUtteranceId != null;
    final generation = ++_generation;
    final messageId = _state.messageId;
    _resumeInFlight = false;
    _activeUtteranceId = null;
    if (hadUtterance) await _engine.stop();
    if (_disposed || generation != _generation) return;
    _setState(_state.copyWith(phase: VoicePlaybackPhase.stopped));
    // A listener may start another answer synchronously from the state change.
    if (_disposed || generation != _generation) return;
    if (messageId != null) await _cache?.removePosition(messageId);
  }

  void _handleEvent(VoiceUtteranceEvent event) {
    if (_disposed || event.utteranceId != _activeUtteranceId) return;
    final generation = _generation;
    switch (event.type) {
      case VoiceUtteranceEventType.started:
        if (_state.phase != VoicePlaybackPhase.paused || _resumeInFlight) {
          _setState(_state.copyWith(phase: VoicePlaybackPhase.playing));
        }
      case VoiceUtteranceEventType.progress:
        if (_state.phase == VoicePlaybackPhase.paused && !_resumeInFlight) {
          return;
        }
        final total = _state.totalCharacters;
        final start = event.start.clamp(0, total);
        _setState(
          _state.copyWith(
            phase: VoicePlaybackPhase.playing,
            spokenCharacters: start,
          ),
        );
      case VoiceUtteranceEventType.paused:
        _resumeInFlight = false;
        _setState(_state.copyWith(phase: VoicePlaybackPhase.paused));
      case VoiceUtteranceEventType.completed:
        _activeUtteranceId = null;
        _setState(
          _state.copyWith(
            phase: VoicePlaybackPhase.completed,
            spokenCharacters: _state.totalCharacters,
          ),
        );
        final messageId = _state.messageId;
        if (messageId != null &&
            !_disposed &&
            generation == _generation &&
            _state.messageId == messageId &&
            _state.phase == VoicePlaybackPhase.completed) {
          unawaited(_cache?.removePosition(messageId));
        }
      case VoiceUtteranceEventType.stopped:
        _activeUtteranceId = null;
        _setState(_state.copyWith(phase: VoicePlaybackPhase.stopped));
      case VoiceUtteranceEventType.error:
        _activeUtteranceId = null;
        _setState(
          _state.copyWith(
            phase: VoicePlaybackPhase.unavailable,
            reason: kVoicePlaybackUnavailableMessage,
          ),
        );
    }
  }

  void _setState(VoicePlaybackState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _resumeInFlight = false;
    if (_activeUtteranceId != null) unawaited(_engine.stop());
    _activeUtteranceId = null;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
