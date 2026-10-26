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
import 'package:ovid_ai/core/voice_input_service.dart';
import 'package:ovid_ai/core/voice_reply_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('ovid/native');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  test('STT start payload contains only metadata, never audio bytes', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      if (call.method == 'voiceCapability') {
        return <String, Object?>{
          'stt': true,
          'tts': true,
          'locales': <String, Object?>{'en-IN': <String, Object?>{'stt': true, 'tts': true}},
        };
      }
      if (call.method == 'voiceSttStart') return true;
      return null;
    });

    final service = VoiceInputService(
      channel: native,
      microphonePermission: () async => true,
      capability: VoiceCapability(channel: native, releaseEnabled: true),
    );
    await service.start((String text, bool isFinal) {}, localeId: 'en-IN');

    final startCall = calls.singleWhere((c) => c.method == 'voiceSttStart');
    final args = startCall.arguments as Map<Object?, Object?>;
    expect(args.keys, contains('sessionId'));
    expect(args.keys, contains('locale'));
    expect(args.keys, contains('pauseFor'));
    expect(args.keys, contains('listenFor'));
    expect(args.keys, contains('onDevice'));
    for (final key in args.keys) {
      final value = args[key];
      if (value is List) fail('Unexpected list value for $key');
    }
  });

  test('TTS speak payload contains only text and ids, never audio bytes', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      if (call.method == 'ttsSpeak') {
        return <String, Object?>{'accepted': true, 'utteranceId': 'u1', 'locale': 'en-IN'};
      }
      return null;
    });

    final service = VoiceReplyService(channel: native, releaseEnabled: true);
    await service.startUtterance(
      utteranceId: 'u1',
      text: 'Synthetic acceptance text.',
      localeId: 'en-IN',
    );

    final speakCall = calls.singleWhere((c) => c.method == 'ttsSpeak');
    final args = speakCall.arguments as Map<Object?, Object?>;
    expect(args['utteranceId'], 'u1');
    expect(args['text'], 'Synthetic acceptance text.');
    expect(args['locale'], 'en-IN');
    for (final entry in args.entries) {
      if (entry.value is List) fail('Unexpected list value for ${entry.key}');
    }
  });

  test('voice cache persists only message ids and character offsets', () async {
    final root = await Directory.systemTemp.createTemp('voice-privacy-');
    addTearDown(() async => root.delete(recursive: true));
    final store = VoiceCacheStore(rootDirectory: () async => root);

    await store.savePosition(messageId: 'msg/1', character: 42);
    final file = File('${root.path}/voice-cache/playback.json');
    expect(await file.exists(), isTrue);
    final contents = await file.readAsString();
    expect(contents, contains('msg/1'));
    expect(contents, contains('42'));
    expect(contents.contains('audio'), isFalse);
    expect(contents.contains('pcm'), isFalse);
  });

  test(
    'sending a voice transcript uses the existing HTTP client and body contains only text',
    () async {
      final requests = <http.Request>[];
      final rest = CloudRestClient(
        restBase: 'https://voice.invalid',
        headers: CloudHeaders.forTest(),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
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

      await store.enqueue('session-1', 'voice transcript only', clientMsgId: 'voice-msg-1');
      await store.flushOutbox();

      expect(requests, hasLength(1));
      final body = requests.single.body;
      expect(body, contains('voice transcript only'));
      expect(body.toLowerCase().contains('audio'), isFalse);
    },
  );
}
