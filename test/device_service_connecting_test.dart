import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/device_control_service.dart';

// Accessibility re-bind window: right after the app process restarts, the
// OS may take a moment to rebind an enabled accessibility service. Native
// must NOT block the main thread waiting for it (that starves the very
// bind callback being waited on); instead it answers SERVICE_CONNECTING
// immediately and Dart retries with backoff until the bind lands.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ovid/service-connecting-test');

  setUp(() {
    DeviceControlService.connectingRetryDelaysForTest = [
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
    DeviceControlService.setMethodChannelForTest(channel);
  });

  tearDown(() {
    DeviceControlService.connectingRetryDelaysForTest = const [
      Duration(milliseconds: 800),
      Duration(milliseconds: 1600),
      Duration(milliseconds: 2400),
    ];
    DeviceControlService.setMethodChannelForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  PlatformException connecting() =>
      PlatformException(code: 'SERVICE_CONNECTING', message: 'connecting');

  test('device action succeeds after transient SERVICE_CONNECTING',
      () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      if (call.method == 'deviceTap' && calls <= 2) throw connecting();
      return true;
    });

    final result = await DeviceControlService.I.tap(x: 1, y: 2);
    expect(result, isTrue);
    expect(calls, 3, reason: 'initial attempt + 2 retries');
  });

  test('persistent SERVICE_CONNECTING surfaces after retries are exhausted',
      () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      throw connecting();
    });

    await expectLater(
      DeviceControlService.I.tap(x: 1, y: 2),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'SERVICE_CONNECTING',
        ),
      ),
    );
    expect(calls, 4, reason: 'initial attempt + 3 retries');
  });

  test('a stop during retries reports superseded, not the native error',
      () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      DeviceControlService.I.cancelDeviceActions();
      throw connecting();
    });

    final result = await DeviceControlService.I.tap(x: 1, y: 2);
    expect(result, DeviceControlService.cancelledSupersededMessage);
    expect(calls, 1, reason: 'no retry after the generation moved on');
  });

  test('device read retries through a transient SERVICE_CONNECTING',
      () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      if (call.method == 'deviceRead' && calls == 1) throw connecting();
      return <String, dynamic>{
        'status': 'ok',
        'added': [
          {'handle': 1, 'class': 'TextView', 'text': 'hi'},
        ],
        'changed': [],
        'removed': [],
      };
    });

    final result = await DeviceControlService.I.read();
    expect(result, contains('"hi"'));
    expect(calls, 2);
  });

  test('native never blocks the main thread waiting for the bind', () {
    final src = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(src.contains('SERVICE_CONNECTING'), isTrue);
    final start = src.indexOf('private fun deviceService(');
    expect(start, greaterThanOrEqualTo(0));
    final end = src.indexOf('\n    private fun ', start + 1);
    final window = src.substring(start, end < 0 ? src.length : end);
    expect(
      window.contains('sleep('),
      isFalse,
      reason: 'deviceService must not block the main thread waiting for bind',
    );
  });
}
