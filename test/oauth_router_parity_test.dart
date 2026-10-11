// PR-7 — MCP OAuth entry/result handling and app routing (F-193…F-197).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/app_router.dart';
import 'package:ovid_ai/ui/mcp_oauth_sheet.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

class _FakeOAuthService implements McpOAuthService {
  int begins = 0;
  final completes = <String>[];

  @override
  Future<String> beginAuthorization(String serverKey) async {
    begins++;
    return 'https://auth.example.test/authorize?state=abc';
  }

  @override
  Future<void> completeAuthorization(
    String serverKey,
    String callbackUri,
  ) async => completes.add(callbackUri);

  @override
  void cancelAuthorization(String serverKey) {}

  @override
  Future<DateTime?> attemptExpiry(String serverKey) async => null;
}

McpServer _remote(String url, {String name = 'remote_mcp'}) => McpServer(
  name: name,
  author: 'test',
  description: 'fixture',
  category: 'Custom',
  command: '',
  custom: true,
  transport: 'http',
  url: url,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
  });

  tearDown(() async {
    for (final s in List<McpServer>.of(AppState.I.mcpServers)) {
      await McpService.I.removeMcpOAuth(s.canonicalId);
    }
    mcpOAuthServiceForTest = null;
    mcpConnectAfterSignInForTest = null;
    AgentNotificationService.I.selectSessionHandler = null;
    AppState.resetTestInstance();
  });

  group('MCP sign-in entry and result (F-193, F-196)', () {
    testWidgets('a server returning 401 + WWW-Authenticate shows "Sign in", '
        'and a successful sheet reconnects with a confirmation', (
      tester,
    ) async {
      final server = await tester.runAsync(() async {
        final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => http.close(force: true));
        http.listen((r) async {
          await utf8.decoder.bind(r).join();
          r.response.statusCode = 401;
          r.response.headers.set(
            'www-authenticate',
            'Bearer resource_metadata="http://127.0.0.1:${http.port}'
                '/.well-known/oauth-protected-resource"',
          );
          await r.response.close();
        });
        final s = _remote('http://127.0.0.1:${http.port}/mcp');
        AppState.I.mcpServers.add(s);
        final outcome = await McpService.I.connectOutcome(
          s,
          handshakeBudget: const Duration(seconds: 3),
        );
        expect(outcome.kind, McpConnectOutcomeKind.needsSetup);
        return s;
      });
      final s = server!;
      expect(McpService.I.mcpNeedsOAuthSignIn(s.canonicalId), isTrue);

      final service = _FakeOAuthService();
      final connected = <String>[];
      mcpOAuthServiceForTest = service;
      mcpConnectAfterSignInForTest = (_, srv) async =>
          connected.add(srv.canonicalId);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: McpDetailScreen(server: s),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final signIn = find.byKey(ValueKey('mcp-auth-sign-in-${s.canonicalId}'));
      expect(signIn, findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);

      await tester.ensureVisible(signIn);
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      expect(find.byType(McpOAuthSheet), findsOneWidget);
      expect(service.begins, 1);

      // The redirect is captured by the app and delivered to the sheet.
      McpOAuthCallbackHub.deliver(
        Uri.parse('com.dhanuk.ovidai://oauth/callback?code=c&state=abc'),
      );
      await tester.pumpAndSettle();
      expect(service.completes, hasLength(1));
      expect(find.byType(McpOAuthSheet), findsNothing);
      expect(connected, [s.canonicalId]);
      expect(find.text('Signed in to ${s.name}'), findsOneWidget);
    });

    testWidgets(
      'a stored token shows expiry with Re-authenticate and Sign out',
      (tester) async {
        final s = _remote('https://mcp.example.test/mcp');
        AppState.I.mcpServers.add(s);
        await tester.runAsync(
          () => McpService.I.storeMcpOAuthToken(
            s.canonicalId,
            McpOAuthToken(
              accessToken: 't',
              expiresAt: DateTime.now().add(
                const Duration(hours: 3, minutes: 5),
              ),
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: McpDetailScreen(server: s),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Signed in · expires in 3 h'), findsOneWidget);
        expect(find.text('Re-authenticate'), findsOneWidget);

        final signOut = find.byKey(
          ValueKey('mcp-auth-sign-out-${s.canonicalId}'),
        );
        await tester.ensureVisible(signOut);
        await tester.tap(signOut);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(
          await tester.runAsync(
            () => McpService.I.mcpOAuthTokenFor(s.canonicalId),
          ),
          isNull,
        );
        expect(find.text('Signed out of ${s.name}'), findsOneWidget);
      },
    );

    test('token status copy', () {
      final now = DateTime(2026, 1, 1, 12);
      expect(
        mcpOAuthTokenStatus(
          McpOAuthToken(
            accessToken: 'a',
            expiresAt: now.add(const Duration(minutes: 20)),
          ),
          now: now,
        ),
        'Signed in · expires in 20 min',
      );
      expect(
        mcpOAuthTokenStatus(const McpOAuthToken(accessToken: 'a')),
        'Signed in',
      );
      expect(
        mcpOAuthTokenStatus(
          McpOAuthToken(accessToken: 'a', expiresAt: DateTime(2000)),
          now: now,
        ),
        'Sign-in expired',
      );
    });
  });

  group('AppRouter (F-197)', () {
    test('parses paths and ovidsi.com links', () {
      expect(AppRouter.parse(Uri.parse('/')), isA<HomeRoute>());
      expect(
        (AppRouter.parse(Uri.parse('https://ovidsi.com/c/123')) as ChatRoute)
            .sessionId,
        '123',
      );
      expect(AppRouter.parse(Uri.parse('/settings')), isA<SettingsRoute>());
      expect(AppRouter.parse(Uri.parse('/browser')), isA<BrowserRoute>());
      expect(
        (AppRouter.parse(Uri.parse('/schedule/abc')) as ScheduleRoute)
            .sessionId,
        'abc',
      );
      expect(AppRouter.parse(Uri.parse('https://evil.test/c/123')), isNull);
      expect(AppRouter.parse(Uri.parse('/c/a/b')), isNull);
      expect(
        AppRouter.parse(
          Uri.parse('com.dhanuk.ovidai://oauth/callback?code=x&state=y'),
        ),
        isNull,
      );
      expect(
        McpService.isMcpOAuthCallback(
          Uri.parse('com.dhanuk.ovidai://oauth/callback?code=x&state=y'),
        ),
        isTrue,
      );
      expect(
        McpService.isMcpOAuthCallback(Uri.parse('https://ovidsi.com/s/abc')),
        isFalse,
      );
    });

    Future<(GlobalKey<NavigatorState>, GlobalKey<ScaffoldMessengerState>)>
    pumpApp(WidgetTester tester) async {
      final nav = GlobalKey<NavigatorState>();
      final messenger = GlobalKey<ScaffoldMessengerState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          scaffoldMessengerKey: messenger,
          home: Scaffold(
            body: AnimatedBuilder(
              animation: AppState.I,
              builder: (_, _) => Text('chat:${AppState.I.activeSessionId}'),
            ),
          ),
        ),
      );
      AgentNotificationService.I.selectSessionHandler = (sid) =>
          AppRouter.openChat(sid, navigatorKey: nav, messengerKey: messenger);
      nav.currentState!.push(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Settings page')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings page'), findsOneWidget);
      return (nav, messenger);
    }

    ChatSession addSession(String id) {
      final s = ChatSession(id: id, title: 'Chat $id', model: 'm');
      AppState.I.sessions.add(s);
      return s;
    }

    testWidgets('notification tap with Settings on top shows that chat', (
      tester,
    ) async {
      addSession('first');
      addSession('target');
      AppState.I.activeSessionId = 'first';
      await pumpApp(tester);

      AgentNotificationService.I.handleSelectSession('target');
      await tester.pumpAndSettle();
      expect(find.text('Settings page'), findsNothing);
      expect(find.text('chat:target'), findsOneWidget);
    });

    testWidgets('unknown session id → "Chat not found", active chat kept', (
      tester,
    ) async {
      addSession('first');
      AppState.I.activeSessionId = 'first';
      await pumpApp(tester);

      AgentNotificationService.I.handleSelectSession('deleted');
      await tester.pumpAndSettle();
      expect(find.textContaining('Chat not found'), findsOneWidget);
      expect(AppState.I.activeSessionId, 'first');
    });

    testWidgets('/c/<id> App Link opens that chat', (tester) async {
      addSession('first');
      addSession('linked');
      AppState.I.activeSessionId = 'first';
      final (nav, messenger) = await pumpApp(tester);

      final route = AppRouter.parse(Uri.parse('https://ovidsi.com/c/linked'))!;
      expect(
        AppRouter.go(route, navigatorKey: nav, messengerKey: messenger),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings page'), findsNothing);
      expect(find.text('chat:linked'), findsOneWidget);
    });

    test('without a router only existing sessions are selected', () {
      addSession('first');
      AppState.I.activeSessionId = 'first';
      AgentNotificationService.I.handleSelectSession('missing');
      expect(AppState.I.activeSessionId, 'first');
    });
  });
}
