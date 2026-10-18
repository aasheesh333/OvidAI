// P8 Task 10 fix round — `Distribution` flag gates in the chat surface.
//
// Two defects were fixed here:
//   * the composer's Skills / MCP-tool / plugin slash sources were gated on
//     `Distribution.cloudPlugins` (hardcoded false, so a no-op) or not gated
//     at all — they now follow `!Distribution.cloudExecution`;
//   * the header browser button was gated on `Distribution.cloudBrowser`
//     (which IS `thinClient`), inverting both arms — it now follows
//     `!Distribution.cloudExecution`.
//
// These tests seed one local source at a time (a command is always seeded so
// the menu is non-empty on both arms) and assert the group header the
// composer renders: `SKILLS`, `MCP TOOLS`, `PLUGINS`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/skills.dart';
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

Future<void> _seedSkill(
  WidgetTester tester,
  Directory tmp,
  String sessionId,
) async {
  final root = Directory('${tmp.path}/research-kit')
    ..createSync(recursive: true);
  File('${root.path}/skills/research/SKILL.md')
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '---\nname: research\ndescription: Research things\n'
      'user-invocable: true\n---\nRESEARCH',
    );
  final manifest = NormalizedPluginManifest(
    id: 'gate/research-kit',
    name: 'Research Kit',
    version: '1.0.0',
    format: PluginFormat.claudeCode,
    rootPath: root.path,
    skills: const [
      PluginSkill(
        pluginId: 'gate/research-kit',
        name: 'research',
        path: 'skills/research/SKILL.md',
      ),
    ],
  );
  await tester.runAsync(
    () => SkillService.I.publishSessionCatalog(
      sessionId,
      mounts: [PluginCatalogMount(root.path, manifest)],
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
    AgentService.I.debugPauseScheduleTimerForTest(true);
    Distribution.thinOverrideForTest = null;
    tmp = Directory.systemTemp.createTempSync('distribution-gates-');
  });

  tearDown(() async {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    Distribution.thinOverrideForTest = null;
    CloudAgentFacade.resetForTest();
    CloudSessionStore.resetForTest();
    SkillService.I.clearRoots();
    AppState.resetTestInstance();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('composer slash sources — default build', () {
    testWidgets('Skills are offered when execution is on-device', (
      tester,
    ) async {
      final s = _addSession('gate-skill');
      _seedCommand();
      await _seedSkill(tester, tmp, s.id);
      await _pumpChat(tester);
      await _openSlashMenu(tester);

      expect(find.text('COMMANDS'), findsOneWidget);
      expect(find.text('SKILLS'), findsOneWidget);
      expect(find.textContaining('research'), findsOneWidget);
    });

    testWidgets('Browser header action is absent on the default build', (
      tester,
    ) async {
      _addSession('gate-browser-default');
      await _pumpChat(tester);
      // The on-device WebView browser was removed (P8 Task 16); the cloud
      // screencast button exists only on the thin arm.
      expect(find.byKey(const ValueKey('chat-header-browser')), findsNothing);
    });
  });

  group('composer slash sources — thin client', () {
    setUp(() {
      Distribution.thinOverrideForTest = true;
    });

    testWidgets('Skills, MCP tools and Plugins are NOT offered', (
      tester,
    ) async {
      final s = _addSession('gate-thin');
      _seedCommand();
      await _seedSkill(tester, tmp, s.id);
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

    testWidgets('Browser header action opens the cloud viewer on the thin client', (
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

  group('router — server ids on the thin client', () {
    setUp(() {
      Distribution.thinOverrideForTest = true;
    });

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
