import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/voice_cache_store.dart';
import 'package:ovid_ai/core/voice_capability.dart';
import 'package:ovid_ai/core/voice_playback_controller.dart';
import 'package:ovid_ai/core/voice_reply_service.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';

class _FakePlaybackEngine implements VoicePlaybackEngine {
  final _events = StreamController<VoiceUtteranceEvent>.broadcast();
  final starts = <({String id, String text, String? locale, int offset})>[];
  final pauses = <String>[];
  final resumes = <String>[];
  var stops = 0;
  var accept = true;
  var acceptedLocale = 'en-IN';
  var startBeforeResumeReturns = false;
  var delayStops = false;
  final pendingStops = <Completer<void>>[];

  @override
  Stream<VoiceUtteranceEvent> get utteranceEvents => _events.stream;

  @override
  Future<VoiceUtteranceAcceptance?> startUtterance({
    required String utteranceId,
    required String text,
    String? localeId,
    int offset = 0,
  }) async {
    starts.add((id: utteranceId, text: text, locale: localeId, offset: offset));
    if (!accept) return null;
    return VoiceUtteranceAcceptance(
      utteranceId: utteranceId,
      localeId: acceptedLocale,
    );
  }

  @override
  Future<bool> pauseUtterance(String utteranceId) async {
    pauses.add(utteranceId);
    return true;
  }

  @override
  Future<bool> resumeUtterance(String utteranceId) async {
    resumes.add(utteranceId);
    if (startBeforeResumeReturns) {
      _events.add(VoiceUtteranceEvent.start(utteranceId));
      await Future<void>.delayed(Duration.zero);
    }
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (delayStops) {
      final pending = Completer<void>();
      pendingStops.add(pending);
      await pending.future;
    }
  }

  Future<void> emit(VoiceUtteranceEvent event) async {
    _events.add(event);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> close() => _events.close();
}

class _FakeVoiceCache extends VoiceCacheStore {
  final positions = <String, int>{};
  final removals = <String>[];

  @override
  Future<int?> positionFor(String messageId) async => positions[messageId];

  @override
  Future<void> savePosition({
    required String messageId,
    required int character,
  }) async {
    positions[messageId] = character;
  }

