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
import 'package:ovid_ai/ui/v2/app/bottom_nav.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/settings/settings_hub.dart';

/// The shell owns the bottom bar and the live status line. These assertions
/// pin the wiring the audit found missing: the bar is mounted, every tab
/// navigates, the stalled watchdog reaches the status label, and `@` refs have
/// a resolver installed.
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
}

class _ShellFacade extends CloudAgentFacade {
  _ShellFacade({required super.rest, required super.ws}) : super(store: null);

  bool stalled = false;

  @override
  bool stalledFor(String sessionId) => stalled;
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
          throw StateError('the wiring test opens no socket'),
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
    v2SessionRefResolver = null;
  });

  ChatSession liveSession() {
    final session = ChatSession(
      id: 'shell-wiring',
      title: 'Wiring test',
      model: 'auto',
      createdAt: DateTime(2026, 10, 21, 10),
    );
    session.messages.add(
      Message(
        role: 'user',
        content: 'Build the landing page',
        time: DateTime(2026, 10, 21, 10),
      ),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    return session;
  }

  testWidgets('the bottom bar is mounted and the Settings tab navigates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    liveSession();
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    expect(find.byType(V2BottomNav), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-nav-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-nav-studio')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-nav-browser')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-nav-library')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-nav-settings')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('v2-nav-settings')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsHubPage), findsOneWidget);

    // The selected tab follows the pushed route.
    final nav = tester.widget<V2BottomNav>(find.byType(V2BottomNav));
    expect(nav.current, V2NavTab.settings);

    // Chat returns to the transcript.
    await tester.tap(find.byKey(const ValueKey('v2-nav-chat')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsHubPage), findsNothing);
    expect(
      tester.widget<V2BottomNav>(find.byType(V2BottomNav)).current,
      V2NavTab.chat,
    );
  });

  testWidgets('the route switches from the empty chat to the transcript', (
    tester,
  ) async {
    final session = ChatSession(
      id: 'shell-empty',
      title: 'Empty chat',
      model: 'auto',
      createdAt: DateTime(2026, 10, 21, 10),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    expect(find.byType(V2ChatPage), findsOneWidget);

    session.messages.add(
      Message(
        role: 'user',
        content: 'First message',
        time: DateTime(2026, 10, 21, 10, 1),
      ),
    );
    app.refresh();
    await tester.pump();

    expect(find.byType(V2LiveChatPage), findsOneWidget);
    expect(find.byType(V2ChatPage), findsNothing);
  });

  testWidgets('the stalled watchdog drives the live status label', (
    tester,
  ) async {
    final session = liveSession();
    facade.setActiveRunForTest(session.id, 'run-1');
    facade.stalled = true;

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    expect(find.text('Still working…'), findsOneWidget);
  });

  testWidgets('the shell installs the @-ref server-id resolver', (
    tester,
  ) async {
    liveSession();
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    final resolver = v2SessionRefResolver;
    expect(resolver, isNotNull);
    // An unmapped local id passes through unchanged; the resolver never
    // returns an empty ref.
    expect(resolver!('local-session'), 'local-session');
  });
}
