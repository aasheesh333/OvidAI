import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/repo_cache.dart';

const _repoPath = '/repos/owner/repo';
const _refPath = '$_repoPath/git/ref/heads/feature/x';
const _patchPath = '$_repoPath/git/refs/heads/feature/x';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _ref(String sha) => _json({
  'ref': 'refs/heads/feature/x',
  'object': {'type': 'commit', 'sha': sha},
});

/// Only HTTP is replaced. All snapshotting, mutation selection, reconciliation,
/// binding fences and dirty bookkeeping run through production commitAll.
class _GitFixture {
  final requests = <http.Request>[];
  FutureOr<http.Response?> Function(http.Request)? intercept;
  String tip = 'base-commit';
  late final client = MockClient((request) async {
    requests.add(request);
    final response = await intercept?.call(request);
    if (response != null) return response;
    final path = request.url.path;
    if (request.method == 'GET' && path == _refPath) return _ref(tip);
    if (request.method == 'GET' && path == '$_repoPath/git/trees/base-commit') {
      return _json({'sha': 'base-tree', 'truncated': false, 'tree': []});
    }
    if (request.method == 'POST') {
      if (path == '$_repoPath/git/blobs') return _json({'sha': 'blob'}, 201);
      if (path == '$_repoPath/git/trees') return _json({'sha': 'tree'}, 201);
      if (path == '$_repoPath/git/commits') {
        return _json({'sha': 'intended-commit'}, 201);
      }
    }
    if (request.method == 'PATCH' && path == _patchPath) {
      tip = (jsonDecode(request.body) as Map)['sha'] as String;
      return _ref(tip);
    }
    // Make the old fallback succeed so it cannot masquerade as safe failure.
    if (path.startsWith('$_repoPath/contents/')) {
      if (request.method == 'GET') return _json({'sha': 'upstream-file'});
      if (request.method == 'PUT') return _json({}, 201);
    }
    throw StateError('Unexpected request: ${request.method} ${request.url}');
  });

  Iterable<http.Request> get mutations =>
      requests.where((r) => r.method != 'GET');

