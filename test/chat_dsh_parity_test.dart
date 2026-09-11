import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_layout.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/transcript_model.dart';

/// End-to-end contract for the chat DSH-parity work (Tasks 1-7).
///
/// One session exercises every surface the project changed: the shared
/// centered content axis at wide and narrow widths, compact default-collapsed
/// reasoning/tool disclosures, a 5,000-message history that folds only a
/// bounded tail, `/preset plan` read-only policy with release on approval, and
/// the composer folder chip opening Studio. The bounded-fold observer is the
/// same optional diagnostic seam the Task 4 tests use.
int _foldedMessages = 0;
int _foldInvocations = 0;

Message _plain(String content, {String role = 'user'}) =>
    Message(role: role, kind: MsgKind.text, content: content);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    // The reminder tick runs forever; pause it so widget teardown is clean.
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
    _foldedMessages = 0;
    _foldInvocations = 0;
    transcriptFoldObserver = (n) {
      _foldedMessages += n;
      _foldInvocations += 1;
    };
  });

  tearDown(() {
    transcriptFoldObserver = null;
    workspaceChipOpenStudioForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  testWidgets('end-to-end DSH parity and large-history contract', (
    tester,
  ) async {
    // 5,000-message history whose tail carries one lone reasoning row and one
    // lone tool row (each followed by an answer, so they render as their own
    // collapsed disclosures rather than folding into a run).
    final messages = <Message>[
      for (var i = 0; i < 4994; i++) _plain('m$i'),
      _plain('hi'),
      Message(
        role: 'assistant',
        kind: MsgKind.reasoning,
        content: 'REASONING_BODY_TOKEN',
      ),
      _plain('answer one', role: 'assistant'),
      _plain('go'),
      Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'search',
        toolTitle: 'Search docs',
        toolSummary: 'query terms',
        toolDetail: 'DETAIL_BODY_TOKEN',
        toolState: 'ok',
      ),
      _plain('answer two', role: 'assistant'),
    ];
    expect(messages.length, 5000);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState.I;
    final session = ChatSession(
      id: 'parity-e2e',
      title: 'Parity',
      model: 'm',
      mode: 'auto',
      messages: messages,
    );
    session.workspaceFolder = '/tmp/some-pinned-folder';
    app.sessions.add(session);
    app.activeSessionId = session.id;

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // ── Large history opens with a bounded fold, tail rendered ────────────
    expect(find.text('answer two'), findsOneWidget);
    expect(find.text('m4993'), findsOneWidget);
    expect(
      _foldedMessages,
      lessThan(1000),
      reason: 'opening a 5,000-message session must not fold the history',
    );
    expect(_foldInvocations, lessThan(10));

    // ── Disclosures are compact and collapsed by default ──────────────────
    const reasoningSummary = ValueKey('chat-reasoning-summary');
    const reasoningBody = ValueKey('chat-reasoning-body');
    const toolSummary = ValueKey('chat-tool-summary');
    const toolBody = ValueKey('chat-tool-body');
    expect(find.byKey(reasoningSummary), findsOneWidget);
    expect(find.byKey(reasoningBody), findsNothing);
    expect(find.byKey(toolSummary), findsOneWidget);
    expect(find.byKey(toolBody), findsNothing);
    // The collapsed summary is a compact 28px line.
    expect(
      tester.getSize(find.byKey(reasoningSummary)).height,
      moreOrLessEquals(28, epsilon: 0.5),
    );
    // Tapping expands the body in place (proving it is a real disclosure).
    await tester.tap(find.byKey(reasoningSummary));
    await tester.pumpAndSettle();
    expect(find.byKey(reasoningBody), findsOneWidget);

    // ── One centered, capped column at wide and narrow widths ─────────────
    const columnKey = ValueKey('chat-transcript-column');
    const composerKey = ValueKey('chat-composer-card');
    final wideLayout = const ChatLayout(viewportWidth: 1400);
    final wideColumn = tester.getRect(find.byKey(columnKey));
    expect(
      wideColumn.width,
      moreOrLessEquals(wideLayout.contentWidth, epsilon: 0.5),
    );
    expect(wideColumn.center.dx, moreOrLessEquals(700, epsilon: 0.5));
    expect(
      tester.getSize(find.byKey(composerKey)).width,
      moreOrLessEquals(wideLayout.composerWidth, epsilon: 0.5),
    );

    // ── Folder chip opens Studio, never an in-chat picker ─────────────────
    var openedStudio = false;
    workspaceChipOpenStudioForTest = (_) => openedStudio = true;
    expect(find.text('some-pinned-folder'), findsOneWidget);
    await tester.tap(find.text('some-pinned-folder'));
    await tester.pump();
    expect(openedStudio, isTrue, reason: 'the folder chip must open Studio');
    expect(find.text('Working folder'), findsNothing);

    // ── Narrow pane collapses the column to the pane, still centered ──────
    tester.view.physicalSize = const Size(400, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final narrowLayout = const ChatLayout(viewportWidth: 400);
    final narrowColumn = tester.getRect(find.byKey(columnKey));
    expect(
      narrowColumn.width,
      moreOrLessEquals(narrowLayout.contentWidth, epsilon: 0.5),
    );
    expect(narrowColumn.width, moreOrLessEquals(400, epsilon: 0.5));
    expect(narrowColumn.center.dx, moreOrLessEquals(200, epsilon: 0.5));

    // ── `/preset plan` is read-only and releases on approval ──────────────
    await tester.runAsync(() async {
      AgentService.setRunSessionForTest(session.id);
      final res = await CommandService.I.execute('/preset plan');
      expect(res, isNotNull);
      expect(res!.feedback, contains('plan'));
      expect(session.presetId, 'plan');
      expect(session.planMode, isTrue);
      expect(session.mode, 'safe');
      expect(AgentService.I.mode, AgentMode.safe);

      // A mutating tool is refused under the read-only Plan policy.
      final denied = await AgentService.I.dispatchForTest('file_write', {
        'path': 'parity.txt',
        'content': 'x',
      });
      expect(denied, contains('PLAN MODE ACTIVE'));

      // Approving the plan releases the plan-owned read-only mode.
      final planFuture = AgentService.I.dispatchForTest('exit_plan_mode', {
        'plan': 'Do the thing',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(AgentService.I.pendingApproval, isNotNull);
      AgentService.I.approve(true);
      expect(await planFuture, contains('approved'));

      expect(session.planMode, isFalse);
      expect(
        session.mode,
        'auto',
        reason: 'plan-owned read-only must be released on approval',
      );
      expect(session.planPreMode, isNull);
    });
  });
}
