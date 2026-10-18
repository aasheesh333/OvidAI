import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

/// F-046 recency order + date headers and F-047 debounced message search.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  }

  late AppState app;
  final now = DateTime.now();

  ChatSession chat(String id, String title, Duration age, List<String> body) =>
      ChatSession(
        id: id,
        title: title,
        model: 'gpt-noise',
        createdAt: now.subtract(age),
        messages: [
          for (final text in body)
            Message(role: 'user', content: text, time: now.subtract(age)),
        ],
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    app.sessions
      ..clear()
      ..addAll([
        chat('older', 'Trip planning', const Duration(days: 40), [
          'pack the snorkel for the reef',
        ]),
        chat('today', 'Morning notes', const Duration(minutes: 5), ['hi']),
        chat('yesterday', 'Recipe ideas', const Duration(days: 1), ['pasta']),
        chat('week', 'Budget review', const Duration(days: 4), ['numbers']),
      ]);
    app.activeSessionId = 'today';
  });

  tearDown(() async {
    AppState.resetTestInstance();
    await SessionHistoryRepository.I.resetForTest();
  });


  Future<void> pumpSidebar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: SessionsSidebar(isDrawer: false)),
      ),
    );
    await tester.pump();
  }

  double y(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('long lists stay lazy and the group header stays pinned', (
    tester,
  ) async {
    app.sessions
      ..clear()
      ..addAll([
        for (var i = 0; i < 300; i++)
          chat('t$i', 'Today chat $i', Duration(seconds: i + 1), ['x']),
        chat('old', 'Ancient chat', const Duration(days: 60), ['y']),
      ]);
    app.activeSessionId = 't0';
    await pumpSidebar(tester);
    // Only a screenful is built.
    expect(find.text('Today chat 0'), findsOneWidget);
    expect(find.text('Today chat 299'), findsNothing);
    expect(find.text('Ancient chat'), findsNothing);
    final headerY = y(tester, 'Today');
    final scroll = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    ).last;
    await tester.drag(scroll, const Offset(0, -600));
    await tester.pump();
    // Scrolled past the first rows, the "Today" header is still on top.
    expect(find.text('Today chat 0'), findsNothing);
    expect(find.text('Today'), findsOneWidget);
    expect(y(tester, 'Today'), closeTo(headerY, 0.5));
  });

  testWidgets('chats are ordered by recency under date headers', (
    tester,
  ) async {
    await pumpSidebar(tester);
    final order = [
      'Today',
      'Morning notes',
      'Yesterday',
      'Recipe ideas',
      'Previous 7 days',
      'Budget review',
      'Older',
      'Trip planning',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        y(tester, order[i - 1]),
        lessThan(y(tester, order[i])),
        reason: '${order[i - 1]} above ${order[i]}',
      );
    }

    // Sending in the old chat moves it to the top under "Today".
    app.selectSession('older');
    app.sendMessage('back to this trip');
    await tester.pump();
    expect(y(tester, 'Trip planning'), lessThan(y(tester, 'Morning notes')));
    expect(find.text('Older'), findsNothing);
  });

  testWidgets('search: titles instantly, message bodies after debounce', (
    tester,
  ) async {
    await pumpSidebar(tester);
    final field = find.byType(TextField);

    await tester.enterText(field, 'gpt');
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('No sessions match'),
      findsOneWidget,
      reason: 'model names are no longer matched',
    );

    await tester.enterText(field, 'recipe');
    await tester.pump();
    expect(find.text('Recipe ideas'), findsOneWidget);
    expect(find.text('Trip planning'), findsNothing);

    await tester.enterText(field, 'snork');
    await tester.pump();
    expect(find.byKey(const ValueKey('content-hit-older')), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('content-hit-older')),
      findsNothing,
      reason: 'still inside the 200 ms debounce',
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.byKey(const ValueKey('content-hit-older')), findsOneWidget);
    expect(find.text('In messages'), findsOneWidget);
    expect(find.textContaining('snorkel', findRichText: true), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('content-hit-older')));
    await tester.pump();
    expect(app.activeSessionId, 'older');
  });

  testWidgets('search uses the SQLite FTS index when enabled', (tester) async {
    final root = Directory.systemTemp.createTempSync('sidebar-fts-');
    addTearDown(() => root.deleteSync(recursive: true));
    SessionHistoryRepository.I.enableSqlite(
      path: '${root.path}/history.db',
      backgroundSearch: false,
    );
    await tester.runAsync(() async {
      await app.loadSessions();
      app.persistSessions();
      await app.flushSessionPersistenceForTest();
    });
    // Prove the hit comes from the index, not the in-memory scan.
    app.sessionById('older')!.messages.clear();
    await pumpSidebar(tester);
    await tester.enterText(find.byType(TextField), 'reef');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('content-hit-older')), findsOneWidget);
  });

  test('recency groups by calendar day', () {
    final at = DateTime(2026, 10, 11, 9);
    expect(sessionRecencyGroup(DateTime(2026, 10, 11, 0, 1), at), 'Today');
    expect(sessionRecencyGroup(DateTime(2026, 10, 10, 23), at), 'Yesterday');
    expect(sessionRecencyGroup(DateTime(2026, 10, 5), at), 'Previous 7 days');
    expect(sessionRecencyGroup(DateTime(2026, 10, 4), at), 'Older');
  });
}
