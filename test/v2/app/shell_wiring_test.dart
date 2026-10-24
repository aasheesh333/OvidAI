import 'dart:async';
import 'dart:convert';

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
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/bottom_nav.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_actions.dart';
import 'package:ovid_ai/ui/v2/library/artifact_detail_page.dart';
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

/// The multiplexer's socket seam: no network, frames pushed by the test.
class _StallSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();
  int? _closeCode;

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String frame) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed.isClosed) return;
    _closeCode = code;
    if (!_frames.isClosed) await _frames.close();
    _closed.add(null);
    await _closed.close();
  }

  void server(Object frame) =>
      _frames.add(frame is String ? frame : jsonEncode(frame));
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

  testWidgets('the share sheet is told why each mode is unavailable', (
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

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share chat'));
    await tester.pumpAndSettle();

    expect(find.text('Share this chat'), findsOneWidget);
    // Signed out in this test: both modes are disabled with the real reason
    // instead of failing only after the person picks one.
    expect(find.text('Not signed in'), findsWidgets);
    expect(find.text('Link revoked'), findsNothing);
  });

  testWidgets('a stored reasoning block renders as a thought row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final session = liveSession();
    session.messages.add(
      Message(
        role: 'assistant',
        content: 'The answer.',
        reasoning: 'The private reasoning text.',
        time: DateTime(2026, 10, 21, 10, 1),
      ),
    );
    // The preference is on: the row opens with the transcript.
    app.showReasoning = true;

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Thought for a moment'), findsOneWidget);
    expect(find.text('The private reasoning text.'), findsOneWidget);
    expect(find.text('The answer.'), findsOneWidget);
  });

  testWidgets('the reasoning preference folds the row instead of hiding it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final session = liveSession();
    session.messages.add(
      Message(
        role: 'assistant',
        content: 'The answer.',
        reasoning: 'The private reasoning text.',
        time: DateTime(2026, 10, 21, 10, 1),
      ),
    );
    app.showReasoning = false;

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // The row stays as a collapsed disclosure; the reasoning is not shown
    // until the reader asks for it.
    expect(find.text('Thought for a moment'), findsOneWidget);
    expect(find.text('The private reasoning text.'), findsNothing);

    await tester.tap(find.text('Thought for a moment'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('The private reasoning text.'), findsOneWidget);
  });

  testWidgets('a message with no reasoning renders no thought row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final session = liveSession();
    session.messages.add(
      Message(
        role: 'assistant',
        content: 'The answer.',
        time: DateTime(2026, 10, 21, 10, 1),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Thought for a moment'), findsNothing);
    expect(find.text('The answer.'), findsOneWidget);
  });

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

  testWidgets('a chat artifact opens the library detail route', (tester) async {
    final session = liveSession();
    session.messages.add(
      Message(
        role: 'assistant',
        kind: MsgKind.htmlArtifact,
        htmlArtifact: HtmlArtifact.create(session.id, {
          'title': 'Receipt',
          'html': '<h1>Real heading</h1>',
        }),
        time: DateTime(2026, 10, 21, 10, 1),
      ),
    );
    app.refresh();

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    await tester.tap(find.text('Receipt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ArtifactDetailPage), findsOneWidget);
    // The inline page's real source, not a synthesized placeholder.
    expect(
      find.textContaining('Real heading', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a URL-backed artifact no longer launches a bare URL', (
    tester,
  ) async {
    final session = liveSession();
    session.messages.add(
      Message(
        role: 'assistant',
        kind: MsgKind.imageGen,
        imageUrl: 'https://files.example.com/hero.png',
        time: DateTime(2026, 10, 21, 10, 1),
      ),
    );
    app.refresh();

    Uri? launched;
    V2TranscriptIo.debugOpenOverride = (uri) async {
      launched = uri;
      return true;
    };
    addTearDown(V2TranscriptIo.reset);

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    await tester.tap(find.text('hero.png'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(launched, isNull, reason: 'the detail route replaces the launch');
    expect(find.byType(ArtifactDetailPage), findsOneWidget);
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

  testWidgets('the Response wait setting drives stalledFor to the label', (
    tester,
  ) async {
    final session = liveSession();

    // A REAL facade with no injected stall window: the watchdog reads the
    // user's setting through AppState exactly as production does.
    final socket = _StallSocket();
    final stallWs = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async => socket,
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    final real = CloudAgentFacade(rest: _ShellRest(), ws: stallWs, store: null);
    CloudAgentFacade.installForTest(real);

    // Settings → Response wait → `ovid_response_timeout_sec`.
    await app.setResponseTimeout(AppState.minResponseTimeoutSec);
    expect(
      (await SharedPreferences.getInstance()).getInt(
        'ovid_response_timeout_sec',
      ),
      AppState.minResponseTimeoutSec,
    );

    real.subscribeForTest(session.id);
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump(const Duration(milliseconds: 50));

    socket.server(<String, dynamic>{
      'op': 'event',
      'event': <String, dynamic>{
        'sessionId': session.id,
        'seq': '1-0',
        'type': 'run_started',
        'payload': <String, dynamic>{'runId': 'run-1'},
        'ts': '2026-10-17T10:00:00.000Z',
      },
    });
    await tester.pump();

    expect(real.busyFor(session.id), isTrue);
    expect(real.stalledFor(session.id), isFalse);
    expect(find.text('Still working…'), findsNothing);

    // One second past the configured window, with no event of any kind.
    await tester.pump(Duration(seconds: AppState.minResponseTimeoutSec + 1));

    expect(real.stalledFor(session.id), isTrue);
    expect(find.text('Still working…'), findsOneWidget);

    // No timer may outlive the tree: the watchdog and the socket both stop.
    real.dispose();
    await stallWs.disconnect();
    await tester.pump();
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
