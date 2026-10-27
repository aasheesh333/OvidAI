import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/voice_capability.dart';
import 'package:ovid_ai/core/voice_input_service.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/v2/chat/composer_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Press-to-talk mic: press mic → listens (stop button shows) → silence
/// auto-stop or manual stop → transcript → AUTO-SEND. No more
/// dictate-then-tap-send.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late AppState app;
  final voice = VoiceInputService.I;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tmpDir = Directory.systemTemp.createTempSync('mic-ptt-');
    SessionSearch.dbPathOverrideForTest = '${tmpDir.path}/search.db';
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
    voice.availabilityOverrideForTest = null;
    voice.startOverrideForTest = null;
    voice.stopOverrideForTest = null;
    voice.ensureMicrophonePermissionForTest = () async => true;
  });

  tearDown(() {
    voice.availabilityOverrideForTest = null;
    voice.startOverrideForTest = null;
    voice.stopOverrideForTest = null;
    voice.ensureMicrophonePermissionForTest = null;
    AppState.resetTestInstance();
  });

  test('listen options silence-stop and cap the session', () {
    final o = voice.listenOptionsForTest();
    expect(o.pauseFor, const Duration(seconds: 2));
    expect(o.listenFor, const Duration(seconds: 60));
    expect(o.partialResults, isTrue);
  });

  testWidgets('silence watchdog stops dictation with no final result', (
    tester,
  ) async {
    // Partial only, then silence: the watchdog must stop the session by
    // itself (ChatGPT-like end-of-speech) instead of listening forever.
    var stopped = false;
    voice.startOverrideForTest = (onResult) {
      onResult('half a thought', false);
    };
    voice.stopOverrideForTest = () => stopped = true;

    final started = await voice.start(
      (text, isFinal) {},
      silenceStop: const Duration(milliseconds: 300),
    );
    expect(started, isTrue);
    expect(voice.isListening, isTrue);

    await tester.pump(const Duration(seconds: 1));
    expect(stopped, isTrue);
    expect(voice.isListening, isFalse);
  });

  testWidgets(
    'composer mic final transcript fills the composer without sending',
    (tester) async {
      // Device providers are retired (SE-004); a test-local provider row.
      final provider = ProviderConfig(
        id: 'ollama-local',
        name: 'Local',
        description: '',
        baseUrl: 'http://127.0.0.1:1/v1',
        requiresApiKey: false,
      );
      app.providers.add(provider);
      provider
        ..baseUrl = 'http://127.0.0.1:1/v1'
        ..models = ['test-model']
        ..selectedModel = 'test-model';
      final s = ChatSession(
        id: 'mic-ptt-1',
        title: 'Custom title',
        providerId: provider.id,
        model: 'test-model',
        mode: 'auto',
      );
      app.sessions.add(s);
      app.activeSessionId = s.id;
      voice.availabilityOverrideForTest = true;
      voice.startOverrideForTest = (onResult) {
        onResult('hello world', true);
      };

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await tester.tap(find.byTooltip('Voice'));
      // Fixed pumps only: ChatScreen owns live timers, so pumpAndSettle
      // never settles. Long enough to flush the notification debounce and
      // the instant-LLM run to completion.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      // PR-3b F-054: dictation fills the composer for review; it never sends
      // on its own (recognition errors must not reach the model unseen).
      expect(
        s.messages.any(
          (m) => m.role == 'user' && m.content.contains('hello world'),
        ),
        isFalse,
        reason: 'final mic transcript fills the composer, it does not send',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'hello world',
      );
    },
  );

  group('native on-device recognition', () {
    const channel = MethodChannel('ovid/native');
    const legacySpeech = MethodChannel('plugin.csdcorp.com/speech_to_text');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late StreamController<Map<String, Object?>> events;
    late List<MethodCall> nativeCalls;
    late List<MethodCall> legacyCalls;
    late int permissionCalls;

    VoiceInputService service({bool permitted = true}) {
      return VoiceInputService(
        capability: VoiceCapability(channel: channel, releaseEnabled: true),
        channel: channel,
        nativeEvents: events.stream,
        microphonePermission: () async {
          permissionCalls++;
          return permitted;
        },
      );
    }

    setUp(() {
      events = StreamController<Map<String, Object?>>.broadcast();
      nativeCalls = <MethodCall>[];
      legacyCalls = <MethodCall>[];
      permissionCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call);
        switch (call.method) {
          case 'voiceCapability':
            return <String, Object?>{
              'stt': true,
              'tts': true,
              'locales': <String, Object?>{
                'en-IN': <String, Object?>{'stt': true, 'tts': true},
                'hi-IN': <String, Object?>{'stt': true, 'tts': true},
              },
            };
          case 'voiceSttStart':
            return true;
          default:
            return null;
        }
      });
      messenger.setMockMethodCallHandler(legacySpeech, (call) async {
        legacyCalls.add(call);
        return true;
      });
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(legacySpeech, null);
      await events.close();
    });

    test(
      'streams native transcripts without the network-capable plugin',
      () async {
        final transcripts = <String>[];
        final input = service();
        final started = await input.start(
          (text, isFinal) => transcripts.add('$text|$isFinal'),
          localeId: 'en-IN',
        );
        expect(started, isTrue);
        expect(input.isListening, isTrue);
        final start = nativeCalls.singleWhere(
          (call) => call.method == 'voiceSttStart',
        );
        final arguments = start.arguments as Map;
        expect(arguments['locale'], 'en-IN');
        expect(arguments['onDevice'], isTrue);
        expect(arguments['sessionId'], isNotNull);
        final sessionId = arguments['sessionId'] as String;

        events.add(<String, Object?>{
          'source': 'stt',
          'type': 'result',
          'sessionId': sessionId,
          'text': 'hello',
          'final': false,
        });
        events.add(<String, Object?>{
          'source': 'stt',
          'type': 'result',
          'sessionId': sessionId,
          'text': 'hello world',
          'final': true,
        });
        await Future<void>.delayed(Duration.zero);

        expect(transcripts, <String>['hello|false', 'hello world|true']);
        expect(input.isListening, isFalse);
        expect(legacyCalls, isEmpty);
        expect(permissionCalls, 1);
      },
    );

    test(
      'unsupported locale neither asks permission nor opens the mic',
      () async {
        final input = service();
        final started = await input.start((_, _) {}, localeId: 'ta-IN');

        expect(started, isFalse);
        expect(input.isListening, isFalse);
        expect(permissionCalls, 0);
        expect(
          nativeCalls.where((call) => call.method == 'voiceSttStart'),
          isEmpty,
        );
      },
    );

    test('permission denial leaves no native recognizer running', () async {
      final input = service(permitted: false);
      final started = await input.start((_, _) {}, localeId: 'en-IN');

      expect(started, isFalse);
      expect(input.isListening, isFalse);
      expect(permissionCalls, 1);
      expect(
        nativeCalls.where((call) => call.method == 'voiceSttStart'),
        isEmpty,
      );
    });

    test(
      'cancel closes the native session and drops its late result',
      () async {
        final transcripts = <String>[];
        final input = service();
        await input.start(
          (text, _) => transcripts.add(text),
          localeId: 'en-IN',
        );
        final start = nativeCalls.singleWhere(
          (call) => call.method == 'voiceSttStart',
        );
        final sessionId = (start.arguments as Map)['sessionId'] as String;

        await input.cancel();
        expect(input.isListening, isFalse);
        expect(
          nativeCalls.where((call) => call.method == 'voiceSttCancel'),
          hasLength(1),
        );
        events.add(<String, Object?>{
          'source': 'stt',
          'type': 'result',
          'sessionId': sessionId,
          'text': 'must not leak after cancel',
          'final': true,
        });
        await Future<void>.delayed(Duration.zero);

        expect(transcripts, isEmpty);
      },
    );

    test(
      'pre-session onStop invalidates delayed capability and permission starts',
      () async {
        final capability = _TestVoiceCapability();
        final pendingPermission = Completer<bool>();
        var permissionCalls = 0;
        final input = VoiceInputService(
          capability: capability,
          channel: channel,
          nativeEvents: events.stream,
          microphonePermission: () {
            permissionCalls++;
            return pendingPermission.future;
          },
        );
        final transcripts = <String>[];
        final starting = input.start(
          (text, _) => transcripts.add(text),
          localeId: 'en-IN',
        );
        for (var i = 0; i < 4 && permissionCalls == 0; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(permissionCalls, 1);

        // No native activeSession exists yet. Every onStop must still cross
        // the native/Dart boundary and invalidate this pending operation.
        events.add(<String, Object?>{
          'source': 'stt',
          'type': 'cancelled',
          'sessionId': null,
        });
        await Future<void>.delayed(Duration.zero);
        pendingPermission.complete(true);
        final started = await starting;

        expect(started, isFalse);
        expect(input.isListening, isFalse);
        expect(
          nativeCalls.where((call) => call.method == 'voiceSttStart'),
          isEmpty,
        );
        expect(transcripts, isEmpty);
      },
    );

    test(
      'pre-session onStop fences composer until foreground and a fresh tap',
      () async {
        final pendingProbe = Completer<VoiceAvailability>();
        final capability = _TestVoiceCapability()..pendingProbe = pendingProbe;
        final input = VoiceInputService(
          capability: capability,
          channel: channel,
          nativeEvents: events.stream,
          microphonePermission: () async => true,
        );
        final dictation = V2VoiceDictation(
          service: _TestPlatformVoiceService(input),
          localeId: 'en-IN',
        );
        addTearDown(dictation.dispose);
        final drafts = <String>[];
        dictation.onTranscript = drafts.add;
        final starting = dictation.toggle('');
        await Future<void>.delayed(Duration.zero);

        events.add(<String, Object?>{
          'source': 'stt',
          'type': 'cancelled',
          'sessionId': null,
        });
        await Future<void>.delayed(Duration.zero);
        // Even if foreground returns before the old probe completes, that old
        // operation is stale. It must not be revived by the foreground event.
        events.add(<String, Object?>{'source': 'stt', 'type': 'foreground'});
        await Future<void>.delayed(Duration.zero);
        pendingProbe.complete(_testVoiceAvailability());
        await starting;

        expect(dictation.listening, isFalse);
        expect(input.isListening, isFalse);
        expect(
          nativeCalls.where((call) => call.method == 'voiceSttStart'),
          isEmpty,
        );
        final lateStarts = nativeCalls
            .where((call) => call.method == 'voiceSttStart')
            .toList();
        final lateSession = lateStarts.isEmpty
            ? 'stt-never-started'
            : (lateStarts.single.arguments as Map)['sessionId'] as String;
        for (final isFinal in <bool>[false, true]) {
          events.add(<String, Object?>{
            'source': 'stt',
            'type': 'result',
            'sessionId': lateSession,
            'text': 'late background microphone text',
            'final': isFinal,
          });
        }
        await Future<void>.delayed(Duration.zero);
        expect(drafts, isEmpty);
        expect(dictation.listening, isFalse);

        // Foreground alone did not revive the old operation. Only this new
        // explicit toggle may create a native session.
        expect(
          nativeCalls.where((call) => call.method == 'voiceSttStart'),
          isEmpty,
        );
        await dictation.toggle('');
        expect(dictation.listening, isTrue);
        expect(
          nativeCalls.where((call) => call.method == 'voiceSttStart'),
          hasLength(1),
        );
        await dictation.cancel();
      },
    );

    test(
      'native lifecycle cancellation idles composer and drops queued results',
      () async {
        final input = voice;
        await input.cancel();
        nativeCalls.clear();
        input.availabilityOverrideForTest = true;
        input.ensureMicrophonePermissionForTest = () async => true;
        const nativeEvents = MethodChannel('ovid/voice_events');
        messenger.setMockMethodCallHandler(nativeEvents, (call) async => null);
        Future<void> emitNative(Map<String, Object?> event) async {
          await messenger.handlePlatformMessage(
            'ovid/voice_events',
            const StandardMethodCodec().encodeSuccessEnvelope(event),
            (_) {},
          );
        }

        addTearDown(() async {
          await input.cancel();
          input.availabilityOverrideForTest = null;
          input.ensureMicrophonePermissionForTest = null;
          messenger.setMockMethodCallHandler(nativeEvents, null);
        });
        final dictation = V2VoiceDictation(
          service: V2PlatformVoiceService.instance,
          localeId: 'en-IN',
        );
        addTearDown(dictation.dispose);
        final drafts = <String>[];
        dictation.onTranscript = drafts.add;
        await dictation.toggle('');
        expect(dictation.listening, isTrue);
        expect(input.isListening, isTrue);
        final start = nativeCalls.singleWhere(
          (call) => call.method == 'voiceSttStart',
        );
        final sessionId = (start.arguments as Map)['sessionId'] as String;

        // MainActivity.onStop emits this only after the native recognizer has
        // already been cancelled and destroyed.
        await emitNative(<String, Object?>{
          'source': 'stt',
          'type': 'cancelled',
          'sessionId': sessionId,
        });
        await Future<void>.delayed(Duration.zero);
        expect(input.isListening, isFalse);
        expect(dictation.listening, isFalse);

        for (final isFinal in <bool>[false, true]) {
          await emitNative(<String, Object?>{
            'source': 'stt',
            'type': 'result',
            'sessionId': sessionId,
            'text': 'late background microphone text',
            'final': isFinal,
          });
        }
        await Future<void>.delayed(Duration.zero);

        expect(drafts, isEmpty);
        expect(dictation.listening, isFalse);
        expect(input.isListening, isFalse);
        expect(
          nativeCalls.where((call) => call.method == 'voiceSttCancel'),
          isEmpty,
          reason: 'the native lifecycle already cancelled the microphone',
        );
      },
    );
  });
}

