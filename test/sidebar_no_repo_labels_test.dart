import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Binding user revision (2026-09-24): the session sidebar shows NO repo
/// name at all. Sessions render as a flat list under the original
/// headings ("Ovid" brand, "New session", "Search sessions", "SESSIONS") —
/// the workspace-folder grouping that rendered labels like
/// `AASHEESH333__OVIDAI__MAIN` is gone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  setUpAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDownAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  Future<void> pumpSidebar(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        // Same overflow guard as delete_row_actions_test's harness.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
        home: const Scaffold(body: SessionsSidebar()),
      ),
    );
  }

  testWidgets('no repo/workspace group labels; all sessions listed flat', (
    tester,
  ) async {
    final bound = ChatSession(
      id: 'bound',
      title: 'Bound session',
      model: 'm',
      workspaceFolder: '/data/repos/AASHEESH333__OVIDAI__MAIN',
      repo: 'aasheesh333/OvidAI',
    );
    final plain = ChatSession(
      id: 'plain',
      title: 'Plain session',
      model: 'm',
    );
    app.sessions
      ..clear()
      ..addAll([bound, plain]);
    app.activeSessionId = bound.id;

    await pumpSidebar(tester);

    // Both sessions render.
    expect(find.text('Bound session'), findsOneWidget);
    expect(find.text('Plain session'), findsOneWidget);
    // No group header derived from the workspace folder or repo.
    expect(find.text('AASHEESH333__OVIDAI__MAIN'), findsNothing);
    expect(find.text('(NO WORKSPACE)'), findsNothing);
    expect(find.text('(no workspace)'), findsNothing);
    expect(find.text('AASHEESH333/OVIDAI'), findsNothing);
    // Original headings are intact.
    expect(find.text('Ovid'), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);
    expect(find.text('SESSIONS'), findsOneWidget);
  });

  testWidgets('search still filters the flat session list', (tester) async {
    app.sessions
      ..clear()
      ..addAll([
        ChatSession(
          id: 'a',
          title: 'Alpha work',
          model: 'm',
          workspaceFolder: '/x/REPO_ONE',
        ),
        ChatSession(
          id: 'b',
          title: 'Beta work',
          model: 'm',
          workspaceFolder: '/y/REPO_TWO',
        ),
      ]);
    app.activeSessionId = 'a';

    await pumpSidebar(tester);
    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pump();

    expect(find.text('Beta work'), findsOneWidget);
    expect(find.text('Alpha work'), findsNothing);
  });
}
