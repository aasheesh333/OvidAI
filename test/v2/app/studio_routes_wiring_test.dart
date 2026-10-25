import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_git_api.dart';
import 'package:ovid_ai/core/cloud/studio_preview_client.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_studio_routes.dart';
import 'package:ovid_ai/ui/v2/app/v2_work_routes.dart';
import 'package:ovid_ai/ui/v2/studio/changes_page.dart';
import 'package:ovid_ai/ui/v2/studio/live_preview_page.dart';
import 'package:ovid_ai/ui/v2/studio/preview_web_view.dart';
import 'package:ovid_ai/ui/v2/studio/studio_workspace_page.dart';

import '../../support/studio_fake_gateway.dart';

const String _cloudBase = 'https://cloud.test/cloud/v1';
const String _serverSession = '0199aaaa-0000-7000-8000-00000000e703';

http.Response _studioJson(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const <String, String>{'content-type': 'application/json'},
);

class _FakeStudioPort extends StudioBindingPort {
  @override
  bool ready = true;

  String? lastRepo;
  String? lastBranch;
  int syncCalls = 0;
  Object? syncError;
  StudioSessionGit? sessionGit;

  @override
  Future<StudioSessionGit?> loadSessionGit(String sessionId) async =>
      sessionGit;

  @override
  StudioBinding? bindingFor(String sessionId) {
    final app = AppState.I;
    final repo = app.getRepoForSession(sessionId);
    if (repo == null || repo.trim().isEmpty) return null;
    return StudioBinding(
      repo: repo.trim(),
      branch: app.getBranchForSession(sessionId),
    );
  }

  @override
  Future<List<String>> listRepos() async => const ['acme/app'];

  @override
  Future<List<String>> listBranches(String repo) async => const ['main', 'dev'];

  @override
  Future<void> bind(
    String sessionId, {
    required String repo,
    required String branch,
  }) async {
    lastRepo = repo;
    lastBranch = branch;
    AppState.I
      ..setRepoForSession(sessionId, repo)
      ..setBranchForSession(sessionId, branch);
    notifyListeners();
  }

  @override
  Future<void> syncLatest(String sessionId) async {
    syncCalls++;
    final error = syncError;
    if (error != null) throw error;
  }
}

/// A gateway-backed port whose deployment has no git transport yet: the
/// connection and the repository page answer, the clone answers the gateway's
/// 503 as the user sees it.
class _RefusingStudioPort extends _FakeStudioPort {
  @override
  Future<StudioGithubConnection?> loadConnection() async =>
      const StudioGithubConnection(connected: true, login: 'octocat');

  @override
  Future<StudioPage<StudioRepo>?> reposPage({
    int page = 1,
    int perPage = 30,
  }) async => const StudioPage<StudioRepo>(
    items: <StudioRepo>[
      StudioRepo(id: 1, owner: 'acme', name: 'app', fullName: 'acme/app'),
    ],
    page: 1,
    perPage: 30,
    hasMore: false,
  );

  @override
  Future<void> bind(
    String sessionId, {
    required String repo,
    required String branch,
  }) async {
    throw const StudioAccessException(
      'Git operations are not available on this deployment yet.',
    );
  }
}

