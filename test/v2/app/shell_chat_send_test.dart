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
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';

/// Regression host for the #1 v2 bug: "inline chat is not working and even
/// not showing any response". The shell must render the transcript the
/// facade projects (`CloudAgentFacade.transcriptFor`), not the cloud-dead
/// `ChatSession.messages` list: every cloud write (the pending prompt row,
/// the confirmed row, the WS answer) lands in the projection only, so a
/// shell that reads `session.messages` renders the EMPTY chat forever —
/// type, send, and nothing ever comes back.
class _SendRest extends CloudRestClient {
  _SendRest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<({String sessionId, String content, String? clientMsgId})> sent =
      [];
  var _seq = 0;

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async {
    sent.add((sessionId: sessionId, content: content, clientMsgId: clientMsgId));
    final n = ++_seq;
    return SendMessageResponse(
      runId: 'run-$n',
      userMessageId: 'msg-user-$n',
      status: 'queued',
    );
  }
}

/// The multiplexer's socket seam: no network, frames pushed by the test.
class _SendSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();
  final List<String> sent = [];
  int? _closeCode;

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String frame) => sent.add(frame);

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

Map<String, dynamic> _eventFrame(
  String sessionId,
  String seq,
  String type,
  Map<String, dynamic> payload,
) =>
    <String, dynamic>{
      'op': 'event',
      'event': <String, dynamic>{
        'sessionId': sessionId,
        'seq': seq,
        'type': type,
        'payload': payload,
        'ts': '2026-10-22T10:00:00.000Z',
      },
    };

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late WsMultiplexer ws;
  late CloudAgentFacade facade;
  late _SendRest rest;
  late List<_SendSocket> sockets;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    rest = _SendRest();
    sockets = [];
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (Uri url) async {
        final socket = _SendSocket();
        sockets.add(socket);
        return socket;
      },
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    // The REAL facade on the store-less direct-send path: the regression
    // lives between it and the shell, so no facade behaviour is faked.
    facade = CloudAgentFacade(rest: rest, ws: ws, store: null);
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

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
  }

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(V2ChatPage),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump();
  }

  /// Flutter's pending-timer invariant runs BEFORE test_api's tearDown, so
  /// the socket heartbeat, the watchdog and the composer-draft debounce
  /// (armed by every keystroke) must stop inside the body — the same pattern
  /// shell_wiring_test's live-socket test uses.
  Future<void> stopNetwork(WidgetTester tester) async {
    facade.dispose();
    await ws.disconnect();
    await ComposerDraftStore.I.flush();
    await tester.pump();
  }

  testWidgets(
    'a send on a fresh session leaves the empty chat and paints the prompt row',
    (tester) async {
      await pumpShell(tester);

      // Fresh start: the active chat has no messages, so the empty chat owns
      // the composer.
      expect(app.activeSession?.messages ?? const [], isEmpty);
      expect(find.byType(V2ChatPage), findsOneWidget);
      expect(find.byType(V2LiveChatPage), findsNothing);

      await typeAndSend(tester, 'hello cloud');

      // The POST really left the device (the facade is live, not faked).
      expect(rest.sent, hasLength(1));
      expect(rest.sent.single.content, 'hello cloud');

      // THE BUG: the pending/confirmed prompt row lands in the facade's
      // projection, but the shell reads ChatSession.messages — empty on the
      // cloud path — so the empty chat stays and the prompt never paints.
      expect(find.byType(V2LiveChatPage), findsOneWidget);
      expect(find.text('hello cloud'), findsOneWidget);

      await stopNetwork(tester);
    },
  );

  testWidgets(
    'a WS answer after the POST paints the assistant row',
    (tester) async {
      await pumpShell(tester);
      await typeAndSend(tester, 'ping');

      // The send subscribed the session: the server now answers over the
      // socket, AFTER the 202 landed.
      expect(sockets, hasLength(1));
      final socket = sockets.single;
      final sessionId = app.activeSessionId!;
      socket.server(
        _eventFrame(sessionId, '1-1', 'run_started', {'runId': 'run-1'}),
      );
      socket.server(
        _eventFrame(sessionId, '1-2', 'message_delta', {
          'runId': 'run-1',
          'text': 'Pong',
        }),
      );
      socket.server(
        _eventFrame(sessionId, '1-3', 'message_completed', {
          'messageId': 'msg-a1',
          'content': 'Pong from Ovid.',
        }),
      );
      socket.server(
        _eventFrame(sessionId, '1-4', 'run_completed', {'runId': 'run-1'}),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('Pong from Ovid.', findRichText: true),
        findsOneWidget,
      );
      // The run settled: the composer offers Send again, not Stop.
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);

      await stopNetwork(tester);
    },
  );
}
