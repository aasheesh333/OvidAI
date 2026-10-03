import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Existing preference failure tests use the transitive platform interface.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ovid_ai/core/repo_cache.dart';

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

class ApprovalGit {
  String tip = 'base';
  final requests = <http.Request>[];
  FutureOr<http.Response?> Function(http.Request)? intercept;
  final entries = <Map<String, Object>>[];
  final originals = <String, String>{};
  late final client = MockClient((r) async {
    requests.add(r);
    final override = await intercept?.call(r);
    if (override != null) return override;
    if (r.method == 'GET' && r.url.path.contains('/git/ref/')) {
      return jsonResponse({
        'object': {'type': 'commit', 'sha': tip},
      });
    }
    if (r.method == 'GET' && r.url.path.contains('/git/trees/')) {
      return jsonResponse({
        'sha': 'base-tree',
        'truncated': false,
        'tree': entries,
      });
    }
    if (r.method == 'GET' && r.url.path.contains('/git/blobs/')) {
      return jsonResponse({
        'encoding': 'base64',
        'content': base64Encode(
          utf8.encode(originals[r.url.pathSegments.last]!),
        ),
      });
    }
    if (r.method == 'POST') {
      return jsonResponse({
        'sha': r.url.path.endsWith('/commits') ? 'intended' : 'new-object',
      }, 201);
    }
    if (r.method == 'PATCH') {
      tip = 'intended';
      return jsonResponse({
        'object': {'sha': tip},
      });
    }
    return http.Response('unexpected request', 404);
  });
  Iterable<http.Request> get mutations =>
      requests.where((r) => r.method != 'GET');
}