VoiceAvailability _testVoiceAvailability() => VoiceAvailability(
  enabled: true,
  stt: true,
  tts: true,
  locales: const <String, VoiceLocaleSupport>{
    'en-IN': VoiceLocaleSupport(stt: true, tts: true),
  },
);

class _TestVoiceCapability extends VoiceCapability {
  _TestVoiceCapability()
    : super(channel: const MethodChannel('ovid/native'), releaseEnabled: true);

  Completer<VoiceAvailability>? pendingProbe;

  @override
  Future<VoiceAvailability> probe() =>
      pendingProbe?.future ??
      Future<VoiceAvailability>.value(_testVoiceAvailability());
}

class _TestPlatformVoiceService extends V2PlatformVoiceService {
  _TestPlatformVoiceService(this.input);

  final VoiceInputService input;

  @override
  Stream<void> get lifecycleCancellations => input.lifecycleCancellations;

  @override
  Future<bool> isAvailable() => input.isAvailable();

  @override
  Future<bool> isLocaleAvailable(String localeId) =>
      input.isLocaleAvailable(localeId);

  @override
  Future<bool> ensureMicrophonePermission() =>
      input.ensureMicrophonePermission();

  @override
  Future<bool> start(
    void Function(String text, bool isFinal) onResult, {
    String? localeId,
  }) => input.start(onResult, localeId: localeId);

  @override
  Future<void> stop() => input.stop();

  @override
  Future<void> cancel() => input.cancel();
}
