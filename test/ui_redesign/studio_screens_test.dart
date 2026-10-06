import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Aether polish smoke tests for the Studio screens.
///
/// These are RENDER-ONLY contracts: each file in the Studio surface
/// (`studio_screen.dart`, `studio_file_tree.dart`, `studio_editor.dart`,
/// `studio_terminal_tabs.dart`) has to pump cleanly under the shared Aether
/// theme and expose its headline affordances through the design-system
/// primitives (surface + hairline hierarchy, `AetherCard`-shaped approval
/// banner with `AetherPrimaryButton` "Approve" + `AetherGhostButton`
/// "Decline"). Behaviour contracts — approval gates, drafts, deletion
/// safety, autonomous Control — are already covered by the dedicated
/// Studio tests (`studio_*_test.dart`); this file only verifies that the
/// polish didn't tear them off the primitives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'ovid_github_token': 'tok'});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    studioLoginPromptOverrideForTest = (_) {};
    studioRepoSyncOverrideForTest = () async {};
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    app.sandboxInstalled = true;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    await GitHubService.I.initialize(
      client: MockClient(
        (request) async => request.url.path == '/user'
            ? http.Response(jsonEncode({'login': 'octocat'}), 200)
            : http.Response('{}', 404),
      ),
    );
    app.activeSession!.repo = 'owner/repo';
    AgentService.I.repoFull = 'owner/repo';
    RepoCache.I.bind(
      'owner/repo',
      'tok',
      branch: 'main',
      sessionId: app.activeSession!.id,
    );
    RepoCache.I.treePaths
      ..clear()
      ..addAll(['lib/a.dart', 'README.md']);
    RepoCache.I.files
      ..clear()
      ..addAll({'lib/a.dart': 'void a() {}', 'README.md': '# hi'});
    RepoCache.I.notifyListeners();
  });

  tearDown(() async {
    studioLoginPromptOverrideForTest = null;
    studioRepoSyncOverrideForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AgentService.I.pendingApproval = null;
    RepoCache.I.unbind();
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
  });

  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpStudio(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('studio_screen renders cleanly on a wide surface', (
    tester,
  ) async {
    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    expect(tester.takeException(), isNull);
    // The three Studio panes are present under their stable keys so a
    // regression that drops one is caught here, not in the behaviour
    // suites.
    expect(find.byKey(studioTreePaneKey), findsOneWidget);
    expect(find.byKey(studioEditorPaneKey), findsOneWidget);
    expect(find.byKey(studioTerminalPaneKey), findsOneWidget);
    // Repo bar still sits above the workspace split and reads the active
    // binding — polish must not drop its identity surface.
    expect(find.byKey(studioRepoBarKey), findsOneWidget);
    expect(find.text('owner/repo'), findsOneWidget);
  });

  testWidgets('studio_file_tree renders rows under the shared Aether theme', (
    tester,
  ) async {
    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    expect(find.byType(StudioFileTree), findsOneWidget);
    expect(find.text('FILES'), findsOneWidget);
    // Tree rows for the seeded repository are visible — the file tree
    // widget is the only thing in this test that paints `lib` and
    // `README.md`.
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('studio_editor renders its tab strip and no-file hint', (
    tester,
  ) async {
    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    expect(find.byType(StudioEditorTabs), findsOneWidget);
    expect(find.byType(StudioEditor), findsOneWidget);
    // No file open yet: the no-tabs hint and the empty-state view are
    // what the editor shows, through the polished Aether surfaces.
    expect(find.textContaining('No open files'), findsOneWidget);
    expect(find.textContaining('Ovid Studio'), findsOneWidget);
  });

  testWidgets('studio_terminal_tabs renders the terminal strip', (
    tester,
  ) async {
    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    expect(find.byType(StudioTerminalTabs), findsOneWidget);
    expect(find.text('TERMINALS'), findsOneWidget);
    expect(find.byTooltip('New terminal'), findsOneWidget);
    // The segmented control is the Aether primitive that renders the
    // per-shell pills.
    expect(find.byType(AetherSegmentedControl<int>), findsOneWidget);
  });

  testWidgets(
    'approval banner is an AetherCard with Approve primary + Decline ghost',
    (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      // Raise a plain tool approval (not a question / plan review): the
      // banner surfaces only this flavour of gate, as a run-blocking
      // AetherCard.
      final req = ApprovalRequest(
        tool: 'shell_exec',
        summary: 'Run `ls` in /tmp',
        detail: 'ls -la /tmp',
      );
      AgentService.I.pendingApproval = req;
      AgentService.I.notifyListeners();
      await tester.pumpAndSettle();

      // Banner anatomy: AetherCard shell, Approve primary + Decline ghost.
      expect(find.byType(AetherCard), findsWidgets);
      expect(find.text('Approval required'), findsOneWidget);
      expect(find.byType(AetherPrimaryButton), findsWidgets);
      expect(find.byType(AetherGhostButton), findsWidgets);
      expect(find.widgetWithText(AetherPrimaryButton, 'Approve'),
          findsOneWidget);
      expect(find.widgetWithText(AetherGhostButton, 'Decline'), findsOneWidget);

      // Approve resolves the completer with true — the approval gate the
      // banner was wired against is still intact (behaviour preservation).
      final completed = req.completer.future;
      await tester.tap(find.widgetWithText(AetherPrimaryButton, 'Approve'));
      await tester.pumpAndSettle();
      expect(await completed.timeout(const Duration(seconds: 2)), isTrue);
    },
  );

  testWidgets(
    'approval banner Decline resolves the pending gate with false',
    (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      final req = ApprovalRequest(
        tool: 'shell_exec',
        summary: 'Remove /tmp/foo',
        detail: 'rm -rf /tmp/foo',
      );
      AgentService.I.pendingApproval = req;
      AgentService.I.notifyListeners();
      await tester.pumpAndSettle();

      final completed = req.completer.future;
      await tester.tap(find.widgetWithText(AetherGhostButton, 'Decline'));
      await tester.pumpAndSettle();
      expect(await completed.timeout(const Duration(seconds: 2)), isFalse);
    },
  );
}
