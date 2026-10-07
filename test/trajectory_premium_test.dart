import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppState app;

  setUp(() async {
    AppState.resetTestInstance();
    app = AppState.createForTest();
    root = await Directory.systemTemp.createTemp('trajectory-premium-');
    SessionLedger.rootOverrideForTest = root;
  });

  tearDown(() async {
    for (final id in SessionLedger.I.sinkOpensForTest.keys.toList()) {
      await SessionLedger.I.close(id);
    }
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpReady(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: TrajectoryScreen(sessionId: id)),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
  }

  testWidgets('shows outcome-accurate event labels and accessible details',
      (tester) async {
    const id = 'trajectory-premium-outcomes';
    app.sessions.add(ChatSession(id: id, title: 'Outcomes', model: 'm', mode: 'auto'));
    await tester.runAsync(() async {
      await SessionLedger.I.append(id, 'tool_end', {
        'tool': 'search', 'ms': 12, 'ok': true,
      });
      await SessionLedger.I.append(id, 'tool_end', {
        'tool': 'write', 'ms': 18, 'ok': false, 'error': 'permission denied',
      });
      await SessionLedger.I.append(id, 'subagent_end', {
        'agent': 'researcher', 'ok': false, 'error': 'timed out',
      });
    });
    await pumpReady(tester, id);

    expect(find.text('Tool succeeded: search'), findsOneWidget);
    expect(find.text('Tool failed: write'), findsOneWidget);
    expect(find.text('Subagent failed: researcher'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNWidgets(2));
    expect(find.bySemanticsLabel('Tool failed: write. 18ms. Error: permission denied'), findsOneWidget);
  });

  testWidgets('renders responsive stats with explicit labels', (tester) async {
    const id = 'trajectory-premium-stats';
    app.sessions.add(ChatSession(id: id, title: 'Stats', model: 'm', mode: 'auto'));
    await tester.runAsync(() async {
      await SessionLedger.I.append(id, 'turn_start', {'turn': 1});
      await SessionLedger.I.append(id, 'tool_start', {'tool': 'search'});
      await SessionLedger.I.append(id, 'turn_end', {'llmMs': 120});
    });
    await pumpReady(tester, id);

    expect(find.text('Turns'), findsOneWidget);
    expect(find.text('Tool calls'), findsOneWidget);
    expect(find.text('Wall time'), findsOneWidget);
    expect(find.text('LLM time'), findsOneWidget);
    expect(find.text('Tool time'), findsOneWidget);
  });

  testWidgets('keeps the existing timeline visible while reloading', (tester) async {
    const id = 'trajectory-premium-refresh';
    app.sessions.add(ChatSession(id: id, title: 'Refresh', model: 'm', mode: 'auto'));
    await tester.runAsync(() async {
      await SessionLedger.I.append(id, 'note', {'text': 'Existing timeline'});
    });
    await pumpReady(tester, id);

    await tester.tap(find.byTooltip('Reload ledger'));
    await tester.pump();

    expect(find.text('Existing timeline'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
