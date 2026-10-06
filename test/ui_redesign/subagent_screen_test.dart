// Aether redesign — Subagent screen smoke tests.
//
// Covers the redesigned surfaces of lib/ui/subagent_screen.dart:
//   • the transcript view's status strip (AetherStatusDot + AetherPill) and
//     its Stop affordances while a child is running,
//   • the subagent catalog sheet: AetherCard per child with name, status
//     AetherPill, runtime caption and an AetherGhostButton "Stop" for running
//     children, and the AetherEmptyState when nothing was dispatched.
//
// These are smoke tests for the redesign contract AND the preserved behavior:
// tapping the ghost Stop still routes to AgentService.stopSubagentRun, and
// tapping a card still opens the child's own SubagentScreen transcript.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/subagent_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    agent.debugPauseScheduleTimerForTest(true);
    SessionLedger.rootOverrideForTest =
        await Directory.systemTemp.createTemp('wave2-subagent-');
  });

  tearDown(() {
    agent.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final root = SessionLedger.rootOverrideForTest;
    SessionLedger.rootOverrideForTest = null;
    try {
      root?.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget host(Widget child) => MaterialApp(theme: Aether.theme(), home: child);

  // A running child keeps an AetherStatusDot pulsing (a repeating animation),
  // so pumpAndSettle would spin forever. Advance by bounded durations instead.
  Future<void> pumpBrief(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  ChatSession parent({required String id}) =>
      ChatSession(id: id, title: 'Parent', model: 'm', mode: 'auto');

  ChatSession child({
    required String id,
    required String parentId,
    required String title,
    String state = 'finished',
    bool continuable = false,
  }) => ChatSession(
    id: id,
    title: title,
    model: 'm',
    mode: 'auto',
    parentId: parentId,
    agentLabel: title,
    agentState: state,
    agentContinuable: continuable,
  );

  Future<void> openCatalog(WidgetTester tester, String parentId) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showSubagentCatalog(context, parentId),
                child: const Text('open-catalog'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-catalog'));
    await pumpBrief(tester);
  }

  testWidgets('gone state renders for a stale session id', (tester) async {
    await tester.pumpWidget(host(const SubagentScreen(sessionId: 'gone')));
    await tester.pump();
    expect(find.text('This subagent session is gone.'), findsOneWidget);
  });

  testWidgets(
    'running subagent mounts Aether status strip and stop affordances',
    (tester) async {
      final p = parent(id: 'smoke-p');
      final c = child(
        id: 'smoke-c',
        parentId: p.id,
        title: 'Scout',
        state: 'running',
        continuable: true,
      );
      app.sessions.addAll([p, c]);
      agent.runBucketForTest(c.id).activeRunId = 'r-smoke';

      await tester.pumpWidget(host(SubagentScreen(sessionId: c.id)));
      await pumpBrief(tester);

      // Status strip: pulsing Aether dot + filled state pill.
      expect(
        find.byKey(const ValueKey('subagent-status-dot')),
        findsOneWidget,
      );
      expect(find.widgetWithText(AetherPill, 'running'), findsOneWidget);
      // Name in the app bar; both Stop entry points preserved (app bar and
      // the live composer of a continuable child).
      expect(find.text('Scout'), findsOneWidget);
      expect(find.byTooltip('Stop this subagent'), findsOneWidget);
      expect(find.byTooltip('Stop'), findsOneWidget);
      // Empty transcript of a running child shows the starting hint.
      expect(find.text('Starting…'), findsOneWidget);

      agent.dropSessionRun(c.id);
    },
  );

  testWidgets(
    'catalog renders AetherEmptyState when the parent dispatched nothing',
    (tester) async {
      final p = parent(id: 'smoke-empty-p');
      app.sessions.add(p);
      await openCatalog(tester, p.id);

      expect(
        find.byKey(const ValueKey('subagent-catalog-empty')),
        findsOneWidget,
      );
      expect(find.byType(AetherEmptyState), findsOneWidget);
      expect(find.text('No subagents yet'), findsOneWidget);
      expect(find.byType(AetherCard), findsNothing);
    },
  );

  testWidgets(
    'catalog renders an AetherCard per subagent with pill, runtime caption '
    'and ghost Stop; stop and open contracts preserved',
    (tester) async {
      final p = parent(id: 'smoke-list-p');
      final running = child(
        id: 'smoke-list-running',
        parentId: p.id,
        title: 'child-running',
        state: 'running',
      );
      final done = child(
        id: 'smoke-list-done',
        parentId: p.id,
        title: 'child-done',
      );
      app.sessions.addAll([p, running, done]);
      agent.runBucketForTest(running.id).activeRunId = 'r-running';

      await openCatalog(tester, p.id);

      // One card per dispatched child; each carries its name, a status pill
      // and the runtime caption (schedule icon + elapsed/placeholder).
      expect(find.byType(AetherCard), findsNWidgets(2));
      expect(find.byType(AetherPill), findsNWidgets(2));
      expect(find.byIcon(Icons.schedule), findsNWidgets(2));
      expect(find.text('child-running'), findsOneWidget);
      expect(find.text('child-done'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'running'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'finished'), findsOneWidget);

      // Ghost Stop only for the running child.
      expect(find.byType(AetherGhostButton), findsOneWidget);
      expect(
        find.byKey(ValueKey('subagent-stop-${running.id}')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('subagent-stop-${done.id}')), findsNothing);

      // Stop contract: the ghost button still stops the run.
      await tester.tap(find.byKey(ValueKey('subagent-stop-${running.id}')));
      await pumpBrief(tester);
      expect(agent.busyFor(running.id), isFalse);
      expect(running.agentState, 'stopped');
      expect(
        find.byKey(ValueKey('subagent-stop-${running.id}')),
        findsNothing,
      );

      // Dispatch/open contract: tapping a card opens the child's own
      // transcript screen.
      await tester.tap(find.text('child-done'));
      await pumpBrief(tester);
      expect(find.byType(SubagentScreen), findsOneWidget);
      expect(find.text('No activity recorded.'), findsOneWidget);

      agent.dropSessionRun(running.id);
    },
  );
}
