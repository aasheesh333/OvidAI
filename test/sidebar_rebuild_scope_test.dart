import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sidebar.dart';

/// F-029 / F-030: the sidebar session list is lazy and its rows do not
/// rebuild for streamed tokens or unrelated agent events.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final bytes = await File('assets/fonts/Inter.ttf').readAsBytes();
    await (FontLoader(
      'Inter',
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AppState.I.sessions.clear();
    AppState.I.activeSessionId = null;
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  void seed(int sessions, int messagesEach) {
    final app = AppState.I;
    for (var i = 0; i < sessions; i++) {
      app.sessions.add(
        ChatSession(
          id: 'perf-$i',
          title: 'Session $i',
          model: 'm',
          mode: 'auto',
          messages: [
            for (var m = 0; m < messagesEach; m++)
              Message(
                role: m.isEven ? 'user' : 'assistant',
                content: 'message $m',
              ),
          ],
        ),
      );
    }
    app.activeSessionId = 'perf-0';
  }

  Future<void> pumpSidebar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 900);
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

  int tileBuilds() => SessionTileDebug.buildCount;

  testWidgets('3,000 sessions: only visible rows build, tokens rebuild none', (
    tester,
  ) async {
    seed(3000, 50);
    SessionTileDebug.reset();
    await pumpSidebar(tester);

    // Lazy list: a screenful of rows, not 3,000.
    final initial = tileBuilds();
    expect(initial, greaterThan(0));
    expect(initial, lessThan(60));

    final live = AppState.I.sessions.first.messages.last;
    SessionTileDebug.reset();
    for (var token = 0; token < 200; token++) {
      live.content += ' t$token';
      AgentService.I.liveBubbleTicks.value++;
      AgentService.I.refreshNow();
      await tester.pump();
    }
    // ≤ 1 build per token is the budget; the narrow listenables give 0.
    expect(tileBuilds(), lessThanOrEqualTo(200));
    expect(tileBuilds(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AppState refreshes that change no row do not rebuild rows', (
    tester,
  ) async {
    seed(200, 5);
    await pumpSidebar(tester);
    SessionTileDebug.reset();
    for (var i = 0; i < 50; i++) {
      AppState.I.refresh();
      await tester.pump();
    }
    expect(tileBuilds(), 0);

    // A title change does rebuild the visible rows.
    AppState.I.sessions[1].title = 'Renamed chat';
    AppState.I.refresh();
    await tester.pump();
    expect(tileBuilds(), greaterThan(0));
    expect(find.text('Renamed chat'), findsOneWidget);
  });

  testWidgets('busy flips repaint only the running badge', (tester) async {
    seed(20, 2);
    await pumpSidebar(tester);
    SessionTileDebug.reset();

    final run = AgentService.I.runBucketForTest('perf-3');
    run.activeRunId = 'run-1';
    AgentService.I.refreshNow();
    await tester.pump();
    expect(find.text('running'), findsOneWidget);
    expect(tileBuilds(), 0);

    run.activeRunId = null;
    AgentService.I.refreshNow();
    await tester.pump();
    expect(find.text('running'), findsNothing);
    expect(tileBuilds(), 0);
  });

  test('hasImage is cached and follows appends and truncation', () {
    final s = ChatSession(
      id: 'img',
      title: 't',
      model: 'm',
      mode: 'auto',
      messages: [Message(role: 'user', content: 'hi')],
    );
    expect(s.hasImage, isFalse);
    s.messages.add(
      Message(role: 'assistant', kind: MsgKind.imageGen, imagePath: '/x.png'),
    );
    expect(s.hasImage, isTrue);
    s.messages.add(Message(role: 'user', content: 'more'));
    expect(s.hasImage, isTrue);
    s.messages.removeRange(1, s.messages.length);
    expect(s.hasImage, isFalse);
  });
}
