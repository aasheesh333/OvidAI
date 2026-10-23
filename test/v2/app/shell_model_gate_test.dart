// The shell's manual-model gate, end to end:
//
//  * a legacy stored tier resolves exactly as the server does (`starter` is
//    Go, so Auto-only), and
//  * the gateway's `manualModelsAllowed` wins in both directions when present,
//  * with the named model still visible and visibly locked — never silently
//    dropped from the menu.

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
import 'package:ovid_ai/ui/v2/chat/model_chip.dart';

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
          throw StateError('the gate test opens no socket'),
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

  void seedChat() {
    final session = ChatSession(
      id: 'gate-chat',
      title: 'Gate test',
      model: 'auto',
      createdAt: DateTime(2026, 10, 23, 10),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    // One manual model, so a locked row has something to draw.
    app.providers.add(
      ProviderConfig(
        id: AppState.ovidCloudProviderId,
        name: 'Ovid Cloud',
        description: 'Ovid Cloud',
        baseUrl: 'https://api.ovidsi.test/v1',
        models: ['auto', 'premium-model'],
        connected: true,
        requiresApiKey: false,
      ),
    );
  }

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
  }

  Future<void> openModelMenu(WidgetTester tester) async {
    await tester.tap(find.byType(V2ModelChip).first);
    await tester.pumpAndSettle();
  }

  V2ModelChip chip(WidgetTester tester) =>
      tester.widget<V2ModelChip>(find.byType(V2ModelChip).first);

  testWidgets('a legacy starter tier is Auto-only and locks the named model', (
    tester,
  ) async {
    seedChat();
    app.setOvidCloudTier('starter');
    // The state keeps the vocabulary the rest of the UI is keyed on.
    expect(app.ovidCloudTier, '3x');

    await pumpShell(tester);
    expect(chip(tester).autoOnly, isTrue);

    await openModelMenu(tester);
    // The named model is still listed; it is locked, not dropped.
    expect(find.text('premium-model'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.text('Plus plan'), findsOneWidget);
  });

  testWidgets('an older gateway falls back to the tier for a paid plan', (
    tester,
  ) async {
    seedChat();
    app.setOvidCloudTier('7x');
    expect(app.ovidCloudManualModelsAllowed, isNull);

    await pumpShell(tester);
    expect(chip(tester).autoOnly, isFalse);

    await openModelMenu(tester);
    expect(find.text('premium-model'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
  });

  testWidgets('the server yes wins over a locally Auto-only tier', (
    tester,
  ) async {
    seedChat();
    app.setOvidCloudTier('free');
    app.setOvidCloudManualModelsAllowed(true);

    await pumpShell(tester);
    expect(chip(tester).autoOnly, isFalse);

    await openModelMenu(tester);
    expect(find.text('premium-model'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
  });

  testWidgets('the server no wins over a locally manual tier', (tester) async {
    seedChat();
    app.setOvidCloudTier('plus');
    app.setOvidCloudManualModelsAllowed(false);

    await pumpShell(tester);
    expect(chip(tester).autoOnly, isTrue);

    await openModelMenu(tester);
    expect(find.text('premium-model'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
  });

  testWidgets('a tier change clears the previous server answer', (
    tester,
  ) async {
    app.setOvidCloudTier('plus');
    app.setOvidCloudManualModelsAllowed(true);
    expect(app.ovidCloudManualModelsAllowed, isTrue);

    app.setOvidCloudTier('free');
    expect(
      app.ovidCloudManualModelsAllowed,
      isNull,
      reason: 'the old answer belonged to the old plan',
    );
  });
}
