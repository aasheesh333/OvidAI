import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/device_control_service.dart';

// After a process restart the accessibility service can stay enabled in
// Settings while `OvidAccessibilityService.instance` is still null until the
// OS rebinds. Native reports `connecting`; Dart must keep retrying (capped
// exponential backoff, generous budget) so the action lands without the user
// toggling the service. A genuinely disabled service still gets the Settings
// guidance; a Stop/new-run generation bump still cancels immediately.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ovid/device-reconnect-test');

  setUp(() {
    DeviceControlService.connectingRetryBaseDelayForTest =
        const Duration(milliseconds: 1);
    DeviceControlService.connectingRetryMaxDelayForTest =
        const Duration(milliseconds: 1);
    DeviceControlService.connectingRetryBudgetForTest =
        const Duration(milliseconds: 50);
    DeviceControlService.setMethodChannelForTest(channel);
  });

  tearDown(() {
    DeviceControlService.connectingRetryBaseDelayForTest =
        const Duration(milliseconds: 500);
    DeviceControlService.connectingRetryMaxDelayForTest =
        const Duration(seconds: 5);
    DeviceControlService.connectingRetryBudgetForTest =
        const Duration(seconds: 90);
    DeviceControlService.setMethodChannelForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  PlatformException connecting() =>
      PlatformException(code: 'SERVICE_CONNECTING', message: 'connecting');

  test('long rebind succeeds after many connecting replies without a toggle',
      () async {
    var taps = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceTap') {
        taps++;
        if (taps <= 12) throw connecting();
        return true;
      }
      if (call.method == 'deviceServiceState') return 'connecting';
      return true;
    });

    final result = await DeviceControlService.I.tap(x: 1, y: 2);
    expect(result, isTrue);
    expect(taps, 13, reason: 'initial attempt + 12 retries');
  });

  test('exhausted budget while connecting advises wait/retry, not Settings',
      () async {
    DeviceControlService.connectingRetryBudgetForTest = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceServiceState') return 'connecting';
      throw connecting();
    });

    await expectLater(
      DeviceControlService.I.tap(x: 1, y: 2),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'SERVICE_CONNECTING')
            .having(
              (e) => e.message ?? '',
              'message',
              allOf(contains('reconnect'), isNot(contains('Settings'))),
            ),
      ),
    );
  });

  test('a genuinely disabled service surfaces the Settings guidance', () async {
    DeviceControlService.connectingRetryBudgetForTest = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceServiceState') return 'disabled';
      throw connecting();
    });

    await expectLater(
      DeviceControlService.I.tap(x: 1, y: 2),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'SERVICE_DISABLED')
            .having((e) => e.message ?? '', 'message', contains('Settings')),
      ),
    );
  });

  test('serviceState maps native states and fails closed to disabled',
      () async {
    var state = 'bound';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceServiceState') return state;
      return true;
    });

    expect(await DeviceControlService.I.serviceState(), 'bound');
    state = 'connecting';
    expect(await DeviceControlService.I.serviceState(), 'connecting');
    state = 'disabled';
    expect(await DeviceControlService.I.serviceState(), 'disabled');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'UNAVAILABLE', message: 'nope');
    });
    expect(await DeviceControlService.I.serviceState(), 'disabled');
  });

  test('refreshServiceBinding waits out a slow rebind and is non-throwing',
      () async {
    var state = 'connecting';
    var stateCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceServiceState') {
        stateCalls++;
        if (stateCalls >= 4) state = 'bound';
        return state;
      }
      return true;
    });

    await DeviceControlService.I.refreshServiceBinding();
    expect(stateCalls, greaterThanOrEqualTo(4));
    expect(await DeviceControlService.I.serviceState(), 'bound');
  });

  test('refreshServiceBinding returns immediately when not connecting',
      () async {
    var stateCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceServiceState') {
        stateCalls++;
        return 'disabled';
      }
      return true;
    });

    await DeviceControlService.I.refreshServiceBinding();
    expect(stateCalls, 1);
  });

  test('a Stop during the rebind wait cancels instead of succeeding', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceServiceState') return 'connecting';
      DeviceControlService.I.cancelDeviceActions();
      throw connecting();
    });

    final result = await DeviceControlService.I.tap(x: 1, y: 2);
    expect(result, DeviceControlService.cancelledSupersededMessage);
  });
}
