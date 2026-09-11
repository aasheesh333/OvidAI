import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Repo + branch binding (spec §5.4).
///
/// The Studio binding is the pair `(repo, branch)`: the session carries the
/// branch, reads/writes carry `?ref=<branch>`, and a contents PUT fetches the
/// blob SHA on that branch (or the commit 409s).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatSession.branch', () {
    test('branch round-trips through JSON', () {
      final session = ChatSession(
        id: 's1',
        title: 'chat',
        model: 'model',
        branch: 'develop',
      );

      final json = session.toJson();

      expect(json['branch'], 'develop');
      expect(ChatSession.fromJson(json).branch, 'develop');
    });

    test('branch defaults to null and is omitted from JSON', () {
      final session = ChatSession(id: 's1', title: 'chat', model: 'model');

      expect(session.branch, isNull);
      expect(session.toJson().containsKey('branch'), isFalse);
      expect(
        ChatSession.fromJson({
          'id': 's1',
          'title': 'chat',
          'model': 'model',
        }).branch,
        isNull,
      );
    });
  });

  group('session branch selection', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
    });

    tearDown(AppState.resetTestInstance);

    test('newSession seeds the persisted last branch', () {
      final app = AppState.createForTest();
      app.lastBranch = 'release';

      app.newSession();

      expect(app.activeSession!.branch, 'release');
    });

    test('setBranchForSession updates the session and persists lastBranch', () async {
      final app = AppState.createForTest();
      final id = app.activeSession!.id;

      app.setBranchForSession(id, 'feature/x');
      await pumpEventQueue();

      expect(app.activeSession!.branch, 'feature/x');
      expect(app.getBranchForSession(id), 'feature/x');
      expect(app.lastBranch, 'feature/x');
    });

    test('getBranchForSession defaults to main when unset', () {
      final app = AppState.createForTest();
      final id = app.activeSession!.id;
      app.activeSession!.branch = null;

      expect(app.getBranchForSession(id), 'main');
    });
  });

  group('GitHubService.listBranches', () {
    const storage = FlutterSecureStorage();

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      await GitHubService.I.signOut();
    });

    tearDown(() async {
      await GitHubService.I.signOut();
    });

    Future<void> signIn() async {
      await storage.write(key: 'ovid_github_token', value: 'tok');
      await GitHubService.I.initialize(
        client: MockClient(
          (request) async => request.url.path == '/user'
              ? http.Response(jsonEncode({'login': 'octocat'}), 200)
              : http.Response('not found', 404),
        ),
      );
    }

    test('returns branch names from /branches?per_page=100', () async {
      await signIn();
      Uri? seen;
      final client = MockClient((request) async {
        seen = request.url;
        return http.Response(
          jsonEncode([
            {'name': 'main'},
            {'name': 'develop'},
          ]),
          200,
        );
      });

      final branches = await GitHubService.I.listBranches(
        'owner',
        'repo',
        client: client,
      );

      expect(branches, ['main', 'develop']);
      expect(seen!.path, '/repos/owner/repo/branches');
      expect(seen!.queryParameters['per_page'], '100');
      expect(client, isNotNull);
    });

    test('listRepoContent carries the branch ref', () async {
      await signIn();
      Uri? seen;
      final client = MockClient((request) async {
        seen = request.url;
        return http.Response(
          jsonEncode([
            {'name': 'README.md', 'type': 'file'},
          ]),
          200,
        );
      });

      await GitHubService.I.listRepoContent(
        owner: 'owner',
        repo: 'repo',
        branch: 'develop',
        client: client,
      );

      expect(seen!.queryParameters['ref'], 'develop');
    });
  });

  group('RepoCache branch threading', () {
    setUp(() {
      RepoCache.I.unbind();
    });

    tearDown(() {
      RepoCache.I.unbind();
    });

    test('bind records the owning session', () {
      RepoCache.I.bind('owner/repo', 'tok', branch: 'develop', sessionId: 's1');

      expect(RepoCache.I.defaultBranch, 'develop');
      expect(RepoCache.I.boundSessionId, 's1');

      RepoCache.I.bind('owner/repo', 'tok', branch: 'main', sessionId: 's2');
      expect(RepoCache.I.boundSessionId, 's2');
    });

    test('sync reads the tree and raw content on the bound branch', () async {
      final urls = <Uri>[];
      final client = MockClient((request) async {
        urls.add(request.url);
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'README.md'},
              ],
            }),
            200,
          );
        }
        return http.Response('hello', 200);
      });

      RepoCache.I.bind(
        'owner/repo',
        'tok',
        branch: 'develop',
        sessionId: 's1',
      );
      await RepoCache.I.sync(client: client);

      final tree = urls.firstWhere((u) => u.path.contains('/git/trees/'));
      expect(tree.path, contains('/git/trees/develop'));

      final raw = urls.firstWhere((u) => u.path.contains('/contents/'));
      expect(raw.queryParameters['ref'], 'develop');
      expect(RepoCache.I.files['README.md'], 'hello');
    });

    test('commitAll reads the SHA and commits on the bound branch', () async {
      Uri? shaUrl;
      Map<String, dynamic>? putBody;
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          shaUrl = request.url;
          return http.Response(jsonEncode({'sha': 'old-sha'}), 200);
        }
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });

      RepoCache.I.bind(
        'owner/repo',
        'tok',
        branch: 'feature/x',
        sessionId: 's1',
      );
      RepoCache.I.write('README.md', 'updated');

      final pushed = await RepoCache.I.commitAll('Update README', client: client);

      expect(pushed, 1);
      expect(shaUrl!.queryParameters['ref'], 'feature/x');
      expect(putBody!['branch'], 'feature/x');
    });
  });
}