Future<void> _openWorkspace(WidgetTester tester, {String? sessionId}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => V2StudioRoutes.openWorkspace(
                context,
                'acme/app',
                'main',
                sessionId: sessionId,
              ),
              child: const Text('open workspace'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open workspace'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late _FakeStudioPort port;
  late FakeStudioGateway gateway;

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    final session = ChatSession(
      id: 'studio-session',
      title: 'Studio',
      model: 'auto',
      createdAt: DateTime(2026, 10, 22),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    app.setRepoForSession(session.id, 'acme/app');
    app.setBranchForSession(session.id, 'main');

    port = _FakeStudioPort();
    StudioBindingPort.installForTest(port);
    CloudSessionStore.installForTest(
      CloudSessionStore.forTest(
        idMap: const <String, String>{'studio-session': _serverSession},
      ),
    );
    CloudRestClient.installForTest(
      CloudRestClient(
        httpClient: MockClient(
          (request) async => _studioJson(<String, Object>{
            'error': <String, Object>{
              'code': 'not_found',
              'message': 'No test route.',
            },
          }, 404),
        ),
        headers: CloudHeaders.forTest(),
        restBase: _cloudBase,
      ),
    );
    StudioPreviewClient.installForTest(null);

    gateway = FakeStudioGateway(
      roots: const <FakeNode>[
        FakeNode.file('index.html'),
        FakeNode.dir('src', <FakeNode>[FakeNode.file('src/main.dart')]),
      ],
      files: <String, String>{
        'index.html': '<h1>Hi</h1>',
        'src/main.dart': 'void main() {}',
      },
    );
    installFakeStudio(gateway);
  });

  tearDown(() {
    StudioRemoteClient.I.clearAll();
    StudioPreviewClient.installForTest(null);
    StudioBindingPort.installForTest(null);
    CloudSessionStore.resetForTest();
    AppState.resetTestInstance();
  });

  StudioSessionGit boundGit() => StudioSessionGit(
    sessionId: _serverSession,
    available: true,
    binding: const StudioRepoBinding(
      repo: 'acme/app',
      repoDir: 'app',
      branch: 'main',
    ),
  );

  List<http.Request> installCloud(
    Future<http.Response> Function(http.Request request) handler,
  ) {
    final requests = <http.Request>[];
    CloudRestClient.installForTest(
      CloudRestClient(
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
        headers: CloudHeaders.forTest(),
        restBase: _cloudBase,
      ),
    );
    return requests;
  }

  Map<String, Object?> gitStatus({int? behind = 3, bool? dirty = true}) =>
      <String, Object?>{
        'branch': 'main',
        'headSha': 'abc123',
        'upstream': 'origin/main',
        'dirty': dirty,
        'ahead': 1,
        'behind': behind,
        'reason': 'diverged',
        'fetchedAt': '2026-10-24T18:30:00.000Z',
      };

  const patch =
      'diff --git a/lib/main.dart b/lib/main.dart\n'
      '--- a/lib/main.dart\n'
      '+++ b/lib/main.dart\n'
      '@@ -1,2 +1,2 @@\n'
      ' void main() {\n'
      '-  oldCall();\n'
      '+  newCall();\n'
      ' }\n';
  const stagedPatch =
      'diff --git a/lib/staged.dart b/lib/staged.dart\n'
      '--- /dev/null\n'
      '+++ b/lib/staged.dart\n'
      '@@ -0,0 +1 @@\n'
      '+ready\n';
  const sameFileStagedPatch =
      'diff --git a/lib/main.dart b/lib/main.dart\n'
      '--- a/lib/main.dart\n'
      '+++ b/lib/main.dart\n'
      '@@ -10 +10 @@\n'
      '-  stagedOld();\n'
      '+  stagedNew();\n';

  group('workspace data mapping', () {
    test('maps the cloud tree and the active editor buffer', () {
      final snapshot = StudioTreeSnapshot(
        sessionId: 's1',
        state: 'warm',
        generation: 1,
        source: 'live',
        truncated: false,
        root: const FileNode(
          name: '',
          path: '',
          kind: 'dir',
          children: <FileNode>[
            FileNode(
              name: 'src',
              path: 'src',
              kind: 'dir',
              children: <FileNode>[
                FileNode(
                  name: 'main.dart',
                  path: 'src/main.dart',
                  kind: 'file',
                ),
              ],
            ),
            FileNode(name: 'index.html', path: 'index.html', kind: 'file'),
          ],
        ),
        fileCount: 2,
        dirCount: 1,
        totalBytes: 32,
      );
      const tabs = StudioTabsState(
        openFiles: <String>['src/main.dart'],
        activePath: 'src/main.dart',
        buffer: <String, String>{'src/main.dart': 'void main() {\n  run();\n}'},
        activeContent: 'void main() {\n  run();\n}',
        dirtyPaths: <String>['src/main.dart'],
        conflicts: <String, String>{},
        guardedPaths: <String>[],
      );

      final data = V2StudioRoutes.workspaceDataFor(
        repo: 'acme/app',
        branch: 'main',
        portReady: true,
        snapshot: snapshot,
        tabs: tabs,
      );

      expect(data.status, V2WorkspaceStatus.content);
      expect(data.repoName, 'acme/app');
      expect(data.branch, 'main');
      expect(data.fileTree.map((node) => node.name), ['src', 'index.html']);
      expect(data.fileTree.first.children.single.path, 'src/main.dart');
      expect(data.openFileName, 'main.dart');
      expect(data.openFilePath, 'src/main.dart');
      expect(data.codeLines.map((line) => line.text), [
        'void main() {',
        '  run();',
        '}',
      ]);
      expect(data.codeLines.first.number, 1);
      expect(data.saved, isFalse);
    });

    test('a workspace is empty without an installed port', () {
      final data = V2StudioRoutes.workspaceDataFor(
        repo: 'acme/app',
        branch: 'dev',
        portReady: false,
      );

      expect(data.status, V2WorkspaceStatus.empty);
      expect(data.branch, isEmpty);
      expect(data.fileTree, isEmpty);
    });

    test('pruned folders are not rendered as tappable files', () {
      final nodes = V2StudioRoutes.fileNodesFrom(const <FileNode>[
        FileNode(name: 'big', path: 'big', kind: 'dir', files: 40),
        FileNode(name: 'empty', path: 'empty', kind: 'dir'),
        FileNode(name: 'index.html', path: 'index.html', kind: 'file'),
      ]);

      expect(nodes.map((node) => node.name), ['index.html']);
    });
    test(
      'maps known diff arithmetic and keeps dirty unknown counts nullable',
      () {
        final diff = StudioDiff.tryParse(<String, Object>{
          'patch': patch,
          'truncated': false,
        })!;
        final data = V2StudioRoutes.workspaceDataFor(
          repo: 'acme/app',
          branch: 'main',
          portReady: true,
          gitStatus: StudioGitStatus.tryParse(
            gitStatus(behind: 0, dirty: false),
          ),
          diff: diff,
        );
        expect(data.filesChanged, 1);
        expect(data.additions, 1);
        expect(data.deletions, 1);
        expect(data.syncCount, 0);

        final dirty = V2StudioRoutes.workspaceDataFor(
          repo: 'acme/app',
          branch: 'main',
          portReady: true,
          gitStatus: StudioGitStatus.tryParse(gitStatus(behind: 4)),
          diff: diff,
        );
        expect(dirty.filesChanged, isNull);
        expect(dirty.additions, isNull);
        expect(dirty.deletions, isNull);
        expect(dirty.syncCount, 4);

        final unknown = V2StudioRoutes.workspaceDataFor(
          repo: 'acme/app',
          branch: 'main',
          portReady: true,
        );
        expect(unknown.filesChanged, isNull);
        expect(unknown.additions, isNull);
        expect(unknown.deletions, isNull);
        expect(unknown.syncCount, isNull);
      },
    );

    test(
      'changes mapper renders real diff records and unknown truncated totals',
      () {
        final status = StudioGitStatus.tryParse(
          gitStatus(behind: 0, dirty: false),
        )!;
        final data = V2StudioRoutes.changesDataFor(
          branch: 'main',
          portReady: true,
          gitStatus: status,
          diff: StudioDiff.tryParse(<String, Object>{
            'patch': patch,
            'truncated': false,
          }),
        );
        expect(data.status, V2ChangesStatus.content);
        expect(data.files.single.path, 'lib/main.dart');
        expect(data.files.single.additions, 1);
        expect(data.files.single.deletions, 1);
        expect(data.files.single.hunks.single.lines, hasLength(4));
        expect(data.behindCount, 0);

        final truncated = V2StudioRoutes.changesDataFor(
          branch: 'main',
          portReady: true,
          gitStatus: status,
          diff: StudioDiff.tryParse(<String, Object>{
            'patch': patch,
            'truncated': true,
          }),
        );
        expect(truncated.files.single.additions, isNull);
        expect(truncated.files.single.deletions, isNull);
        expect(truncated.additions, isNull);
        expect(truncated.deletions, isNull);
      },
    );

    test('mixed tracked and untracked scope warns without exact totals', () {
      final data = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        gitStatus: StudioGitStatus.tryParse(gitStatus()),
        diff: StudioDiff.tryParse(<String, Object>{
          'patch': patch,
          'truncated': false,
        }),
      );

      expect(data.status, V2ChangesStatus.content);
      expect(data.files.single.path, 'lib/main.dart');
      expect(data.files.single.additions, 1);
      expect(data.files.single.deletions, 1);
      expect(data.totalsKnown, isFalse);
      expect(data.additions, isNull);
      expect(data.deletions, isNull);
      expect(data.coverageWarning, contains('Untracked files'));
      expect(data.coverageWarning, contains('totals are unknown'));
      expect(data.errorMessage, isNull);
    });

    test('same file staged and unstaged edits become one scoped record', () {
      final data = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        gitStatus: StudioGitStatus.tryParse(gitStatus()),
        diff: StudioDiff(
          patch: '$patch\n$sameFileStagedPatch',
          truncated: false,
          parts: const <StudioDiffPart>[
            StudioDiffPart(patch: patch, staged: false),
            StudioDiffPart(patch: sameFileStagedPatch, staged: true),
          ],
        ),
      );

      expect(data.files, hasLength(1));
      final file = data.files.single;
      expect(file.path, 'lib/main.dart');
      expect(file.scopeLabel, 'Staged + unstaged');
      expect(file.additions, 2);
      expect(file.deletions, 2);
      expect(file.hunks, hasLength(2));
      expect(file.hunks.map((hunk) => hunk.scopeLabel), <String?>[
        'Unstaged',
        'Staged',
      ]);
      expect(file.initiallyExpanded, isTrue);
      expect(data.additions, isNull);
      expect(data.deletions, isNull);
      expect(data.coverageWarning, isNotNull);
    });

    test(
      'untracked-only dirty work never becomes an empty zero change set',
      () {
        final status = StudioGitStatus.tryParse(gitStatus())!;
        const diff = StudioDiff(patch: '', truncated: false);

        final changes = V2StudioRoutes.changesDataFor(
          branch: 'main',
          portReady: true,
          gitStatus: status,
          diff: diff,
        );
        expect(changes.status, V2ChangesStatus.error);
        expect(changes.files, isEmpty);
        expect(changes.additions, isNull);
        expect(changes.deletions, isNull);
        expect(changes.errorMessage, contains('full diff'));

        final workspace = V2StudioRoutes.workspaceDataFor(
          repo: 'acme/app',
          branch: 'main',
          portReady: true,
          gitStatus: status,
          diff: diff,
        );
        expect(workspace.filesChanged, isNull);
        expect(workspace.additions, isNull);
        expect(workspace.deletions, isNull);
      },
    );

    test('changes mapper keeps binary diff paths without inventing hunks', () {
      final data = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        diff: StudioDiff.tryParse(<String, Object>{
          'patch':
              'diff --git a/assets/logo.png b/assets/logo.png\n'
              'index 1234567..89abcde 100644\n'
              'Binary files a/assets/logo.png and b/assets/logo.png differ\n',
          'truncated': false,
        }),
      );

      expect(data.files.single.path, 'assets/logo.png');
      expect(data.files.single.additions, 0);
      expect(data.files.single.deletions, 0);
      expect(data.additions, isNull);
      expect(data.deletions, isNull);
      expect(data.files.single.hunks, isEmpty);
      expect(data.files.single.canExpand, isFalse);
    });

    test('changes mapper retains loading empty error and content states', () {
      final loading = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        loading: true,
      );
      expect(loading.status, V2ChangesStatus.loading);
      expect(loading.totalsKnown, isFalse);
      expect(loading.additions, isNull);
      expect(loading.deletions, isNull);

      final requestError = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        errorMessage: 'Could not load changes.',
      );
      expect(requestError.status, V2ChangesStatus.error);
      expect(requestError.totalsKnown, isFalse);
      expect(requestError.additions, isNull);
      expect(requestError.deletions, isNull);

      final cleanEmpty = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        gitStatus: StudioGitStatus.tryParse(gitStatus(behind: 0, dirty: false)),
        diff: const StudioDiff(patch: '', truncated: false),
      );
      expect(cleanEmpty.status, V2ChangesStatus.empty);
      expect(cleanEmpty.totalsKnown, isTrue);
      expect(cleanEmpty.additions, 0);
      expect(cleanEmpty.deletions, 0);

      final unfetched = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        diff: const StudioDiff(patch: '', truncated: false),
      );
      expect(
        unfetched.status,
        V2ChangesStatus.error,
        reason: 'An unfetched diff is unknown, never a clean tree.',
      );
      expect(unfetched.totalsKnown, isFalse);
      expect(unfetched.additions, isNull);
      expect(unfetched.deletions, isNull);

      final dirtyEmpty = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        gitStatus: StudioGitStatus.tryParse(gitStatus()),
        diff: const StudioDiff(patch: '', truncated: false),
      );
      expect(dirtyEmpty.status, V2ChangesStatus.error);
      expect(dirtyEmpty.totalsKnown, isFalse);
      expect(dirtyEmpty.additions, isNull);
      expect(dirtyEmpty.deletions, isNull);
      expect(dirtyEmpty.errorMessage, contains('full diff'));
    });

    test('unknown changes data defaults never fabricate zero totals', () {
      for (final status in <V2ChangesStatus>[
        V2ChangesStatus.loading,
        V2ChangesStatus.error,
        V2ChangesStatus.empty,
      ]) {
        final data = V2ChangesData(status: status);
        expect(data.totalsKnown, isFalse, reason: '$status');
        expect(data.additions, isNull, reason: '$status');
        expect(data.deletions, isNull, reason: '$status');
      }
      const emptyContent = V2ChangesData();
      expect(emptyContent.totalsKnown, isFalse);
      expect(emptyContent.additions, isNull);
      expect(emptyContent.deletions, isNull);
    });
  });

  group('workspace route wiring', () {
    testWidgets('unknown sync count renders an em dash not zero', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const V2StudioWorkspacePage(
            data: V2StudioWorkspaceData(
              repoName: 'acme/app',
              branch: 'main',
              syncCount: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sync = tester.widget<OIconButton>(
        find.byKey(const Key('studio-sync')),
      );
      expect(sync.badge, isA<Text>());
      expect((sync.badge! as Text).data, '—');
      expect(find.text('0'), findsNothing);
    });

    testWidgets('mixed tracked and untracked scope warning stays visible', (
      tester,
    ) async {
      final data = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        gitStatus: StudioGitStatus.tryParse(gitStatus()),
        diff: StudioDiff.tryParse(<String, Object>{
          'patch': patch,
          'truncated': false,
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: V2ChangesPage(data: data),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('studio-diff-scope-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('Untracked files'), findsOneWidget);
      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.text('No changes to review'), findsNothing);
      expect(find.text('+2'), findsNothing);
      expect(find.text('−2'), findsNothing);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('−1'), findsOneWidget);
    });

    testWidgets('same file combined row shares expansion for scoped hunks', (
      tester,
    ) async {
      final data = V2StudioRoutes.changesDataFor(
        branch: 'main',
        portReady: true,
        gitStatus: StudioGitStatus.tryParse(gitStatus()),
        diff: const StudioDiff(
          patch: '',
          truncated: false,
          parts: <StudioDiffPart>[
            StudioDiffPart(patch: patch, staged: false),
            StudioDiffPart(patch: sameFileStagedPatch, staged: true),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: V2ChangesPage(data: data),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.text('Staged + unstaged'), findsOneWidget);
      expect(find.text('Unstaged'), findsOneWidget);
      expect(find.text('Staged'), findsOneWidget);
      expect(find.text('@@ -1,2 +1,2 @@'), findsOneWidget);
      expect(find.text('@@ -10 +10 @@'), findsOneWidget);

      await tester.tap(find.text('lib/main.dart'));
      await tester.pumpAndSettle();
      expect(find.text('@@ -1,2 +1,2 @@'), findsNothing);
      expect(find.text('@@ -10 +10 @@'), findsNothing);

      await tester.tap(find.text('lib/main.dart'));
      await tester.pumpAndSettle();
      expect(find.text('@@ -1,2 +1,2 @@'), findsOneWidget);
      expect(find.text('@@ -10 +10 @@'), findsOneWidget);
    });

    testWidgets('shows the real cloud tree and opens a selected file', (
      tester,
    ) async {
      await _openWorkspace(tester, sessionId: 'studio-session');

      expect(find.byKey(const Key('studio-file-tree')), findsOneWidget);
      expect(find.text('index.html'), findsOneWidget);
      expect(find.text('src'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('v2-file-tree-row-index.html')),
      );
      await tester.pumpAndSettle();

      expect(find.text('<h1>Hi</h1>'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('studio-open-code-viewer')),
        findsOneWidget,
      );
    });

    testWidgets('sync reports success only after the port finishes', (
      tester,
    ) async {
      await _openWorkspace(tester, sessionId: 'studio-session');

      await tester.tap(find.byKey(const Key('studio-sync')));
      await tester.pump();
      expect(port.syncCalls, 1);

      await tester.pumpAndSettle();
      expect(find.text('Sync finished.'), findsOneWidget);
    });

    testWidgets('sync reports the port error instead of pretending', (
      tester,
    ) async {
      port.syncError = const StudioAccessException(
        'Sign in to GitHub to use Studio.',
      );
      await _openWorkspace(tester, sessionId: 'studio-session');

      await tester.tap(find.byKey(const Key('studio-sync')));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to GitHub to use Studio.'), findsOneWidget);
      expect(find.text('Sync finished.'), findsNothing);
    });

    testWidgets('sync without a chat session says so and does not call', (
      tester,
    ) async {
      await _openWorkspace(tester);

      await tester.tap(find.byKey(const Key('studio-sync')));
      await tester.pumpAndSettle();

      expect(find.text('Open Studio from a chat to sync.'), findsOneWidget);
      expect(port.syncCalls, 0);
    });

    testWidgets('sync without a session binding reports it and does not call', (
      tester,
    ) async {
      app
        ..setRepoForSession('studio-session', '')
        ..setBranchForSession('studio-session', '');
      await _openWorkspace(tester, sessionId: 'studio-session');

      await tester.tap(find.byKey(const Key('studio-sync')));
      await tester.pumpAndSettle();

      expect(
        find.text('Bind a repository and branch to sync.'),
        findsOneWidget,
      );
      expect(find.text('Sync finished.'), findsNothing);
      expect(port.syncCalls, 0);
    });

    testWidgets('switching branch binds the session the chat gate reads', (
      tester,
    ) async {
      await _openWorkspace(tester, sessionId: 'studio-session');

      await tester.tap(find.byKey(const Key('studio-branch-chip')));
      await tester.pumpAndSettle();
      expect(find.text('Switch branch'), findsOneWidget);
      expect(find.text('dev'), findsOneWidget);
      await tester.tap(find.text('dev'));
      await tester.pumpAndSettle();

      expect(port.lastRepo, 'acme/app');
      expect(port.lastBranch, 'dev');
      expect(
        app.sessions.where((s) => s.id == 'studio-session').single.repo,
        'acme/app',
      );
      expect(
        app.sessions.where((s) => s.id == 'studio-session').single.branch,
        'dev',
      );
      expect(port.bindingFor('studio-session')?.ready, isTrue);
      expect(find.text('dev'), findsOneWidget);
    });

    testWidgets('copy writes the open file and then confirms', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _openWorkspace(tester, sessionId: 'studio-session');
      await tester.tap(
        find.byKey(const ValueKey<String>('v2-file-tree-row-index.html')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('studio-open-code-viewer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('v2-code-viewer-copy')));
      await tester.pumpAndSettle();

      final copy = calls.where((call) => call.method == 'Clipboard.setData');
      expect(copy, isNotEmpty);
      expect(
        (copy.first.arguments as Map<Object?, Object?>)['text'],
        '<h1>Hi</h1>',
      );
      expect(find.text('Copied file.'), findsOneWidget);
    });

    testWidgets('the empty workspace opens the real repository picker', (
      tester,
    ) async {
      port.ready = false;
      await _openWorkspace(tester);

      expect(find.text('No repository open'), findsOneWidget);
      await tester.tap(find.text('Pick a repository'));
      await tester.pumpAndSettle();

      expect(find.text('No repositories yet'), findsOneWidget);
    });

    testWidgets('confirming a repo binds the session before the workspace', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => V2WorkRoutes.openRepoPicker(context),
                  child: const Text('open picker'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open picker'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('acme/app'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('repo-picker-branch-main')));
      await tester.pumpAndSettle();
      expect(find.text('Start'), findsOneWidget);
      await tester.tap(find.byKey(const Key('repo-picker-primary')));
      await tester.pumpAndSettle();

      final session = app.sessions
          .where((s) => s.id == 'studio-session')
          .single;
      expect(session.repo, 'acme/app');
      expect(session.branch, 'main');
      expect(port.bindingFor(session.id)?.ready, isTrue);
      expect(find.byKey(const Key('studio-file-tree')), findsOneWidget);
    });

    testWidgets('a refused clone says so and opens no workspace', (
      tester,
    ) async {
      // The gateway answers 503 `studio_git_unavailable` until the worker
      // transport lands. The picker must relay that message and leave the
      // session unbound — never show a workspace for a clone that did not
      // happen.
      final refusing = _RefusingStudioPort();
      StudioBindingPort.installForTest(refusing);
      app.setRepoForSession('studio-session', '');
      app.setBranchForSession('studio-session', '');
      final session = app.sessions
          .where((s) => s.id == 'studio-session')
          .single;
      session.repo = null;
      session.branch = null;

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => V2WorkRoutes.openRepoPicker(context),
                  child: const Text('open picker'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open picker'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('acme/app'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('repo-picker-branch-main')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('repo-picker-primary')));
      await tester.pumpAndSettle();

      expect(
        find.text('Git operations are not available on this deployment yet.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('studio-file-tree')), findsNothing);
      expect(session.repo, isNull);
      expect(refusing.bindingFor('studio-session'), isNull);
    });

    testWidgets(
      'production preview navigation hides start without registration',
      (tester) async {
        port.sessionGit = boundGit();
        final requests = installCloud((request) async {
          if (request.url.path.endsWith('/git/preflight') ||
              request.url.path.endsWith('/git/status')) {
            return _studioJson(gitStatus());
          }
          if (request.url.path.endsWith('/git/diff')) {
            return _studioJson(<String, Object>{
              'patch': request.url.queryParameters['staged'] == 'true'
                  ? ''
                  : patch,
              'truncated': false,
            });
          }
          return _studioJson(<String, Object>{
            'error': <String, Object>{'code': 'not_found', 'message': 'No.'},
          }, 404);
        });
        await _openWorkspace(tester, sessionId: 'studio-session');

        expect(find.byKey(const Key('studio-open-preview')), findsOneWidget);
        await tester.tap(find.byKey(const Key('studio-open-preview')));
        await tester.pumpAndSettle();

        expect(find.text('No preview'), findsOneWidget);
        expect(find.text('Live preview is not connected yet.'), findsOneWidget);
        expect(find.text('Start preview'), findsNothing);
        expect(find.text('Cancel'), findsNothing);
        expect(find.text('Stop preview'), findsNothing);
        expect(find.byTooltip('Reload'), findsNothing);
        expect(
          requests.where((request) => request.url.path.contains('/previews')),
          isEmpty,
          reason: 'No server registration means no create/ticket/stop calls.',
        );
      },
    );

    testWidgets(
      'preview opens refreshes and stops through isolated native view',
      (tester) async {
        port.sessionGit = boundGit();
        const previewId = 'preview-live';
        StudioPreviewWebView.resetConsumedLaunchesForTest();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final channels = <int, MethodChannel>{};
        final nativeCalls = <String>[];
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
          call,
        ) async {
          final args = call.arguments as Map;
          final id = args['id'] as int;
          if (call.method == 'create') {
            final channel = MethodChannel('ovid/studio-preview/$id');
            channels[id] = channel;
            messenger.setMockMethodCallHandler(channel, (call) async {
              nativeCalls.add('${call.method}:$id');
              return null;
            });
            return 1;
          }
          return null;
        });
        addTearDown(() {
          StudioPreviewWebView.resetConsumedLaunchesForTest();
          for (final channel in channels.values) {
            messenger.setMockMethodCallHandler(channel, null);
          }
          messenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          );
        });

        var tickets = 0;
        var creates = 0;
        Map<String, Object?> preview(String status) => <String, Object?>{
          'id': previewId,
          'kind': 'dev_server',
          'status': status,
          'generation': creates,
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
          'lastAccessAt': null,
          'logAvailable': false,
        };
        final requests = installCloud((request) async {
          if (request.url.path.endsWith('/git/preflight') ||
              request.url.path.endsWith('/git/status')) {
            return _studioJson(gitStatus());
          }
          if (request.url.path.endsWith('/git/diff')) {
            return _studioJson(<String, Object>{
              'patch': request.url.queryParameters['staged'] == 'true'
                  ? ''
                  : patch,
              'truncated': false,
            });
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/previews')) {
            creates++;
            return _studioJson(preview('running'), 201);
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/previews/$previewId')) {
            return _studioJson(preview('running'));
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/ticket')) {
            tickets++;
            return _studioJson(<String, Object>{
              'launchUrl':
                  'https://preview.test/preview/exchange?ticket=route-$tickets',
              'ticketExpiresAt': DateTime.now()
                  .add(const Duration(minutes: 1))
                  .toUtc()
                  .toIso8601String(),
              'cookieExpiresAt': DateTime.now()
                  .add(Duration(seconds: tickets == 2 ? 1 : 15 * 60))
                  .toUtc()
                  .toIso8601String(),
            });
          }
          if (request.method == 'POST' && request.url.path.endsWith('/stop')) {
            return _studioJson(preview('stopped'));
          }
          return _studioJson(<String, Object>{
            'error': <String, Object>{'code': 'not_found', 'message': 'No.'},
          }, 404);
        });

        Future<void> pumpFrames() async {
          for (var index = 0; index < 6; index++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        Future<void> loaded(int id) async {
          await messenger.handlePlatformMessage(
            channels[id]!.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('loadComplete'),
            ),
            (_) {},
          );
          await tester.pump();
        }

        await _openWorkspace(tester, sessionId: 'studio-session');
        final registration = StudioPreviewRegistration.tryParse(
          <String, Object>{'projectDir': 'app', 'startScriptId': 'start'},
        )!;
        unawaited(
          V2StudioRoutes.openLivePreview(
            tester.element(find.byType(V2StudioWorkspacePage)),
            'acme/app',
            'main',
            sessionId: 'studio-session',
            registration: registration,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start preview'));
        await pumpFrames();

        final create = requests.singleWhere(
          (request) =>
              request.method == 'POST' &&
              request.url.path.endsWith('/previews'),
        );
        expect(jsonDecode(create.body), <String, Object>{
          'projectDir': 'app',
          'startScriptId': 'start',
        });
        expect(find.byType(AndroidView), findsOneWidget);
        expect(channels, hasLength(1));
        final firstId = channels.keys.single;
        await loaded(firstId);
        expect(
          tester
              .widget<V2LivePreviewPage>(find.byType(V2LivePreviewPage))
              .data
              .status,
          V2PreviewStatus.live,
        );

        await tester.tap(find.byTooltip('Reload'));
        await pumpFrames();
        expect(
          channels,
          hasLength(2),
          reason:
              'tickets=$tickets native=$nativeCalls requests=${requests.map((request) => '${request.method} ${request.url.path}').toList()}',
        );
        final secondId = channels.keys.last;
        expect(secondId, isNot(firstId));
        await loaded(secondId);
        expect(
          tester
              .widget<V2LivePreviewPage>(find.byType(V2LivePreviewPage))
              .data
              .status,
          V2PreviewStatus.live,
        );
        expect(tickets, 2);

        // The second cookie expires immediately. The page must tell its host,
        // stop that registration, and offer a genuinely fresh start.
        await tester.pump(const Duration(seconds: 2));
        await pumpFrames();
        expect(find.text('Preview ended'), findsOneWidget);
        expect(find.text('Start preview'), findsOneWidget);
        expect(
          requests.where(
            (request) =>
                request.method == 'POST' &&
                request.url.path.endsWith('/previews/$previewId/stop'),
          ),
          hasLength(1),
        );

        await tester.tap(find.text('Start preview'));
        await pumpFrames();
        expect(creates, 2);
        expect(channels, hasLength(3));
        final thirdId = channels.keys.last;
        await loaded(thirdId);
        expect(
          tester
              .widget<V2LivePreviewPage>(find.byType(V2LivePreviewPage))
              .data
              .status,
          V2PreviewStatus.live,
        );
        expect(tickets, 3);

        await tester.ensureVisible(find.text('Stop preview'));
        await tester.tap(find.text('Stop preview'));
        await pumpFrames();
        expect(
          tester
              .widget<V2LivePreviewPage>(find.byType(V2LivePreviewPage))
              .data
              .status,
          V2PreviewStatus.unavailable,
        );
        expect(find.text('Start preview'), findsOneWidget);
        expect(
          requests.where(
            (request) =>
                request.method == 'POST' &&
                request.url.path.endsWith('/previews/$previewId/stop'),
          ),
          hasLength(2),
        );
        expect(nativeCalls, contains('disposePreview:$firstId'));
        expect(nativeCalls, contains('disposePreview:$secondId'));
        expect(nativeCalls, contains('disposePreview:$thirdId'));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );

    testWidgets('failed preview retry creates a fresh registration', (
      tester,
    ) async {
      port.sessionGit = boundGit();
      var creates = 0;
      final stops = <String>[];
      final createdBodies = <Map<String, dynamic>>[];
      Map<String, Object?> preview(String id, String status) =>
          <String, Object?>{
            'id': id,
            'kind': 'dev_server',
            'status': status,
            'generation': 1,
            'expiresAt': DateTime.now()
                .add(const Duration(hours: 1))
                .toUtc()
                .toIso8601String(),
            'lastAccessAt': null,
            'logAvailable': false,
          };
      installCloud((request) async {
        if (request.url.path.endsWith('/git/preflight') ||
            request.url.path.endsWith('/git/status')) {
          return _studioJson(gitStatus());
        }
        if (request.url.path.endsWith('/git/diff')) {
          return _studioJson(<String, Object>{
            'patch': request.url.queryParameters['staged'] == 'true'
                ? ''
                : patch,
            'truncated': false,
          });
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/previews')) {
          creates++;
          createdBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _studioJson(
            preview('preview-failed-$creates', 'starting'),
            201,
          );
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/previews/')) {
          final id =
              request.url.pathSegments[request.url.pathSegments.length - 1];
          return _studioJson(
            preview(id, id.endsWith('-1') ? 'failed' : 'starting'),
          );
        }
        if (request.method == 'POST' && request.url.path.endsWith('/stop')) {
          stops.add(request.url.path);
          return _studioJson(preview('preview-failed-$creates', 'stopped'));
        }
        return _studioJson(<String, Object>{
          'error': <String, Object>{'code': 'not_found', 'message': 'No.'},
        }, 404);
      });
      await _openWorkspace(tester, sessionId: 'studio-session');
      final registration = StudioPreviewRegistration.tryParse(<String, Object>{
        'projectDir': 'app',
        'startScriptId': 'preview',
      })!;
      unawaited(
        V2StudioRoutes.openLivePreview(
          tester.element(find.byType(V2StudioWorkspacePage)),
          'acme/app',
          'main',
          sessionId: 'studio-session',
          registration: registration,
        ),
      );
      await tester.pumpAndSettle();
      Future<void> pumpFrames() async {
        for (var index = 0; index < 6; index++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      await tester.tap(find.text('Start preview'));
      await pumpFrames();
      expect(find.text('Preview failed'), findsOneWidget);
      expect(creates, 1);

      await tester.tap(find.text('Try again'));
      await pumpFrames();

      expect(creates, 2);
      expect(
        stops.single,
        endsWith('/previews/preview-failed-1/stop'),
        reason: 'The terminal id is cleaned up, not refreshed.',
      );
      expect(createdBodies, hasLength(2));
      expect(
        createdBodies.every((body) => body['startScriptId'] == 'preview'),
        isTrue,
      );
      expect(find.text('Connecting'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await pumpFrames();
      expect(stops, hasLength(2));
      expect(stops.last, endsWith('/previews/preview-failed-2/stop'));
      expect(find.text('Start preview'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('the live preview route has no unwired controls', (
      tester,
    ) async {
      await _openWorkspace(tester, sessionId: 'studio-session');

      await tester.tap(find.byKey(const Key('studio-open-preview')));
      await tester.pumpAndSettle();

      // No server-issued preview registration exists, so the screen says so
      // and draws no control that could not act. It never paints a blank frame
      // that looks loaded.
      expect(find.text('No preview'), findsOneWidget);
      expect(find.text('Live preview is not connected yet.'), findsOneWidget);
      expect(find.text('Start preview'), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Stop'), findsNothing);
      expect(find.byTooltip('Refresh'), findsNothing);
      expect(find.text('Reconnect'), findsNothing);

      // The route passes no live session or deadline: user-action handlers
      // are absent and only internal deadline cleanup remains wired.
      final preview = tester.widget<V2LivePreviewPage>(
        find.byType(V2LivePreviewPage),
      );
      expect(preview.data.status, V2PreviewStatus.unavailable);
      expect(preview.data.url, isEmpty);
      expect(preview.data.expiresAt, isNull);
      expect(preview.onReload, isNull);
      expect(preview.onOpenInBrowser, isNull);
      expect(preview.onCopyUrl, isNull);
      expect(preview.onStop, isNull);
      expect(preview.onReconnect, isNull);
      expect(preview.onStart, isNull);
      expect(preview.onRetry, isNull);
      expect(preview.onCancel, isNull);
    });

    testWidgets(
      'changes route loads real status and diff without a fake commit',
      (tester) async {
        port.sessionGit = boundGit();
        installCloud((request) async {
          if (request.url.path.endsWith('/git/preflight') ||
              request.url.path.endsWith('/git/status')) {
            return _studioJson(gitStatus());
          }
          if (request.url.path.endsWith('/git/diff')) {
            return _studioJson(<String, Object>{
              'patch': request.url.queryParameters['staged'] == 'true'
                  ? stagedPatch
                  : patch,
              'truncated': false,
            });
          }
          return _studioJson(<String, Object>{
            'error': <String, Object>{'code': 'not_found', 'message': 'No.'},
          }, 404);
        });
        await _openWorkspace(tester, sessionId: 'studio-session');

        await tester.tap(find.byKey(const Key('studio-open-changes')));
        await tester.pumpAndSettle();

        expect(find.text('lib/main.dart'), findsOneWidget);
        expect(find.text('lib/staged.dart'), findsOneWidget);
        expect(find.text('@@ -1,2 +1,2 @@'), findsOneWidget);
        expect(find.textContaining('newCall();'), findsOneWidget);
        await tester.tap(find.text('lib/staged.dart'));
        await tester.pumpAndSettle();
        expect(find.textContaining('ready'), findsOneWidget);
        final changes = tester.widget<V2ChangesPage>(
          find.byType(V2ChangesPage),
        );
        expect(changes.data.status, V2ChangesStatus.content);
        expect(changes.data.files, hasLength(2));
        expect(changes.data.files[0].additions, 1);
        expect(changes.data.files[0].deletions, 1);
        expect(changes.data.files[1].additions, 1);
        expect(changes.data.files[1].deletions, 0);
        expect(changes.data.additions, isNull);
        expect(changes.data.deletions, isNull);
        expect(changes.data.totalsKnown, isFalse);
        expect(changes.canCommit, isFalse);
        expect(find.byKey(const Key('studio-open-commit-sheet')), findsNothing);
      },
    );

    testWidgets('production request error keeps all totals unknown', (
      tester,
    ) async {
      port.sessionGit = boundGit();
      installCloud((request) async {
        return _studioJson(<String, Object>{
          'error': <String, Object>{
            'code': 'studio_git_unavailable',
            'message':
                'Git operations are not available on this deployment yet.',
          },
        }, 503);
      });
      await _openWorkspace(tester, sessionId: 'studio-session');

      await tester.tap(find.byKey(const Key('studio-open-changes')));
      await tester.pumpAndSettle();

      final changes = tester.widget<V2ChangesPage>(find.byType(V2ChangesPage));
      expect(changes.data.status, V2ChangesStatus.error);
      expect(changes.data.totalsKnown, isFalse);
      expect(changes.data.additions, isNull);
      expect(changes.data.deletions, isNull);
      expect(changes.data.files, isEmpty);
      expect(changes.onRetry, isNotNull);
      expect(find.text('No changes to review'), findsNothing);
    });

    testWidgets('unfetched changes are unavailable not a clean tree', (
      tester,
    ) async {
      await _openWorkspace(tester, sessionId: 'studio-session');

      await tester.tap(find.byKey(const Key('studio-open-changes')));
      await tester.pumpAndSettle();

      expect(
        find.text('Changes are unavailable for this workspace.'),
        findsOneWidget,
      );
      expect(find.text('No changes to review'), findsNothing);

      // Without a diff source the route supplies no commit or sync handler,
      // so the screen cannot offer a commit that would not commit anything.
      final changes = tester.widget<V2ChangesPage>(find.byType(V2ChangesPage));
      expect(changes.data.status, V2ChangesStatus.error);
      expect(changes.data.files, isEmpty);
      expect(changes.data.totalsKnown, isFalse);
      expect(changes.data.additions, isNull);
      expect(changes.data.deletions, isNull);
      expect(changes.canCommit, isFalse);
      expect(changes.onCommit, isNull);
      expect(changes.onCommitAsync, isNull);
      expect(changes.onSync, isNull);
      expect(changes.onRetry, isNull);
      expect(find.byKey(const Key('studio-open-commit-sheet')), findsNothing);
    });
  });
}
