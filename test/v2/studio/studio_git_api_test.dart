// The Studio git client speaks the COMMITTED gateway contract, read from
//   cloud/apps/gateway/src/routes/studio.ts
//   cloud/apps/gateway/src/studioGithub.ts
//   cloud/apps/gateway/src/studioGit.ts
// on the web/cloud branch. The server is the contract:
//
//   GET  /studio/github                              -> {connected, login, source}
//   GET  /studio/repos?page&perPage                   -> {items, page, perPage, hasMore}
//   GET  /studio/repos/:owner/:repo/branches?page&perPage
//                                                    -> {items, page, perPage, hasMore}
//   GET  /studio/sessions/:id/git                     -> {sessionId, repo, git}
//   POST /studio/sessions/:id/git/clone               -> 201 {sessionId, repo, repoDir, branch, bindingStored}
//   POST /studio/sessions/:id/git/branch              -> {status, branch, stashed, message}
//   POST /studio/sessions/:id/git/sync                -> {status, dirty, behind, ahead, branch, message}
//
// The git half answers 503 `studio_git_unavailable` until the worker
// transport lands. That refusal must surface as a typed, honest failure —
// never as a fake success.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_git_api.dart';

const String _base = 'https://cloud.test/cloud/v1';
const String _localSession = 'local-session';
const String _serverSession = '0199aaaa-0000-7000-8000-00000000e001';

