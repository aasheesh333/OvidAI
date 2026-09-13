import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:ovid_ai/core/voice_input_service.dart';

/// P5 (2026-09-13): voice-input service contract.
void main() {
  final voice = VoiceInputService.I;

  tearDown(() {
    voice.availabilityOverrideForTest = null;
    voice.startOverrideForTest = null;
    voice.stopOverrideForTest = null;
  });

  test('reports unavailable when the device has no STT', () async {
    voice.availabilityOverrideForTest = false;
    expect(await voice.isAvailable(), isFalse);
    final started = await voice.start((_, _) {});
    expect(started, isFalse);
  });

  test('start routes partial and final transcripts to the callback', () async {
    voice.availabilityOverrideForTest = true;
    final seen = <String>[];
    voice.startOverrideForTest = (onResult) {
      onResult('hello', false);
      onResult('hello world', true);
    };
    expect(await voice.isAvailable(), isTrue);
    final started = await voice.start((text, final_) {
      seen.add('$text:$final_');
    });
    expect(started, isTrue);
    expect(voice.isListening, isTrue);
    expect(seen, ['hello:false', 'hello world:true']);
  });

  test('stop clears the listening state', () async {
    voice.availabilityOverrideForTest = true;
    var stopped = false;
    voice.startOverrideForTest = (_) {};
    voice.stopOverrideForTest = () => stopped = true;
    await voice.start((_, _) {});
    expect(voice.isListening, isTrue);
    await voice.stop();
    expect(stopped, isTrue);
    expect(voice.isListening, isFalse);
  });

  test('overlay mic is wired native<->Dart', () {
    final agent = File('lib/core/agent_service.dart').readAsStringSync();
    expect(agent.contains("deviceOverlayMicMethod = 'deviceOverlayMic'"), isTrue);
    expect(agent.contains('handleDeviceOverlayMic'), isTrue);
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
    ).readAsStringSync();
    expect(kt.contains('onOverlayMic'), isTrue);
    expect(kt.contains('setOverlayInputText'), isTrue);
    final main = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(main.contains('"deviceOverlaySetText"'), isTrue);
    expect(main.contains('"deviceOverlayMicListening"'), isTrue);
  });
}