class FailingIntentPreferences extends InMemorySharedPreferencesStore {
  FailingIntentPreferences() : super.empty();
  bool failWrites = false;
  bool failRemovals = false;
  Future<void> Function()? onWrite;
  Future<void> Function()? onRemove;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    await onWrite?.call();
    if (failWrites) return false;
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    await onRemove?.call();
    if (failRemovals) return false;
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = RepoCache.I;
  late ApprovalGit git;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache.unbind();
    cache.bind('owner/repo', 'token', sessionId: 's1');
    cache.retryBaseDelay = Duration.zero;
    cache.write('a.txt', 'approved');
    git = ApprovalGit();
  });
  tearDown(() {
    git.client.close();
    cache.unbind();
    cache.requestTimeout = const Duration(seconds: 20);
  });

  test(
    'unknown intent blocks a second call with read-only reconciliation',
    () async {
      git.intercept = (r) {
        if (r.method == 'PATCH') throw http.ClientException('lost');
        return null;
      };
      await expectLater(
        cache.commitAll('first', client: git.client),
        throwsA(anything),
      );
      final count = git.mutations.length;
      await expectLater(
        cache.commitAll('second', client: git.client),
        throwsA(anything),
      );
      expect(
        git.mutations.length,
        count,
        reason: 'uncertain publication must not be repeated',
      );
      expect(cache.hasPending, isTrue);
    },
  );

  test(
    'restart reconciles persisted intended SHA without a second mutation',
    () async {
      git.intercept = (r) {
        if (r.method == 'PATCH') throw http.ClientException('lost');
        return null;
      };
      await expectLater(
        cache.commitAll('first', client: git.client),
        throwsA(anything),
      );
      final prefs = await SharedPreferences.getInstance();
      final disk = {for (final k in prefs.getKeys()) k: prefs.get(k)!};
      expect(
        disk,
        isNotEmpty,
        reason: 'publication intent must survive the process',
      );
      SharedPreferences.setMockInitialValues(disk);
      cache.unbind();
      cache.bind('owner/repo', 'token', sessionId: 's1');
      cache.write('a.txt', 'newer draft');
      git.tip = 'intended';
      git.intercept = null;
      final count = git.mutations.length;
      expect(await cache.commitAll('new message', client: git.client), 1);
      expect(git.mutations.length, count);
      expect(cache.hasPending, isTrue);
      expect(cache.read('a.txt'), 'newer draft');
      expect(cache.lastCommit?.commitSha, 'intended');
    },
  );

  test('intent persistence failure fails closed before PATCH', () async {
    final backend = FailingIntentPreferences()..failWrites = true;
    SharedPreferencesStorePlatform.instance = backend;
    await expectLater(
      cache.commitAll('msg', client: git.client),
      throwsA(anything),
    );
    expect(git.requests.where((r) => r.method == 'PATCH'), isEmpty);
    expect(cache.hasPending, isTrue);
  });

  test('concurrent admission cannot publish two commits', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    git.intercept = (r) async {
      if (r.method == 'POST' && r.url.path.endsWith('/commits')) {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }
      return null;
    };
    final first = cache.commitAll('first', client: git.client);
    await entered.future;
    final second = cache
        .commitAll('second', client: git.client)
        .then<Object>((n) => n, onError: (Object e) => e);
    release.complete();
    await first;
    await second;
    expect(git.requests.where((r) => r.method == 'PATCH').length, 1);
    expect(
      git.requests
          .where((r) => r.method == 'POST' && r.url.path.endsWith('/commits'))
          .length,
      1,
    );
  });

  test(
    'preview freezes selected bytes message base and truthful executable diff',
    () async {
      git.entries.add({
        'path': 'a.txt',
        'type': 'blob',
        'mode': '100755',
        'sha': 'old-blob',
      });
      git.originals['old-blob'] = 'old\n';
      cache.write('b.txt', 'unselected');
      final dynamic approval = await (cache as dynamic).prepareCommit(
        'exact message',
        paths: ['a.txt'],
        client: git.client,
      );
      expect(approval.repo, 'owner/repo');
      expect(approval.branch, 'main');
      expect(approval.baseCommit, 'base');
      expect(approval.message, 'exact message');
      expect(approval.contents, {'a.txt': 'approved'});
      expect(approval.diff, contains('-old\n'));
      expect(
        approval.diff,
        contains('+approved\n\\ No newline at end of file'),
      );
      expect(approval.diff, contains('100755'));
      expect(git.mutations, isEmpty);
      expect(
        () => approval.contents['a.txt'] = 'tampered',
        throwsUnsupportedError,
      );
      cache.write('b.txt', 'later unselected');
      expect(
        await (cache as dynamic).commitApproved(approval, client: git.client),
        1,
      );
      expect(cache.dirtyCount, 1);
      expect(cache.read('b.txt'), 'later unselected');
      final commit = git.requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/commits'),
      );
      expect(jsonDecode(commit.body)['message'], 'exact message');
      expect(jsonDecode(commit.body)['parents'], ['base']);
      final tree = git.requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/trees'),
      );
      expect(jsonDecode(tree.body), {
        'base_tree': 'base-tree',
        'tree': [
          {
            'path': 'a.txt',
            'mode': '100755',
            'type': 'blob',
            'sha': 'new-object',
          },
        ],
      });
    },
  );

  for (final change in ['edit', 'rebind', 'upstream']) {
    test(
      '$change after preview fails before creating remote objects',
      () async {
        final dynamic approval = await (cache as dynamic).prepareCommit(
          'msg',
          client: git.client,
        );
        if (change == 'edit') cache.write('a.txt', 'later');
        if (change == 'rebind') {
          cache.bind('owner/repo', 'token', sessionId: 's2');
        }
        if (change == 'upstream') git.tip = 'advanced';
        await expectLater(
          (cache as dynamic).commitApproved(approval, client: git.client),
          throwsA(anything),
        );
        expect(git.mutations, isEmpty);
      },
    );
  }

  test('edit during preview loading requires a fresh preview', () async {
    git.intercept = (r) {
      if (r.url.path.contains('/git/trees/')) cache.write('a.txt', 'changed');
      return null;
    };
    await expectLater(
      (cache as dynamic).prepareCommit('msg', client: git.client),
      throwsA(anything),
    );
    expect(git.mutations, isEmpty);
  });

  test(
    'incomplete tree cannot invent an addition or default executable mode',
    () async {
      git.intercept = (r) => r.url.path.contains('/git/trees/')
          ? jsonResponse({'sha': 'base-tree', 'tree': [], 'truncated': true})
          : null;
      await expectLater(
        (cache as dynamic).prepareCommit('msg', client: git.client),
        throwsA(anything),
      );
      expect(git.mutations, isEmpty);
    },
  );

  test(
    'selected deletion previews old bytes and sends null tree SHA',
    () async {
      git.entries.add({
        'path': 'a.txt',
        'type': 'blob',
        'mode': '100644',
        'sha': 'old-blob',
      });
      git.originals['old-blob'] = 'deleted\n';
      (cache as dynamic).stageDeletion('a.txt');
      final dynamic approval = await (cache as dynamic).prepareCommit(
        'delete',
        client: git.client,
      );
      expect(approval.diff, contains('deleted file mode 100644'));
      expect(approval.diff, contains('-deleted\n'));
      expect(
        await (cache as dynamic).commitApproved(approval, client: git.client),
        1,
      );
      expect(
        git.requests.where(
          (r) => r.method == 'POST' && r.url.path.endsWith('/blobs'),
        ),
        isEmpty,
      );
      final tree = git.requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/trees'),
      );
      expect(jsonDecode(tree.body)['tree'], [
        {'path': 'a.txt', 'mode': '100644', 'type': 'blob', 'sha': null},
      ]);
      expect(cache.hasPending, isFalse);
    },
  );

  test('read-only recovery works after restart with no dirty files', () async {
    git.intercept = (r) {
      if (r.method == 'PATCH') throw http.ClientException('lost');
      return null;
    };
    await expectLater(
      cache.commitAll('first', client: git.client),
      throwsA(anything),
    );
    cache.unbind();
    cache.bind('owner/repo', 'token', sessionId: 's1');
    git.tip = 'intended';
    git.intercept = null;
    final mutations = git.mutations.length;
    expect(await (cache as dynamic).reconcilePending(client: git.client), 1);
    expect(git.mutations.length, mutations);
    expect(cache.lastCommit?.commitSha, 'intended');
  });

  test(
    'staged deletion survives sync rather than resurrecting upstream file',
    () async {
      (cache as dynamic).stageDeletion('a.txt');
      git.entries.add({
        'path': 'a.txt',
        'type': 'blob',
        'mode': '100644',
        'sha': 'old-blob',
      });
      git.intercept = (r) =>
          r.url.path.contains('/contents/') ? http.Response('old', 200) : null;
      await cache.sync(client: git.client);
      expect(cache.read('a.txt'), isNull);
      expect(cache.pendingPaths, ['a.txt']);
    },
  );

  test(
    'failed intent removal cannot authorize a new mutation from optimistic cache',
    () async {
      final backend = FailingIntentPreferences()..failRemovals = true;
      SharedPreferencesStorePlatform.instance = backend;
      await expectLater(
        cache.commitAll('first', client: git.client),
        throwsA(anything),
      );
      final mutations = git.mutations.length;
      cache.write('a.txt', 'later');
      await expectLater(
        cache.commitAll('second', client: git.client),
        throwsA(anything),
      );
      expect(git.mutations.length, mutations);
      backend.failRemovals = false;
      expect(await cache.commitAll('third', client: git.client), 1);
      expect(git.mutations.length, mutations);
      expect(cache.read('a.txt'), 'later');
      expect(cache.hasPending, isTrue);
    },
  );

  test(
    'late timed-out PATCH reconciles on a later call without duplicate commit',
    () async {
      final release = Completer<http.Response>();
      cache.requestTimeout = const Duration(milliseconds: 20);
      git.intercept = (r) => r.method == 'PATCH' ? release.future : null;
      await expectLater(
        cache.commitAll('msg', client: git.client),
        throwsA(anything),
      );
      cache.write('a.txt', 'later');
      final mutations = git.mutations.length;
      await expectLater(
        cache.commitAll('retry', client: git.client),
        throwsA(anything),
      );
      expect(git.mutations.length, mutations);
      git.tip = 'intended';
      release.complete(
        jsonResponse({
          'object': {'sha': 'intended'},
        }),
      );
      await pumpEventQueue();
      expect(cache.lastCommit, isNull);
      expect(await cache.commitAll('retry', client: git.client), 1);
      expect(git.mutations.length, mutations);
      expect(cache.hasPending, isTrue);
    },
  );

  test(
    'rebound session targeting same remote must reconcile previous intent',
    () async {
      git.intercept = (r) {
        if (r.method == 'PATCH') {
          cache.bind('other/repo', 'token', sessionId: 'other');
          throw http.ClientException('lost');
        }
        return null;
      };
      await expectLater(
        cache.commitAll('first', client: git.client),
        throwsA(isA<StateError>()),
      );
      cache.bind('owner/repo', 'token', sessionId: 's2');
      cache.write('a.txt', 'approved');
      git.tip = 'intended';
      git.intercept = null;
      final mutations = git.mutations.length;
      expect(await cache.commitAll('new', client: git.client), 1);
      expect(git.mutations.length, mutations);
      expect(
        cache.hasPending,
        isTrue,
        reason: 'a different working copy owns these edits',
      );
      cache.bind('owner/repo', 'token', sessionId: 's1');
      expect(
        cache.hasPending,
        isFalse,
        reason: 'the original owner must not retain replayable confirmed bytes',
      );
    },
  );

  test(
    'disk changes after publication starts remain pending on success',
    () async {
      final dir = Directory.systemTemp.createTempSync('ovid-commit-disk');
      addTearDown(() => dir.deleteSync(recursive: true));
      cache.bind(
        'owner/repo',
        'token',
        sessionId: 's1',
        workspaceFolder: dir.path,
      );
      final file = File('${dir.path}/a.txt')..writeAsStringSync('approved');
      cache.write('a.txt', 'approved');
      cache.didSaveWorkspaceFile('a.txt', 'approved');
      git.intercept = (r) {
        if (r.method == 'PATCH') file.writeAsStringSync('newer on disk');
        return null;
      };
      expect(await cache.commitAll('msg', client: git.client), 1);
      expect(cache.read('a.txt'), 'newer on disk');
      expect(cache.hasPending, isTrue);
    },
  );

  test(
    'malformed persisted payload remains fenced even when tip matches',
    () async {
      git.intercept = (r) =>
          r.method == 'PATCH' ? throw http.ClientException('lost') : null;
      await expectLater(
        cache.commitAll('msg', client: git.client),
        throwsA(anything),
      );
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getKeys().single;
      final record = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
      record['pending'] = {'a.txt': 123};
      SharedPreferences.setMockInitialValues({key: jsonEncode(record)});
      git.tip = 'intended';
      final mutations = git.mutations.length;
      await expectLater(
        cache.commitAll('retry', client: git.client),
        throwsA(anything),
      );
      expect((await SharedPreferences.getInstance()).getString(key), isNotNull);
      expect(git.mutations.length, mutations);
    },
  );

  test(
    'rebind while persisting intent fences PATCH and retains recovery record',
    () async {
      final backend = FailingIntentPreferences();
      SharedPreferencesStorePlatform.instance = backend;
      backend.onWrite = () async {
        cache.bind('other/repo', 'token', sessionId: 'other');
      };
      await expectLater(
        cache.commitAll('msg', client: git.client),
        throwsA(isA<StateError>()),
      );
      expect(git.requests.where((r) => r.method == 'PATCH'), isEmpty);
      cache.bind('owner/repo', 'token', sessionId: 's1');
      final mutations = git.mutations.length;
      await expectLater(
        cache.commitAll('retry', client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      expect(git.mutations.length, mutations);
    },
  );

  test(
    'rebind during confirmed intent cleanup cannot leave replayable old drafts',
    () async {
      final backend = FailingIntentPreferences();
      SharedPreferencesStorePlatform.instance = backend;
      backend.onRemove = () async {
        cache.bind('other/repo', 'token', sessionId: 'other');
      };
      await expectLater(
        cache.commitAll('msg', client: git.client),
        throwsA(isA<StateError>()),
      );
      cache.bind('owner/repo', 'token', sessionId: 's1');
      expect(
        cache.hasPending,
        isFalse,
        reason:
            'confirmed bytes must be accounted for before releasing their intent',
      );
      expect(
        cache.lastCommit,
        isNull,
        reason: 'late result cannot publish into a rebound view',
      );
      final mutations = git.mutations.length;
      expect(await cache.commitAll('again', client: git.client), 0);
      expect(git.mutations.length, mutations);
    },
  );

  test(
    'missing workspace bytes cannot be mistaken for an approved deletion',
    () async {
      final dir = Directory.systemTemp.createTempSync('ovid-missing-commit');
      addTearDown(() => dir.deleteSync(recursive: true));
      cache.bind(
        'owner/repo',
        'token',
        sessionId: 's1',
        workspaceFolder: dir.path,
      );
      cache.write('a.txt', 'draft');
      cache.didSaveWorkspaceFile('a.txt', 'draft');
      git.entries.add({
        'path': 'a.txt',
        'type': 'blob',
        'mode': '100644',
        'sha': 'old',
      });
      git.originals['old'] = 'old';
      await expectLater(
        cache.prepareCommit('msg', client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      expect(git.mutations, isEmpty);
    },
  );

  test(
    'unknown publication remains fenced through repository casing aliases',
    () async {
      git.intercept = (r) =>
          r.method == 'PATCH' ? throw http.ClientException('lost') : null;
      await expectLater(
        cache.commitAll('first', client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      final mutations = git.mutations.length;
      cache.bind('Owner/Repo', 'token', sessionId: 's1');
      cache.write('a.txt', 'approved');
      await expectLater(
        cache.commitAll('alias', client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      expect(git.mutations.length, mutations);
    },
  );

  test('concurrent casing alias cannot bypass remote-ref admission', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    git.intercept = (r) async {
      if (r.method == 'POST' &&
          r.url.path.endsWith('/commits') &&
          !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      return null;
    };
    final first = cache
        .commitAll('first', client: git.client)
        .then<Object>((n) => n, onError: (Object e) => e);
    await entered.future;
    final mutations = git.mutations.length;
    cache.bind('OWNER/REPO', 'token', sessionId: 's2');
    cache.write('a.txt', 'different');
    final second = await cache
        .commitAll('second', client: git.client)
        .then<Object>((n) => n, onError: (Object e) => e);
    release.complete();
    expect(await first, isA<StateError>());
    expect(
      second,
      isA<CommitFailure>().having(
        (e) => e.kind,
        'kind',
        CommitFailureKind.busy,
      ),
    );
    expect(git.mutations.length, mutations);
  });

  String legacyKey(String repo, String branch) =>
      'ovid.repo.pending.v1.${base64Url.encode(utf8.encode(jsonEncode([repo, branch])))}';
  Map<String, Object> legacyIntent(String repo, String branch) => {
    'sha': 'intended',
    'repo': repo,
    'branch': branch,
    'base': 'base',
    'message': 'legacy',
    'pending': {'a.txt': 'approved'},
    'owner': jsonEncode(['s1', repo, branch, null]),
  };

  test(
    'legacy mixed-case intent survives restart and clears only after proof',
    () async {
      final key = legacyKey('Owner/Repo', 'main');
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(legacyIntent('Owner/Repo', 'main')),
      });
      await expectLater(
        cache.commitAll('retry', client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      expect(git.mutations, isEmpty);
      expect((await SharedPreferences.getInstance()).getString(key), isNotNull);
      git.tip = 'intended';
      expect(await cache.reconcilePending(client: git.client), 1);
      expect(git.mutations, isEmpty);
      expect(cache.hasPending, isFalse);
      expect((await SharedPreferences.getInstance()).getString(key), isNull);
    },
  );

  test(
    'branch case remains distinct when loading legacy repository aliases',
    () async {
      final key = legacyKey('Owner/Repo', 'Main');
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(legacyIntent('Owner/Repo', 'Main')),
      });
      expect(await cache.commitAll('main branch', client: git.client), 1);
      expect((await SharedPreferences.getInstance()).getString(key), isNotNull);
    },
  );

  test(
    'original BOM survives preview and exact approved blob encoding',
    () async {
      git.entries.add({
        'path': 'a.txt',
        'type': 'blob',
        'mode': '100644',
        'sha': 'old',
      });
      git.originals['old'] = '\uFEFForiginal';
      cache.write('a.txt', '\uFEFFapproved');
      final artifact = await cache.prepareCommit('BOM', client: git.client);
      expect(artifact.originals['a.txt'], '\uFEFForiginal');
      expect(artifact.diff, contains('-\uFEFForiginal'));
      await cache.commitApproved(artifact, client: git.client);
      final blob = git.requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/blobs'),
      );
      expect(base64Decode(jsonDecode(blob.body)['content'] as String), [
        239,
        187,
        191,
        97,
        112,
        112,
        114,
        111,
        118,
        101,
        100,
      ]);
    },
  );

  for (final addBom in [false, true]) {
    test(
      'workspace BOM-only ${addBom ? 'addition' : 'removal'} invalidates approved bytes',
      () async {
        final dir = Directory.systemTemp.createTempSync('ovid-bom');
        addTearDown(() => dir.deleteSync(recursive: true));
        cache.bind(
          'owner/repo',
          'token',
          sessionId: 's1',
          workspaceFolder: dir.path,
        );
        final original = addBom ? 'text' : '\uFEFFtext';
        final file = File('${dir.path}/a.txt')
          ..writeAsBytesSync(utf8.encode(original));
        cache.write('a.txt', original);
        cache.didSaveWorkspaceFile('a.txt', original);
        await cache.sync();
        expect(cache.files['a.txt'], original);
        final artifact = await cache.prepareCommit('BOM', client: git.client);
        expect(artifact.contents['a.txt'], original);
        file.writeAsBytesSync(utf8.encode(addBom ? '\uFEFFtext' : 'text'));
        await expectLater(
          cache.commitApproved(artifact, client: git.client),
          throwsA(isA<CommitFailure>()),
        );
        expect(git.mutations, isEmpty);
      },
    );
  }

  test('remote sync retains BOM for subsequent edits and approval', () async {
    git.entries.add({
      'path': 'a.txt',
      'type': 'blob',
      'mode': '100644',
      'sha': 'old',
    });
    cache.remove('a.txt');
    git.intercept = (r) => r.url.path.contains('/contents/')
        ? http.Response.bytes([239, 187, 191, 116, 101, 120, 116], 200)
        : null;
    await cache.sync(client: git.client);
    expect(cache.read('a.txt'), '\uFEFFtext');
  });

  test(
    'malformed intent diagnostic never exposes persisted file content',
    () async {
      const sentinel = 'SECRET_FILE_CONTENT_SENTINEL';
      SharedPreferences.setMockInitialValues({
        legacyKey('owner/repo', 'main'): '{"pending":"$sentinel", broken',
      });
      final result = await cache
          .commitAll('retry', client: git.client)
          .then<Object>((n) => n, onError: (Object e) => e);
      expect(
        result,
        isA<CommitFailure>().having(
          (e) => e.kind,
          'kind',
          CommitFailureKind.persistence,
        ),
      );
      expect('$result', isNot(contains(sentinel)));
      expect('$result', isNot(contains('broken')));
      expect(git.requests, isEmpty);
    },
  );

  test(
    'conflicting legacy casing intents cannot overwrite each other',
    () async {
      final first = legacyKey('Owner/Repo', 'main');
      final second = legacyKey('OWNER/REPO', 'main');
      SharedPreferences.setMockInitialValues({
        first: jsonEncode(legacyIntent('Owner/Repo', 'main')),
        second: jsonEncode({
          ...legacyIntent('OWNER/REPO', 'main'),
          'sha': 'other-intended',
        }),
      });
      git.tip = 'intended';
      await expectLater(
        cache.reconcilePending(client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), containsAll([first, second]));
      expect(git.requests, isEmpty);
    },
  );

  test(
    'failed legacy alias cleanup retains its canonical admission fence',
    () async {
      final key = legacyKey('Owner/Repo', 'main');
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(legacyIntent('Owner/Repo', 'main')),
      });
      // First hydrate the existing legacy record, then fail removal in the real
      // preferences backend while its Dart cache optimistically removes the key.
      await expectLater(
        cache.reconcilePending(client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      final backend = FailingIntentPreferences()..failRemovals = true;
      SharedPreferencesStorePlatform.instance = backend;
      git.tip = 'intended';
      await expectLater(
        cache.reconcilePending(client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      cache.bind('OWNER/REPO', 'token', sessionId: 's2');
      cache.write('a.txt', 'later');
      await expectLater(
        cache.commitAll('alias', client: git.client),
        throwsA(isA<CommitFailure>()),
      );
      expect(git.mutations, isEmpty);
      backend.failRemovals = false;
      expect(await cache.reconcilePending(client: git.client), 1);
      expect(cache.hasPending, isTrue);
    },
  );
}
