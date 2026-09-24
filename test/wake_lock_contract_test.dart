import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BATTERY / PLAY POLICY (2026-09-24): the foreground service used to acquire a
/// renewable **6-hour PARTIAL_WAKE_LOCK** on ANY `startForegroundService` call —
/// including the idle "Ready & Listening" update and the BootReceiver start.
/// With keep-alive defaulting ON, every device that ever installed Ovid held the
/// CPU awake overnight with no agent work in flight, and a permanently-running
/// `specialUse` FGS with no task is a Play policy exposure.
///
/// The lock is now tied to real work: Dart sends `wake` on every start/update,
/// and the service acquires only when it is true. These are source-contract
/// pins (the repo's established pattern for native behaviour, which cannot run
/// in a JVM/Flutter unit test) — each one names the exact line that would
/// regress the battery behaviour.
void main() {
  final service = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/AgentForegroundService.kt',
  ).readAsStringSync();
  final activity = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
  ).readAsStringSync();
  final dart = File(
    'lib/core/agent_notification_service.dart',
  ).readAsStringSync();

  group('the wake lock follows real agent work', () {
    test('the service exposes a wake extra and tracks intent', () {
      expect(service, contains('const val EXTRA_WAKE = "wake"'));
      expect(service, contains('private var wantWakeLock = false'));
      // A null intent (START_STICKY restart) must not silently drop the lock
      // mid-run, so the previous state is the default.
      expect(
        service,
        contains('getBooleanExtra(EXTRA_WAKE, wantWakeLock)'),
      );
    });

    test('acquisition is conditional, never unconditional', () {
      expect(
        service,
        contains('if (wantWakeLock) acquireWakeLock() else releaseWakeLock()'),
        reason: 'the normal start path must branch on wantWakeLock',
      );
      // The old unconditional call must be gone from onStartCommand.
      final body = service.substring(service.indexOf('override fun onStartCommand'));
      expect(
        RegExp(r'\n\s{8}acquireWakeLock\(\)').hasMatch(body),
        isFalse,
        reason: 'no bare acquireWakeLock() may remain in onStartCommand',
      );
    });

    test('idle presence and Stop release the lock', () {
      // Recents-swipe survival re-asserts the notification but only re-acquires
      // the lock when a run is in flight.
      expect(
        service,
        contains('if (wantWakeLock) acquireWakeLock()\n'
            '            startForeground(NOTIFICATION_ID'),
      );
      // The notification's Stop action ends the run, so it ends the lock.
      final stop = service.substring(service.indexOf('if (action == ACTION_STOP)'));
      expect(stop.indexOf('wantWakeLock = false'), greaterThan(-1));
      expect(stop.indexOf('releaseWakeLock()'), greaterThan(-1));
    });

    test('MainActivity forwards the Dart flag on both routes', () {
      // agentServiceStart AND agentServiceUpdate both carry it — an in-run
      // update must not drop the lock, and an idle update must not take it.
      expect(
        'call.argument<String>("wake") == "true"'.allMatches(activity).length,
        2,
        reason: 'both start and update must forward EXTRA_WAKE',
      );
      expect(activity, contains('AgentForegroundService.EXTRA_WAKE'));
    });

    test('Dart asks for the lock only while working', () {
      // agentWorking → wake true.
      expect(dart, contains("'wake': 'true',"));
      // Both idle paths (Control-mode presence and keep-alive "Ready &
      // Listening") → wake false.
      expect(
        "'wake': 'false',".allMatches(dart).length,
        2,
        reason: 'control-mode idle and keep-alive idle must both release',
      );
      // Ordering: the working call is the one that says true.
      final working = dart.indexOf("'wake': 'true',");
      final idle = dart.indexOf("'wake': 'false',");
      expect(working, greaterThan(-1));
      expect(idle, greaterThan(working));
    });

    test('the boot start carries no wake extra, so boot never takes the lock',
        () {
      final boot = File(
        'android/app/src/main/kotlin/com/dhanuk/ovidai/BootReceiver.kt',
      ).readAsStringSync();
      expect(boot, isNot(contains('EXTRA_WAKE')));
      expect(boot, contains('startForegroundService'));
    });
  });
}
