import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SessionProjection.fromEvents projects without ledger I/O', () {
    final p = SessionProjection.fromEvents([
      {'kind': 'turn_start', 't': '2026-10-11T10:00:00.000Z'},
      {'kind': 'tool_start', 'tool': 'read'},
      {'kind': 'tool_end', 'tool': 'read', 'ms': 30},
      {'kind': 'tool_start', 'tool': 'read'},
      {'kind': 'tool_end', 'tool': 'read', 'ms': 12},
      {'kind': 'tool_start', 'tool': 'bash'},
      {'kind': 'llm', 'ms': 7},
      {'kind': 'turn_start', 't': '2026-10-11T10:00:05.000Z'},
      {'kind': 'turn_end', 't': '2026-10-11T10:00:10.000Z'},
      {'kind': 'note'},
    ]);
    expect(p.turns, 2);
    expect(p.steps, 3);
    expect(p.toolMs, 42);
    expect(p.llmMs, 7);
    expect(p.wallMs, 10000);
    expect(p.toolCounts, {'read': 2, 'bash': 1});
    expect(SessionProjection.fromEvents(const []).turns, 0);
  });

  group('ledger paging', () {
    late Directory root;
    late AppState app;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      app = AppState.createForTest();
      app.seenWelcomeVersion = AppState.welcomeVersion;
      root = await Directory.systemTemp.createTemp('trajectory-paging-');
      SessionLedger.rootOverrideForTest = root;
    });

    tearDown(() async {
      for (final sid in SessionLedger.I.sinkOpensForTest.keys.toList()) {
        await SessionLedger.I.close(sid);
      }
      SessionLedger.rootOverrideForTest = null;
      AppState.resetTestInstance();
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('readTail returns newest page and whole-ledger projection', () async {
      for (var i = 0; i < 5; i++) {
        await SessionLedger.I.append('tail', 'tool_start', {'tool': 't$i'});
      }
      SessionLedger.scansForTest = 0;
      final tail = await SessionLedger.I.readTail('tail', limit: 2);
      expect(SessionLedger.scansForTest, 1);
      expect(tail.total, 5);
      expect(tail.firstOffset, 3);
      expect(tail.events.map((e) => e['seq']), [4, 5]);
      expect(tail.projection.steps, 5);
      final earlier = await SessionLedger.I.read('tail', offset: 1, limit: 2);
      expect(earlier.map((e) => e['seq']), [2, 3]);
      expect(
        (await SessionLedger.I.readTail('missing')).events,
        isEmpty,
      );
    });

    testWidgets('trajectory opens with one scan and pages older events', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = ChatSession(
        id: 'paging',
        title: 'Paging',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.add(session);
      const total = TrajectoryScreen.pageSize + 50;

      Future<void> settleIo() async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        bool busy() =>
            find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
            find.text('Loading…').evaluate().isNotEmpty;
        do {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        } while (busy() && DateTime.now().isBefore(deadline));
      }

      await tester.runAsync(() async {
        await SessionLedger.I.append(session.id, 'turn_start', {'turn': 1});
        for (var i = 1; i < total; i++) {
          await SessionLedger.I.append(session.id, 'tool_start', {
            'tool': 'read',
          });
        }
        SessionLedger.scansForTest = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: TrajectoryScreen(sessionId: session.id),
          ),
        );
        await settleIo();
      });
      expect(SessionLedger.scansForTest, 1, reason: 'one scan on open');
      // Projection covers the whole ledger even though only a page is loaded.
      expect(
        find.textContaining('1 turns · ${total - 1} tool calls'),
        findsOneWidget,
      );
      final more = find.byKey(const ValueKey('trajectory-load-earlier'));
      expect(more, findsOneWidget);
      expect(find.text('Show 50 earlier events'), findsOneWidget);
      expect(find.text('#51 · Tool: read'), findsOneWidget);
      expect(find.text('#50 · Tool: read'), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(more);
        await settleIo();
      });
      expect(SessionLedger.scansForTest, 2);
      expect(more, findsNothing);
      expect(find.text('#1 · Turn start (turn 1)'), findsOneWidget);
    });
  });
}
