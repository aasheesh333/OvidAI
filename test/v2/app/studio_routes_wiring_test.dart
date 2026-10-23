import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_git_api.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_studio_routes.dart';
import 'package:ovid_ai/ui/v2/app/v2_work_routes.dart';
import 'package:ovid_ai/ui/v2/studio/changes_page.dart';
import 'package:ovid_ai/ui/v2/studio/live_preview_page.dart';
import 'package:ovid_ai/ui/v2/studio/studio_workspace_page.dart';

import '../../support/studio_fake_gateway.dart';

class _FakeStudioPort extends StudioBindingPort {
  @override
  bool ready = true;

  String? lastRepo;
  String? lastBranch;
  int syncCalls = 0;
  Object? syncError;

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
    StudioBindingPort.installForTest(null);
    AppState.resetTestInstance();
  });

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
  });

  group('workspace route wiring', () {
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

    testWidgets('the live preview route has no unwired controls', (
      tester,
    ) async {
      await _openWorkspace(tester, sessionId: 'studio-session');

      // The workspace keeps Changes/Preview off its chrome; the route opens
      // through the host callback the same way the shell wires it.
      final page = tester.widget<V2StudioWorkspacePage>(
        find.byType(V2StudioWorkspacePage),
      );
      page.onPreview!();
      await tester.pumpAndSettle();

      // No preview client exists yet, so the screen says so and draws no
      // control that could not act. It must never paint a blank frame that
      // looks loaded.
      expect(find.text('No preview'), findsOneWidget);
      expect(find.text('Live preview is not connected yet.'), findsOneWidget);
      expect(find.text('Start preview'), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Stop'), findsNothing);
      expect(find.byTooltip('Refresh'), findsNothing);
      expect(find.text('Reconnect'), findsNothing);

      // The route passes nothing that would imply a live session or a
      // deadline: every handler is absent and there is no countdown.
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

    testWidgets('the changes route stays honestly empty', (tester) async {
      await _openWorkspace(tester, sessionId: 'studio-session');

      // Changes lives on a pushed page opened through the host callback; the
      // workspace body itself draws no control for it.
      final page = tester.widget<V2StudioWorkspacePage>(
        find.byType(V2StudioWorkspacePage),
      );
      page.onCommit!();
      await tester.pumpAndSettle();

      expect(find.text('No changes to review'), findsOneWidget);
      expect(find.text('Back to workspace'), findsOneWidget);

      // Without a diff source the route supplies no commit or sync handler,
      // so the screen cannot offer a commit that would not commit anything.
      final changes = tester.widget<V2ChangesPage>(find.byType(V2ChangesPage));
      expect(changes.data.status, V2ChangesStatus.empty);
      expect(changes.data.files, isEmpty);
      expect(changes.canCommit, isFalse);
      expect(changes.onCommit, isNull);
      expect(changes.onCommitAsync, isNull);
      expect(changes.onSync, isNull);
      expect(changes.onRetry, isNull);
      expect(find.byKey(const Key('studio-open-commit-sheet')), findsNothing);
    });
  });
}
