import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static pins for the thin-client notification/alarm surface.
///
/// P8 Task 12 removed the foreground-service keep-alive: runs execute detached
/// in the cloud, so the manifest must not declare an FGS, a wake lock or boot
/// restart. What remains is local schedule alarms and the notification display
/// path fed by FCM. Behaviour is executed under Robolectric (OvidNotifications,
/// NativeHostRouting, ExactAlarmFallback); these pins keep the manifest and
/// the source contracts a host test cannot see from drifting.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final play = File('android/app/src/play/AndroidManifest.xml').readAsStringSync();
  String kt(String name) =>
      File('android/app/src/main/kotlin/com/dhanuk/ovidai/$name.kt').readAsStringSync();

  String element(String tag, String name) {
    final open = RegExp('<$tag\\s[^>]*android:name="\\.?$name"[^>]*>')
        .firstMatch(manifest);
    expect(open, isNotNull, reason: '$tag $name missing');
    if (open!.group(0)!.endsWith('/>')) return open.group(0)!;
    final end = manifest.indexOf('</$tag>', open.end);
    return manifest.substring(open.start, end + '</$tag>'.length);
  }

  test('notification and exact-alarm permissions survive; keep-alive ones do not',
      () {
    for (final p in [
      'POST_NOTIFICATIONS',
      'SCHEDULE_EXACT_ALARM',
      'USE_EXACT_ALARM',
      'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
    ]) {
      expect(
        manifest,
        contains('<uses-permission android:name="android.permission.$p"'),
        reason: p,
      );
    }
    // P8 Task 12: no foreground service, wake lock or boot-restart apparatus.
    for (final p in [
      'FOREGROUND_SERVICE',
      'FOREGROUND_SERVICE_DATA_SYNC',
      'FOREGROUND_SERVICE_SPECIAL_USE',
      'WAKE_LOCK',
      'RECEIVE_BOOT_COMPLETED',
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

  test('alarm receiver re-registers on time and zone changes', () {
    final alarm = element('receiver', 'ScheduleAlarmReceiver');
    expect(alarm, contains('android.intent.action.TIME_SET'));
    expect(alarm, contains('android.intent.action.TIMEZONE_CHANGED'));
    expect(alarm, contains('android:exported="false"'));
  });

  test('periodic fallback job is declared', () {
    final job = element('service', 'ScheduleFallbackJob');
    expect(job, contains('android.permission.BIND_JOB_SERVICE'));
    expect(job, contains('android:exported="false"'));
  });

  test('Play overlay drops USE_EXACT_ALARM but keeps the user-granted one', () {
    expect(
      play,
      contains(
        '<uses-permission android:name="android.permission.USE_EXACT_ALARM" tools:node="remove" />',
      ),
    );
    expect(play, isNot(contains('SCHEDULE_EXACT_ALARM" tools:node="remove"')));
    expect(play, isNot(contains('foregroundServiceType')));
  });

  test('exact alarms with permission check and inexact + job fallback', () {
    final alarms = kt('ScheduleAlarmReceiver');
    expect(alarms, contains('setExactAndAllowWhileIdle'));
    expect(alarms, contains('setAndAllowWhileIdle'));
    expect(alarms, contains('ScheduleFallbackJob.ensure(context)'));
    expect(alarms, contains('canScheduleExactAlarms()'));
  });

  test('notification taps carry an app route into Dart', () {
    final activity = kt('MainActivity');
    expect(activity, contains('routeNotificationIntent'));
    expect(activity, contains('"onOpenRoute"'));
    // P8 Task 12: tap routing is fed by FCM (PushService) instead of the
    // deleted local run-state notification service.
    final dart = File('lib/core/cloud/push_service.dart').readAsStringSync();
    expect(dart, contains('onOpenRoute'));
    expect(File('lib/main.dart').readAsStringSync(),
        contains('PushService.I.onOpenRoute = _openRouteFromNotification'));
  });

  test('notification resources: original chime and a monochrome status icon', () {
    expect(File('android/app/src/main/res/raw/ovid_chime.wav').existsSync(), isTrue);
    expect(File('android/app/src/main/res/drawable/ic_stat_ovid.xml').existsSync(), isTrue);
  });
}
