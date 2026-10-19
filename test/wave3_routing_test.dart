// Wave 3 routing: external opens wait for the account (SH-007, SH-019),
// server ids resolve to local rows (FE-011), schedules reconcile, and the
// `ovid/native` routing methods reach Dart (CT-009).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/native_routes.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/app_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Rest extends CloudRestClient {
  _Rest({this.sessions = const []})
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  List<SessionDto> sessions;

  @override
  Future<CloudPage<SessionDto>> listSessions({
    int limit = 50,
    String? cursor,
  }) async => CloudPage<SessionDto>(items: sessions, nextCursor: null);
}

SessionDto _dto(String id) => SessionDto(
  id: id,
  title: 'Server $id',
  mode: 'auto',
  createdAt: DateTime.utc(2026, 10, 17),
  updatedAt: DateTime.utc(2026, 10, 17),
);

Future<CloudSessionStore> _bindCloud({
  List<SessionDto> sessions = const [],
  Map<String, String> idMap = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    if (idMap.isNotEmpty) CloudSessionStore.idMapKey: jsonEncode(idMap),
  });
  final prefs = await SharedPreferences.getInstance();
  final ws = WsMultiplexer(mintTicket: () async => 'ticket', prefs: prefs);
  final rest = _Rest(sessions: sessions);
  final store = CloudSessionStore(
    rest: rest,
    cache: SessionHistoryRepository.I,
    prefs: prefs,
    connection: ConnectionService.forTest(),
    ws: ws,
  );
  CloudSessionStore.installForTest(store);
  CloudAgentFacade.installForTest(
    CloudAgentFacade(rest: rest, ws: ws, store: store),
  );
  await store.ready;
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GlobalKey<NavigatorState> nav;
  late GlobalKey<ScaffoldMessengerState> messenger;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AppRouter.resetForTest();
    nav = GlobalKey<NavigatorState>();
    messenger = GlobalKey<ScaffoldMessengerState>();
  });

  tearDown(() {
    AppRouter.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpRoot(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      scaffoldMessengerKey: messenger,
      home: const Scaffold(body: Text('root')),
    ),
  );

  testWidgets('signed out: an external open is parked, never pushed above '
      'the login screen (SH-007)', (tester) async {
    await _bindCloud();
    await pumpRoot(tester);
    var ready = false;
    AppRouter.isAccountReady = () => ready;

    expect(
      AppRouter.open(
        const SettingsRoute(),
        navigatorKey: nav,
        messengerKey: messenger,
      ),
      isTrue,
    );
    await tester.pump();
    expect(find.text('Settings'), findsNothing);
    expect(AppRouter.pendingRoute, isA<SettingsRoute>());

    // Still signed out: nothing drains.
    expect(AppRouter.drainPending(navigatorKey: nav), isFalse);

    // Sign-out clears the parked route entirely.
    AppRouter.clearPending();
    expect(AppRouter.pendingRoute, isNull);
    ready = true;
    expect(AppRouter.drainPending(navigatorKey: nav), isFalse);
  });

  testWidgets('a cold-start chat link opens once the account is ready and '
      'sessions reconciled (SH-019)', (tester) async {
    await _bindCloud(sessions: [_dto('srv-1')]);
    await pumpRoot(tester);
    var ready = false;
    AppRouter.isAccountReady = () => ready;

    AppRouter.open(const ChatRoute('srv-1'), navigatorKey: nav);
    await tester.pump();
    expect(AppState.I.activeSessionId, isNot('srv-1'));

    ready = true;
    await CloudSessionStore.I.refreshSessions();
    expect(
      AppRouter.drainPending(navigatorKey: nav, messengerKey: messenger),
      isTrue,
    );
    await tester.pump();
    expect(AppState.I.activeSessionId, 'srv-1');
    expect(find.textContaining('not found'), findsNothing);
    expect(AppRouter.pendingRoute, isNull);
  });

  testWidgets('share links open even while signed out', (tester) async {
    await _bindCloud();
    AppRouter.isAccountReady = () => false;
    final token = 'a' * 43;
    final route = AppRouter.parse(Uri.parse('https://ovidsi.com/s/$token'));
    expect(route, isA<SharedChatRoute>());
    // Not parked: share links are public read-only views.
    AppRouter.open(route!, navigatorKey: GlobalKey<NavigatorState>());
    expect(AppRouter.pendingRoute, isNull);
  });

  testWidgets('a push carrying the SERVER id opens the local chat it maps to '
      '(FE-011)', (tester) async {
    final local = ChatSession(
      id: '1700000000000001',
      title: 'Made on this device',
      model: 'auto',
    );
    AppState.I.sessions.add(local);
    await _bindCloud(idMap: {'1700000000000001': 'srv-mapped'});
    await pumpRoot(tester);
    AppRouter.isAccountReady = () => true;

    expect(
      AppRouter.open(
        const ChatRoute('srv-mapped'),
        navigatorKey: nav,
        messengerKey: messenger,
      ),
      isTrue,
    );
    await tester.pump();
    expect(AppState.I.activeSessionId, '1700000000000001');
    expect(find.textContaining('not found'), findsNothing);
  });

  testWidgets('a schedule tap opens the Schedule screen even before the '
      'session synced, and selects a mapped local chat (FE-011)', (
    tester,
  ) async {
    final local = ChatSession(
      id: '1700000000000009',
      title: 'Reminder chat',
      model: 'auto',
    );
    AppState.I.sessions.add(local);
    await _bindCloud(idMap: {'1700000000000009': 'srv-sched'});
    final pushed = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        scaffoldMessengerKey: messenger,
        navigatorObservers: [_Observer(pushed)],
        home: const Scaffold(body: Text('root')),
      ),
    );
    AppRouter.isAccountReady = () => true;

    AppRouter.open(
      const ScheduleRoute('srv-sched'),
      navigatorKey: nav,
      messengerKey: messenger,
    );
    expect(pushed.last, '/schedule/srv-sched');
    expect(AppState.I.activeSessionId, '1700000000000009');
    expect(find.textContaining('not found'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('CloudSessionStore.localIdFor maps server ids back', () async {
    final store = await _bindCloud(idMap: {'local-1': 'srv-1'});
    expect(store.localIdFor('srv-1'), 'local-1');
    expect(store.localIdFor('srv-x'), isNull);
    expect(store.resolveLocalSessionId('srv-x'), 'srv-x');
  });

  test('CloudSessionStore reports syncing / synced / failed (SH-017)',
      () async {
    final store = await _bindCloud(sessions: [_dto('srv-1')]);
    expect(store.hasSynced, isFalse);
    final walk = store.refreshSessions();
    expect(store.syncing, isTrue);
    await walk;
    expect(store.syncing, isFalse);
    expect(store.hasSynced, isTrue);
    expect(store.lastSyncError, isNull);
    store.resetSyncState();
    expect(store.hasSynced, isFalse);
  });

  group('ovid/native routing channel (CT-009)', () {
    Future<void> deliver(String method, Object? args) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        NativeRouteChannel.channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    }

    test('onOpenRoute and onSelectSession reach the Dart router', () async {
      final routes = <String>[];
      NativeRouteChannel.install(routes.add);
      await deliver('onOpenRoute', '/schedule/abc');
      await deliver('onSelectSession', 'sess-1');
      await deliver('onOpenRoute', 'https://evil.example/x');
      await deliver('onOpenRoute', 42);
      expect(routes, ['/schedule/abc', '/c/sess-1']);
      NativeRouteChannel.channel.setMethodCallHandler(null);
    });

    test('takePendingRoute pulls the cold-start route', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeRouteChannel.channel, (call) async {
        return call.method == 'takePendingRoute' ? '/c/cold' : null;
      });
      expect(await NativeRouteChannel.takePendingRoute(), '/c/cold');
      messenger.setMockMethodCallHandler(NativeRouteChannel.channel, null);
      // No host activity: null, never a throw.
      expect(await NativeRouteChannel.takePendingRoute(), isNull);
    });
  });
}

class _Observer extends NavigatorObserver {
  _Observer(this.pushed);
  final List<String?> pushed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route.settings.name);
}