  @override
  Future<void> removePosition(String messageId) async {
    removals.add(messageId);
    positions.remove(messageId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlaybackEngine engine;
  late VoicePlaybackController controller;

  setUp(() {
    engine = _FakePlaybackEngine();
    controller = VoicePlaybackController(engine: engine, releaseEnabled: true);
  });

  tearDown(() async {
    controller.dispose();
    await engine.close();
  });

  test('play waits for activation and speaks the exact final answer', () async {
    const answer =
        '  **Exact answer.**\nKeep [links](https://x.invalid) and code.  ';

    expect(engine.starts, isEmpty);
    expect(controller.state.phase, VoicePlaybackPhase.idle);

    await controller.play(
      messageId: 'assistant-1',
      text: answer,
      localeId: 'en-IN',
    );

    expect(engine.starts, hasLength(1));
    expect(engine.starts.single.text, answer);
    expect(engine.starts.single.locale, 'en-IN');
    expect(controller.state.phase, VoicePlaybackPhase.starting);
    expect(controller.state.text, answer);
    expect(controller.state.acceptedLocaleId, 'en-IN');
    expect(controller.state.totalCharacters, answer.length);

    final id = engine.starts.single.id;
    await engine.emit(VoiceUtteranceEvent.start(id));
    expect(controller.state.phase, VoicePlaybackPhase.playing);
    expect(controller.state.messageId, 'assistant-1');
  });

  test('unsupported locale cannot start actual playback', () async {
    engine.accept = false;

    await controller.play(
      messageId: 'assistant-1',
      text: 'Final answer',
      localeId: 'ta-IN',
    );

    expect(controller.state.phase, VoicePlaybackPhase.unavailable);
    expect(controller.state.reason, kVoicePlaybackUnavailableMessage);
    expect(controller.state.playing, isFalse);
    expect(controller.state.acceptedLocaleId, isNull);
    expect(engine.pauses, isEmpty);
    expect(engine.resumes, isEmpty);
  });

  test(
    'pause and resume retain actual utterance progress and answer text',
    () async {
      const answer = '0123456789 exact final answer';
      await controller.play(messageId: 'a1', text: answer);
      final id = engine.starts.single.id;
      await engine.emit(VoiceUtteranceEvent.start(id));
      await engine.emit(VoiceUtteranceEvent.progress(id, start: 4, end: 9));
      final playing = controller.state;

      await controller.pause();
      expect(engine.pauses, <String>[id]);
      expect(controller.state.phase, VoicePlaybackPhase.paused);
      expect(controller.state.spokenCharacters, 4);
      expect(controller.state.text, answer);

      await controller.resume();
      expect(engine.resumes, <String>[id]);
      expect(controller.state.phase, VoicePlaybackPhase.starting);
      await engine.emit(VoiceUtteranceEvent.start(id));
      await engine.emit(VoiceUtteranceEvent.progress(id, start: 9, end: 15));
      expect(controller.state.phase, VoicePlaybackPhase.playing);
      expect(controller.state.spokenCharacters, 9);
      expect(controller.state.text, answer);
      expect(
        playing.spokenCharacters,
        4,
        reason: 'old snapshots stay immutable',
      );
    },
  );

  test('late native start cannot undo an explicit pause', () async {
    await controller.play(messageId: 'a1', text: 'Exact final answer');
    final id = engine.starts.single.id;
    await engine.emit(VoiceUtteranceEvent.start(id));
    await controller.pause();

    await engine.emit(VoiceUtteranceEvent.start(id));

    expect(controller.state.phase, VoicePlaybackPhase.paused);
  });

  test('resume does not regress an already started native utterance', () async {
    await controller.play(messageId: 'a1', text: 'Exact final answer');
    final id = engine.starts.single.id;
    await engine.emit(VoiceUtteranceEvent.start(id));
    await controller.pause();
    engine.startBeforeResumeReturns = true;

    await controller.resume();

    expect(controller.state.phase, VoicePlaybackPhase.playing);
  });

  test('stop is terminal and ignores late native callbacks', () async {
    await controller.play(messageId: 'a1', text: 'Final answer');
    final id = engine.starts.single.id;
    await engine.emit(VoiceUtteranceEvent.start(id));
    await engine.emit(VoiceUtteranceEvent.progress(id, start: 3, end: 5));

    await controller.stop();
    expect(engine.stops, greaterThanOrEqualTo(1));
    expect(controller.state.phase, VoicePlaybackPhase.stopped);
    final stopped = controller.state;
    await engine.emit(VoiceUtteranceEvent.progress(id, start: 5, end: 7));
    await engine.emit(VoiceUtteranceEvent.done(id));

    expect(identical(controller.state, stopped), isTrue);
    expect(controller.state.playing, isFalse);
  });

  test(
    'delayed old stop cannot stop a newer play or clear its cache',
    () async {
      controller.dispose();
      final cache = _FakeVoiceCache();
      controller = VoicePlaybackController(
        engine: engine,
        cache: cache,
        releaseEnabled: true,
      );
      await controller.play(messageId: 'old', text: 'Old answer');
      final oldId = engine.starts.single.id;
      await engine.emit(VoiceUtteranceEvent.start(oldId));
      engine.delayStops = true;

      final oldStop = controller.stop();
      await Future<void>.delayed(Duration.zero);
      final newPlay = controller.play(messageId: 'new', text: 'New answer');
      await Future<void>.delayed(Duration.zero);
      engine.pendingStops.single.complete();
      await Future.wait(<Future<void>>[oldStop, newPlay]);

      expect(controller.state.messageId, 'new');
      expect(controller.state.phase, VoicePlaybackPhase.starting);
      expect(controller.state.text, 'New answer');
      expect(engine.starts.last.text, 'New answer');
      expect(cache.removals, isNot(contains('new')));
    },
  );

  test(
    'older delayed play completion cannot replace the newest play',
    () async {
      await controller.play(messageId: 'a', text: 'Answer A');
      engine.delayStops = true;

      final playB = controller.play(messageId: 'b', text: 'Answer B');
      final playC = controller.play(messageId: 'c', text: 'Answer C');
      await Future<void>.delayed(Duration.zero);
      expect(engine.pendingStops, hasLength(2));

      engine.pendingStops[1].complete();
      await Future<void>.delayed(Duration.zero);
      engine.pendingStops[0].complete();
      await Future.wait(<Future<void>>[playB, playC]);

      expect(controller.state.messageId, 'c');
      expect(controller.state.text, 'Answer C');
      expect(engine.starts.map((start) => start.text), <String>[
        'Answer A',
        'Answer C',
      ]);
    },
  );

  test(
    'release gate refuses play without touching the native engine',
    () async {
      final gated = VoicePlaybackController(engine: engine);
      addTearDown(gated.dispose);

      await gated.play(messageId: 'a1', text: 'Final answer');

      expect(engine.starts, isEmpty);
      expect(gated.state.phase, VoicePlaybackPhase.unavailable);
      expect(gated.state.reason, kOvidVoiceUnavailableMessage);
    },
  );

  test(
    'native adapter reports accepted locale and utterance progress',
    () async {
      const channel = MethodChannel('ovid/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ttsSpeak') {
          expect((call.arguments as Map)['text'], '  Exact final answer  ');
          expect((call.arguments as Map)['locale'], 'hi-IN');
          return <String, Object?>{
            'accepted': true,
            'utteranceId': 'native-1',
            'locale': 'hi-IN',
          };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Map<String, Object?>>.broadcast();
      addTearDown(events.close);
      final service = VoiceReplyService(
        channel: channel,
        nativeEvents: events.stream,
        releaseEnabled: true,
      );

      final acceptance = await service.startUtterance(
        utteranceId: 'native-1',
        text: '  Exact final answer  ',
        localeId: 'hi-IN',
      );
      expect(acceptance?.localeId, 'hi-IN');

      final future = service.utteranceEvents.first;
      events.add(<String, Object?>{
        'source': 'tts',
        'type': 'progress',
        'utteranceId': 'native-1',
        'start': 7,
        'end': 12,
      });
      final progress = await future;
      expect(progress.type, VoiceUtteranceEventType.progress);
      expect(progress.start, 7);
      expect(progress.end, 12);
    },
  );

  testWidgets('assistant audio starts only from the play control', (
    tester,
  ) async {
    const answer = '**Exact final assistant text**, not a generated summary.';
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: V2LiveChatPage(
          data: const V2LiveChatData(
            items: <V2LiveChatItem>[
              V2LiveAssistantMessage(id: 'a1', markdown: answer),
            ],
          ),
          onVoicePlay: (id) =>
              controller.play(messageId: id, text: answer, localeId: 'en-IN'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.starts, isEmpty);

    await tester.tap(find.bySemanticsLabel('Play answer'));
    await tester.pump();

    expect(engine.starts, hasLength(1));
    expect(engine.starts.single.id, isNotEmpty);
    expect(engine.starts.single.text, answer);
  });
}
