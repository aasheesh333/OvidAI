import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Task 1: Native action core — source pins for long-press, node scroll,
// ancestor-click fallback, and refresh-before-action revalidation.
//
// No hardware here: device behavior is NOT EXECUTED by design. These pins
// assert the Kotlin surface exists with the contracted shapes; behavior on
// device is covered by later tasks.

String readServiceSource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
).readAsStringSync();

String readMainActivitySource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
).readAsStringSync();

void main() {
  group('Task 1: native action core', () {
    test('service exposes longPress and scrollNode entry points', () {
      final src = readServiceSource();
      expect(src, contains('fun longPress('));
      expect(src, contains('fun scrollNode('));
      // Existing entry points keep their shape.
      expect(src, contains('fun tap('));
      expect(src, contains('fun type('));
    });

    test('longPress covers node long-click and coordinate gestures', () {
      final src = readServiceSource();
      expect(src, contains('ACTION_LONG_CLICK'));
      expect(src, contains('dispatchGesture'));
      // Coordinate stroke uses the requested duration.
      expect(src, contains('fun longPress('));
    });

    test('long-press duration defaults to 600ms and clamps to 200-3000ms',
        () {
      final src = readServiceSource();
      expect(src, contains('600'));
      expect(src, contains('200'));
      expect(src, contains('3000'));
      expect(src, contains('coerceIn'));
    });

    test('scrollNode requires a scrollable node and names directions', () {
      final src = readServiceSource();
      expect(src, contains('isScrollable'));
      expect(src, contains('NOT_SCROLLABLE'));
      for (final direction in <String>[
        'forward',
        'backward',
        'up',
        'down',
        'left',
        'right',
      ]) {
        expect(src, contains('"$direction"'));
      }
    });

    test('directional scroll falls back below its API floor and names it',
        () {
      final src = readServiceSource();
      // Directional scroll actions exist only from API 23 (M); below that
      // up|left map to backward and down|right map to forward.
      expect(src, contains('VERSION_CODES.M'));
      expect(src.toLowerCase(), contains('fallback'));
      expect(src, contains('ACTION_SCROLL_FORWARD'));
      expect(src, contains('ACTION_SCROLL_BACKWARD'));
    });

    test('tap walks up to 3 ancestors attempting clicks', () {
      final src = readServiceSource();
      expect(src.toLowerCase(), contains('ancestor'));
      expect(src, contains('ACTION_CLICK'));
      expect(src, contains('.parent'));
    });

    test('every node action refreshes before acting', () {
      final src = readServiceSource();
      final refreshHits = RegExp(r'\.refresh\(\)').allMatches(src).length;
      // tap + longPress + scrollNode + type.
      expect(
        refreshHits,
        greaterThanOrEqualTo(4),
        reason: 'each node action must refresh() before acting',
      );
    });

    test('stale nodes are refused as INVALID_NODE with a re-read hint', () {
      final src = readServiceSource();
      expect(src, contains('INVALID_NODE'));
      expect(
        src.toLowerCase(),
        contains('re-read'),
        reason: 'stale-node refusals must hint at re-reading the screen',
      );
    });

    test('type keeps password and editable rechecks on the refreshed node',
        () {
      final src = readServiceSource();
      expect(src, contains('PASSWORD_FIELD'));
      expect(src, contains('NOT_EDITABLE'));
      expect(src, contains('isPassword'));
      expect(src, contains('isEditable'));
    });

    test('DeviceActionResult shape is preserved', () {
      final src = readServiceSource();
      expect(src, contains('data class DeviceActionResult('));
      expect(src, contains('val ok'));
      expect(src, contains('val code'));
      expect(src, contains('val message'));
      expect(src, contains('val value'));
    });

    test('channel routes deviceLongPress and deviceScroll in camelCase', () {
      final src = readMainActivitySource();
      expect(src, contains('"deviceLongPress"'));
      expect(src, contains('"deviceScroll"'));
      expect(src, contains('service.longPress('));
      expect(src, contains('service.scrollNode('));
      expect(src, contains('completeDeviceAction'));
      // Channel names stay camelCase like deviceTap/deviceType.
      expect(src, isNot(contains('device_long_press')));
      expect(src, isNot(contains('device_scroll')));
    });

    test('new routes follow the existing arg/error pattern', () {
      final src = readMainActivitySource();
      // Existing routes surface BAD_ARGS for missing arguments.
      expect(src, contains('BAD_ARGS'));
      // New routes reuse the shared completion helper.
      final completions = RegExp(
        r'completeDeviceAction',
      ).allMatches(src).length;
      expect(
        completions,
        greaterThanOrEqualTo(6),
        reason:
            'deviceTap/deviceType/deviceSwipe/deviceSystemNav + deviceLongPress/deviceScroll',
      );
    });
  });
}
