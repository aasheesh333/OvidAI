import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static pins for background operation. Behaviour is executed under
/// Robolectric (BackgroundRuntimeTest, ExactAlarmFallbackTest,
/// OvidNotificationsTest); these keep the manifest and the source contracts
/// that a host test cannot see from drifting.
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

  test('permissions for notifications, exact alarms, boot and the service', () {
    for (final p in [
      'POST_NOTIFICATIONS',
      'SCHEDULE_EXACT_ALARM',
      'USE_EXACT_ALARM',
      'RECEIVE_BOOT_COMPLETED',
      'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      'FOREGROUND_SERVICE',
      'FOREGROUND_SERVICE_DATA_SYNC',
      'FOREGROUND_SERVICE_SPECIAL_USE',
      'WAKE_LOCK',
    ]) {
      expect(
        manifest,
        contains('<uses-permission android:name="android.permission.$p"'),
        reason: p,
      );
    }
  });

  test('boot receiver: direct boot, full boot and app update', () {
    final boot = element('receiver', 'BootReceiver');
    expect(boot, contains('android:directBootAware="true"'));
    for (final a in [
      'android.intent.action.LOCKED_BOOT_COMPLETED',
      'android.intent.action.BOOT_COMPLETED',
      'android.intent.action.MY_PACKAGE_REPLACED',
    ]) {
      expect(boot, contains(a), reason: a);
    }
  });

  test('alarm receiver re-registers on time and zone changes', () {
    final alarm = element('receiver', 'ScheduleAlarmReceiver');
    expect(alarm, contains('android.intent.action.TIME_SET'));
    expect(alarm, contains('android.intent.action.TIMEZONE_CHANGED'));
    expect(alarm, contains('android:exported="false"'));
  });

  test('foreground service type and periodic fallback job are declared', () {
    final service = element('service', 'AgentForegroundService');
    expect(service, contains('android:foregroundServiceType="dataSync|specialUse"'));
    expect(service, contains('android:stopWithTask="false"'));
    expect(service, contains('PROPERTY_SPECIAL_USE_FGS_SUBTYPE'));
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
    // The overlay keeps its existing dataSync-only service type.
    expect(play, contains('android:foregroundServiceType="dataSync"'));
  });

  test('service is sticky and restarts the Dart runtime', () {
    final service = kt('AgentForegroundService');
    expect(service, contains('return START_STICKY'));
    expect(service, contains('OvidEngineHost.ensure(this)'));
    final host = kt('OvidEngineHost');
    expect(host, contains('executeDartEntrypoint'));
    expect(host, contains('FlutterEngineCache.getInstance().put(ENGINE_ID, engine)'));
    expect(kt('MainActivity'), contains('get(OvidEngineHost.ENGINE_ID)'));
  });

  test('exact alarms with permission check and inexact + job fallback', () {
    final alarms = kt('ScheduleAlarmReceiver');
    expect(alarms, contains('setExactAndAllowWhileIdle'));
    expect(alarms, contains('setAndAllowWhileIdle'));
    expect(alarms, contains('ScheduleFallbackJob.ensure(context)'));
    expect(kt('BackgroundChannel'), contains('canScheduleExactAlarms()'));
    expect(kt('BackgroundChannel'), contains('ACTION_REQUEST_SCHEDULE_EXACT_ALARM'));
  });

  test('notification taps carry an app route into Dart', () {
    final activity = kt('MainActivity');
    expect(activity, contains('routeNotificationIntent'));
    expect(activity, contains('"onOpenRoute"'));
    // P8 Task 12: tap routing is re-fed from FCM (PushService) instead of
    // the local run-state notification service.
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
