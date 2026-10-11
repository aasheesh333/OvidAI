import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/studio_terminal.dart';

String _bash() =>
    File('/bin/bash').existsSync() ? '/bin/bash' : '/usr/bin/bash';

Future<Process> _spawnShell() =>
    Process.start(_bash(), ['--norc'], workingDirectory: '/tmp');

Future<void> _waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  tearDown(() async {
    await PtyPool.I.discardAllShells();
  });

  test('streams output and persists cd across commands', () async {
    final s = StudioShellSession(tabId: 'u-cd');
    addTearDown(s.dispose);

    s.begin('cd /tmp');
    expect(
      await s.runPersistent('cd /tmp', sid: 'sess-u-cd', spawner: _spawnShell),
      isTrue,
    );
    await _waitFor(() => !s.busy, reason: 'cd command completes');

    s.begin('pwd');
    expect(
      await s.runPersistent('pwd', sid: 'sess-u-cd', spawner: _spawnShell),
      isTrue,
    );
    await _waitFor(
      () => s.history.any((l) => l.trim() == '/tmp'),
      reason: 'pwd shows the persisted cwd',
    );
    expect(s.busy, isFalse);
  });

  test(
    'changing workspace replaces a live shell for the same session',
    () async {
      final root = Directory.systemTemp.createTempSync('terminal-workspace-');
      final a = Directory('${root.path}/a')..createSync();
      final b = Directory('${root.path}/b')..createSync();
      final s = StudioShellSession(tabId: 'workspace-change');
      addTearDown(() {
        s.dispose();
        root.deleteSync(recursive: true);
      });
      for (final dir in [a, b]) {
        s.begin('pwd');
        await s.runPersistent(
          'pwd',
          sid: 'same-session',
          workspace: dir.path,
          spawner: () =>
              Process.start(_bash(), ['--norc'], workingDirectory: dir.path),
        );
        await _waitFor(() => !s.busy);
        expect(s.history, contains(dir.path));
      }
    },
  );

  test('shell exit clears busy and the next command recreates', () async {
    final s = StudioShellSession(tabId: 'u-death');
    addTearDown(s.dispose);

    s.begin('exit');
    expect(
      await s.runPersistent('exit', sid: 'sess-u-death', spawner: _spawnShell),
      isTrue,
    );
    await _waitFor(() => s.dead && !s.busy, reason: 'shell death clears busy');
    expect(
      s.history.any((l) => l.contains('shell exited')),
      isTrue,
      reason: 'death is surfaced in the scrollback',
    );

    s.begin('echo alive');
    expect(
      await s.runPersistent(
        'echo alive',
        sid: 'sess-u-death',
        spawner: _spawnShell,
      ),
      isTrue,
    );
    await _waitFor(
      () => s.history.contains('alive'),
      reason: 'a later command recreates the shell and works',
    );
    expect(s.dead, isFalse, reason: 'recovered shell is live again');
    expect(s.busy, isFalse);
  });

  test('a dead shell is not reused across tabs (owner isolation)', () async {
    final a = StudioShellSession(tabId: 'u-iso-a');
    final b = StudioShellSession(tabId: 'u-iso-b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    a.begin('export OVID=A');
    expect(
      await a.runPersistent(
        'export OVID=A',
        sid: 'sess-iso',
        spawner: _spawnShell,
      ),
      isTrue,
    );
    b.begin('echo "b=\$OVID"');
    expect(
      await b.runPersistent(
        'echo "b=\$OVID"',
        sid: 'sess-iso',
        spawner: _spawnShell,
      ),
      isTrue,
    );
    await _waitFor(
      () => b.history.any((l) => l.contains('b=')),
      reason: 'tab b output',
    );
    expect(
      b.history.any((l) => l.contains('b=A')),
      isFalse,
      reason: 'tab b does not inherit tab a state',
    );

    await PtyPool.I.discardFor('sess-iso');
    expect(a.dead, isFalse, reason: 'agent stop must not kill studio tabs');
    expect(b.dead, isFalse);
  });

  test('a quiet command gets an idle notice instead of being killed', () async {
    final original = StudioShellSession.idleNoticeAfterForTest;
    StudioShellSession.idleNoticeAfterForTest = const Duration(
      milliseconds: 250,
    );
    addTearDown(() => StudioShellSession.idleNoticeAfterForTest = original);

    final s = StudioShellSession(tabId: 'u-hang');
    addTearDown(s.dispose);

    s.begin('sleep 30');
    expect(
      await s.runPersistent('sleep 30', sid: 'sess-hang', spawner: _spawnShell),
      isTrue,
    );
    await _waitFor(
      () => s.history.any((l) => l.contains('still running')),
      timeout: const Duration(seconds: 3),
      reason: 'idle notice',
    );
    expect(s.busy, isTrue, reason: 'a quiet command is not killed');
    expect(s.dead, isFalse);
  });

  test('read x does not consume the sentinel; stdin answers it', () async {
    final s = StudioShellSession(tabId: 'u-read');
    addTearDown(s.dispose);

    s.begin('read x; echo "got=\$x"');
    expect(
      await s.runPersistent(
        'read x; echo "got=\$x"',
        sid: 'sess-read',
        spawner: _spawnShell,
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      s.busy,
      isTrue,
      reason: 'read is waiting for the user, not the token',
    );
    expect(s.acceptsStdin, isTrue);
    expect(s.history.any((l) => l.contains('got=__OVID')), isFalse);

    expect(s.sendStdin('hello'), isTrue);
    await _waitFor(() => !s.busy, reason: 'read finishes after stdin');
    expect(s.history, contains('got=hello'));
    expect(s.acceptsStdin, isFalse);
  });

  test(
    'interrupt() stops the command but keeps the shell and its cwd',
    () async {
      final dir = Directory.systemTemp.createTempSync('ovid-int-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = StudioShellSession(tabId: 'u-int');
      addTearDown(s.dispose);

      s.begin('cd');
      await s.runPersistent(
        'cd "${dir.path}"',
        sid: 'sess-int',
        spawner: _spawnShell,
      );
      await _waitFor(() => !s.busy, reason: 'cd completes');

      s.begin('sleep 30');
      await s.runPersistent('sleep 30', sid: 'sess-int', spawner: _spawnShell);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(s.busy, isTrue);
      final shellBefore = s.shell;

      s.interrupt();
      await _waitFor(() => !s.busy, reason: 'Ctrl-C ends sleep');
      expect(s.shell, same(shellBefore), reason: 'shell survives Ctrl-C');
      expect(s.history, contains('^C'));

      s.begin('pwd');
      await s.runPersistent('pwd', sid: 'sess-int', spawner: _spawnShell);
      await _waitFor(() => !s.busy, reason: 'pwd completes');
      expect(s.history.any((l) => l.trim() == dir.path), isTrue);
    },
  );

  test('non-interactive env is exported and non-zero exit is shown', () async {
    final s = StudioShellSession(tabId: 'u-env');
    addTearDown(s.dispose);
    s.begin('env');
    await s.runPersistent(
      'echo "ed=\$GIT_EDITOR ci=\$CI"; false',
      sid: 'sess-env',
      spawner: _spawnShell,
    );
    await _waitFor(() => !s.busy, reason: 'env command completes');
    expect(s.history, contains('ed=true ci=1'));
    expect(s.history, contains('⚠ exit 1'));
  });

  test('incompleteReason rejects unclosed quotes only', () {
    expect(StudioShellSession.incompleteReason('echo "foo'), isNotNull);
    expect(StudioShellSession.incompleteReason("echo 'foo"), isNotNull);
    expect(StudioShellSession.incompleteReason('echo foo \\'), isNotNull);
    expect(StudioShellSession.incompleteReason('echo "a\'b"'), isNull);
    expect(StudioShellSession.incompleteReason("echo 'a\"b'"), isNull);
    expect(StudioShellSession.incompleteReason(r'echo "a\"b"'), isNull);
    expect(StudioShellSession.incompleteReason('ls -la'), isNull);
  });

  test('cancel() stops a running command and drops the shell', () async {
    final s = StudioShellSession(tabId: 'u-cancel');
    addTearDown(s.dispose);

    s.begin('sleep 30');
    expect(
      await s.runPersistent(
        'sleep 30',
        sid: 'sess-cancel',
        spawner: _spawnShell,
      ),
      isTrue,
    );
    expect(s.busy, isTrue);

    s.cancel();
    expect(s.busy, isFalse);
    expect(s.shell, isNull);
  });
}
