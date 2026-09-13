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
    final body = chat.substring(idx, idx + 1600);
    expect(body.contains('controlDisclosureAccepted'), isTrue);
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

  test('overlay is see-through (alpha lowered)', () {
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
    ).readAsStringSync();
    expect(kt.contains('0xB31A1A1A'), isTrue);
    expect(kt.contains('0xE61A1A1A'), isFalse);
  });

  test('AI questions surface in the overlay and are answered there', () {
    expect(agent.contains("deviceOverlaySetPromptMethod = 'deviceOverlaySetPrompt'"), isTrue);
    expect(agent.contains('_pushQuestionToOverlayIfNeeded'), isTrue);
    // Overlay text answers a pending question.
    final idx = agent.indexOf('Future<void> handleDeviceOverlayText');
    final body = agent.substring(idx, idx + 1400);
    expect(body.contains('pendingApproval'), isTrue);
    expect(body.contains('approve(true)'), isTrue);
    final kt = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
    ).readAsStringSync();
    expect(kt.contains('setOverlayPrompt'), isTrue);
  });
}
