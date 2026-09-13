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

  test('the workspace folder picker lives only in Studio', () {
    final studio = File('lib/ui/studio_screen.dart').readAsStringSync();
    expect(studio.contains('getDirectoryPath'), isTrue);
    // No other screen opens a directory picker.
    for (final f in [
      'lib/ui/chat_screen.dart',
      'lib/ui/sidebar.dart',
      'lib/ui/shell.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(
        src.contains('getDirectoryPath'),
        isFalse,
        reason: '$f must not open a folder picker',
      );
    }
  });

  test('in-app browser uses a non-wv mobile UA for OAuth', () {
    final src = File('lib/core/agent_service.dart').readAsStringSync();
    expect(src.contains('mobileUserAgent'), isTrue);
    // The mobile UA must not carry the embedded-WebView `wv` token.
    final idx = src.indexOf('static const mobileUserAgent');
    final line = src.substring(idx, idx + 220);
    expect(line.contains('; wv'), isFalse);
    expect(src.contains('setUserAgent(BrowserTab.mobileUserAgent)'), isTrue);
  });
}
