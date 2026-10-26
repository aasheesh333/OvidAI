import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/voice_cache_store.dart';
import 'package:ovid_ai/core/voice_capability.dart';
import 'package:ovid_ai/core/voice_playback_controller.dart';
import 'package:ovid_ai/core/voice_reply_service.dart';

class _FakeEngine implements VoicePlaybackEngine {
  final _events = StreamController<VoiceUtteranceEvent>.broadcast();
  final calls = <String>[];
  String? lastStopped;
  String? activeUtteranceId;

  @override
  Stream<VoiceUtteranceEvent> get utteranceEvents => _events.stream;

  void emit(VoiceUtteranceEvent event) => _events.add(event);

  @override
  Future<VoiceUtteranceAcceptance?> startUtterance({
    required String utteranceId,
    required String text,
    String? localeId,
    int offset = 0,
  }) async {
    calls.add('start:$utteranceId:$text:$localeId:$offset');
    activeUtteranceId = utteranceId;
    return VoiceUtteranceAcceptance(utteranceId: utteranceId, localeId: localeId ?? 'en-IN');
  }

  @override
  Future<bool> pauseUtterance(String utteranceId) async {
    calls.add('pause:$utteranceId');
    return true;
  }

  @override
  Future<bool> resumeUtterance(String utteranceId) async {
    calls.add('resume:$utteranceId');
    return true;
  }

  @override
  Future<void> stop() async {
    lastStopped = activeUtteranceId;
    calls.add('stop');
  }

  void dispose() => _events.close();
}

class _NoopCache implements VoiceCacheStore {
  final positions = <String, int>{};

  @override
  Future<void> clear() async {}

  @override
  Future<int?> positionFor(String messageId) async => positions[messageId];

  @override
  Future<void> removePosition(String messageId) async => positions.remove(messageId);

  @override
  Future<void> savePosition({required String messageId, required int character}) async {
    positions[messageId] = character;
  }
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('play drives the engine and transitions through starting to playing', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
    final states = <VoicePlaybackState>[];
    controller.addListener(() => states.add(controller.state));

    await controller.play(messageId: 'm1', text: 'Hello world', localeId: 'en-IN');
    expect(controller.state.phase, VoicePlaybackPhase.starting);

    engine.emit(const VoiceUtteranceEvent.start('ovid-answer-1'));
    await _pump();
    expect(controller.state.phase, VoicePlaybackPhase.playing);
    expect(controller.state.utteranceId, 'ovid-answer-1');
    expect(controller.state.acceptedLocaleId, 'en-IN');

    engine.dispose();
    controller.dispose();
  });

  test('pause while playing stops the engine and persists the offset', () async {
    final engine = _FakeEngine();
    final cache = _NoopCache();
    final controller = VoicePlaybackController(engine: engine, cache: cache, releaseEnabled: true);
    await controller.play(messageId: 'm1', text: 'Hello world', localeId: 'en-IN');
    engine.emit(const VoiceUtteranceEvent.start('ovid-answer-1'));
    await _pump();
    engine.emit(const VoiceUtteranceEvent.progress('ovid-answer-1', start: 3, end: 5));
    await _pump();
    expect(controller.state.spokenCharacters, 3);

    await controller.pause();
    expect(controller.state.phase, VoicePlaybackPhase.paused);
    expect(cache.positions['m1'], 3);
    expect(engine.calls, contains('pause:ovid-answer-1'));

    engine.dispose();
    controller.dispose();
  });

  test('resume from paused transitions back to playing on a start callback', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
    await controller.play(messageId: 'm1', text: 'Hello world', localeId: 'en-IN');
    engine.emit(const VoiceUtteranceEvent.start('ovid-answer-1'));
    await controller.pause();

    await controller.resume();
    engine.emit(const VoiceUtteranceEvent.start('ovid-answer-1'));
    await _pump();
    expect(controller.state.phase, VoicePlaybackPhase.playing);

    engine.dispose();
    controller.dispose();
  });

  test('pause when not playing is a no-op', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
    await controller.pause();
    expect(controller.state.phase, VoicePlaybackPhase.idle);
    expect(engine.calls, isEmpty);

    engine.dispose();
    controller.dispose();
  });

  test('resume when paused is a no-op', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
    await controller.resume();
    expect(controller.state.phase, VoicePlaybackPhase.idle);
    expect(engine.calls, isEmpty);

    engine.dispose();
    controller.dispose();
  });

  test('error event transitions to unavailable', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
    await controller.play(messageId: 'm1', text: 'Hello world', localeId: 'en-IN');
    engine.emit(const VoiceUtteranceEvent.error('ovid-answer-1'));
    await _pump();
    expect(controller.state.phase, VoicePlaybackPhase.unavailable);
    expect(controller.state.reason, kVoicePlaybackUnavailableMessage);

    engine.dispose();
    controller.dispose();
  });

  test('stop while playing cancels the active utterance and clears state', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
    await controller.play(messageId: 'm1', text: 'Hello world', localeId: 'en-IN');
    engine.emit(const VoiceUtteranceEvent.start('ovid-answer-1'));
    await _pump();
    await controller.stop();
    expect(controller.state.phase, VoicePlaybackPhase.stopped);
    expect(engine.lastStopped, 'ovid-answer-1');

    engine.dispose();
    controller.dispose();
  });

  test('starting a new utterance stops the previous one', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
    await controller.play(messageId: 'm1', text: 'First', localeId: 'en-IN');
    engine.emit(const VoiceUtteranceEvent.start('ovid-answer-1'));
    await _pump();
    await controller.play(messageId: 'm2', text: 'Second', localeId: 'hi-IN');
    expect(engine.lastStopped, 'ovid-answer-1');
    expect(controller.state.utteranceId, 'ovid-answer-2');

    engine.dispose();
    controller.dispose();
  });

  test('completed utterance removes cached position', () async {
    final engine = _FakeEngine();
    final cache = _NoopCache();
    cache.positions['m1'] = 5;
    final controller = VoicePlaybackController(engine: engine, cache: cache, releaseEnabled: true);
    await controller.play(messageId: 'm1', text: 'Hello world', localeId: 'en-IN');
    engine.emit(const VoiceUtteranceEvent.start('ovid-answer-1'));
    engine.emit(const VoiceUtteranceEvent.done('ovid-answer-1'));
    await _pump();
    expect(controller.state.phase, VoicePlaybackPhase.completed);
    expect(cache.positions.containsKey('m1'), isFalse);

    engine.dispose();
    controller.dispose();
  });

  test('release disabled reports unavailable without touching the engine', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(engine: engine, releaseEnabled: false);
    await controller.play(messageId: 'm1', text: 'Hello world', localeId: 'en-IN');
    expect(controller.state.phase, VoicePlaybackPhase.unavailable);
    expect(controller.state.reason, kOvidVoiceUnavailableMessage);
    expect(engine.calls, isEmpty);

    engine.dispose();
    controller.dispose();
  });
}
