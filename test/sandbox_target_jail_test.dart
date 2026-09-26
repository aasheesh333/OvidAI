import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/sandbox_service.dart';

/// The sandbox jail must check TARGETS, not just the working directory
/// (2026-09-24).
///
/// `checkPolicy` used to verify only that the CWD was inside the allowed roots.
/// A command whose cwd was inside the workspace could therefore still read, write
/// or delete anything the app UID can reach:
///
///   `cat ../../shared_prefs/x.xml`   ← the app's own settings/sessions dir
///   `cat $HOME/.ssh/id_rsa`
///   `ln -s /data/data/<pkg> l && cat l/x`
///
/// The agent layer's token gate only inspects ABSOLUTE tokens, so relative
/// escapes and `$VAR` forms slipped past it as well.
///
/// The check is additive: it only ever denies MORE. A legitimate outside path
/// still works through the approval flow, because the granted path is passed into
/// the dispatch zone as an extra root.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = SandboxService.I;

  late Directory root;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('jail-root-');
    outside = Directory.systemTemp.createTempSync('jail-outside-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (outside.existsSync()) outside.deleteSync(recursive: true);
  });

  String? check(String cmd, {List<String>? zoneRoots}) {
    String? run() => svc.checkPolicy(
      ['sh', '-c', cmd],
      hostWorkDir: root,
    );
    if (zoneRoots == null) return run();
    return runZoned(run, zoneValues: {
      SandboxService.allowedRootsZoneKey: zoneRoots,
    });
  }

  group('relative escapes are refused', () {
    test('a ../ target outside the root is denied', () {
      final d = check('cat ../../shared_prefs/x.xml');
      expect(d, isNotNull);
      expect(d, contains('target escapes allowed roots'));
    });

    test('a deep ../ escape is denied', () {
      expect(
        check('rm -rf ../../../../data/data/com.dhanuk.ovidai'),
        isNotNull,
      );
    });

    test('in-workspace relative paths are NOT denied', () {
      expect(check('cat ./notes.txt'), isNull);
      expect(check('cat sub/dir/file.txt'), isNull);
      expect(check('ls -la'), isNull);
      // A `..` that stays inside the workspace is fine (and not even matched).
      expect(check('cat sub/../notes.txt'), isNull);
    });
  });

  group('absolute targets are confined', () {
    test('an absolute path inside the root is allowed', () {
      expect(check('cat ${root.path}/notes.txt'), isNull);
      expect(check('ls ${root.path}'), isNull);
    });

    test('an absolute path outside the root is denied', () {
      final d = check('cat ${outside.path}/secret.txt');
      expect(d, isNotNull);
      expect(d, contains('target escapes allowed roots'));
    });

    test('a granted outside path is permitted when passed as a root', () {
      // This is the approval flow: the user said yes, so the agent layer passes
      // the granted path into the dispatch zone. Without this the sandbox would
      // hard-deny a command the user had just approved.
      final cmd = 'cat ${outside.path}/secret.txt';
      expect(check(cmd), isNotNull, reason: 'denied before approval');
      expect(
        check(cmd, zoneRoots: [root.path, outside.path]),
        isNull,
        reason: 'an approved path must actually run',
      );
    });
  });

  group('expansion forms cannot smuggle a target', () {
    test('an unresolvable \$HOME is treated as an escape, not allowed', () {
      // No sandbox prefix is installed in this test, so $HOME cannot be
      // resolved — denying is the safe reading.
      final d = check(r'cat $HOME/.ssh/id_rsa');
      expect(d, isNotNull);
    });

    test('an unresolvable \$PREFIX is treated as an escape', () {
      expect(check(r'cat $PREFIX/etc/passwd'), isNotNull);
    });

    test('~ is treated as an escape when unresolvable', () {
      expect(check('cat ~/.bash_history'), isNotNull);
    });
  });

  group('an approval mid-dispatch reaches the jail', () {
    // Regression for the report "Allow and Always Allow both come back DENIED".
    //
    // The dispatch zone is built BEFORE the tool runs, but the approval prompt
    // happens INSIDE it. With the roots frozen at dispatch time, checkPolicy
    // denied the path the user had just approved — so the card closed and the
    // command still failed. The roots therefore have to be a mutable scope the
    // approval can append to, not a snapshot.
    test('addApprovedRoots unblocks a path denied a moment earlier', () {
      final cmd = 'cat ${outside.path}/secret.txt';
      final scope = SandboxRootScope([root.path]);
      String? first;
      String? second;
      runZoned(() {
        first = svc.checkPolicy(['sh', '-c', cmd], hostWorkDir: root);
        // The user tapped Allow: _checkCommandPaths records the tokens.
        SandboxService.addApprovedRoots([outside.path]);
        second = svc.checkPolicy(['sh', '-c', cmd], hostWorkDir: root);
      }, zoneValues: {SandboxService.allowedRootsZoneKey: scope});
      expect(first, isNotNull, reason: 'denied before approval');
      expect(second, isNull, reason: 'an approved path must actually run');
      expect(scope.roots, contains(outside.path));
    });

    test('a legacy List zone value is still honoured', () {
      expect(
        check('cat ${outside.path}/s.txt', zoneRoots: [outside.path]),
        isNull,
      );
    });

    test('outside a dispatch zone addApprovedRoots is a no-op', () {
      // No scope installed: nothing to record, and nothing must throw.
      expect(() => SandboxService.addApprovedRoots(['/whatever']), returnsNormally);
    });
  });

  group('runtime pseudo-paths are not targets', () {
    test('/dev, /proc and /sys are exempt', () {
      expect(check('cat /dev/null'), isNull);
      expect(check('echo hi > /dev/null'), isNull);
      expect(check('ls /proc/self'), isNull);
      expect(check('cat /sys/kernel/ostype'), isNull);
    });
  });
}
