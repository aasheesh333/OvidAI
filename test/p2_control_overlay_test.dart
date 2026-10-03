import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P2 (2026-09-13) control-mode + overlay pins. Source pins follow the repo's
/// existing pattern for UI/native-shape invariants.
void main() {
  late String chat;
  late String agent;
  late String state;

  setUpAll(() {
    chat = File('lib/ui/chat_screen.dart').readAsStringSync();
    agent = File('lib/core/agent_service.dart').readAsStringSync();
    state = File('lib/core/state.dart').readAsStringSync();
  });

  test('control disclosure is accepted once and persisted', () {
    expect(state.contains('controlDisclosureAccepted'), isTrue);
    expect(state.contains('ovid_control_disclosure_accepted'), isTrue);
    // The enable path consults the persisted flag before showing the dialog.
    final idx = chat.indexOf('Future<void> _enableControlMode');
    // Window covers the disclosure check, the one-time battery-exemption
    // prompt, the notifications-for-background-survival nudge, and the
    // accessibility deep-link below it.
    final body = chat.substring(idx, idx + 4200);
    expect(body.contains('controlDisclosureAccepted'), isTrue);
    expect(body.contains('controlBatteryPromptShown'), isTrue);
    // And only deep-links to Settings when the service is not enabled.
    expect(body.contains('isEnabled()'), isTrue);
  });

  test('overlay visibility is gated on app foreground state', () {
    expect(agent.contains('_appForegrounded'), isTrue);
    expect(agent.contains('setAppForegrounded'), isTrue);
    final idx = agent.indexOf('Future<void> showDeviceOverlay');
    final body = agent.substring(idx, idx + 320);
    expect(body.contains('_appForegrounded'), isTrue);
    // Shell drives it from lifecycle.
    final shell = File('lib/ui/shell.dart').readAsStringSync();
    expect(shell.contains('setAppForegrounded'), isTrue);
  });

  test('control mode gets a positive briefing in the system prompt', () {
    expect(agent.contains('CONTROL MODE:'), isTrue);
    expect(agent.contains('device_tap'), isTrue);
  });

  test('the overlay barely occludes the app it is steering', () {
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
    ).readAsStringSync();
    // SUPERSEDED 2026-09-25. This used to pin a 70%-opaque dark pill
    // (0xB31A1A1A) and assert the more opaque variant was absent. The redesign
    // replaced the always-expanded pill with a 48dp circle that expands only on
    // tap, so occlusion is now bounded by SIZE rather than by alpha — a small
    // solid white circle hides far less of the screen than a permanently open
    // translucent bar did. Pinning the old colour would have frozen the very
    // thing the owner asked to change.
    expect(kt.contains('0xB31A1A1A'), isFalse);
    expect(kt.contains('overlayCircleView'), isTrue);
    expect(kt.contains('(48 * density)'), isTrue, reason: 'collapsed footprint');
    // And the expanded surface is the simple white the owner asked for.
    expect(kt.contains('private fun overlayBoxView'), isTrue);
  });

  test('AI questions surface in the overlay and are answered there', () {
    expect(agent.contains("deviceOverlaySetPromptMethod = 'deviceOverlaySetPrompt'"), isTrue);
    expect(agent.contains('_pushQuestionToOverlayIfNeeded'), isTrue);
    // Overlay text answers a pending question.
    final idx = agent.indexOf('Future<void> handleDeviceOverlayText');
    final body = agent.substring(idx, idx + 1400);
    expect(body.contains('pendingApproval'), isTrue);
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
    ).readAsStringSync();
    expect(kt.contains('setOverlayPrompt'), isTrue);
  });

  test('deviceServiceEnabled checks system-level enablement via isAccessibilityServiceEnabled', () {
    final main = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    expect(main.contains('isAccessibilityServiceEnabled(this)'), isTrue);

    final service = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
    ).readAsStringSync();
    expect(service.contains('fun isAccessibilityServiceConfigured'), isTrue);
    expect(service.contains('fun isAccessibilityServiceEnabled'), isTrue);
    expect(service.contains('ENABLED_ACCESSIBILITY_SERVICES'), isTrue);
  });
}
