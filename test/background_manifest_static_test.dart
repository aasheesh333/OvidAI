import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static pins for the thin-client notification surface.
///
/// P8 Task 12 removed the foreground-service keep-alive; P8 Task 14 removed
/// the local scheduler runtime (alarm receiver, periodic fallback job and the
/// exact-alarm permissions). Runs execute detached in the cloud, so the
/// manifest must not declare an FGS, a wake lock, boot restart or local alarm
/// apparatus. What remains is the notification display path fed by FCM.
/// Behaviour is executed under Robolectric (OvidNotifications,
/// NativeHostRouting); these pins keep the manifest and the source contracts
/// a host test cannot see from drifting.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final play = File('android/app/src/play/AndroidManifest.xml').readAsStringSync();
  String kt(String name) =>
      File('android/app/src/main/kotlin/com/dhanuk/ovidai/$name.kt')
          .readAsStringSync();

  test('notification permission survives; keep-alive and alarm ones do not', () {
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"',
      ),
    );
    for (final p in [
      'FOREGROUND_SERVICE',
      'FOREGROUND_SERVICE_DATA_SYNC',
      'FOREGROUND_SERVICE_SPECIAL_USE',
      'WAKE_LOCK',
      'RECEIVE_BOOT_COMPLETED',
      // P8 Task 14: schedules are server-executed; no local alarm runtime.
      'SCHEDULE_EXACT_ALARM',
      'USE_EXACT_ALARM',
    ]) {
      expect(
        manifest,
        isNot(contains('<uses-permission android:name="android.permission.$p"')),
        reason: p,
      );
    }
    expect(manifest, isNot(contains('foregroundServiceType')));
    expect(manifest, isNot(contains('.BootReceiver')));
    expect(manifest, isNot(contains('.AgentStopReceiver')));
  });

  test('no local schedule receiver or fallback job is declared', () {
    expect(manifest, isNot(contains('.ScheduleAlarmReceiver')));
    expect(manifest, isNot(contains('.ScheduleFallbackJob')));
    expect(
      File(
        'android/app/src/main/kotlin/com/dhanuk/ovidai/ScheduleAlarmReceiver.kt',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        'android/app/src/main/kotlin/com/dhanuk/ovidai/ScheduleFallbackJob.kt',
      ).existsSync(),
      isFalse,
    );
  });

  test('Play overlay no longer mentions exact alarms', () {
    expect(play, isNot(contains('USE_EXACT_ALARM')));
    expect(play, isNot(contains('SCHEDULE_EXACT_ALARM')));
    expect(play, isNot(contains('foregroundServiceType')));
  });

  test('notification taps carry an app route into Dart', () {
    final activity = kt('MainActivity');
    expect(activity, contains('routeNotificationIntent'));
    expect(activity, contains('"onOpenRoute"'));
    // Tap routing is fed by FCM (PushService) instead of the deleted local
    // run-state notification service.
    final dart = File('lib/core/cloud/push_service.dart').readAsStringSync();
    expect(dart, contains('onOpenRoute'));
    expect(File('lib/main.dart').readAsStringSync(),
        contains('PushService.I.onOpenRoute = _openRouteFromNotification'));
    // CT-009: Kotlin's onOpenRoute/onSelectSession have a Dart handler, and a
    // cold start parks the route for Dart to pull.
    expect(activity, contains('"takePendingRoute"'));
    expect(File('lib/main.dart').readAsStringSync(),
        contains('NativeRouteChannel.install(_openRouteFromNotification)'));
    final native = File('lib/core/native_routes.dart').readAsStringSync();
    expect(native, contains("'onOpenRoute'"));
    expect(native, contains("'onSelectSession'"));
  });

  test('the IANA zone channel backs server daily/cron triggers', () {
    expect(kt('MainActivity'), contains('"timeZoneId"'));
    expect(kt('MainActivity'), contains('TimeZone.getDefault().id'));
  });

  test('notification resources: original chime and a monochrome status icon', () {
    expect(File('android/app/src/main/res/raw/ovid_chime.wav').existsSync(), isTrue);
    expect(File('android/app/src/main/res/drawable/ic_stat_ovid.xml').existsSync(), isTrue);
  });
}
