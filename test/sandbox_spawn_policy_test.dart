import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('spawn refuses a denied command without spawning', () async {
    await expectLater(
      SandboxService.I.spawn(['rm', '-rf', '/']),
      throwsA(
        predicate(
          (e) => '$e'.contains('DENIED by sandbox policy'),
          'a sandbox policy denial',
        ),
      ),
    );
  });

  test('spawn enforces cwd containment', () async {
    final sandbox = SandboxService.I;
    final originalPolicy = sandbox.policy;
    addTearDown(() => sandbox.policy = originalPolicy);
    sandbox.policy = (
      allowedRoots: ['/data/allowed'],
      deniedCommands: SandboxService.defaultDeniedCommands,
    );

    await expectLater(
      sandbox.spawn(['true'], hostWorkDir: Directory('/var/log')),
      throwsA(
        predicate(
          (e) => '$e'.contains('DENIED by sandbox policy: cwd escapes'),
          'a cwd containment denial',
        ),
      ),
    );
  });

  test('spawn permits a normal command when the sandbox is installed',
      () async {
    if (!SandboxService.I.isInstalled) return;
    final proc = await SandboxService.I.spawn(['true']);
    expect(await proc.exitCode, 0);
  });
}
