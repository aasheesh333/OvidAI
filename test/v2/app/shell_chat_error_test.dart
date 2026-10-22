import 'dart:async';

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

/// The inline error bar is the only place a refused send is visible. A failure
/// must paint it above the composer, and its Retry must re-send the prompt.
class _FailOnceRest extends CloudRestClient {
  _FailOnceRest()
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<String> sent = <String>[];
  int attempts = 0;

  /// Keeps refusing every send so the bar can be dismissed while it is still
  /// the current failure.
  bool failAlways = false;

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async {
    attempts++;
    sent.add(content);
    if (failAlways || attempts == 1) {
      throw CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'gateway is restarting',
      );
    }
    return const SendMessageResponse(
      runId: 'run-retry',
      userMessageId: 'msg-retry',
      status: 'queued',
    );
  }
}

class _ErrorSocket implements CloudSocket {
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
}

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WsMultiplexer ws;
  late CloudAgentFacade facade;
  late _FailOnceRest rest;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    // Building the app state is the side effect these tests need.
    AppState.createForTest();
    rest = _FailOnceRest();
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async => _ErrorSocket(),
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
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

  testWidgets('a failed send shows the inline bar and Retry re-sends', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    await tester.enterText(
      find.descendant(
        of: find.byType(V2ChatPage),
        matching: find.byType(TextField),
      ),
      'hello cloud',
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump();

    expect(rest.attempts, 1);
    expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);
    expect(
      find.text('Ovid had a problem handling this message. Try again.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    // The same prompt left the device again and the failure cleared.
    expect(rest.attempts, 2);
    expect(rest.sent, <String>['hello cloud', 'hello cloud']);
    expect(find.byKey(const Key('v2-chat-error')), findsNothing);

    facade.dispose();
    await ws.disconnect();
    await ComposerDraftStore.I.flush();
    await tester.pump();
  });

  testWidgets('dismissing the inline bar clears it without resending', (
    tester,
  ) async {
    rest.failAlways = true;
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();

    await tester.enterText(
      find.descendant(
        of: find.byType(V2ChatPage),
        matching: find.byType(TextField),
      ),
      'still failing',
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump();

    expect(rest.attempts, 1);
    expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Dismiss error'));
    await tester.pump();

    expect(find.byKey(const Key('v2-chat-error')), findsNothing);
    expect(rest.attempts, 1, reason: 'dismiss must not resend the prompt');

    facade.dispose();
    await ws.disconnect();
    await ComposerDraftStore.I.flush();
    await tester.pump();
  });
}
