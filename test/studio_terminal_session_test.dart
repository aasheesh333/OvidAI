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

  test('shell exit clears busy and the next command recreates', () async {
    final s = StudioShellSession(tabId: 'u-death');
    addTearDown(s.dispose);

    s.begin('exit');
    expect(
      await s.runPersistent('exit', sid: 'sess-u-death', spawner: _spawnShell),
      isTrue,
    );
    await _waitFor(
      () => s.dead && !s.busy,
      reason: 'shell death clears busy',
    );
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
      await a.runPersistent('export OVID=A', sid: 'sess-iso', spawner: _spawnShell),
      isTrue,
    );
    b.begin('echo "b=\$OVID"');
    expect(
      await b.runPersistent('echo "b=\$OVID"', sid: 'sess-iso', spawner: _spawnShell),
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
}