  void expectNoFallback() {
    expect(requests.where((r) => r.url.path.contains('/contents/')), isEmpty);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = RepoCache.I;
  late _GitFixture git;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache.unbind();
    cache.retryBaseDelay = Duration.zero;
    cache.bind('owner/repo', 'tok', branch: 'feature/x', sessionId: 's1');
    cache.write('a.md', 'approved a');
    cache.write('b.md', 'approved b');
    git = _GitFixture();
  });
  tearDown(() {
    git.client.close();
    cache.unbind();
    cache.retryBaseDelay = const Duration(milliseconds: 500);
    cache.requestTimeout = const Duration(seconds: 20);
  });

  void expectPending() {
    expect(cache.dirtyCount, 2);
    expect(cache.read('a.md'), 'approved a');
    expect(cache.read('b.md'), 'approved b');
    expect(cache.lastCommit, isNull);
    git.expectNoFallback();
  }

  for (final failure in ['network', '503', '401', '404']) {
    test('ref read $failure fails before any blob or fallback', () async {
      git.intercept = (r) {
        if (r.url.path != _refPath) return null;
        if (failure == 'network') throw http.ClientException('offline');
        return http.Response('ref unavailable', int.parse(failure));
      };
      await expectLater(
        cache.commitAll('msg', client: git.client),
        throwsA(isA<Exception>()),
      );
      expect(git.mutations, isEmpty);
      expectPending();
    });
  }

  for (final stage in ['blobs', 'trees', 'commits']) {
    for (final failure in ['network', '503', '409', '422']) {
      test('$stage $failure is never replayed or changed into PUTs', () async {
        var failedRequests = 0;
        git.intercept = (r) {
          if (r.method != 'POST' || r.url.path != '$_repoPath/git/$stage') {
            return null;
          }
          failedRequests++;
          if (failure == 'network') throw http.ClientException('lost response');
          return http.Response('create failed', int.parse(failure));
        };
        await expectLater(
          cache.commitAll('msg', client: git.client),
          throwsA(isA<Exception>()),
        );
        // Two distinct blob requests may already be in the bounded pool.
        expect(failedRequests, stage == 'blobs' ? 2 : 1);
        expect(git.requests.where((r) => r.method == 'PATCH'), isEmpty);
        expectPending();
      });
    }
  }

  for (final status in [409, 422]) {
    test(
      'upstream advance causing ref $status is an actionable conflict',
      () async {
        git.intercept = (r) {
          if (r.method != 'PATCH') return null;
          git.tip = 'upstream-edit';
          return http.Response('Update is not a fast forward', status);
        };
        await expectLater(
          cache.commitAll('msg', client: git.client),
          throwsA(
            predicate(
              (Object e) =>
                  '$e'.contains('conflict') && '$e'.contains('$status'),
            ),
          ),
        );
        final patch = git.requests.singleWhere((r) => r.method == 'PATCH');
        expect(jsonDecode(patch.body), {
          'sha': 'intended-commit',
          'force': false,
        });
        expect(git.tip, 'upstream-edit');
        expectPending();
      },
    );
  }

  for (final failure in ['connection', 'timeout', '503']) {
    test(
      'accepted ref then $failure reconciles without duplicate mutations',
      () async {
        git.intercept = (r) {
          if (r.method != 'PATCH') return null;
          git.tip = 'intended-commit';
          if (failure == '503') return http.Response('proxy error', 503);
          if (failure == 'timeout') throw TimeoutException('lost response');
          throw http.ClientException('lost response');
        };
        expect(await cache.commitAll('msg', client: git.client), 2);
        expect(cache.hasPending, isFalse);
        expect(cache.lastCommit?.mode, CommitMode.atomic);
        expect(cache.lastCommit?.commitSha, 'intended-commit');
        expect(git.requests.where((r) => r.method == 'PATCH').length, 1);
        expect(git.requests.where((r) => r.url.path == _refPath).length, 3);
        expect(
          git.requests.where((r) => r.url.path.endsWith('/commits')).length,
          1,
        );
        git.expectNoFallback();
      },
    );
  }

  for (final result in [
    'base-commit',
    'upstream-edit',
    'unreadable',
    'malformed',
  ]) {
    test('lost ref response with $result remains unknown and dirty', () async {
      var patchSent = false;
      git.intercept = (r) {
        if (r.method == 'PATCH') {
          patchSent = true;
          throw http.ClientException('lost response');
        }
        if (patchSent && r.url.path == _refPath) {
          if (result == 'unreadable') return http.Response('unavailable', 503);
          if (result == 'malformed') return _json({'object': {}});
          return _ref(result);
        }
        return null;
      };
      await expectLater(
        cache.commitAll('msg', client: git.client),
        throwsA(
          predicate(
            (Object e) =>
                '$e'.contains('unknown') &&
                '$e'.contains('intended-commit') &&
                '$e'.contains('feature/x') &&
                !'$e'.contains('nothing was pushed'),
          ),
        ),
      );
      expect(git.requests.where((r) => r.method == 'PATCH').length, 1);
      expectPending();
    });
  }

  test(
    'reconciliation clears only the pushed snapshot, retaining newer edits',
    () async {
      git.intercept = (r) {
        if (r.method == 'PATCH') {
          git.tip = 'intended-commit';
          cache.write('a.md', 'newer a');
          cache.write('c.md', 'new c');
          throw http.ClientException('lost response');
        }
        return null;
      };
      expect(await cache.commitAll('msg', client: git.client), 2);
      expect(cache.dirtyCount, 2);
      expect(cache.read('a.md'), 'newer a');
      expect(cache.read('c.md'), 'new c');
      final bodies = git.requests
          .where((r) => r.url.path.endsWith('/blobs'))
          .map(
            (r) => utf8.decode(
              base64Decode(jsonDecode(r.body)['content'] as String),
            ),
          )
          .toSet();
      expect(bodies, {'approved a', 'approved b'});
      git.expectNoFallback();
    },
  );

  test(
    'actual PATCH timeout reconciles while its response is still pending',
    () async {
      final release = Completer<http.Response>();
      cache.requestTimeout = const Duration(milliseconds: 50);
      git.intercept = (r) {
        if (r.method != 'PATCH') return null;
        git.tip = 'intended-commit';
        return release.future;
      };
      try {
        expect(await cache.commitAll('msg', client: git.client), 2);
        expect(release.isCompleted, isFalse);
        expect(cache.hasPending, isFalse);
        expect(cache.lastCommit?.commitSha, 'intended-commit');
        expect(git.requests.where((r) => r.method == 'PATCH').length, 1);
        git.expectNoFallback();
      } finally {
        release.complete(_ref('intended-commit'));
      }
    },
  );

  test(
    'late acceptance after unknown timeout cannot clear newer drafts',
    () async {
      final release = Completer<http.Response>();
      cache.requestTimeout = const Duration(milliseconds: 50);
      git.intercept = (r) {
        if (r.method != 'PATCH') return null;
        return release.future;
      };
      try {
        await expectLater(
          cache.commitAll('msg', client: git.client),
          throwsA(predicate((Object e) => '$e'.contains('unknown'))),
        );
        cache.write('a.md', 'newer draft');
        git.tip = 'intended-commit';
        release.complete(_ref('intended-commit'));
        await pumpEventQueue();
        expect(cache.dirtyCount, 2);
        expect(cache.read('a.md'), 'newer draft');
        expect(cache.lastCommit, isNull);
        expect(git.requests.where((r) => r.method == 'PATCH').length, 1);
        git.expectNoFallback();
      } finally {
        if (!release.isCompleted) release.complete(_ref('intended-commit'));
      }
    },
  );

  test('conflict preserves edits arriving after the commit snapshot', () async {
    git.intercept = (r) {
      if (r.method != 'PATCH') return null;
      cache.write('a.md', 'newer draft');
      cache.write('c.md', 'new file');
      return http.Response('not fast forward', 409);
    };
    await expectLater(
      cache.commitAll('msg', client: git.client),
      throwsA(predicate((Object e) => '$e'.contains('conflict'))),
    );
    expect(cache.dirtyCount, 3);
    expect(cache.read('a.md'), 'newer draft');
    expect(cache.read('b.md'), 'approved b');
    expect(cache.read('c.md'), 'new file');
    expect(cache.lastCommit, isNull);
    git.expectNoFallback();
  });

  test(
    'a later unknown attempt does not replace last successful commit info',
    () async {
      expect(await cache.commitAll('first', client: git.client), 2);
      final previous = cache.lastCommit;
      cache.write('a.md', 'second draft');
      git.tip = 'base-commit';
      git.intercept = (r) {
        if (r.method == 'PATCH') throw http.ClientException('lost response');
        return null;
      };
      await expectLater(
        cache.commitAll('second', client: git.client),
        throwsA(predicate((Object e) => '$e'.contains('unknown'))),
      );
      expect(cache.lastCommit, same(previous));
      expect(cache.dirtyCount, 1);
      expect(cache.read('a.md'), 'second draft');
      git.expectNoFallback();
    },
  );

  for (final status in [401, 403, 404, 405, 429]) {
    test('ref rejection $status preserves drafts without fallback', () async {
      git.intercept = (r) =>
          r.method == 'PATCH' ? http.Response('rejected', status) : null;
      await expectLater(
        cache.commitAll('msg', client: git.client),
        throwsA(predicate((Object e) => '$e'.contains('$status'))),
      );
      expect(git.requests.where((r) => r.method == 'PATCH').length, 1);
      expectPending();
    });
  }

  for (final stage in [
    'ref retry',
    'mode read',
    'blob',
    'tree',
    'commit',
    'patch',
    'patch loss',
    'reconcile',
    'reconcile retry',
  ]) {
    test(
      'late rebind at $stage fences requests and dirty publication',
      () async {
        // One blob avoids conflating already-dispatched pool requests with a
        // request newly started after the binding changed.
        cache.remove('b.md');
        var patchSent = false;
        var switched = false;
        int? requestsAtSwitch;
        git.intercept = (r) {
          final hit = switch (stage) {
            'ref retry' => r.url.path == _refPath,
            'mode read' =>
              r.method == 'GET' && r.url.path.contains('/git/trees/'),
            'blob' => r.url.path.endsWith('/blobs'),
            'tree' => r.method == 'POST' && r.url.path.endsWith('/trees'),
            'commit' => r.url.path.endsWith('/commits'),
            'patch' || 'patch loss' => r.method == 'PATCH',
            _ => patchSent && r.url.path == _refPath,
          };
          if (hit && !switched) {
            switched = true;
            requestsAtSwitch = git.requests.length;
            cache.bind(
              'other/repo',
              'other-token',
              branch: 'main',
              sessionId: 's2',
            );
            cache.write('a.md', 'other draft');
            if (stage == 'ref retry' ||
                stage == 'reconcile retry' ||
                stage == 'patch loss') {
              throw http.ClientException('lost response');
            }
          }
          if (r.method == 'PATCH' && stage.startsWith('reconcile')) {
            patchSent = true;
            git.tip = 'intended-commit';
            throw http.ClientException('lost response');
          }
          return null;
        };
        await expectLater(
          cache.commitAll('msg', client: git.client),
          throwsA(isA<StateError>()),
        );
        expect(switched, isTrue);
        expect(git.requests.length, requestsAtSwitch);
        expect(cache.boundSessionId, 's2');
        expect(cache.read('a.md'), 'other draft');
        expect(cache.dirtyCount, 1);
        expect(cache.lastCommit, isNull);
        git.expectNoFallback();
        cache.bind('owner/repo', 'tok', branch: 'feature/x', sessionId: 's1');
        expect(cache.dirtyCount, 1);
        expect(cache.read('a.md'), 'approved a');
        expect(cache.lastCommit, isNull);
      },
    );
  }
}
