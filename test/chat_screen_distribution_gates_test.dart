// P8 Task 10 fix round — distribution gates in the chat surface.
//
// Task 20 removed the dual-path flags: the app is the thin client on every
// channel, so these tests pin the surviving (cloud) arm:
//   * the composer's on-device Skills / MCP-tool / plugin slash sources stay
//     gone;
//   * the header browser action always opens the cloud screencast viewer;
//   * `/c/<server-id>` reconciliation always runs.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/app_router.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

// ---------------------------------------------------------------------------
// Cloud fakes — only to keep the thin arm's `_bootCloud` off the network.
// The link starts disconnected, so `CloudSessionStore.offline` is true and
// `_bootCloud` skips reconciliation; the REST fakes are a safety net.
// ---------------------------------------------------------------------------

class _EmptyRest extends CloudRestClient {
  _EmptyRest({this.sessions = const []})
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<SessionDto> sessions;

  @override
  Future<SessionDto> createSession({String? title}) async => SessionDto(
    id: 'srv-created',
    title: title,
    mode: 'auto',
    createdAt: DateTime.utc(2026, 10, 17),
    updatedAt: DateTime.utc(2026, 10, 17),
  );

  @override
  Future<CloudPage<SessionDto>> listSessions({
    int limit = 50,
    String? cursor,
  }) async => CloudPage<SessionDto>(items: sessions, nextCursor: null);

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
    bool withEvents = false,
  }) async => const CloudPage<MessageDto>(items: [], nextCursor: null);
}

Future<void> _bindCloud({List<SessionDto> sessions = const []}) async {
  final prefs = await SharedPreferences.getInstance();
  final ws = WsMultiplexer(mintTicket: () async => 'ticket', prefs: prefs);
  final rest = _EmptyRest(sessions: sessions);
  final store = CloudSessionStore(
    rest: rest,
    cache: SessionHistoryRepository.I,
    prefs: prefs,
    connection: ConnectionService.forTest(),
    ws: ws,
  );
  final facade = CloudAgentFacade(rest: rest, ws: ws, store: store);
  CloudSessionStore.installForTest(store);
  CloudAgentFacade.installForTest(facade);
  await store.ready;
}

// ---------------------------------------------------------------------------
// Local-source seeds
// ---------------------------------------------------------------------------

void _seedCommand() {
  CommandService.I.register(
    AgentCommand(
      name: 'gatecheck',
      description: 'Gate test command',
      handler: (_) async => const CommandResult(),
    ),
  );
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

ChatSession _addSession(String id) {
  final s = ChatSession(id: id, title: 'Gate chat', model: 'm', mode: 'auto');
  AppState.I.sessions.add(s);
  AppState.I.activeSessionId = id;
  return s;
}

Future<void> _pumpChat(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openSlashMenu(WidgetTester tester) async {
  // Filter to the seeded sources: a bare `/` lists every built-in command,
  // pushing the Skills/MCP/plugin groups past the menu's 220px viewport
  // (ListView.builder never builds them, so `find` cannot see them).
  await tester.enterText(find.byKey(const ValueKey('chat-composer')), '/gate');
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    FlutterSecureStorage.setMockInitialValues(const <String, String>{});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    tmp = Directory.systemTemp.createTempSync('distribution-gates-');
  });

  tearDown(() async {
    CloudAgentFacade.resetForTest();
    CloudSessionStore.resetForTest();
    AppState.resetTestInstance();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('composer slash sources — cloud client', () {
    testWidgets('Browser header action is present and opens the cloud viewer', (
      tester,
    ) async {
      _addSession('gate-browser-default');
      await _bindCloud();
      await _pumpChat(tester);
      // The on-device WebView browser was removed (P8 Task 16); the header
      // action is the cloud screencast viewer and exists on every build.
      expect(find.byKey(const ValueKey('chat-header-browser')), findsOneWidget);
    });

    testWidgets('Skills, MCP tools and Plugins are NOT offered', (
      tester,
    ) async {
      _addSession('gate-thin');
      _seedCommand();
      await _bindCloud();
      await _pumpChat(tester);
      await _openSlashMenu(tester);

      // The menu is open (commands are still composer-side) …
      expect(find.text('COMMANDS'), findsOneWidget);
      expect(find.text('/gatecheck'), findsOneWidget);
      // … but the on-device runtime sources are gone.
      expect(find.text('SKILLS'), findsNothing);
      expect(find.text('MCP TOOLS'), findsNothing);
      expect(find.text('PLUGINS'), findsNothing);
      expect(find.text('/research'), findsNothing);
      expect(find.text('gate_tool'), findsNothing);
      expect(find.text('Gate Plugin'), findsNothing);
    });

    testWidgets('Browser header action opens the cloud viewer', (
      tester,
    ) async {
      _addSession('gate-browser-thin');
      await _bindCloud();
      await _pumpChat(tester);

      expect(find.byKey(const ValueKey('chat-header-browser')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-header-studio')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-header-more')), findsOneWidget);
    });
  });

  group('router — server ids', () {
    Future<(GlobalKey<NavigatorState>, GlobalKey<ScaffoldMessengerState>)>
    pumpShell(WidgetTester tester) async {
      final nav = GlobalKey<NavigatorState>();
      final messenger = GlobalKey<ScaffoldMessengerState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          scaffoldMessengerKey: messenger,
          home: const Scaffold(body: Text('root')),
        ),
      );
      return (nav, messenger);
    }

    testWidgets('unknown /c/<server-id> opens once reconciliation lands', (
      tester,
    ) async {
      await _bindCloud(
        sessions: [
          SessionDto(
            id: 'srv-9',
            title: 'Server chat',
            mode: 'auto',
            createdAt: DateTime.utc(2026, 10, 17),
            updatedAt: DateTime.utc(2026, 10, 17),
          ),
        ],
      );
      final (nav, messenger) = await pumpShell(tester);
      expect(AppState.I.sessionById('srv-9'), isNull);

      expect(
        AppRouter.go(
          const ChatRoute('srv-9'),
          navigatorKey: nav,
          messengerKey: messenger,
        ),
        isTrue,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(AppState.I.sessionById('srv-9'), isNotNull);
      expect(AppState.I.activeSessionId, 'srv-9');
      expect(find.textContaining('Chat not found'), findsNothing);
    });

    testWidgets('a genuinely missing id still reports not found', (
      tester,
    ) async {
      await _bindCloud();
      final (nav, messenger) = await pumpShell(tester);

      expect(
        AppRouter.go(
          const ChatRoute('srv-missing'),
          navigatorKey: nav,
          messengerKey: messenger,
        ),
        isTrue,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Chat not found'), findsOneWidget);
    });
  });
}
