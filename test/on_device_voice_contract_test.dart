import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/voice_cache_store.dart';
import 'package:ovid_ai/core/voice_capability.dart';
import 'package:ovid_ai/core/voice_reply_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const native = MethodChannel('ovid/native');
  const legacySpeech = MethodChannel('plugin.csdcorp.com/speech_to_text');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(legacySpeech, null);
  });

  test('voice unavailable does not open microphone or send audio', () async {
    final nativeCalls = <MethodCall>[];
    final legacyCalls = <MethodCall>[];
    final rest = _RecordingRest();
    messenger.setMockMethodCallHandler(native, (call) async {
      nativeCalls.add(call);
      if (call.method == 'voiceCapability') {
        return <String, Object?>{
          'stt': false,
          'tts': false,
          'locales': <String, Object?>{},
          'reason': 'On-device voice needs a downloaded speech language.',
        };
      }
      if (call.method == 'voiceSttStart') return true;
      return null;
    });
    // A cloud-capable plugin must not make the capability probe succeed.
    messenger.setMockMethodCallHandler(legacySpeech, (call) async {
      legacyCalls.add(call);
      return call.method == 'initialize' || call.method == 'listen';
    });

    final availability = await VoiceCapability(
      channel: native,
      releaseEnabled: true,
    ).probe();

    expect(availability.enabled, isFalse);
    expect(availability.stt, isFalse);
    expect(availability.tts, isFalse);
    expect(availability.reason, isNotNull);
    expect(
      nativeCalls.where((call) => call.method == 'voiceSttStart'),
      isEmpty,
    );
    expect(legacyCalls, isEmpty);
    expect(
      rest.requests.where((request) => request.bodyBytes.isNotEmpty),
      isEmpty,
    );
  });

  test('capability reports per-locale STT and offline TTS support', () async {
    messenger.setMockMethodCallHandler(native, (call) async {
      expect(call.method, 'voiceCapability');
      expect(
        (call.arguments as Map)['locales'],
        containsAll(<String>['en-IN', 'hi-IN', 'pa-IN', 'ta-IN']),
      );
      return <String, Object?>{
        'stt': true,
        'tts': true,
        'locales': <String, Object?>{
          'en-IN': <String, Object?>{'stt': true, 'tts': true},
          'hi-IN': <String, Object?>{'stt': true, 'tts': false},
        },
      };
    });

    final availability = await VoiceCapability(
      channel: native,
      releaseEnabled: true,
    ).probe();

    expect(availability.enabled, isTrue);
    expect(availability.stt, isTrue);
    expect(availability.tts, isTrue);
    expect(availability.supportsStt('en-IN'), isTrue);
    expect(availability.supportsTts('en_IN'), isTrue);
    expect(availability.supportsStt('hi-IN'), isTrue);
    expect(availability.supportsTts('hi-IN'), isFalse);
    expect(availability.supportsStt('ta-IN'), isFalse);
    expect(availability.reason, isNull);
  });

  test(
    'release gate disables real playback even when native support exists',
    () async {
      final nativeCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(native, (call) async {
        nativeCalls.add(call);
        if (call.method == 'voiceCapability') {
          return <String, Object?>{
            'stt': true,
            'tts': true,
            'locales': <String, Object?>{
              'en-IN': <String, Object?>{'stt': true, 'tts': true},
            },
          };
        }
        if (call.method == 'ttsSpeak') {
          return <String, Object?>{
            'accepted': true,
            'utteranceId': 'u1',
            'locale': 'en-IN',
          };
        }
        return null;
      });

      expect(kOvidVoiceEnabled, isFalse);
      final availability = await VoiceCapability(channel: native).probe();
      expect(availability.enabled, isFalse);
      expect(availability.stt, isTrue);
      expect(availability.reason, kOvidVoiceUnavailableMessage);

      final spoken = await VoiceReplyService(
        channel: native,
      ).speak('A settled answer must never autoplay.', localeId: 'en-IN');
      expect(spoken, isFalse);
      expect(nativeCalls.where((call) => call.method == 'ttsSpeak'), isEmpty);
    },
  );

  test('legacy generated-summary entry point cannot autoplay', () async {
    final nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      nativeCalls.add(call);
      if (call.method == 'ttsSpeak') {
        return <String, Object?>{
          'accepted': true,
          'utteranceId': 'legacy-voice-1',
          'locale': 'en-IN',
        };
      }
      return null;
    });
    final legacy = VoiceReplyService(channel: native, releaseEnabled: true);

    final spoken = await legacy.speak(
      'A generated summary, not the exact answer.',
      localeId: 'en-IN',
    );

    expect(spoken, isFalse);
    expect(nativeCalls.where((call) => call.method == 'ttsSpeak'), isEmpty);
  });

  test('Punjabi playback requests the explicit pa-IN locale', () async {
    final nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      nativeCalls.add(call);
      if (call.method == 'ttsSpeak') {
        return <String, Object?>{
          'accepted': true,
          'utteranceId': 'punjabi-acceptance',
          'locale': 'pa-IN',
        };
      }
      return null;
    });

    final accepted = await VoiceReplyService(
      channel: native,
      releaseEnabled: true,
    ).startUtterance(
      utteranceId: 'punjabi-acceptance',
      text: 'Synthetic acceptance text.',
      localeId: VoiceReplyService.localeFor('pa'),
    );

    final speak = nativeCalls.singleWhere((call) => call.method == 'ttsSpeak');
    expect((speak.arguments as Map)['locale'], 'pa-IN');
    expect(accepted?.localeId, 'pa-IN');
    expect(kOvidVoiceEnabled, isFalse);
  });

  test(
    'production outbox and sendMessage carry only transcript content',
    () async {
      const transcript = 'यह केवल लिखित उत्तर है';
      final requests = <http.Request>[];
      final rest = CloudRestClient(
        restBase: 'https://voice.invalid',
        headers: CloudHeaders.forTest(),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'runId': 'run-1',
              'userMessageId': 'message-1',
              'status': 'queued',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      AppState.resetTestInstance();
      AppState.createForTest(sessionAccountIdForTest: 'voice-test-account');
      addTearDown(AppState.resetTestInstance);
      final connection = ConnectionService.forTest();
      addTearDown(connection.dispose);
      final store = CloudSessionStore.forTest(
        idMap: const <String, String>{'session-1': 'session-1'},
        rest: rest,
        connection: connection,
      );
      addTearDown(store.dispose);

      final entry = await store.enqueue(
        'session-1',
        transcript,
        clientMsgId: 'client-voice-1',
      );
      final outboxJson = entry.toJson();
      expect(outboxJson['content'], transcript);
      expect(outboxJson.containsKey('audio'), isFalse);
      expect(outboxJson.containsKey('audioBytes'), isFalse);
      expect(outboxJson['attachmentFiles'], isNull);
      expect(outboxJson['attachmentIds'], isNull);

      // This drives the real CloudSessionStore._deliver path into the real
      // CloudRestClient.sendMessage serializer, not a synthetic postJson.
      await store.flushOutbox();

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/sessions/session-1/messages');
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body, <String, dynamic>{
        'content': transcript,
        'clientMsgId': 'client-voice-1',
      });
      expect(
        body.keys.where((key) => key.toLowerCase().contains('audio')),
        isEmpty,
      );
      expect(requests.single.bodyBytes, isNotEmpty);
      expect(store.outboxEntry('client-voice-1'), isNull);
      // No voice artifact or attachment usage path exists: the only HTTP
      // request is the content-only prompt above. VoiceCacheStore is covered
      // separately below and is not part of CloudUsageStore or chat backup.
    },
  );

  test(
    'voice cache clears independently and never contains chat text',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'voice-cache-contract-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final chat = File('${root.path}/chat.txt');
      await chat.writeAsString('private chat text', flush: true);
      final store = VoiceCacheStore(rootDirectory: () async => root);

      await store.savePosition(messageId: 'message/1', character: 17);
      expect(await store.positionFor('message/1'), 17);
      final voiceDirectory = Directory('${root.path}/voice-cache');
      expect(await voiceDirectory.exists(), isTrue);
      expect(
        await voiceDirectory
            .list(recursive: true)
            .where((entity) => entity is File)
            .asyncMap((entity) => (entity as File).readAsString())
            .any((contents) => contents.contains('private chat text')),
        isFalse,
      );

      await store.clear();
      expect(await store.positionFor('message/1'), isNull);
      expect(await voiceDirectory.exists(), isFalse);
      expect(await chat.readAsString(), 'private chat text');
    },
  );
}

class _RecordingRest {
  final requests = <http.Request>[];
  late final client = CloudRestClient(
    restBase: 'https://voice.invalid',
    headers: CloudHeaders.forTest(),
    httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    }),
  );
}
