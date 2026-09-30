import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Control-mode gesture completion (audit 2026-09-25).
///
/// Every gesture used to call `dispatchGesture(gesture, null, null)` with a
/// NULL `GestureResultCallback`. Two consequences, both real bugs:
///
/// (a) `DeviceActionResult(true)` was returned as soon as the stroke was
///     ACCEPTED for dispatch, not when it FINISHED — so the agent could
///     `device_read` before the tap landed and read a stale screen.
/// (b) A second gesture dispatched while the first was still animating made
///     `dispatchGesture` return false, producing "Android did not accept the
///     tap gesture" for a perfectly valid tap. Nothing serialized them.
///
/// The fix must: wait on a real callback (onCompleted/onCancelled) behind a
/// bounded timeout, serialize gestures, and — critically — never block the
/// platform (main) thread, because both `dispatchGesture` and the
/// `GestureResultCallback` are delivered there. These are source-contract pins
/// (the repo has no JVM harness): they read the .kt files and assert the shape.
void main() {
  final serviceSrc = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
  ).readAsStringSync();
  final activitySrc = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
  ).readAsStringSync();

  // The gesture primitives live in Api24Actions; the completion helper is the
  // single place a stroke is dispatched and awaited. The helper's rationale
  // doc-comment sits just above `fun runGesture(`, so the region starts before
  // it to capture the "why" alongside the "what".
  final primitives = serviceSrc.indexOf('private object Api24Actions');
  final helper = serviceSrc.indexOf('fun runGesture(');
  final regionStart = (helper - 1400).clamp(0, helper);
  final helperRegion = serviceSrc.substring(regionStart, helper + 5000);

  group('gestures report completion, not mere acceptance', () {
    test('no dispatchGesture keeps a null GestureResultCallback', () {
      // The exact bug: `dispatchGesture(gesture, null, null)` /
      // `dispatchGesture(builder.build(), null, null)`.
      final nullCallbacks = RegExp(
        r'dispatchGesture\([^\n]*null,\s*null\)',
      ).allMatches(serviceSrc).length;
      expect(
        nullCallbacks,
        0,
        reason: 'every stroke must pass a real GestureResultCallback',
      );
    });

    test('a real callback observes onCompleted and onCancelled', () {
      expect(helperRegion, contains('GestureResultCallback'));
      expect(helperRegion, contains('onCompleted'));
      expect(helperRegion, contains('onCancelled'));
    });

    test('success is gated on completion behind a bounded latch wait', () {
      expect(helper, greaterThan(-1), reason: 'a single dispatch+await helper');
      expect(helperRegion, contains('CountDownLatch'), reason: 'wait for the stroke');
      expect(helperRegion, contains('.await('), reason: 'bounded, never open-ended');
      expect(helperRegion, contains('GESTURE_TIMEOUT_MS'));
      expect(helperRegion, contains('TimeUnit.MILLISECONDS'));
      // Completion — not the dispatch-accepted boolean — is what maps to ok.
      expect(
        helperRegion,
        contains('GestureOutcome.COMPLETED -> DeviceActionResult(true)'),
      );
    });

    test('primitives now yield an honest DeviceActionResult', () {
      // They used to return a Boolean "accepted" flag that the caller blindly
      // mapped to success.
      expect(primitives, greaterThan(-1));
      for (final fn in ['fun tap(', 'fun swipe(', 'fun multiTap(']) {
        final i = serviceSrc.indexOf(fn, primitives);
        expect(i, greaterThan(-1), reason: fn);
        final sig = serviceSrc.substring(i, i + 260);
        expect(sig, contains('DeviceActionResult'), reason: '$fn return type');
      }
    });
  });

  group('a lost callback or a busy system can never hang or lie', () {
    test('timeout and cancellation report failure, not success', () {
      expect(helperRegion, contains('GESTURE_TIMEOUT'), reason: 'honest timeout code');
      expect(helperRegion, contains('GestureOutcome.CANCELLED ->'));
      expect(helperRegion, contains('GestureOutcome.TIMEOUT ->'));
      // The not-accepted branch keeps the caller's honest message.
      expect(helperRegion, contains('notAcceptedMessage'));
    });

    test('the wait is bounded to 3000ms', () {
      expect(serviceSrc, contains('GESTURE_TIMEOUT_MS = 3000'));
    });
  });

  group('overlapping gestures are serialized', () {
    test('a bounded lock makes a second gesture wait for the first', () {
      expect(serviceSrc, contains('ReentrantLock'), reason: 'serialize strokes');
      expect(helperRegion, contains('tryLock'), reason: 'bounded, not indefinite');
      expect(helperRegion, contains('GESTURE_BUSY'), reason: 'honest refusal');
    });
  });

  group('the platform (main) thread is never blocked on the wait', () {
    test('the service dispatches on the main handler and documents why', () {
      expect(serviceSrc, contains('Looper.getMainLooper()'));
      expect(helperRegion, contains('mainHandler.post'), reason: 'dispatch on main');
      // The rationale must be in the source: blocking main would deadlock the
      // very callback that releases the latch.
      expect(helperRegion.toLowerCase(), contains('main thread'));
      expect(helperRegion.toLowerCase(), contains('deadlock'));
      expect(helperRegion, contains('audit 2026-09-25'));
    });

    test('MainActivity runs gestures on a background executor', () {
      expect(activitySrc, contains('gestureExecutor'));
      expect(activitySrc, contains('newSingleThreadExecutor'));
      // The channel handler is on the platform thread; the blocking wait must
      // be handed to a background thread.
      final exec = RegExp(
        r'gestureExecutor\.execute',
      ).allMatches(activitySrc).length;
      expect(exec, greaterThanOrEqualTo(1));
    });

    test('every gesture branch is routed off the platform thread', () {
      // tap, swipe, longPress, multiTap, drag, pinch, twoFingerSwipe.
      final routed = RegExp(
        r'runDeviceGesture\(result\)',
      ).allMatches(activitySrc).length;
      expect(routed, greaterThanOrEqualTo(7), reason: 'one per gesture');
    });

    test('the result is still completed on the UI thread', () {
      final i = activitySrc.indexOf('private fun runDeviceGesture(');
      expect(i, greaterThan(-1));
      final body = activitySrc.substring(i, i + 400);
      expect(body, contains('gestureExecutor.execute'));
      expect(body, contains('runOnUiThread'));
      expect(body, contains('completeDeviceAction'));
    });
  });
}
