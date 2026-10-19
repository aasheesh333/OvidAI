// Wave 2 Studio — ST-001 / ST-021 / EM-007: every Studio entry point used to
// show a SnackBar ("Studio moves to the cloud in this build."), StudioScreen
// was never built anywhere, and AOT tree-shook the whole Studio UI out of the
// release binary. No test navigated to Studio — they all built StudioScreen
// directly. These tests tap the real entry points inside the real ChatScreen.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

import 'support/studio_fake_gateway.dart';

class _EmptyRest extends CloudRestClient {
  _EmptyRest()
      : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  @override
  Future<CloudPage<SessionDto>> listSessions({
    int limit = 50,
    String? cursor,
  }) async =>
      const CloudPage<SessionDto>(items: [], nextCursor: null);

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
    bool withEvents = false,
  }) async =>
      const CloudPage<MessageDto>(items: [], nextCursor: null);
}

Future<CloudSessionStore> _bindCloud() async {
  final prefs = await SharedPreferences.getInstance();
  final ws = WsMultiplexer(mintTicket: () async => 'ticket', prefs: prefs);
  final rest = _EmptyRest();
  final store = CloudSessionStore(
    rest: rest,
    cache: SessionHistoryRepository.I,
    prefs: prefs,
    connection: ConnectionService.forTest(),
    ws: ws,
  );
  CloudSessionStore.installForTest(store);
  CloudAgentFacade.installForTest(
      CloudAgentFacade(rest: rest, ws: ws, store: store));
  await store.ready;
  return store;
}

void _addSession(String id, {String mode = 'auto'}) {
  AppState.I.sessions
      .add(ChatSession(id: id, title: 'Chat', model: 'm', mode: mode));
  AppState.I.activeSessionId = id;
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

/// Lets the route transition and the first workspace load finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    FlutterSecureStorage.setMockInitialValues(const <String, String>{});
    AppState.resetTestInstance();
    StudioDraftStore.I.disableForTest();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    tmp = Directory.systemTemp.createTempSync('studio-nav-');
  });

  tearDown(() async {
    StudioRemoteClient.I.clearAll();
    CloudAgentFacade.resetForTest();
    CloudSessionStore.resetForTest();
    AppState.resetTestInstance();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('ST-021: the chat header </> button opens Studio', (tester) async {
    _addSession('nav-header');
    await _bindCloud();
    final fake = FakeStudioGateway(
      files: {'README.md': '# hi'},
      roots: const [FakeNode.file('README.md')],
    );
    installFakeStudio(fake);
    await _pumpChat(tester);

    final button = find.byKey(const ValueKey('chat-header-studio'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await _settle(tester);

    expect(find.byType(StudioScreen), findsOneWidget);
    expect(find.text('Studio moves to the cloud in this build.'), findsNothing);
    // It opened on the user's workspace and loaded it.
    expect(fake.treeCalls, greaterThanOrEqualTo(1));
    expect(find.text('README.md'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('EM-008: the header tooltip no longer promises a terminal',
      (tester) async {
    _addSession('nav-tooltip');
    await _bindCloud();
    installFakeStudio(FakeStudioGateway());
    await _pumpChat(tester);

    final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('chat-header-studio')));
    expect(button.tooltip, isNot(contains('terminal')));
    expect(button.tooltip, startsWith('Studio'));
  });

  testWidgets('Studio mode: the composer chip opens Studio (no folder picker)',
      (tester) async {
    _addSession('nav-chip', mode: 'studio');
    await _bindCloud();
    installFakeStudio(FakeStudioGateway());
    await _pumpChat(tester);

    expect(find.text('Sandbox folder (Studio)'), findsNothing);
    final chip = find.byKey(const ValueKey('composer-studio-chip'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await _settle(tester);

    expect(find.byType(StudioScreen), findsOneWidget);
    expect(find.text('Select working folder'), findsNothing);
  });

  testWidgets(
      'ST-002: a brand-new chat with no server session opens Studio on a '
      'clear "no workspace yet" state, without a request', (tester) async {
    _addSession('1739999999999999'); // a local, never-synced chat id
    final store = await _bindCloud();
    final requests = <String>[];
    final rest = CloudRestClient(
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        return http.Response('{}', 404);
      }),
      headers: CloudHeaders.forTest(),
      restBase: kFakeStudioBase,
    );
    StudioRemoteClient.installForTest(StudioRemoteClient(
      files: StudioFilesClient(rest, sessions: store),
      drafts: StudioDraftStore.I,
    ));
    await _pumpChat(tester);

    await tester.tap(find.byKey(const ValueKey('chat-header-studio')));
    await _settle(tester);

    expect(find.byType(StudioScreen), findsOneWidget);
    expect(find.text('No cloud workspace yet'), findsOneWidget);
    expect(find.textContaining('Send a message in any chat'), findsOneWidget);
    expect(requests, isEmpty,
        reason: 'a local chat id must never be put on the wire');
    expect(find.textContaining('CloudApiException'), findsNothing);
  });
}
