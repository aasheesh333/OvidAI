import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_pins.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/queue_dock.dart';

/// The live shell owns the composer queue: the dock count/preview come from
/// `CloudAgentFacade`, "Send now" dispatches the queued head and the dock's
/// dismiss removes only the first row. These are host-wiring assertions, so
/// the facade records the stop instead of hitting the network.
class _ShellRest extends CloudRestClient {
  _ShellRest()
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async => const SendMessageResponse(
    runId: 'run-1',
    userMessageId: 'msg-1',
    status: 'queued',
  );

  @override
  Future<RunCancelResponse> cancelRun(String runId) async =>
      RunCancelResponse(runId: runId, status: 'cancelled');
}

class _ShellFacade extends CloudAgentFacade {
  _ShellFacade({required super.rest, required super.ws}) : super(store: null);

  int dispatchQueuedCalls = 0;

  @override
  bool stopRequested({required String sessionId, bool dispatchQueued = false}) {
    if (dispatchQueued) dispatchQueuedCalls++;
    return true;
  }
}

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late WsMultiplexer ws;
  late _ShellFacade facade;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async =>
          throw StateError('the queue-only shell test opens no socket'),
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    facade = _ShellFacade(rest: _ShellRest(), ws: ws);
    CloudAgentFacade.installForTest(facade);
    ProjectsController.installForTest(_SilentProjects());
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();
  });

  tearDown(() async {
    await ws.disconnect();
    facade.dispose();
    CloudAgentFacade.resetForTest();
    ProjectsController.resetForTest();
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();
    AppState.resetTestInstance();
  });

  ChatSession liveSession() {
    final session = ChatSession(
      id: 'shell-queue',
      title: 'Queue test',
      model: 'auto',
      createdAt: DateTime(2026, 10, 21, 10),
    );
    session.messages.addAll([
      Message(
        role: 'user',
        content: 'Build the landing page',
        time: DateTime(2026, 10, 21, 10),
      ),
      Message(
        role: 'assistant',
        content: 'Working on it.',
        time: DateTime(2026, 10, 21, 10, 0, 2),
      ),
    ]);
    app.sessions.add(session);
    app.activeSessionId = session.id;
    return session;
  }

  testWidgets('the dock shows the live queue and Send now dispatches it', (
    tester,
  ) async {
    final session = liveSession();
    facade.setActiveRunForTest(session.id, 'run-1');
    facade.enqueueMessage('Queue me first', sessionId: session.id);
    facade.enqueueMessage('Then this one', sessionId: session.id);

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    // Count comes from the facade's real queue, not a hard-coded zero. The
    // dock is one line: count, "Send now", dismiss — no preview paragraph.
    expect(find.text('2 queued'), findsOneWidget);
    expect(find.text('Queue me first'), findsNothing);

    await tester.tap(find.text('Send now'));
    await tester.pump();

    expect(facade.dispatchQueuedCalls, 1);
    expect(
      facade.queuedCountFor(session.id),
      2,
      reason: 'send-now dispatches; it does not drop the rows locally',
    );

    // Dismiss removes exactly the first queued message and the dock follows.
    await tester.tap(
      find.descendant(
        of: find.byType(V2QueueDock),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pump();

    expect(facade.queuedCountFor(session.id), 1);
    expect(find.text('1 queued'), findsOneWidget);
    expect(find.text('Then this one'), findsNothing);
    expect(find.text('Queue me first'), findsNothing);
  });
}
