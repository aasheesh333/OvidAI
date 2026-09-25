import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Control-mode permanent presence: while any session is in control mode,
// agentIdle must never stop the foreground service — not even between runs.
// Stopping happens only via explicit Exit / mode off / master switch off.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AgentNotificationService always talks on 'ovid/native' (no override
  // seam), so the mock must live on that exact channel name.
  const channel = MethodChannel('ovid/native');

  ChatSession controlSession(AppState app, String id) {
    final s = ChatSession(id: id, title: 'C', model: 'm', mode: 'control');
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AgentNotificationService.I.resetForTest();
    // resetForTest does NOT clear this static: reset explicitly so one
    // test's stop-request never leaks into the next.
    AgentNotificationService.serviceStopRequestedForTestFlag = false;
    AgentNotificationService.keepAliveOverrideForTest = false;
    DeviceControlService.setMethodChannelForTest(channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AgentNotificationService.serviceStopRequestedForTestFlag = false;
    AgentNotificationService.keepAliveOverrideForTest = null;
    AgentNotificationService.anyRunActiveOverrideForTest = null;
    DeviceControlService.setMethodChannelForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppState.resetTestInstance();
  });

  test('agentIdle keeps the service while a control session exists', () async {
    final app = AppState.createForTest();
    controlSession(app, 'control-1');
    setAnyRunActiveForTest(false);

    await agentIdleForTest();

    expect(
      serviceStopRequestedForTest(),
      isFalse,
      reason: 'idle gaps in control mode must not stop the service',
    );
    expect(AgentNotificationService.I.activeForTest, isTrue);
  });

  test('presence lock respects the master notification switch being off',
      () async {
    final app = AppState.createForTest();
    controlSession(app, 'control-1');
    setAnyRunActiveForTest(false);
    await app.setNotificationsEnabled(false);

    await agentIdleForTest();

    expect(
      serviceStopRequestedForTest(),
      isTrue,
      reason: 'explicit user opt-out still stops the service',
    );
    await app.setNotificationsEnabled(true);
  });

  test('keep-alive re-arms after the failure cooldown instead of dying silent',
      () async {
    final app = AppState.createForTest();
    controlSession(app, 'control-1');
    setAnyRunActiveForTest(true);
    AgentNotificationService.supportCooldownForTest = Duration.zero;

    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      throw PlatformException(code: 'START_FAIL');
    });

    // `agentWorking` debounces for 600 ms, so the old fixed 700 ms sleeps left
    // only 100 ms of slack — under full-suite parallel load the timer could miss
    // the window and the failure count never reached three, failing this test
    // while it passed in isolation. Poll for the expected state instead.
    Future<void> settleUntil(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    // Three failures disable the notifier…
    await AgentNotificationService.I.agentWorking('one');
    await settleUntil(() => calls >= 1);
    await AgentNotificationService.I.agentWorking('two');
    await settleUntil(() => calls >= 2);
    await AgentNotificationService.I.agentWorking('three');
    await settleUntil(
      () => !AgentNotificationService.I.supportedForTest,
    );
    expect(AgentNotificationService.I.supportedForTest, isFalse);

    // …but the next run re-arms instead of staying dead for the session.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return true;
    });
    final beforeReArm = calls;
    await AgentNotificationService.I.agentWorking('four');
    // Poll the CHANNEL CALL, not the re-arm flag: the flag flips immediately
    // while the actual invoke still waits out the 600 ms debounce.
    await settleUntil(() => calls > beforeReArm);
    expect(
      AgentNotificationService.I.supportedForTest,
      isTrue,
      reason: 'the re-armed notifier must be usable again',
    );
    expect(calls, greaterThan(beforeReArm));
  });

  test('presence lock lifts when control mode turns off', () async {
    final app = AppState.createForTest();
    final s = controlSession(app, 'control-1');
    setAnyRunActiveForTest(false);

    await agentIdleForTest();
    expect(serviceStopRequestedForTest(), isFalse);

    s.mode = 'auto';
    await agentIdleForTest();
    expect(
      serviceStopRequestedForTest(),
      isTrue,
      reason: 'no control session left, keep-alive off → service stops',
    );
  });

  test('killer-OEM detection matches known aggressive ROMs only', () {
    for (final oem in [
      'Xiaomi',
      'Redmi',
      'POCO',
      'OPPO',
      'Realme',
      'OnePlus',
      'vivo',
      'iQOO',
      'HUAWEI',
      'HONOR',
      'samsung',
      'asus',
      'Infinix',
      'TECNO',
    ]) {
      expect(
        DeviceControlService.isKillerOemForTest(oem),
        isTrue,
        reason: oem,
      );
    }
    for (final oem in ['Google', 'Motorola', 'Nothing', 'Sony', '']) {
      expect(
        DeviceControlService.isKillerOemForTest(oem),
        isFalse,
        reason: oem,
      );
    }
  });

  test('background health exposes manufacturer and exemption state', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getBackgroundHealth') {
        return {'manufacturer': 'Xiaomi', 'batteryExempt': false};
      }
      return true;
    });

    final health = await DeviceControlService.I.backgroundHealth();
    expect(health.manufacturer, 'Xiaomi');
    expect(health.batteryExempt, isFalse);
    expect(health.needsOemGuidance, isTrue);
  });

  test('battery-exemption prompt flag persists once shown', () async {
    final app = AppState.createForTest();
    expect(app.controlBatteryPromptShown, isFalse);
    await app.markControlBatteryPromptShown();
    expect(app.controlBatteryPromptShown, isTrue);

    final again = AppState.createForTest();
    await again.initialize();
    expect(
      again.controlBatteryPromptShown,
      isTrue,
      reason: 'flag survives restart so we never nag twice',
    );
  });

  test('native exposes background-health check without opening UI', () {
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(kt.contains('"getBackgroundHealth"'), isTrue);
    expect(kt.contains('Build.MANUFACTURER'), isTrue);
    // Pure check: must not launch the exemption settings screen itself.
    final idx = kt.indexOf('"getBackgroundHealth"');
    final body = kt.substring(idx, idx + 1500);
    expect(body.contains('isIgnoringBatteryOptimizations'), isTrue);
    expect(body.contains('ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'), isFalse);
  });
}
