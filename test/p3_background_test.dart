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

  // Boot alarm rearming and stopped-runtime behavior are executed under
  // Robolectric in BackgroundRuntimeTest, rather than pinned to source text.

  test('native exposes a battery-exemption request', () {
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(kt.contains('"requestBatteryExemption"'), isTrue);
    expect(kt.contains('ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'), isTrue);
  });

  test('native exposes an OEM autostart-settings opener with fallback', () {
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(kt.contains('"openAutoStartSettings"'), isTrue);
    // Known OEM autostart components are tried in order …
    expect(kt.contains('com.miui.securitycenter'), isTrue);
    expect(kt.contains('com.coloros.safecenter'), isTrue);
    expect(kt.contains('com.vivo.permissionmanager'), isTrue);
    // … with the app-details page as the always-resolvable fallback.
    expect(kt.contains('ACTION_APPLICATION_DETAILS_SETTINGS'), isTrue);
    final dart = File('lib/core/agent_service.dart').readAsStringSync();
    expect(dart.contains('openAutoStartSettings'), isTrue);
  });

  test('self-launch verifies the foreground landing, never silent success',
      () {
    // Android 10+ can swallow a background startActivity without throwing:
    // MainActivity must poll for the actual foreground state, retry once,
    // and report LAUNCH_BLOCKED instead of success(true) when Ovid never
    // lands — otherwise Control-mode return silently strands the user.
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(kt.contains('LAUNCH_BLOCKED'), isTrue);
    expect(kt.contains('IMPORTANCE_FOREGROUND'), isTrue);
  });

  test('foreground service refreshes the wake lock before expiry', () {
    // The 6h PARTIAL_WAKE_LOCK ceiling must be refreshed on update ticks —
    // otherwise 24/7 runs silently lose the lock and Doze kills them.
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/AgentForegroundService.kt',
    ).readAsStringSync();
    expect(kt.contains('wakeLockAcquiredAt'), isTrue);
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

  // In-app/notification Exit is covered behaviorally by
  // schedule_background_test.dart and session_stop_isolation_test.dart.
}
