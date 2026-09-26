import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/security_service.dart';
import 'package:ovid_ai/core/state.dart';

/// S6: the native device-integrity probe must actually be CONSUMED, not just
/// defined. Before this, `getSecurityStatus` existed in Kotlin and
/// `SecurityService` existed in Dart but nothing ever called it — dead code.
/// These tests prove the status flows into AppState and drives a decision.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() {
    SecurityService.setMethodChannelForTest(null);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  void mockNative(Map<String, dynamic> status) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
          call,
        ) async {
          if (call.method == 'getSecurityStatus') return status;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
    });
  }

  test('refreshDeviceSecurity stores the native probe result', () async {
    mockNative({
      'isRooted': false,
      'isDebuggerAttached': false,
      'isHookingFrameworkPresent': false,
    });
    final app = AppState.I;
    expect(app.securityChecked, isFalse);
    await app.refreshDeviceSecurity();
    expect(app.securityChecked, isTrue);
    expect(app.deviceSecurity['isRooted'], isFalse);
    expect(app.deviceEnvironmentCompromised, isFalse);
  });

  test('a rooted device is reported as compromised', () async {
    mockNative({
      'isRooted': true,
      'isDebuggerAttached': false,
      'isHookingFrameworkPresent': false,
    });
    await AppState.I.refreshDeviceSecurity();
    expect(AppState.I.deviceEnvironmentCompromised, isTrue);
  });

  test('a hooking framework or debugger is reported as compromised', () async {
    mockNative({
      'isRooted': false,
      'isDebuggerAttached': true,
      'isHookingFrameworkPresent': true,
    });
    await AppState.I.refreshDeviceSecurity();
    expect(AppState.I.deviceEnvironmentCompromised, isTrue);
  });

  test('a missing native handler degrades gracefully, never throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
          call,
        ) async {
          throw MissingPluginException('no handler');
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
    });
    await AppState.I.refreshDeviceSecurity();
    expect(AppState.I.securityChecked, isTrue);
    expect(AppState.I.deviceEnvironmentCompromised, isFalse);
  });

  test('readiness actually invokes the probe (no dead code)', () {
    // Pin the consumption point: _initializeReadiness must call
    // refreshDeviceSecurity, otherwise the probe is defined but unused
    // (the exact bug this item fixes).
    final src = File('lib/core/state.dart').readAsStringSync();
    expect(src, contains('unawaited(refreshDeviceSecurity())'));
  });
}
