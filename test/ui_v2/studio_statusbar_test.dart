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
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Studio v2 status bar: the six stacked banners (repo bar, sync progress,
/// sync error, clone status, plus the auth badge folded into the app bar)
/// collapse into ONE calm status line —
/// `repo@branch · sync state · Ln:Col` — with a status dot only when
/// something needs attention and a tap that opens a details sheet. The
/// sandbox-missing banner stays as its own actionable banner and the
/// approval flow stays inline (safety), only restyled.
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
    AgentService.I.openStudioFile('lib/a.dart', 'void a() {}');
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

  void setSurface(WidgetTester tester, Size size, {double dpr = 1.0}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
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

  /// The attention dot's semantics label — present only when something
  /// (sync failure, pending approval) needs the user.
  Finder attentionDot() => find.byWidgetPredicate(
        (w) =>
            w is Semantics && w.properties.label == 'Workspace needs attention',
      );

  testWidgets('status bar shows repo@branch, sync state and cursor', (
    tester,
  ) async {
    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    expect(tester.takeException(), isNull);
    // One bar, under the long-standing key.
    expect(find.byKey(studioRepoBarKey), findsOneWidget);
    final bar = find.byKey(studioRepoBarKey);
    // repo@branch — composed as repo + '@' + branch so the binding reads as
    // a single `owner/repo@main` identity.
    expect(find.descendant(of: bar, matching: find.text('owner/repo')),
        findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('@')), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('main')),
        findsOneWidget);
    // Sync state segment: calm steady state reads as synced.
    expect(find.descendant(of: bar, matching: find.text(' · Synced')),
        findsOneWidget);
    // Ln:Col segment: a file is open with the caret at the top.
    expect(find.descendant(of: bar, matching: find.textContaining('Ln 1:1')),
        findsOneWidget);
    // Nothing needs attention → no dot.
    expect(attentionDot(), findsNothing);
  });

  testWidgets('tapping the status bar opens the details sheet', (
    tester,
  ) async {
    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    await tester.tap(find.text(' · Synced'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Workspace status'), findsOneWidget);
    expect(find.text('Change repository'), findsOneWidget);
    expect(find.text('Change branch'), findsOneWidget);

    // Dismiss through the barrier; the sheet must not linger.
    await tester.tapAt(const Offset(12, 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Workspace status'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app bar slims to back + title + commit + overflow + account '
      'on 360x640 @2x', (tester) async {
    // 360x640 logical at devicePixelRatio 2.
    setSurface(tester, const Size(720, 1280), dpr: 2.0);
    await pumpStudio(tester);

    expect(tester.takeException(), isNull,
        reason: 'slim app bar must not overflow at 360dp');
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    // Primary actions stay: files, commit, overflow, the merged account chip.
    expect(find.byTooltip('Toggle files'), findsOneWidget);
    expect(
      find.byTooltip('Commit ${RepoCache.I.dirtyCount} pending file(s)'),
      findsOneWidget,
    );
    expect(find.byTooltip('More Studio actions'), findsOneWidget);
    expect(find.byTooltip('GitHub account'), findsOneWidget);
    // Secondary actions fold into the overflow menu.
    expect(find.byTooltip('Working folder'), findsNothing);
    expect(find.byTooltip('Sync repo'), findsNothing);

    await tester.tap(find.byTooltip('More Studio actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Working folder'), findsWidgets);
    expect(find.text('Sync repo'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('approval still surfaces inline and resolves the gate', (
    tester,
  ) async {
    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    final req = ApprovalRequest(
      tool: 'shell_exec',
      summary: 'Run `ls` in /tmp',
      detail: 'ls -la /tmp',
    );
    AgentService.I.pendingApproval = req;
    AgentService.I.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // The safety surface is untouched: an inline card with Approve/Decline.
    expect(find.text('Approval required'), findsOneWidget);
    expect(find.widgetWithText(AetherPrimaryButton, 'Approve'),
        findsOneWidget);
    expect(find.widgetWithText(AetherGhostButton, 'Decline'), findsOneWidget);
    // ...and the calm bar flags that attention is needed.
    expect(attentionDot(), findsOneWidget);

    final completed = req.completer.future;
    await tester.tap(find.widgetWithText(AetherPrimaryButton, 'Approve'));
    await tester.pump();
    expect(await completed.timeout(const Duration(seconds: 2)), isTrue);
  });

  testWidgets('sandbox-missing banner stays a single actionable banner', (
    tester,
  ) async {
    SandboxService.I.setInstallInFlightForTest(false);
    SandboxService.I.resetCheckExistingForTest();
    SandboxService.execCheckedOverrideForTest = null;
    addTearDown(() {
      SandboxService.I.setInstallInFlightForTest(false);
      SandboxService.I.resetCheckExistingForTest();
      SandboxService.execCheckedOverrideForTest = null;
    });
    app.sandboxInstalled = false;
    app.sandboxSkipped = false;

    setSurface(tester, const Size(1200, 900));
    await pumpStudio(tester);

    expect(
      find.text('Sandbox not installed — the terminal needs the one-time '
          'setup.'),
      findsOneWidget,
    );
    expect(find.text('Install'), findsOneWidget);

    // Actionable: Install routes through openStudio → the setup screen.
    // Bounded pumps only — the setup screen runs a 1s ticker.
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SandboxSetupScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
