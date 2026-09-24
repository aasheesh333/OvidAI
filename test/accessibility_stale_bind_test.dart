import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/device_control_service.dart';

/// Accessibility service after an app restart (2026-09-24).
///
/// Ordinary process death self-heals: AccessibilityManagerService rebinds and
/// `onServiceConnected` republishes the static `instance`. The case that does
/// NOT heal is a force-stop (the package enters the stopped state and the system
/// will not restart its services) or an OEM autostart blocker — the service stays
/// listed in Settings.Secure, so Settings shows it ON, while `instance` is null
/// for the whole process lifetime.
///
/// Before this, that state was indistinguishable from a slow rebind: native said
/// `connecting` forever, every `device_*` call burned a 90s retry budget and then
/// advised "wait a moment — it should bind on its own" (false), and the one UI
/// row that could have offered a toggle was gated on the Settings-level
/// `isEnabled()`, which returns true, so it never rendered. There was also no
/// cold-start probe at all: the only trigger was `AppLifecycleState.resumed`,
/// which Android dispatches before `runApp`, so the shell's observer never saw it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ovid/device-stale-test');
  final svc = DeviceControlService.I;

  setUp(() {
    DeviceControlService.connectingRetryBaseDelayForTest =
        const Duration(milliseconds: 1);
    DeviceControlService.connectingRetryMaxDelayForTest =
        const Duration(milliseconds: 1);
    DeviceControlService.connectingRetryBudgetForTest =
        const Duration(milliseconds: 40);
    DeviceControlService.reconnectGracePeriodForTest = Duration.zero;
    DeviceControlService.setMethodChannelForTest(channel);
    svc.staleBindingDetected = false;
  });

  tearDown(() {
    DeviceControlService.connectingRetryBaseDelayForTest =
        const Duration(milliseconds: 500);
    DeviceControlService.connectingRetryMaxDelayForTest =
        const Duration(seconds: 5);
    DeviceControlService.connectingRetryBudgetForTest =
        const Duration(seconds: 90);
    DeviceControlService.reconnectGracePeriodForTest =
        const Duration(seconds: 20);
    DeviceControlService.setMethodChannelForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  group('the stale state is a distinct, honest signal', () {
    test('serviceState passes connecting_stale through instead of folding it',
        () async {
      mock((call) async {
        if (call.method == 'deviceServiceState') return 'connecting_stale';
        return null;
      });
      expect(await svc.serviceState(), 'connecting_stale');
      expect(
        svc.staleBindingDetected,
        isTrue,
        reason: 'the UI needs this to offer the toggle',
      );
    });

    test('binding again clears the stale flag', () async {
      var state = 'connecting_stale';
      mock((call) async {
        if (call.method == 'deviceServiceState') return state;
        return null;
      });
      await svc.serviceState();
      expect(svc.staleBindingDetected, isTrue);

      state = 'bound';
      expect(await svc.serviceState(), 'bound');
      expect(svc.staleBindingDetected, isFalse);
    });

    test('an unknown state still fails closed to disabled', () async {
      mock((call) async => 'nonsense');
      expect(await svc.serviceState(), 'disabled');
    });
  });

  group('a stale bind fails fast instead of burning the retry budget', () {
    test('one call, immediate SERVICE_STALE, no retry loop', () async {
      var stateCalls = 0;
      var tapCalls = 0;
      mock((call) async {
        if (call.method == 'deviceServiceState') {
          stateCalls++;
          return 'connecting_stale';
        }
        tapCalls++;
        throw PlatformException(
          code: 'SERVICE_STALE',
          message: DeviceControlService.staleMessage,
        );
      });

      final started = DateTime.now();
      await expectLater(
        svc.tap(x: 1, y: 2),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'SERVICE_STALE',
          ),
        ),
      );

      expect(tapCalls, 1, reason: 'retrying a terminal state is pointless');
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
        reason: 'must not wait out the 90s connecting budget',
      );
      expect(svc.staleBindingDetected, isTrue);
      expect(stateCalls, isNonNegative);
    });

    test('an exhausted connecting budget re-reads state and tells the truth',
        () async {
      // Native keeps saying SERVICE_CONNECTING for the action, but the state
      // probe reports stale — the budget-exhausted error must surface the
      // toggle instruction, not "it should bind on its own".
      mock((call) async {
        if (call.method == 'deviceServiceState') return 'connecting_stale';
        throw PlatformException(code: 'SERVICE_CONNECTING', message: 'wait');
      });

      await expectLater(
        svc.tap(x: 1, y: 2),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'SERVICE_STALE')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('switch it off and on'),
                  isNot(contains('should bind on its own')),
                ),
              ),
        ),
      );
    });

    test('a genuinely slow rebind still gets the patient message', () async {
      mock((call) async {
        if (call.method == 'deviceServiceState') return 'connecting';
        throw PlatformException(code: 'SERVICE_CONNECTING', message: 'wait');
      });

      await expectLater(
        svc.tap(x: 1, y: 2),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'SERVICE_CONNECTING')
              .having(
                (e) => e.message,
                'message',
                contains('should bind on its own'),
              ),
        ),
      );
    });
  });

  group('cold start actually probes the binding', () {
    test('a localState startup task exists and cannot be deadline-skipped', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      expect(src, contains("id: 'device.serviceBinding'"));
      expect(
        src,
        contains('body: DeviceControlService.I.refreshServiceBinding'),
      );
      // localState tasks are never skipped at the coordinator deadline, and the
      // probe must not be droppable — it is the only cold-start trigger.
      final task = src.substring(src.indexOf("id: 'device.serviceBinding'"));
      expect(
        task.substring(0, 220),
        contains('StartupItemKind.localState'),
      );
    });

    test('the service declares the screenshot capability', () {
      // AccessibilityService.takeScreenshot() (device_screenshot on API 30+)
      // requires this; the shipped XML had lost it, so every screenshot failed.
      final xml = File(
        'android/app/src/main/res/xml/ovid_accessibility_service.xml',
      ).readAsStringSync();
      expect(xml, contains('android:canTakeScreenshot="true"'));
    });

    test('native distinguishes stale from connecting', () {
      final kt = File(
        'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
      ).readAsStringSync();
      expect(kt, contains('"connecting_stale"'));
      expect(kt, contains('"SERVICE_STALE"'));
      // And it must never go back to force-toggling the component: while the
      // component is disabled the system DROPS it from Settings.Secure and
      // re-enabling does not restore it.
      expect(kt, isNot(contains('setComponentEnabledSetting')));
    });

    test('the Control-mode notice reads the four-state signal', () {
      final ui = File('lib/ui/chat_screen.dart').readAsStringSync();
      final notice = ui.substring(ui.indexOf('class _ControlServiceNoticeState'));
      expect(notice, contains('_serviceState'));
      expect(notice, contains('DeviceControlService.staleState'));
      expect(
        notice,
        contains('Android has not restarted it'),
        reason: 'the stale row must be worded differently from "service off"',
      );
    });
  });
}
