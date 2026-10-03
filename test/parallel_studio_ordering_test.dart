import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'repo_cache_approval_test.dart' show ApprovalGit;

MockClient snapshot(String content) => MockClient((request) async =>
    request.url.path.contains('/git/trees/')
        ? http.Response(jsonEncode({'truncated': false, 'tree': [
            {'type': 'blob', 'path': 'a.txt'},
          ]}), 200)
        : http.Response(content, 200));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = RepoCache.I;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache.unbind();
    cache.bind('owner/repo', 'token', sessionId: 'studio');
  });
  tearDown(cache.unbind);

  for (final fetchFirst in [true, false]) {
    test('failed newer read cannot delete sync download (fetch first: $fetchFirst)', () async {
      final entered = Completer<void>();
      final download = Completer<http.Response>();
      final fetchReply = Completer<http.Response>();
      final syncing = cache.sync(client: MockClient((r) async {
        if (r.url.path.contains('/git/trees/')) {
          return http.Response(jsonEncode({'tree': [{'type': 'blob', 'path': 'a.txt'}]}), 200);
        }
        entered.complete();
        return download.future;
      }));
      await entered.future;
      final fetching = cache.fetchFileResult('a.txt', client: MockClient((_) => fetchReply.future));
      if (fetchFirst) {
        fetchReply.complete(http.Response('missing', 404));
        expect((await fetching).failure, FetchFailure.notFound);
      }
      download.complete(http.Response('valid sync bytes', 200));
      final report = await syncing;
      if (!fetchFirst) {
        fetchReply.complete(http.Response('missing', 404));
        await fetching;
      }
      expect(cache.read('a.txt'), 'valid sync bytes');
      expect(cache.treePaths, contains('a.txt'));
      expect(report.fetched, 1);
      expect(report.partial, isFalse);
      expect(cache.hasPending, isFalse);
    });
  }

  test('older sync cannot publish after a newer sync', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final client = MockClient((request) {
      entered.complete();
      return release.future;
    });
    final old = cache.sync(client: client);
    final rejected = expectLater(old, throwsStateError);
    await entered.future;
    final latest = await cache.sync(client: snapshot('new snapshot'));
    release.complete(http.Response(jsonEncode({'tree': []}), 200));
    await rejected;
    expect(cache.read('a.txt'), 'new snapshot');
    expect(cache.lastSyncReport, same(latest));
  });

  test('reversed on-demand fetches return and retain the newest owned bytes', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final old = cache.fetchFileResult('a.txt', client: MockClient((_) {
      entered.complete();
      return release.future;
    }));
    await entered.future;
    await cache.fetchFileResult('a.txt', client: snapshot('new fetch'));
    release.complete(http.Response('old fetch', 200));
    expect((await old).content, 'new fetch');
    expect(cache.read('a.txt'), 'new fetch');
  });

  test('late fetch returns the local edit instead of handing stale bytes to Studio', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final result = cache.fetchFileResult('a.txt', client: MockClient((_) {
      entered.complete();
      return release.future;
    }));
    await entered.future;
    cache.write('a.txt', 'new draft');
    release.complete(http.Response('upstream', 200));
    expect((await result).content, 'new draft');
    expect(cache.read('a.txt'), 'new draft');
    expect(cache.pendingPaths, ['a.txt']);
  });

  test('a sync started before commit cannot restore pre-commit bytes', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final slow = MockClient((r) {
      if (r.url.path.contains('/git/trees/')) {
        return Future.value(http.Response(jsonEncode({'tree': [
          {'type': 'blob', 'path': 'a.txt'},
        ]}), 200));
      }
      entered.complete();
      return release.future;
    });
    final syncing = cache.sync(client: slow);
    await entered.future;
    cache.write('a.txt', 'committed');
    final git = ApprovalGit();
    expect(await cache.commitAll('save', client: git.client), 1);
    release.complete(http.Response('pre-commit', 200));
    await syncing;
    expect(cache.read('a.txt'), 'committed');
    expect(cache.hasPending, isFalse);
  });

  test('partial downloads retain previously fetched clean files', () async {
    await cache.sync(client: snapshot('known bytes'));
    final report = await cache.sync(client: MockClient((r) async =>
        r.url.path.contains('/git/trees/')
            ? http.Response(jsonEncode({'tree': [
                {'type': 'blob', 'path': 'a.txt'},
              ]}), 200)
            : http.Response('missing', 404)));
    expect(report.partial, isTrue);
    expect(report.failedPaths, ['a.txt']);
    expect(report.fetched, 0);
    expect(cache.read('a.txt'), 'known bytes');
  });

  test('failed sync cleanup retains ordinary remote drafts', () {
    cache.write('a.txt', 'unsent draft');
    cache.clearWorkingCopy();
    expect(cache.read('a.txt'), 'unsent draft');
    expect(cache.pendingPaths, ['a.txt']);
  });
}
