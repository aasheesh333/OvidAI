import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/pty_service.dart';

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
    await PtyPool.I.discardAll();
  });

  test('output streams before the command completes', () async {
    final shell = await PtyShell.start(_spawnShell);
    expect(shell, isNotNull, reason: 'host bash spawned');
    addTearDown(() => shell!.close());
    final lines = <String>[];
    final sub = shell!.output.listen(lines.add);
    addTearDown(sub.cancel);

    shell.writeStdin('echo first; sleep 2; echo second\n');

    await _waitFor(
      () => lines.contains('first'),
      reason: 'first line to stream',
    );
    expect(
      lines.contains('second'),
      isFalse,
      reason: 'second must not arrive before the sleep finishes',
    );
    await _waitFor(
      () => lines.contains('second'),
      reason: 'second line to stream',
    );
  });

  test('cd persists across two commands in one tab', () async {
    final dir = Directory.systemTemp.createTempSync('ovid-studio-tab-');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final shell = await PtyPool.I.getOrCreate('sess-cd', _spawnShell, tab: 't1');
    expect(shell, isNotNull, reason: 'pool spawned tab shell');
    final lines = <String>[];
    final sub = shell!.output.listen(lines.add);
    addTearDown(sub.cancel);

    shell.writeStdin('cd "${dir.path}"\n');
    shell.writeStdin('pwd\n');

    await _waitFor(
      () => lines.any((l) => l.trim() == dir.path),
      reason: 'pwd to show the persisted cwd',
    );
  });

  test('two tabs on one session are independent shells', () async {
    var spawns = 0;
    Future<Process> spawner() async {
      spawns++;
      return _spawnShell();
    }

    final a = await PtyPool.I.getOrCreate('sess-tabs', spawner, tab: 'a');
    final b = await PtyPool.I.getOrCreate('sess-tabs', spawner, tab: 'b');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(identical(a, b), isFalse, reason: 'tabs are distinct shells');
    expect(spawns, 2);

    final sameA = await PtyPool.I.getOrCreate('sess-tabs', spawner, tab: 'a');
    expect(identical(sameA, a), isTrue, reason: 'same tab reuses its shell');
    expect(spawns, 2);

    final linesA = <String>[];
    final linesB = <String>[];
    final subA = a!.output.listen(linesA.add);
    final subB = b!.output.listen(linesB.add);
    addTearDown(subA.cancel);
    addTearDown(subB.cancel);

    a.writeStdin('export OVID_TAB=A\n');
    a.writeStdin('echo "ta=\$OVID_TAB"\n');
    b.writeStdin('echo "tb=\$OVID_TAB"\n');

    await _waitFor(
      () => linesA.any((l) => l.contains('ta=A')),
      reason: 'tab a export visible',
    );
    await _waitFor(
      () => linesB.any((l) => l.contains('tb=')),
      reason: 'tab b echo visible',
    );
    expect(
      linesB.any((l) => l.contains('tb=A')),
      isFalse,
      reason: 'tab b must not inherit tab a state',
    );
  });

  test('marker lines are not surfaced on output', () async {
    final shell = await PtyShell.start(_spawnShell);
    expect(shell, isNotNull);
    addTearDown(() => shell!.close());
    final lines = <String>[];
    final sub = shell!.output.listen(lines.add);
    addTearDown(sub.cancel);

    final out = await shell.run('echo visible');
    expect(out, contains('visible'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      lines.any((l) => l.contains('__OVID_DONE_')),
      isFalse,
      reason: 'internal completion markers stay internal',
    );
  });

  test('discardFor closes every tab shell for the session', () async {
    final a = await PtyPool.I.getOrCreate(
      'sess-discard',
      _spawnShell,
      tab: 'a',
    );
    final b = await PtyPool.I.getOrCreate(
      'sess-discard',
      _spawnShell,
      tab: 'b',
    );
    expect(a, isNotNull);
    expect(b, isNotNull);

    await PtyPool.I.discardFor('sess-discard');
    expect(a!.isDead, isTrue, reason: 'tab a shell closed');
    expect(b!.isDead, isTrue, reason: 'tab b shell closed');

    var respawned = 0;
    final replacement = await PtyPool.I.getOrCreate(
      'sess-discard',
      () async {
        respawned++;
        return _spawnShell();
      },
      tab: 'a',
    );
    expect(replacement, isNotNull);
    expect(identical(replacement, a), isFalse);
    expect(respawned, 1);
  });
}