void main() {
  late List<http.Request> requests;

  StudioGitApi apiWith(
    Future<http.Response> Function(http.Request) handler, {
    Map<String, String> idMap = const <String, String>{
      _localSession: _serverSession,
    },
  }) {
    requests = <http.Request>[];
    return StudioGitApi(
      rest: CloudRestClient(
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
        headers: CloudHeaders.forTest(),
        restBase: _base,
      ),
      sessions: CloudSessionStore.forTest(idMap: idMap),
    );
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  group('connection', () {
    test('a connected account answers its login', () async {
      final api = apiWith(
        (r) async =>
            json({'connected': true, 'login': 'octocat', 'source': 'mcp'}),
      );

      final connection = await api.github();

      expect(requests.single.method, 'GET');
      expect(requests.single.url.toString(), '$_base/studio/github');
      expect(connection.connected, isTrue);
      expect(connection.login, 'octocat');
      expect(connection.source, 'mcp');
    });

    test('a disconnected account is a state, not an error', () async {
      final api = apiWith(
        (r) async => json({'connected': false, 'login': null, 'source': 'mcp'}),
      );

      final connection = await api.github();

      expect(connection.connected, isFalse);
      expect(connection.login, isNull);
    });
  });

  group('repos', () {
    test('reads a page and reports whether another exists', () async {
      final api = apiWith(
        (r) async => json({
          'items': [
            {
              'id': 42,
              'owner': 'acme',
              'name': 'app',
              'fullName': 'acme/app',
              'private': true,
              'defaultBranch': 'main',
              'description': 'The app',
              'updatedAt': '2026-10-01T10:00:00Z',
              'url': 'https://github.com/acme/app',
            },
          ],
          'page': 2,
          'perPage': 30,
          'hasMore': true,
        }),
      );

      final page = await api.repos(page: 2, perPage: 30);

      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/cloud/v1/studio/repos');
      expect(requests.single.url.queryParameters, {
        'page': '2',
        'perPage': '30',
      });
      expect(page.page, 2);
      expect(page.hasMore, isTrue);
      expect(page.items.single.fullName, 'acme/app');
      expect(page.items.single.defaultBranch, 'main');
      expect(page.items.single.isPrivate, isTrue);
      expect(page.items.single.description, 'The app');
    });

    test('a full page with no more items is honest about hasMore', () async {
      final api = apiWith(
        (r) async => json({
          'items': <Object>[],
          'page': 1,
          'perPage': 30,
          'hasMore': false,
        }),
      );

      final page = await api.repos();

      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });

  group('branches', () {
    test('encodes both path segments and parses the page', () async {
      final api = apiWith(
        (r) async => json({
          'items': [
            {'name': 'release/1.0', 'protected': true, 'commitSha': 'abc123'},
          ],
          'page': 1,
          'perPage': 30,
          'hasMore': false,
        }),
      );

      final page = await api.branches('acme', 'app', page: 1, perPage: 30);

      expect(
        requests.single.url.path,
        '/cloud/v1/studio/repos/acme/app/branches',
      );
      expect(requests.single.url.queryParameters, {
        'page': '1',
        'perPage': '30',
      });
      expect(page.items.single.name, 'release/1.0');
      expect(page.items.single.isProtected, isTrue);
      expect(page.items.single.commitSha, 'abc123');
    });
  });

  group('session git', () {
    test('maps the binding and the honest capability flag', () async {
      final api = apiWith(
        (r) async => json({
          'sessionId': _serverSession,
          'repo': {
            'repo': 'acme/app',
            'repoDir': 'app',
            'branch': 'main',
            'updatedAt': '2026-10-02T08:00:00Z',
          },
          'git': {'available': false, 'reason': 'studio_git_unavailable'},
        }),
      );

      final state = await api.sessionGit(_localSession);

      expect(
        requests.single.url.toString(),
        '$_base/studio/sessions/$_serverSession/git',
      );
      expect(state, isNotNull);
      expect(state!.binding?.repo, 'acme/app');
      expect(state.binding?.repoDir, 'app');
      expect(state.binding?.branch, 'main');
      expect(state.available, isFalse);
      expect(state.reason, 'studio_git_unavailable');
    });

    test('a chat with no server session is not asked for at all', () async {
      final api = apiWith(
        (r) async => json(<String, Object>{}),
        idMap: const <String, String>{},
      );

      final state = await api.sessionGit('never-sent');

      expect(state, isNull);
      expect(requests, isEmpty);
    });
  });

  group('git operations', () {
    test('clone posts owner/name and reports the stored binding', () async {
      final api = apiWith(
        (r) async => json({
          'sessionId': _serverSession,
          'repo': 'acme/app',
          'repoDir': 'app',
          'branch': 'dev',
          'bindingStored': true,
        }, 201),
      );

      final result = await api.clone(
        _localSession,
        repo: 'acme/app',
        branch: 'dev',
      );

      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.toString(),
        '$_base/studio/sessions/$_serverSession/git/clone',
      );
      expect(jsonDecode(requests.single.body), {
        'repo': 'acme/app',
        'branch': 'dev',
      });
      expect(result.repoDir, 'app');
      expect(result.branch, 'dev');
      expect(result.bindingStored, isTrue);
    });

    test('branch switch posts the branch and reports the outcome', () async {
      final api = apiWith(
        (r) async => json({
          'status': 'switched',
          'branch': 'dev',
          'stashed': true,
          'stashRef': 'stash@{0}',
          'stashNote': 'Saved 2 files',
          'message': 'Switched to dev.',
        }),
      );

      final result = await api.switchBranch(_localSession, branch: 'dev');

      expect(
        requests.single.url.toString(),
        '$_base/studio/sessions/$_serverSession/git/branch',
      );
      expect(jsonDecode(requests.single.body), {'branch': 'dev'});
      expect(result.status, 'switched');
      expect(result.stashed, isTrue);
      expect(result.stashRef, 'stash@{0}');
    });

    test('sync reports the real status, not a success claim', () async {
      final api = apiWith(
        (r) async => json({
          'status': 'needs_merge',
          'dirty': true,
          'behind': 3,
          'ahead': 1,
          'branch': 'main',
          'message': 'The branch has diverged.',
          'reason': 'diverged',
        }),
      );

      final result = await api.sync(_localSession);

      expect(
        requests.single.url.toString(),
        '$_base/studio/sessions/$_serverSession/git/sync',
      );
      expect(result.status, 'needs_merge');
      expect(result.dirty, isTrue);
      expect(result.behind, 3);
      expect(result.ahead, 1);
      expect(result.reason, 'diverged');
    });

    test('the 503 refusal is a typed honest failure', () async {
      final api = apiWith(
        (r) async => json({
          'error': {
            'code': 'studio_git_unavailable',
            'message':
                'Git operations are not available on this deployment yet.',
          },
        }, 503),
      );

      await expectLater(
        api.clone(_localSession, repo: 'acme/app'),
        throwsA(
          isA<StudioGitUnavailableException>().having(
            (e) => e.message,
            'message',
            'Git operations are not available on this deployment yet.',
          ),
        ),
      );
    });

    test('a 409 no_repo on sync keeps the server message', () async {
      final api = apiWith(
        (r) async => json({
          'error': {
            'code': 'no_repo',
            'message': 'Clone a repository into this session before syncing.',
          },
        }, 409),
      );

      await expectLater(
        api.sync(_localSession),
        throwsA(
          isA<CloudApiException>()
              .having((e) => e.code, 'code', 'no_repo')
              .having(
                (e) => e.message,
                'message',
                'Clone a repository into this session before syncing.',
              ),
        ),
      );
    });
  });
}
