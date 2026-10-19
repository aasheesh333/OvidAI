import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';

/// Release builds must pass the account feature define explicitly.
///
/// The static half runs in the normal suite. CI's "Guard release feature
/// flags" step re-runs this file with the release defines
/// (`OVID_RELEASE_FLAGS_CHECK=true` plus `OVID_ACCOUNT_ENABLED=<value>`), so a
/// release built without the define, or with a value the code does not see,
/// fails before compilation.
void main() {
  const releaseCheck = bool.fromEnvironment('OVID_RELEASE_FLAGS_CHECK');

  test('every release build command passes OVID_ACCOUNT_ENABLED', () {
    final workflow = File('.github/workflows/build.yml').readAsLinesSync();
    final releaseCommands = workflow
        .map((line) => line.trim())
        .where(
          (line) =>
              line.startsWith('flutter build') && line.contains('--release'),
        )
        .toList();
    expect(releaseCommands, hasLength(2), reason: 'APK and AAB');
    for (final command in releaseCommands) {
      expect(
        command,
        contains('--dart-define=OVID_ACCOUNT_ENABLED="\$OVID_ACCOUNT_ENABLED"'),
      );
    }
    expect(
      workflow.any(
        (line) => line.contains(
          "OVID_ACCOUNT_ENABLED: \${{ vars.OVID_ACCOUNT_ENABLED || 'false' }}",
        ),
      ),
      isTrue,
    );
  });

  test('no build enables App Check (OVID_APPCHECK) while off-Play', () {
    // Owner decision 2026-10-19: the app is distributed outside Google Play,
    // so Play Integrity cannot attest it. Enabling OVID_APPCHECK=true here
    // must be a deliberate change made together with the gateway's
    // OVID_APPCHECK_MODE=required and the mint's APPCHECK_ENABLED=true.
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    expect(workflow.contains('OVID_APPCHECK=true'), isFalse);
  });

  test(
    'release defines reach AccountService',
    () {
      expect(
        const bool.hasEnvironment('OVID_ACCOUNT_ENABLED'),
        isTrue,
        reason: 'release builds must set OVID_ACCOUNT_ENABLED explicitly',
      );
      const expected = String.fromEnvironment('OVID_ACCOUNT_ENABLED');
      expect(expected, anyOf('true', 'false'));
      final service = AccountService(
        idToken: (_) async => null,
        appCheck: () async => null,
      );
      expect(service.enabled, expected == 'true');
    },
    skip: releaseCheck ? false : 'runs only with the release defines',
  );
}
