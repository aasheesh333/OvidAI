import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P3 (2026-09-13): 24/7 background operation pins.
void main() {
  test('manifest declares boot + battery-exemption permissions', () {
    final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(m.contains('RECEIVE_BOOT_COMPLETED'), isTrue);
    expect(m.contains('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'), isTrue);
    expect(m.contains('BOOT_COMPLETED'), isTrue);
    expect(m.contains('.BootReceiver'), isTrue);
  });

  test('boot receiver respects the keep-alive pref', () {
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/BootReceiver.kt',
    ).readAsStringSync();
    expect(kt.contains('flutter.ovid_keep_alive'), isTrue);
    expect(kt.contains('AgentForegroundService'), isTrue);
  });

  test('native exposes a battery-exemption request', () {
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(kt.contains('"requestBatteryExemption"'), isTrue);
    expect(kt.contains('ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'), isTrue);
  });

  test('in-app exit cancels runs and stops the service', () {
    final src = File('lib/core/agent_notification_service.dart').readAsStringSync();
    final idx = src.indexOf('Future<void> agentExit');
    expect(idx, greaterThan(0));
    final body = src.substring(idx, idx + 300);
    expect(body.contains('cancelAllRuns'), isTrue);
    expect(body.contains("agentServiceStop"), isTrue);
  });
}
