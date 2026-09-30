import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/repo_cache.dart';

/// Regression tests for the repo-cache audit 2026-09-25 (data-loss findings).
///
/// Every case drives the real `RepoCache` singleton through a `MockClient`
/// (no network), mirroring `repo_branch_test.dart`. The findings covered:
///   §1 re-sync must preserve uncommitted edits (was: `_dirty.clear()`);
///   §2 partial repos must be reported, not announced as "synced ✓";
///   §3 the skip-list must match segment boundaries, not substrings;
///   §4 `commitAll` must be ONE atomic commit (blobs → tree → commit → ref);
///   §5 path segments are percent-encoded individually (slashes preserved);
///   §6 `fetchFile` caches and distinguishes no-token/401/404;
///   §7 `bind` notifies listeners;
///   §8 transient failures retry; fetches overlap under a bounded pool.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    RepoCache.I.unbind();
    // Zero backoff keeps the retry tests fast; restored in tearDown.
    RepoCache.I.retryBaseDelay = Duration.zero;
  });
  tearDown(() {
    RepoCache.I.unbind();
    RepoCache.I.retryBaseDelay = const Duration(milliseconds: 500);
    RepoCache.I.requestTimeout = const Duration(seconds: 20);
  });

  /// MockClient serving a recursive tree of [blobs] plus raw contents.
  /// [statusByPath]/[bodyByPath] are keyed by the DECODED repo-relative path.
  MockClient gitClient({
    required List<String> blobs,
    Map<String, int> statusByPath = const {},
    Map<String, String> bodyByPath = const {},
    bool truncated = false,
    List<Uri>? log,
  }) {
    return MockClient((request) async {
      log?.add(request.url);
      final p = request.url.path;
      if (p.contains('/git/trees/')) {
        return http.Response(
          jsonEncode({
            'truncated': truncated,
            'tree': [
              for (final b in blobs) {'type': 'blob', 'path': b},
            ],
          }),
          200,
        );
      }
      const marker = '/contents/';
      final rel = Uri.decodeComponent(p.substring(p.indexOf(marker) + marker.length));
      return http.Response(
        bodyByPath[rel] ?? 'body of $rel',
        statusByPath[rel] ?? 200,
      );
    });
  }

  group('audit §1 — re-sync preserves uncommitted edits', () {
    test('a dirty file keeps the local edit over refreshed upstream content', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['README.md', 'lib/a.dart'],
          bodyByPath: const {'README.md': 'v1'},
        ),
      );
      expect(RepoCache.I.files['README.md'], 'v1');

      RepoCache.I.write('README.md', 'LOCAL EDIT');

      await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['README.md', 'lib/a.dart'],
          bodyByPath: const {'README.md': 'v2'},
        ),
      );

      expect(
        RepoCache.I.files['README.md'],
        'LOCAL EDIT',
        reason: 'a re-sync must never clobber uncommitted work',
      );
      expect(RepoCache.I.hasPending, isTrue);
      expect(
        RepoCache.I.files['lib/a.dart'],
        'body of lib/a.dart',
        reason: 'clean files still refresh from upstream',
      );
    });

    test('a dirty file removed from the upstream tree survives the re-sync', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(
        client: gitClient(blobs: const ['README.md', 'notes.md']),
      );
      RepoCache.I.write('notes.md', 'keep me');

      await RepoCache.I.sync(client: gitClient(blobs: const ['README.md']));

      expect(RepoCache.I.files['notes.md'], 'keep me');
      expect(RepoCache.I.hasPending, isTrue);
      expect(
        RepoCache.I.treePaths,
        contains('notes.md'),
        reason: 'pending local work must stay visible in the tree',
      );
    });

    test('the dirty flag drops once upstream already matches the local edit', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['a.md'],
          bodyByPath: const {'a.md': 'same'},
        ),
      );
      RepoCache.I.write('a.md', 'same');
      expect(RepoCache.I.hasPending, isTrue);

      await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['a.md'],
          bodyByPath: const {'a.md': 'same'},
        ),
      );

      expect(RepoCache.I.files['a.md'], 'same');
      expect(RepoCache.I.hasPending, isFalse);
    });
  });

  group('audit §3 — skip-list matches segments, not substrings', () {
    test('false-positive substrings stay; true positives go', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      await RepoCache.I.sync(
        client: gitClient(blobs: const [
          // False positives of `p.contains(s)` — must be KEPT:
          'lib/foo.binding.dart', // '.bin'
          'src/rebuild/gen.dart', // 'build/'
          'notes.png.md', // '.png'
          // True positives — must be SKIPPED:
          'build/output.o',
          'foo/build/x.dart',
          'assets/logo.PNG', // extension match is case-insensitive
          'assets/icon.png',
          'node_modules/pkg/index.js',
          '.git/config',
          'android/app/build/intermediate/x',
          'ios/Pods/Manifest.lock',
          'vendor/main.bin',
          // Kept:
          'main.dart',
        ]),
      );

      expect(RepoCache.I.files.keys.toSet(), {
        'lib/foo.binding.dart',
        'src/rebuild/gen.dart',
        'notes.png.md',
        'main.dart',
      });
      // treePaths keeps the deterministic tree order; `files` insertion order
      // follows pool completion, so compare as sets.
      expect(RepoCache.I.treePaths.toSet(), RepoCache.I.files.keys.toSet());
    });

    test('the predicate matches directory segments and extensions exactly', () {
      // Directory patterns: segment boundaries only.
      expect(RepoCache.shouldSkipPath('build/x'), isTrue);
      expect(RepoCache.shouldSkipPath('a/build/x'), isTrue);
      expect(RepoCache.shouldSkipPath('src/rebuild/x.dart'), isFalse);
      expect(RepoCache.shouldSkipPath('rebuild/x.dart'), isFalse);
      expect(RepoCache.shouldSkipPath('node_modules/a/b'), isTrue);
      expect(RepoCache.shouldSkipPath('x/node_modules/a'), isTrue);
      expect(RepoCache.shouldSkipPath('my_node_modules/a'), isFalse);
      expect(RepoCache.shouldSkipPath('.git/config'), isTrue);
      expect(RepoCache.shouldSkipPath('a/.git/config'), isTrue);
      expect(RepoCache.shouldSkipPath('android/app/build/x'), isTrue);
      expect(RepoCache.shouldSkipPath('ios/Pods/x'), isTrue);
      expect(RepoCache.shouldSkipPath('.dart_tool/x'), isTrue);
      expect(RepoCache.shouldSkipPath('dist/x'), isTrue);
      // Extensions: exact suffix, case-insensitive.
      expect(RepoCache.shouldSkipPath('a/b.PNG'), isTrue);
      expect(RepoCache.shouldSkipPath('a/b.PnG'), isTrue);
      expect(RepoCache.shouldSkipPath('notes.png.md'), isFalse);
      expect(RepoCache.shouldSkipPath('lib/foo.binding.dart'), isFalse);
      expect(RepoCache.shouldSkipPath('x.bin'), isTrue);
      expect(RepoCache.shouldSkipPath('x.BIN'), isTrue);
      expect(RepoCache.shouldSkipPath('main.dart'), isFalse);
      expect(RepoCache.shouldSkipPath('README.md'), isFalse);
    });
  });

  group('audit §5 — per-segment path encoding', () {
    test('contents requests preserve slashes and encode each segment', () async {
      final log = <Uri>[];
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['docs/my file.md', 'a/b/c.dart', 'weird#1.md'],
          log: log,
        ),
      );

      final contents = log
          .where((u) => u.path.contains('/contents/'))
          .map((u) => u.path)
          .toList();
      expect(
        contents,
        containsAll(<String>[
          '/repos/owner/repo/contents/docs/my%20file.md',
          '/repos/owner/repo/contents/a/b/c.dart',
          '/repos/owner/repo/contents/weird%231.md',
        ]),
      );
      expect(
        contents.any((p) => p.contains('%2F')),
        isFalse,
        reason: 'path separators must never be encoded as %2F',
      );
    });
  });

  group('audit §7 — bind notifies', () {
    test('bind notifies listeners before sync runs', () {
      var notifications = 0;
      void listener() => notifications++;
      RepoCache.I.addListener(listener);
      addTearDown(() => RepoCache.I.removeListener(listener));

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      expect(notifications, greaterThan(0));
    });
  });

  group('audit §4 — commitAll is one atomic commit', () {
    test('N dirty files produce ONE commit and ONE ref update', () async {
      final calls = <({String method, String path, Map<String, dynamic>? body})>[];
      final client = MockClient((request) async {
        final body = request.body.isEmpty
            ? null
            : jsonDecode(request.body) as Map<String, dynamic>;
        calls.add((method: request.method, path: request.url.path, body: body));
        final p = request.url.path;
        if (p.startsWith('/repos/owner/repo/git/ref/')) {
          return http.Response(
            jsonEncode({
              'ref': 'refs/heads/feature/x',
              'object': {'type': 'commit', 'sha': 'base-commit'},
            }),
            200,
          );
        }
        if (p == '/repos/owner/repo/git/trees/base-commit') {
          return http.Response(
            jsonEncode({
              'tree': [
                {'path': 'README.md', 'mode': '100644', 'type': 'blob', 'sha': 'b0'},
                {'path': 'tool.sh', 'mode': '100755', 'type': 'blob', 'sha': 'b1'},
              ],
            }),
            200,
          );
        }
        if (p == '/repos/owner/repo/git/blobs') {
          return http.Response(jsonEncode({'sha': 'blob-${calls.length}'}), 201);
        }
        if (p == '/repos/owner/repo/git/trees' && request.method == 'POST') {
          return http.Response(jsonEncode({'sha': 'new-tree'}), 201);
        }
        if (p == '/repos/owner/repo/git/commits') {
          return http.Response(jsonEncode({'sha': 'new-commit'}), 201);
        }
        if (request.method == 'PATCH') {
          return http.Response(jsonEncode({'object': {'sha': 'new-commit'}}), 200);
        }
        return http.Response('unexpected ${request.method} $p', 404);
      });

      RepoCache.I.bind('owner/repo', 'tok', branch: 'feature/x', sessionId: 's1');
      RepoCache.I.write('README.md', 'updated');
      RepoCache.I.write('tool.sh', '#!/bin/sh\necho hi');
      RepoCache.I.create('lib/new.dart', 'void main() {}');

      final n = await RepoCache.I.commitAll('one commit', client: client);

      expect(n, 3);
      expect(RepoCache.I.hasPending, isFalse);
      expect(
        calls.where((c) => c.method == 'PATCH').length,
        1,
        reason: 'exactly one ref update',
      );
      expect(
        calls.where((c) => c.path.contains('/contents/')),
        isEmpty,
        reason: 'the atomic path never touches the contents API',
      );
      expect(
        calls.where((c) => c.path == '/repos/owner/repo/git/blobs').length,
        3,
        reason: 'one blob per dirty file',
      );

      final treeCall = calls.firstWhere(
        (c) => c.method == 'POST' && c.path == '/repos/owner/repo/git/trees',
      );
      expect(treeCall.body!['base_tree'], 'base-commit');
      final entries = (treeCall.body!['tree'] as List).cast<Map<String, dynamic>>();
      expect(entries.length, 3);
      final byPath = {for (final e in entries) e['path'] as String: e};
      expect(
        byPath['tool.sh']!['mode'],
        '100755',
        reason: 'the exec bit of an existing file is preserved',
      );
      expect(byPath['README.md']!['mode'], '100644');
      expect(
        byPath['lib/new.dart']!['mode'],
        '100644',
        reason: 'new files default to a regular blob',
      );
      for (final e in entries) {
        expect(e['type'], 'blob');
        expect(e['sha'], startsWith('blob-'));
      }

      final commitCall = calls.firstWhere(
        (c) => c.path == '/repos/owner/repo/git/commits',
      );
      expect(commitCall.body!['message'], 'one commit');
      expect(commitCall.body!['tree'], 'new-tree');
      expect(commitCall.body!['parents'], ['base-commit']);

      final patch = calls.firstWhere((c) => c.method == 'PATCH');
      expect(patch.path, '/repos/owner/repo/git/refs/heads/feature/x');
      expect(patch.body!['sha'], 'new-commit');
      expect(patch.body!['force'], isNot(equals(true)));
    });

    test('falls back to per-file commits when the Git Data API fails', () async {
      final reqs = <String>[];
      final client = MockClient((request) async {
        reqs.add('${request.method} ${request.url.path}');
        final p = request.url.path;
        if (p.contains('/git/')) {
          // e.g. a fine-grained token without Git Data API access
          return http.Response('forbidden', 403);
        }
        if (request.method == 'GET' && p.contains('/contents/')) {
          return http.Response(jsonEncode({'sha': 'old-sha'}), 200);
        }
        if (request.method == 'PUT' && p.contains('/contents/')) {
          return http.Response('{}', 200);
        }
        return http.Response('?', 404);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      RepoCache.I.write('a.md', '1');
      RepoCache.I.write('b.md', '2');

      final n = await RepoCache.I.commitAll('msg', client: client);

      expect(n, 2);
      expect(RepoCache.I.hasPending, isFalse);
      expect(
        reqs.where((s) => s.startsWith('PUT ')).length,
        2,
        reason: 'both files still land via the contents API',
      );
      expect(
        reqs.any((s) => s.contains('/git/')),
        isTrue,
        reason: 'the atomic path must be attempted first',
      );
    });

    test('a mid-fallback failure reports the partial push honestly', () async {
      var puts = 0;
      final client = MockClient((request) async {
        final p = request.url.path;
        if (p.contains('/git/')) return http.Response('nope', 403);
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'sha': 's'}), 200);
        }
        puts++;
        return puts == 1
            ? http.Response('{}', 200)
            : http.Response('gone', 404);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      RepoCache.I.write('a.md', '1');
      RepoCache.I.write('b.md', '2');

      await expectLater(
        RepoCache.I.commitAll('msg', client: client),
        throwsA(
          predicate(
            (Object e) => '$e'.contains('partial') && '$e'.contains('1/2'),
            'error names the partial push count',
          ),
        ),
      );
      expect(
        RepoCache.I.dirtyCount,
        1,
        reason: 'the file that never landed stays pending',
      );
      expect(RepoCache.I.hasPending, isTrue);
    });
  });

  group('audit §2 — a partial sync tells the truth', () {
    test('per-file fetch failures surface instead of "repo synced ✓"', () async {
      final lines = <String>[];
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['ok.md', 'gone.md'],
          statusByPath: const {'gone.md': 404},
        ),
        onLine: lines.add,
      );

      expect(RepoCache.I.files.keys, ['ok.md']);
      expect(lines.last, contains('⚠'));
      expect(lines.last, contains('gone.md'));
    });
  });

  group('audit §8 — retry and bounded concurrency', () {
    test('a transient 503 is retried instead of silently dropping the file', () async {
      var hits = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'a.md'},
              ],
            }),
            200,
          );
        }
        hits++;
        if (hits < 3) return http.Response('unavailable', 503);
        return http.Response('recovered', 200);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(client: client);

      expect(RepoCache.I.files['a.md'], 'recovered');
      expect(hits, 3, reason: 'two transient failures then success');
    });

    test('content fetches overlap under a bounded pool', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final blobs = List.generate(6, (i) => 'f$i.md');
      final client = MockClient((request) async {
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                for (final b in blobs) {'type': 'blob', 'path': b},
              ],
            }),
            200,
          );
        }
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        inFlight--;
        return http.Response('x', 200);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(client: client);

      expect(RepoCache.I.files.length, 6);
      expect(maxInFlight, greaterThan(1), reason: 'requests must overlap');
      expect(maxInFlight, lessThanOrEqualTo(8), reason: 'but stay bounded');
    });

    test('the concurrency parameter caps the in-flight requests', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final blobs = List.generate(6, (i) => 'f$i.md');
      final client = MockClient((request) async {
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                for (final b in blobs) {'type': 'blob', 'path': b},
              ],
            }),
            200,
          );
        }
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return http.Response('x', 200);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(client: client, concurrency: 2);

      expect(RepoCache.I.files.length, 6);
      expect(maxInFlight, lessThanOrEqualTo(2));
      expect(maxInFlight, greaterThan(1));
    });

    test('429 with Retry-After is retried instead of dropping the file', () async {
      var hits = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'a.md'},
              ],
            }),
            200,
          );
        }
        hits++;
        if (hits < 3) {
          return http.Response('rate limited', 429, headers: {'retry-after': '0'});
        }
        return http.Response('recovered', 200);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(client: client);

      expect(RepoCache.I.files['a.md'], 'recovered');
      expect(hits, 3);
    });

    test('a non-transient 404 is not retried', () async {
      var hits = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'gone.md'},
              ],
            }),
            200,
          );
        }
        hits++;
        return http.Response('nope', 404);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      final report = await RepoCache.I.sync(client: client);

      expect(hits, 1, reason: 'a missing file is a fact, not a transient fault');
      expect(report.failedPaths, ['gone.md']);
    });

    test('an overall deadline stops the sync and reports the skipped files', () async {
      final blobs = List.generate(10, (i) => 'f$i.md');
      final client = MockClient((request) async {
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                for (final b in blobs) {'type': 'blob', 'path': b},
              ],
            }),
            200,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return http.Response('x', 200);
      });

      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      final report = await RepoCache.I.sync(
        client: client,
        deadline: const Duration(milliseconds: 250),
        concurrency: 2,
      );

      expect(report.fetched, inInclusiveRange(2, 4));
      expect(report.deadlineExceeded, isTrue);
      expect(report.unattemptedPaths.length, 10 - report.fetched);
      expect(report.partial, isTrue);
      expect(report.summary.toLowerCase(), contains('deadline'));
      expect(RepoCache.I.files.length, report.fetched);
    });
  });

  group('audit §2 — SyncReport tells the truth', () {
    test('a truncated tree is reported, not silently accepted', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      final report = await RepoCache.I.sync(
        client: gitClient(blobs: const ['a.md'], truncated: true),
      );

      expect(report.treeTruncated, isTrue);
      expect(report.partial, isTrue);
      expect(report.summary.toLowerCase(), contains('truncat'));
      expect(RepoCache.I.lastSyncReport, same(report));
    });

    test('the maxFiles cap is counted and reported', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      final report = await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['a.md', 'b.md', 'c.md', 'd.md', 'e.md'],
        ),
        maxFiles: 2,
      );

      expect(report.requested, 2);
      expect(report.fetched, 2);
      expect(report.droppedByCap, 3);
      expect(report.partial, isTrue);
      expect(report.summary, contains('3'));
      expect(RepoCache.I.files.length, 2);
    });

    test('failed fetches and filtered binaries are counted separately', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      final report = await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['ok.md', 'gone.md', 'assets/logo.png'],
          statusByPath: const {'gone.md': 404},
        ),
      );

      expect(report.fetched, 1);
      expect(report.failedPaths, ['gone.md']);
      expect(report.skippedByFilter, 1);
      expect(report.requested, 2, reason: 'the filtered binary was never requested');
      expect(report.partial, isTrue);
      expect(report.summary, contains('gone.md'));
    });

    test('preserved local edits are listed on the report', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      await RepoCache.I.sync(client: gitClient(blobs: const ['a.md']));
      RepoCache.I.write('a.md', 'LOCAL');

      final report = await RepoCache.I.sync(
        client: gitClient(
          blobs: const ['a.md'],
          bodyByPath: const {'a.md': 'UPSTREAM'},
        ),
      );

      expect(report.preservedPaths, ['a.md']);
      expect(RepoCache.I.files['a.md'], 'LOCAL');
    });

    test('a clean full sync is not flagged partial', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      final report = await RepoCache.I.sync(
        client: gitClient(blobs: const ['a.md', 'b.md']),
      );

      expect(report.partial, isFalse);
      expect(report.fetched, 2);
      expect(report.requested, 2);
      expect(report.issues, isEmpty);
    });

    test('sync aborts loudly when contents start returning 401', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      final client = MockClient((request) async {
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'a.md'},
                {'type': 'blob', 'path': 'b.md'},
              ],
            }),
            200,
          );
        }
        return http.Response('bad credentials', 401);
      });

      await expectLater(
        RepoCache.I.sync(client: client),
        throwsA(predicate((Object e) => '$e'.contains('401'))),
      );
      expect(RepoCache.I.files, isEmpty);
    });
  });

  group('audit §6 — fetchFile caches and classifies failures', () {
    test('a successful fetch is cached into the working copy', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      final result = await RepoCache.I.fetchFileResult(
        'x.md',
        client: gitClient(blobs: const [], bodyByPath: const {'x.md': 'remote'}),
      );

      expect(result.ok, isTrue);
      expect(result.content, 'remote');
      expect(
        RepoCache.I.files['x.md'],
        'remote',
        reason: 'the docstring always promised caching',
      );
      expect(RepoCache.I.read('x.md'), 'remote');

      // The String? wrapper stays backward compatible and caches too.
      final again = await RepoCache.I.fetchFile(
        'y.md',
        client: gitClient(blobs: const [], bodyByPath: const {'y.md': 'y-body'}),
      );
      expect(again, 'y-body');
      expect(RepoCache.I.files['y.md'], 'y-body');
    });

    test('a cached fetch never clobbers a dirty local edit', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      RepoCache.I.write('d.md', 'local');

      final result = await RepoCache.I.fetchFileResult(
        'd.md',
        client: gitClient(blobs: const [], bodyByPath: const {'d.md': 'remote'}),
      );

      expect(result.content, 'remote');
      expect(RepoCache.I.files['d.md'], 'local');
      expect(RepoCache.I.hasPending, isTrue);
    });

    test('401, 404 and 5xx are distinguishable', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      expect(
        (await RepoCache.I.fetchFileResult(
          'a.md',
          client: _statusClient(401),
        )).failure,
        FetchFailure.unauthorized,
      );
      expect(
        (await RepoCache.I.fetchFileResult(
          'a.md',
          client: _statusClient(404),
        )).failure,
        FetchFailure.notFound,
      );
      var serverHits = 0;
      final server = MockClient((request) async {
        serverHits++;
        return http.Response('boom', 500);
      });
      final r = await RepoCache.I.fetchFileResult('a.md', client: server);
      expect(r.failure, FetchFailure.server);
      expect(serverHits, 3, reason: '5xx is transient and gets retried');
      expect(r.ok, isFalse);
      expect(r.content, isNull);
    });

    test('no token is reported without making a doomed request', () async {
      RepoCache.I.bind('owner/repo', '', sessionId: 's1');
      var requested = false;
      final client = MockClient((request) async {
        requested = true;
        return http.Response('x', 200);
      });

      final r = await RepoCache.I.fetchFileResult('a.md', client: client);

      expect(r.failure, FetchFailure.noToken);
      expect(requested, isFalse);
    });

    test('no binding is reported as notBound', () async {
      // setUp unbinds; no repo, no token.
      final r = await RepoCache.I.fetchFileResult('a.md');
      expect(r.failure, FetchFailure.notBound);
      expect(RepoCache.I.fetchFile('a.md'), completion(isNull));
    });

    test('a timeout is distinguishable from a missing file', () async {
      RepoCache.I.requestTimeout = const Duration(milliseconds: 40);
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return http.Response('late', 200);
      });

      final r = await RepoCache.I.fetchFileResult('slow.md', client: client);

      expect(r.failure, FetchFailure.timeout);
    });

    test('a network error is distinguishable from a 404', () async {
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');
      final client = MockClient((request) async {
        throw http.ClientException('connection reset');
      });

      final r = await RepoCache.I.fetchFileResult('a.md', client: client);

      expect(r.failure, FetchFailure.network);
    });
  });

  group('audit §4 — commitAll result surface', () {
    test('lastCommit describes the atomic commit', () async {
      final client = MockClient((request) async {
        final p = request.url.path;
        if (p.contains('/git/ref/')) {
          return http.Response(
            jsonEncode({
              'object': {'type': 'commit', 'sha': 'base-commit'},
            }),
            200,
          );
        }
        if (request.method == 'GET' && p.contains('/git/trees/')) {
          return http.Response(jsonEncode({'tree': []}), 200);
        }
        if (p.endsWith('/git/blobs')) {
          return http.Response(jsonEncode({'sha': 'blob-1'}), 201);
        }
        if (request.method == 'POST' && p.endsWith('/git/trees')) {
          return http.Response(jsonEncode({'sha': 'tree-1'}), 201);
        }
        if (p.endsWith('/git/commits')) {
          return http.Response(jsonEncode({'sha': 'commit-1'}), 201);
        }
        if (request.method == 'PATCH') return http.Response('{}', 200);
        return http.Response('?', 404);
      });

      RepoCache.I.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
      RepoCache.I.write('a.md', '1');
      RepoCache.I.write('b.md', '2');

      final n = await RepoCache.I.commitAll('msg', client: client);

      expect(n, 2);
      expect(RepoCache.I.lastCommit, isNotNull);
      expect(RepoCache.I.lastCommit!.mode, CommitMode.atomic);
      expect(RepoCache.I.lastCommit!.commitSha, 'commit-1');
      expect(RepoCache.I.lastCommit!.files, 2);
      expect(RepoCache.I.lastCommit!.branch, 'main');
    });

    test('commitAll with nothing pending makes no requests', () async {
      var requested = false;
      final client = MockClient((request) async {
        requested = true;
        return http.Response('{}', 200);
      });
      RepoCache.I.bind('owner/repo', 'tok', sessionId: 's1');

      expect(await RepoCache.I.commitAll('msg', client: client), 0);
      expect(requested, isFalse);
    });
  });
}

MockClient _statusClient(int status) =>
    MockClient((request) async => http.Response('x', status));

