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
    expect(src.contains('Aether.danger'), isTrue);
  });

  test('the on-device workspace folder picker is gone (remote Studio)', () {
    // P8 Task 15 removed the local git/working-folder UI: the server owns
    // the workspace. No Studio surface may open a device directory picker.
    for (final f in [
      'lib/ui/studio_screen.dart',
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

}
