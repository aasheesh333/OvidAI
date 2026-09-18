import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screenshot capture across Android versions.
///
/// - API 30+: AccessibilityService.takeScreenshot (existing path).
/// - API 23–29: MediaProjection consent flow in MainActivity (no more
///   "Screenshots require Android 11 or newer" dead-end).
/// - TakeScreenshotCallback.onFailure numeric codes map to readable reasons.
void main() {
  String mainActivity() => File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
  ).readAsStringSync();

  String accessibilityService() => File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
  ).readAsStringSync();

  test('pre-R screenshots go through the MediaProjection consent flow', () {
    final kt = mainActivity();
    expect(kt.contains('createScreenCaptureIntent'), isTrue);
    expect(kt.contains('MediaProjectionManager'), isTrue);
    // Denied consent and missing frames answer honestly, never hang.
    expect(kt.contains('SCREENSHOT_DENIED'), isTrue);
  });

  test('screenshot failures report readable reasons, not bare codes', () {
    final kt = accessibilityService();
    expect(kt.contains('ERROR_TAKE_SCREENSHOT_INVALID_DISPLAY'), isTrue);
    expect(kt.contains('invalid display'), isTrue);
  });
}
