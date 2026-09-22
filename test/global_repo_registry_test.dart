import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/global_repo_registry.dart';

/// Regression tests for the clone-once [GlobalRepoRegistry]:
/// index JSON round-trip, registry-hit without git, folder-name
/// sanitization, and re-clone when the indexed folder vanished.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ovid-reg-test');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  GlobalRepoRegistry registryWith({
    required List<(String repo, String branch, String dest)> calls,
  }) {
    return GlobalRepoRegistry.createForTest(
      baseDir: Directory('${tmp.path}/global'),
      gitRunner: (repoFull, branch, dest) async {
        calls.add((repoFull, branch, dest));
        await Directory(dest).create(recursive: true);
        await File('$dest/.gitkeep').writeAsString('fake clone');
      },
    );
  }

  group('index JSON round-trip', () {
    test('save/load preserves (repoFull,branch)->path and session bindings',
        () async {
      final calls = <(String, String, String)>[];
      final r1 = registryWith(calls: calls);
      final path = await r1.ensureCloned('acme/app', 'main');
      await r1.bindSession('sess-1', 'acme/app', 'main', path);

      // The index file really exists on disk under global/.
      final indexFile = File('${tmp.path}/global/repo_index.json');
      expect(indexFile.existsSync(), isTrue);
      final raw = jsonDecode(indexFile.readAsStringSync()) as Map;
      expect((raw['repos'] as Map).containsKey('acme/app@main'), isTrue);

      // A fresh instance loading the same index sees everything.
      final r2 = registryWith(calls: calls);
      await r2.reload();
      expect(r2.boundWorkspaceFor('sess-1'), path);
      // Registry hit on the fresh instance: no git invocation.
      final again = await r2.ensureCloned('acme/app', 'main');
      expect(again, path);
      expect(calls, hasLength(1));
    });

    test('corrupt index loads as empty instead of throwing', () async {
      final global = Directory('${tmp.path}/global')..createSync();
      File('${global.path}/repo_index.json').writeAsStringSync('{oops');
      final r = registryWith(calls: <(String, String, String)>[]);
      await r.reload(); // must not throw
      expect(r.boundWorkspaceFor('nope'), isNull);
    });
  });

  group('ensureCloned', () {
    test('registry hit returns the same path WITHOUT invoking git',
        () async {
      final calls = <(String, String, String)>[];
      final r1 = registryWith(calls: calls);
      final first = await r1.ensureCloned('acme/app', 'develop');

      final r2 = registryWith(calls: calls);
      await r2.reload();
      final second = await r2.ensureCloned('acme/app', 'develop');

      expect(second, first);
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'acme/app');
      expect(calls.single.$2, 'develop');
    });

    test('different branches get different folders', () async {
      final calls = <(String, String, String)>[];
      final r = registryWith(calls: calls);
      final a = await r.ensureCloned('acme/app', 'main');
      final b = await r.ensureCloned('acme/app', 'develop');
      expect(a, isNot(equals(b)));
      expect(calls, hasLength(2));
    });

    test('missing folder on hit triggers re-clone', () async {
      final calls = <(String, String, String)>[];
      final r1 = registryWith(calls: calls);
      final path = await r1.ensureCloned('acme/app', 'main');
      expect(Directory(path).existsSync(), isTrue);

      // Simulate the user (or storage pressure) deleting the clone.
      Directory(path).deleteSync(recursive: true);

      final r2 = registryWith(calls: calls);
      await r2.reload();
      final again = await r2.ensureCloned('acme/app', 'main');
      expect(again, path); // same deterministic folder
      expect(calls, hasLength(2)); // git ran again
      expect(Directory(again).existsSync(), isTrue);
    });

    test('failed clone is not indexed and leaves no half-clone', () async {
      final r = GlobalRepoRegistry.createForTest(
        baseDir: Directory('${tmp.path}/global'),
        gitRunner: (repoFull, branch, dest) async {
          await Directory(dest).create(recursive: true);
          throw Exception('network down');
        },
      );
      await expectLater(r.ensureCloned('acme/app', 'main'), throwsException);
      // No half-clone left behind and nothing indexed …
      expect(
        Directory('${tmp.path}/global/repos/acme__app__main').existsSync(),
        isFalse,
      );
      // Next attempt retries the clone instead of returning a dead hit.
      var ran = 0;
      final r2 = GlobalRepoRegistry.createForTest(
        baseDir: Directory('${tmp.path}/global'),
        gitRunner: (repoFull, branch, dest) async {
          ran++;
          await Directory(dest).create(recursive: true);
        },
      );
      await r2.reload();
      final path = await r2.ensureCloned('acme/app', 'main');
      expect(ran, 1);
      expect(Directory(path).existsSync(), isTrue);
    });

    test('invalid repoFull/branch throws ArgumentError', () async {
      final r = registryWith(calls: <(String, String, String)>[]);
      await expectLater(
        r.ensureCloned('not-a-repo', 'main'),
        throwsArgumentError,
      );
      await expectLater(
        r.ensureCloned('acme/app', ''),
        throwsArgumentError,
      );
    });
  });

  group('folderNameFor sanitization', () {
    test('feature/foo branch becomes filesystem-safe', () {
      expect(
        GlobalRepoRegistry.folderNameFor('acme/app', 'feature/foo'),
        'acme__app__feature_foo',
      );
    });

    test('no unsafe characters survive', () {
      final name = GlobalRepoRegistry.folderNameFor(
        'my-org/my.repo_2',
        'fix: weird#branch name/v2',
      );
      expect(name.contains('/'), isFalse);
      expect(name.contains(' '), isFalse);
      expect(name.contains(':'), isFalse);
      expect(name.contains('#'), isFalse);
      expect(
        RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name),
        isTrue,
        reason: 'got: $name',
      );
    });

    test('same key always maps to the same folder', () {
      expect(
        GlobalRepoRegistry.folderNameFor('a/b', 'x'),
        GlobalRepoRegistry.folderNameFor('a/b', 'x'),
      );
    });
  });

  group('session bindings', () {
    test('bind / lookup / unbind', () async {
      final r = registryWith(calls: <(String, String, String)>[]);
      final dir = Directory('${tmp.path}/ws')..createSync();
      await r.bindSession('s1', 'acme/app', 'main', dir.path);
      expect(r.boundWorkspaceFor('s1'), dir.path);
      await r.unbindSession('s1');
      expect(r.boundWorkspaceFor('s1'), isNull);
    });

    test('binding to a vanished folder resolves to null', () async {
      final r = registryWith(calls: <(String, String, String)>[]);
      final dir = Directory('${tmp.path}/ws2')..createSync();
      await r.bindSession('s2', 'acme/app', 'main', dir.path);
      dir.deleteSync(recursive: true);
      expect(r.boundWorkspaceFor('s2'), isNull);
    });
  });
}
