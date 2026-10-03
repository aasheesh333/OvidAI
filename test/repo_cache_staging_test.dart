import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'repo_cache_approval_test.dart' show ApprovalGit;

// Mirrors dart:io's documented split: typeSync hides EACCES as notFound,
// whereas resolveSymbolicLinksSync/readAsBytesSync preserve the OS error.
// Real files and all accessible paths still use the host filesystem.
final class DeniedAncestorIO extends IOOverrides {
  DeniedAncestorIO(this.ancestor, {this.errorCode = 13});
  final String ancestor;
  final int errorCode;
  bool inaccessible(String path) => path.startsWith('$ancestor/');
  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      inaccessible(path) ? FileSystemEntityType.notFound : super.fseGetTypeSync(path, followLinks);
  @override
  File createFile(String path) => inaccessible(path)
      ? DeniedFile(super.createFile(path), errorCode) : super.createFile(path);
}

class DeniedFile implements File {
  DeniedFile(this.file, this.errorCode);
  final File file;
  final int errorCode;
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  String resolveSymbolicLinksSync() => throw FileSystemException(
      'Cannot resolve symbolic links', path, OSError('Injected lookup failure', errorCode));
  @override
  Uint8List readAsBytesSync() => throw FileSystemException(
      'Cannot open file', path, OSError('Injected lookup failure', errorCode));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = RepoCache.I;
  late ApprovalGit git;
  Directory? workspace;
  void mode(String path, String value) => cache.stageMode(path, value);
  void bindWorkspace() {
    workspace = Directory.systemTemp.createTempSync('ovid-staging');
    cache.bind('owner/repo', 'token', sessionId: 's1', workspaceFolder: workspace!.path);
  }
  void seed(String oldMode) {
    git.entries.add({'path': 'a.sh', 'type': 'blob', 'mode': oldMode, 'sha': 'old'});
    git.originals['old'] = 'same\n';
    cache.files['a.sh'] = 'same\n';
    cache.treePaths.add('a.sh');
  }
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache.unbind();
    cache.bind('owner/repo', 'token', sessionId: 's1');
    git = ApprovalGit();
  });
  tearDown(() {
    cache.unbind();
    git.client.close();
    workspace?.deleteSync(recursive: true);
    workspace = null;
  });

  for (final transition in [('100644', '100755'), ('100755', '100644')]) {
    test('mode-only ${transition.$1} to ${transition.$2} diff and selected payload', () async {
      seed(transition.$1);
      mode('a.sh', transition.$2);
      cache.write('b.txt', 'unselected');
      final approval = await cache.prepareCommit('mode', paths: ['a.sh'], client: git.client);
      expect(approval.diff, contains('old mode ${transition.$1}\nnew mode ${transition.$2}'));
      expect(approval.diff, isNot(contains('@@')));
      expect(() => approval.modes['a.sh'] = '100644', throwsUnsupportedError);
      await cache.commitApproved(approval, client: git.client);
      final tree = git.requests.singleWhere((r) => r.method == 'POST' && r.url.path.endsWith('/trees'));
      expect(jsonDecode(tree.body), {'base_tree': 'base-tree', 'tree': [
        {'path': 'a.sh', 'mode': transition.$2, 'type': 'blob', 'sha': 'new-object'},
      ]});
      expect(cache.pendingPaths, ['b.txt']);
      expect(jsonDecode(git.requests.singleWhere((r) => r.method == 'PATCH').body), {'sha': 'intended', 'force': false});
    });
  }

  for (final action in ['mode', 'operation', 'mode back', 'during preview']) {
    test('$action change invalidates review before objects', () async {
      seed('100644');
      mode('a.sh', '100755');
      if (action == 'during preview') {
        git.intercept = (r) {
          if (r.url.path.contains('/git/trees/')) mode('a.sh', '100644');
          return null;
        };
        await expectLater(cache.prepareCommit('mode', client: git.client), throwsA(isA<CommitFailure>()));
      } else {
        final approval = await cache.prepareCommit('mode', client: git.client);
        if (action == 'operation') {
          cache.stageDeletion('a.sh');
        } else {
          mode('a.sh', '100644');
          if (action == 'mode back') mode('a.sh', '100755');
        }
        await expectLater(cache.commitApproved(approval, client: git.client), throwsA(isA<CommitFailure>()));
      }
      expect(git.mutations, isEmpty);
    });
  }

  test('mode-only staging survives remote sync and working-copy rebind', () async {
    seed('100644');
    mode('a.sh', '100755');
    git.intercept = (r) => r.url.path.contains('/contents/') ? http.Response('same\n', 200) : null;
    await cache.sync(client: git.client);
    cache.bind('other/repo', 'token', sessionId: 's2');
    cache.bind('owner/repo', 'token', sessionId: 's1');
    expect(cache.pendingPaths, ['a.sh']);
    final approval = await cache.prepareCommit('mode', client: git.client);
    expect(approval.modes, {'a.sh': '100755'});
  });

  test('explicit missing checkout deletion survives sync and rebind, publishes old contents', () async {
    bindWorkspace();
    seed('100755');
    cache.stageDeletion('a.sh');
    final report = await cache.sync();
    expect(report.preservedPaths, contains('a.sh'));
    cache.bind('other/repo', 'token');
    cache.bind('owner/repo', 'token', sessionId: 's1', workspaceFolder: workspace!.path);
    final approval = await cache.prepareCommit('delete', client: git.client);
    expect(approval.diff, contains('deleted file mode 100755'));
    expect(approval.diff, contains('-same\n'));
    await cache.commitApproved(approval, client: git.client);
    expect(git.requests.where((r) => r.method == 'POST' && r.url.path.endsWith('/blobs')), isEmpty);
    final tree = git.requests.singleWhere((r) => r.method == 'POST' && r.url.path.endsWith('/trees'));
    expect(jsonDecode(tree.body)['tree'], [{'path': 'a.sh', 'mode': '100755', 'type': 'blob', 'sha': null}]);
    expect(cache.hasPending, isFalse);
    expect(File('${workspace!.path}/a.sh').existsSync(), isFalse);
  });

  for (final action in ['write', 'create', 'recreate', 'recreate sync']) {
    test('$action cancels stale checkout deletion and invalidates review', () async {
      bindWorkspace();
      seed('100644');
      cache.stageDeletion('a.sh');
      final approval = await cache.prepareCommit('delete', client: git.client);
      if (action == 'write') {
        cache.write('a.sh', 'new');
      } else if (action == 'create') {
        cache.create('a.sh', 'new');
      } else {
        File('${workspace!.path}/a.sh').writeAsStringSync('new');
        if (action == 'recreate sync') await cache.sync();
      }
      await expectLater(cache.commitApproved(approval, client: git.client), throwsA(isA<CommitFailure>()));
      expect(git.mutations, isEmpty);
      final updated = await cache.prepareCommit('update', client: git.client);
      expect(updated.contents, {'a.sh': 'new'});
    });
  }

  for (final unsafe in ['present', 'directory', 'symlink', 'escape', 'noncanonical', 'unreadable']) {
    test('deletion refuses $unsafe without changing disk', () async {
      bindWorkspace();
      seed('100644');
      final path = '${workspace!.path}/a.sh';
      if (unsafe == 'present') File(path).writeAsStringSync('keep');
      if (unsafe == 'directory') Directory(path).createSync();
      if (unsafe == 'symlink') Link(path).createSync('${workspace!.path}/missing');
      if (unsafe == 'unreadable') File(path).writeAsBytesSync([255]);
      expect(() => cache.stageDeletion(unsafe == 'escape' ? '../escape' : unsafe == 'noncanonical' ? './a.sh' : 'a.sh'), throwsA(anything));
      expect(cache.hasPending, isFalse);
      if (unsafe == 'present') expect(File(path).readAsStringSync(), 'keep');
    });
  }

  test('unreadable or nonregular workspace bytes never become implicit deletion', () async {
    bindWorkspace();
    seed('100644');
    cache.write('a.sh', 'draft');
    cache.didSaveWorkspaceFile('a.sh', 'draft');
    File('${workspace!.path}/a.sh').writeAsBytesSync([255]);
    await expectLater(cache.prepareCommit('bad', client: git.client), throwsA(isA<CommitFailure>()));
    expect(git.mutations, isEmpty);
  });

  test('mode staging rejects unknown modes and unsafe file types', () async {
    seed('100644');
    expect(() => mode('a.sh', '120000'), throwsA(isA<CommitFailure>()));
    expect(cache.hasPending, isFalse);
    bindWorkspace();
    Directory('${workspace!.path}/dir').createSync();
    Link('${workspace!.path}/link').createSync('${workspace!.path}/dir');
    for (final path in ['dir', 'link', '../escape']) {
      expect(() => mode(path, '100755'), throwsA(anything));
    }
    expect(cache.hasPending, isFalse);
  });

  for (final later in ['mode', 'deletion', 'content', 'mode back']) {
    test('later $later intent remains pending after publication starts', () async {
      seed('100644');
      mode('a.sh', '100755');
      git.intercept = (r) {
        if (r.method == 'PATCH') {
          if (later == 'deletion') {
            cache.stageDeletion('a.sh');
          } else if (later == 'content') {
            cache.write('a.sh', 'later');
          } else {
            mode('a.sh', '100644');
            if (later == 'mode back') mode('a.sh', '100755');
          }
        }
        return null;
      };
      await cache.commitAll('first', client: git.client);
      expect(cache.pendingPaths, ['a.sh']);
    });
  }

  for (final rebound in [false, true]) {
    test('unknown restart recovery retains later mode in ${rebound ? 'saved' : 'active'} owner', () async {
      seed('100644');
      mode('a.sh', '100755');
      git.intercept = (r) => r.method == 'PATCH' ? throw http.ClientException('lost') : null;
      await expectLater(cache.commitAll('first', client: git.client), throwsA(isA<CommitFailure>()));
      final prefs = await SharedPreferences.getInstance();
      final disk = {for (final k in prefs.getKeys()) k: prefs.get(k)!};
      SharedPreferences.setMockInitialValues(disk);
      cache.unbind();
      cache.bind('owner/repo', 'token', sessionId: 's1');
      cache.files['a.sh'] = 'same\n';
      mode('a.sh', '100644');
      if (rebound) cache.bind('owner/repo', 'token', sessionId: 's2');
      git.tip = 'intended';
      git.intercept = null;
      final count = git.mutations.length;
      expect(await cache.reconcilePending(client: git.client), 1);
      if (rebound) cache.bind('owner/repo', 'token', sessionId: 's1');
      expect(cache.pendingPaths, ['a.sh']);
      expect(git.mutations.length, count);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });
  }

  test('legacy content-only intent recovery does not discard explicit later mode', () async {
    seed('100644');
    mode('a.sh', '100755');
    final key = 'ovid.repo.pending.v1.${base64Url.encode(utf8.encode(jsonEncode(['owner/repo', 'main'])))}';
    SharedPreferences.setMockInitialValues({key: jsonEncode({
      'sha': 'intended', 'repo': 'owner/repo', 'branch': 'main',
      'pending': {'a.sh': 'same\n'}, 'owner': jsonEncode(['s1', 'owner/repo', 'main', null]),
    })});
    git.tip = 'intended';
    expect(await cache.reconcilePending(client: git.client), 1);
    expect(cache.pendingPaths, ['a.sh']);
    expect(git.mutations, isEmpty);
  });

  test('clearing failed workspace view preserves explicit mode and deletion staging', () async {
    bindWorkspace();
    seed('100644');
    File('${workspace!.path}/a.sh').writeAsStringSync('same\n');
    mode('a.sh', '100755');
    cache.stageDeletion('gone.txt');
    cache.clearWorkingCopy();
    expect(cache.pendingPaths, ['a.sh', 'gone.txt']);
    expect(cache.stagedMode('a.sh'), '100755');
    expect(cache.isStagedDeletion('gone.txt'), isTrue);
    final approval = await cache.prepareCommit('mode', paths: ['a.sh'], client: git.client);
    expect(approval.modes, {'a.sh': '100755'});
  });

  for (final saved in [false, true]) {
    test('confirmed unknown mode and deletion clean only the ${saved ? 'saved' : 'active'} original intent', () async {
      seed('100644');
      mode('a.sh', '100755');
      git.entries.add({'path': 'gone.txt', 'type': 'blob', 'mode': '100755', 'sha': 'gone'});
      git.originals['gone'] = 'gone';
      cache.stageDeletion('gone.txt');
      git.intercept = (r) => r.method == 'PATCH' ? throw http.ClientException('lost') : null;
      await expectLater(cache.commitAll('first', client: git.client), throwsA(isA<CommitFailure>()));
      if (saved) cache.bind('owner/repo', 'token', sessionId: 's2');
      git.tip = 'intended';
      final count = git.mutations.length;
      expect(await cache.reconcilePending(client: git.client), 2);
      if (saved) cache.bind('owner/repo', 'token', sessionId: 's1');
      expect(cache.pendingPaths, isEmpty);
      expect(cache.stagedMode('a.sh'), isNull);
      expect(git.mutations.length, count);
    });
  }

  for (final corruption in ['mode', 'missing modes', 'revision', 'version']) {
    test('malformed v2 $corruption remains durably fenced', () async {
      seed('100644');
      mode('a.sh', '100755');
      git.intercept = (r) => r.method == 'PATCH' ? throw http.ClientException('lost') : null;
      await expectLater(cache.commitAll('first', client: git.client), throwsA(isA<CommitFailure>()));
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getKeys().single;
      final record = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
      if (corruption == 'mode') record['modes'] = {'a.sh': '120000'};
      if (corruption == 'missing modes') record.remove('modes');
      if (corruption == 'revision') record['revisions'] = {'a.sh': 123};
      if (corruption == 'version') record['version'] = 3;
      SharedPreferences.setMockInitialValues({key: jsonEncode(record)});
      git.tip = 'intended';
      final count = git.requests.length;
      await expectLater(cache.reconcilePending(client: git.client), throwsA(isA<CommitFailure>()));
      expect(git.requests.length, count);
      expect((await SharedPreferences.getInstance()).getString(key), isNotNull);
    });
  }

  test('executable new file uses explicit new-file mode', () async {
    cache.create('new.sh', 'new');
    mode('new.sh', '100755');
    final approval = await cache.prepareCommit('new', client: git.client);
    expect(approval.diff, contains('new file mode 100755'));
    await cache.commitApproved(approval, client: git.client);
    final tree = git.requests.singleWhere((r) => r.method == 'POST' && r.url.path.endsWith('/trees'));
    expect(jsonDecode(tree.body)['tree'][0]['mode'], '100755');
  });

  for (final replacement in ['symlink', 'directory']) {
    test('checkout deletion replaced by $replacement fails before remote objects', () async {
      bindWorkspace();
      seed('100644');
      cache.stageDeletion('a.sh');
      final approval = await cache.prepareCommit('delete', client: git.client);
      if (replacement == 'symlink') {
        Link('${workspace!.path}/a.sh').createSync('${workspace!.path}/missing');
      } else {
        Directory('${workspace!.path}/a.sh').createSync();
      }
      await expectLater(cache.commitApproved(approval, client: git.client), throwsA(isA<CommitFailure>()));
      expect(git.mutations, isEmpty);
    });
  }

  test('nonregular checkout FIFO cannot be staged even with a readable draft', () async {
    bindWorkspace();
    cache.write('pipe', 'draft');
    final made = Process.runSync('mkfifo', ['${workspace!.path}/pipe']);
    expect(made.exitCode, 0);
    expect(() => mode('pipe', '100755'), throwsA(isA<CommitFailure>()));
    await expectLater(cache.prepareCommit('pipe', client: git.client), throwsA(isA<CommitFailure>()));
    expect(git.mutations, isEmpty);
  }, skip: !Platform.isLinux);

  for (final nested in [false, true]) {
    test('EACCES ${nested ? 'parent lookup' : 'leaf lookup'} refuses staging an existing inaccessible file', () async {
      bindWorkspace();
      final path = nested ? 'locked/nested/a.sh' : 'locked/a.sh';
      final file = File('${workspace!.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('existing bytes');
      final denied = DeniedAncestorIO('${workspace!.path}/locked');
      IOOverrides.runWithIOOverrides(() {
        expect(FileSystemEntity.typeSync(file.path, followLinks: false), FileSystemEntityType.notFound);
        expect(() => File(file.path).resolveSymbolicLinksSync(),
            throwsA(isA<FileSystemException>().having((e) => e.osError?.errorCode, 'errno', 13)));
        expect(() => cache.stageDeletion(path), throwsA(isA<CommitFailure>()));
      }, denied);
      expect(cache.pendingPaths, isEmpty);
      expect(file.readAsStringSync(), 'existing bytes');
      expect(git.requests, isEmpty);
    });
  }

  test('EACCES after deletion review refuses publication before remote objects', () async {
    bindWorkspace();
    const path = 'locked/nested/a.sh';
    final file = File('${workspace!.path}/$path');
    file.parent.createSync(recursive: true);
    git.entries.add({'path': path, 'type': 'blob', 'mode': '100644', 'sha': 'old'});
    git.originals['old'] = 'old';
    cache.stageDeletion(path);
    final approval = await cache.prepareCommit('delete', client: git.client);
    file.writeAsStringSync('recreated but inaccessible');
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(cache.commitApproved(approval, client: git.client), throwsA(isA<CommitFailure>()));
    }, DeniedAncestorIO('${workspace!.path}/locked'));
    expect(git.mutations, isEmpty);
    expect(cache.pendingPaths, [path]);
  });

  for (final saved in [false, true]) {
    test('EACCES reconciliation retains uncertain deletion in ${saved ? 'saved' : 'active'} owner', () async {
      bindWorkspace();
      const path = 'locked/nested/a.sh';
      final file = File('${workspace!.path}/$path');
      file.parent.createSync(recursive: true);
      git.entries.add({'path': path, 'type': 'blob', 'mode': '100644', 'sha': 'old'});
      git.originals['old'] = 'old';
      cache.stageDeletion(path);
      git.intercept = (r) => r.method == 'PATCH' ? throw http.ClientException('lost') : null;
      await expectLater(cache.commitAll('delete', client: git.client), throwsA(isA<CommitFailure>()));
      file.writeAsStringSync('new local bytes');
      if (saved) cache.bind('owner/repo', 'token', sessionId: 's2');
      git.tip = 'intended';
      final mutations = git.mutations.length;
      await IOOverrides.runWithIOOverrides(() async {
        expect(await cache.reconcilePending(client: git.client), 1);
      }, DeniedAncestorIO('${workspace!.path}/locked'));
      if (saved) cache.bind('owner/repo', 'token', sessionId: 's1', workspaceFolder: workspace!.path);
      expect(cache.pendingPaths, [path]);
      expect(cache.isStagedDeletion(path), isTrue);
      expect(git.mutations.length, mutations);
      final next = await cache.prepareCommit('review recreated file', client: git.client);
      expect(next.contents[path], 'new local bytes');
    });
  }

  for (final code in [5, 20, -1]) {
    test('lookup errno $code is not confirmed absence', () {
      bindWorkspace();
      IOOverrides.runWithIOOverrides(() {
        expect(() => cache.stageDeletion('locked/a.sh'), throwsA(isA<CommitFailure>()));
      }, DeniedAncestorIO('${workspace!.path}/locked', errorCode: code));
      expect(cache.pendingPaths, isEmpty);
      expect(git.requests, isEmpty);
    });
  }

  test('confirmed ENOENT with missing parent directories still permits deletion', () async {
    bindWorkspace();
    const path = 'missing/nested/a.sh';
    git.entries.add({'path': path, 'type': 'blob', 'mode': '100644', 'sha': 'old'});
    git.originals['old'] = 'old';
    cache.stageDeletion(path);
    final approval = await cache.prepareCommit('delete', client: git.client);
    expect(approval.contents, {path: null});
    expect(await cache.commitApproved(approval, client: git.client), 1);
    expect(cache.pendingPaths, isEmpty);
  });
}
