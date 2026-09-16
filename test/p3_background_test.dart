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

  test('foreground service refreshes the wake lock before expiry', () {
    // The 6h PARTIAL_WAKE_LOCK ceiling must be refreshed on update ticks —
    // otherwise 24/7 runs silently lose the lock and Doze kills them.
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/AgentForegroundService.kt',
    ).readAsStringSync();
    expect(kt.contains('wakeLockAcquiredAt'), isTrue);
  });

  test('failed foreground start stays sticky so the system restarts it', () {
    // Only the explicit EXIT path may be NOT_STICKY; a startForeground
    // failure must stay STICKY so the OS restarts the service instead of
    // letting the agent die in the background.
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/AgentForegroundService.kt',
    ).readAsStringSync();
    expect('START_NOT_STICKY'.allMatches(kt).length, 1);
  });

  test('foreground service declares dataSync + specialUse with reason', () {
    // Android 14+ needs a matching type + permission + property, or the
    // start throws. The personal-assistant workload is declared under both
    // dataSync (transfers) and specialUse (assistant presence) so neither
    // path can crash the service on launch.
    final m = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(m.contains('foregroundServiceType="dataSync|specialUse"'), isTrue);
    expect(
      m.contains('FOREGROUND_SERVICE_SPECIAL_USE'),
      isTrue,
    );
    expect(m.contains('PROPERTY_SPECIAL_USE_FGS_SUBTYPE'), isTrue);
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
