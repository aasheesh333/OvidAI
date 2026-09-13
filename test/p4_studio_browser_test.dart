import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P4 (2026-09-13) Studio + browser pins.
void main() {
  test('GitHub device login opens the external browser', () {
    final src = File('lib/ui/github_login_sheet.dart').readAsStringSync();
    expect(src.contains('LaunchMode.externalApplication'), isTrue);
    expect(src.contains('BrowserScreen'), isFalse);
  });

  test('Studio shows a login-status dot, not "Sandbox ready" text', () {
    final src = File('lib/ui/studio_screen.dart').readAsStringSync();
    expect(src.contains('Sandbox ready'), isFalse);
    expect(src.contains('isLoggedIn'), isTrue);
    expect(src.contains('Aether.dangerC'), isTrue);
  });

  test('a new session starts with a fresh blank tab', () {
    final src = File('lib/core/agent_service.dart').readAsStringSync();
    final idx = src.indexOf('Future<void> _restoreSessionTabsIfNeeded');
    final body = src.substring(idx, idx + 1400);
    expect(body.contains("about:blank"), isTrue);
  });
}
