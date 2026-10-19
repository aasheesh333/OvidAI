import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P4 (2026-09-13) Studio + browser pins.
void main() {
  test('GitHub device login opens the external browser', () {
    final src = File('lib/ui/github_login_sheet.dart').readAsStringSync();
    expect(src.contains('LaunchMode.externalApplication'), isTrue);
    expect(src.contains('BrowserScreen'), isFalse);
  });

  test('Studio has no GitHub sign-in UI (ST-004) and no sandbox copy', () {
    // The device-flow token never reached the cloud: the workspace, git and
    // the agent are server-side. The auto-prompt, account chip, auth badge
    // and the misleading sign-out dialog are gone until a server-side GitHub
    // connection exists.
    final src = File('lib/ui/studio_screen.dart').readAsStringSync();
    expect(src.contains('Sandbox ready'), isFalse);
    expect(src.contains('GitHubService'), isFalse);
    expect(src.contains('showGithubLoginSheet'), isFalse);
    expect(src.contains('repo connection will be cleared'), isFalse);
  });

  test('no Studio surface mentions a terminal (ST-011, EM-008)', () {
    for (final f in [
      'lib/ui/studio_screen.dart',
      'lib/ui/studio_editor.dart',
      'lib/ui/studio_file_tree.dart',
      'lib/ui/studio_layout.dart',
      'lib/core/studio_drafts.dart',
    ]) {
      final src = File(f).readAsStringSync().toLowerCase();
      expect(src.contains('copy terminal command'), isFalse, reason: f);
      expect(src.contains('terminal below'), isFalse, reason: f);
      expect(src.contains('open in terminal'), isFalse, reason: f);
    }
    final arb = File('lib/l10n/app_en.arb').readAsStringSync();
    expect(arb.contains('code & terminal'), isFalse);
  });

  test('the on-device workspace folder picker is gone (remote Studio)', () {
    // P8 Task 15 removed the local git/working-folder UI: the server owns
    // the workspace. No Studio surface may open a device directory picker.
    for (final f in [
      'lib/ui/studio_screen.dart',
      'lib/ui/sidebar.dart',
      'lib/ui/shell.dart',
      // CH-027 / ST-012: the composer "Sandbox folder" chip picked a phone
      // folder the cloud never saw.
      'lib/ui/chat_screen.dart',
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
