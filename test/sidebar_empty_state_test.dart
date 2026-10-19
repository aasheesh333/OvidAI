// SH-017: loading vs failed vs empty are different sidebar states.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Rest extends CloudRestClient {
  _Rest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');
  bool fail = false;

  @override
  Future<CloudPage<SessionDto>> listSessions({
    int limit = 50,
    String? cursor,
  }) async {
    if (fail) throw CloudApiException(status: 0, code: 'unreachable', message: 'x');
    return const CloudPage<SessionDto>(items: [], nextCursor: null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Rest rest;
  late CloudSessionStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    rest = _Rest();
    final prefs = await SharedPreferences.getInstance();
    final ws = WsMultiplexer(mintTicket: () async => 't', prefs: prefs);
    store = CloudSessionStore.forTest(
      rest: rest,
      connection: ConnectionService.forTest(),
      ws: ws,
    );
  });

  tearDown(AppState.resetTestInstance);

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SidebarEmptyState(store: store, onRetry: store.refreshSessions),
      ),
    ),
  );

  testWidgets('before the first sync: loading, not "No chats"', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('sidebar-empty-loading')), findsOneWidget);
    expect(find.textContaining('No chats yet'), findsNothing);
  });

  testWidgets('after a sync with no chats: the real empty state', (
    tester,
  ) async {
    await store.refreshSessions();
    await pump(tester);
    expect(find.byKey(const ValueKey('sidebar-empty-none')), findsOneWidget);
  });

  testWidgets('a failed sync offers Retry', (tester) async {
    rest.fail = true;
    await expectLater(store.refreshSessions(), throwsA(anything));
    await pump(tester);
    expect(find.byKey(const ValueKey('sidebar-empty-error')), findsOneWidget);
    rest.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('sidebar-empty-none')), findsOneWidget);
  });
}
