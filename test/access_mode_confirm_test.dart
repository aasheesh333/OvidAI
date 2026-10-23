import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

class _OkRest extends CloudRestClient {
  _OkRest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  @override
  Future<SessionDto> patchSession(String id,
          {String? title, String? mode, bool? pinned}) async =>
      SessionDto(
        id: id,
        title: title,
        mode: mode ?? 'auto',
        createdAt: DateTime.utc(2026, 10, 18),
        updatedAt: DateTime.utc(2026, 10, 18),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ChatSession session;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    CloudAgentFacade.resetForTest();
    CloudAgentFacade.installForTest(
      CloudAgentFacade(
        rest: _OkRest(),
        ws: WsMultiplexer(
          mintTicket: () async => 'ticket',
          socketFactory: (_) async =>
              throw UnimplementedError('no socket in this test'),
          heartbeatInterval: const Duration(hours: 1),
        ),
        store: null,
      ),
    );
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    debugResetFullAccessConfirmations();
    session = ChatSession(
      id: 'mode-confirm',
      title: 'Chat',
      model: 'm',
      mode: AgentMode.auto.name,
      messages: [Message(role: 'assistant', content: 'Ready')],
    );
    app.sessions
      ..clear()
      ..add(session);
    app.activeSessionId = session.id;
  });

  tearDown(() {
    debugResetFullAccessConfirmations();
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> pickFullAccess(WidgetTester tester) async {
    await tester.tap(find.text(AgentMode.auto.label).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('Agent access mode'), findsOneWidget);
    expect(find.textContaining('Tools run without asking'), findsOneWidget);
    await tester.tap(find.text(AgentMode.drive.label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('choosing Full Access asks; cancel leaves the mode unchanged', (
    tester,
  ) async {
    await pumpChat(tester);
    await pickFullAccess(tester);
    expect(find.byKey(const ValueKey('full-access-confirm')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(session.mode, AgentMode.auto.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming switches this session and is asked once', (
    tester,
  ) async {
    await pumpChat(tester);
    await pickFullAccess(tester);
    await tester.tap(find.text('Switch to Full Access'));
    await tester.pumpAndSettle();
    expect(session.mode, AgentMode.drive.name);

    // Back to General (no confirmation needed), then Full Access again:
    // already confirmed for this session and nothing is running.
    CloudAgentFacade.I.setMode(AgentMode.auto, sessionId: session.id);
    AppState.I.refresh();
    await tester.pumpAndSettle();
    await pickFullAccess(tester);
    expect(find.byKey(const ValueKey('full-access-confirm')), findsNothing);
    expect(session.mode, AgentMode.drive.name);
  });

  test('setMode with a sessionId only changes that session', () {
    final other = ChatSession(
      id: 'other',
      title: 'Other',
      model: 'm',
      mode: AgentMode.auto.name,
      planMode: true,
    );
    AppState.I.sessions.add(other);
    CloudAgentFacade.I.setMode(AgentMode.studio, sessionId: session.id);
    expect(session.mode, AgentMode.studio.name);
    expect(other.mode, AgentMode.auto.name);
    expect(other.planMode, isTrue);
  });
}
