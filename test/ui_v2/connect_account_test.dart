import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/ui/github_login_sheet.dart';
import 'package:ovid_ai/ui/mcp_oauth_sheet.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Unified connect-account pattern — MCP OAuth and GitHub device flow share
/// one calm scaffold (code chip + copy, countdown, open-in-browser,
/// paste-back field, one primary action per state) with designed
/// waiting/verifying/done/error/expired states.
///
/// GitHub pumps stay bounded and never settle while the sheet is open: the
/// 1s expiry ticker reschedules a frame every second. Token-touching work
/// (signOut) runs inside `tester.runAsync` so the singleton's serialized
/// write queue never retains a finished fake-time zone.

/// Fake seam over the MCP OAuth flow. Records every call so the tests can
/// prove the sheet's contract without secure storage or the network.
class _FakeOAuthService implements McpOAuthService {
  final List<String> beginCalls = [];
  final List<(String, String)> completeCalls = [];
  final List<String> cancelCalls = [];
  String authUrl = 'https://auth.example.test/authorize?state=abc&client_id=x';
  String completeError = '';
  Future<void> Function()? completeGate;

  @override
  Future<String> beginAuthorization(String serverKey) async {
    beginCalls.add(serverKey);
    return authUrl;
  }

  @override
  Future<void> completeAuthorization(
    String serverKey,
    String callbackUri,
  ) async {
    completeCalls.add((serverKey, callbackUri));
    final gate = completeGate;
    if (gate != null) await gate();
    if (completeError.isNotEmpty) throw StateError(completeError);
  }

  @override
  void cancelAuthorization(String serverKey) => cancelCalls.add(serverKey);
}

Widget _mcpHost({required McpOAuthService service}) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showMcpOAuthSheet(
          context,
          serverKey: 'srv',
          serverName: 'Demo Server',
          service: service,
          launcher: (_) async => true,
        ),
        child: const Text('open-sheet'),
      ),
    ),
  ),
);

Future<void> _openMcpSheet(WidgetTester tester, _FakeOAuthService service) {
  return tester
      .pumpWidget(_mcpHost(service: service))
      .then((_) => tester.tap(find.text('open-sheet')))
      .then((_) => tester.pumpAndSettle());
}

/// Mock GitHub backend. [tokenBehavior] selects the access-token response:
/// `pending` (never authorizes) or `expired` (device code lapses).
http.Client _githubClient({String tokenBehavior = 'pending'}) {
  return MockClient((request) async {
    if (request.url.path == '/login/device/code') {
      return http.Response(
        jsonEncode({
          'device_code': 'device-code',
          'user_code': 'ABCD-1234',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': 900,
          'interval': 1,
        }),
        200,
      );
    }
    if (request.url.path == '/login/oauth/access_token') {
      return http.Response(
        jsonEncode(
          tokenBehavior == 'expired'
              ? {'error': 'expired_token'}
              : {'error': 'authorization_pending'},
        ),
        200,
      );
    }
    if (request.url.path == '/user') {
      return http.Response(jsonEncode({'login': 'octocat'}), 200);
    }
    return http.Response('not found', 404);
  });
}

Future<void> _openGithubSheet(WidgetTester tester, http.Client client) async {
  // Only the singleton's token work runs in the real zone (its serialized
  // write queue must never retain a finished fake-time zone). The sheet
  // itself is pumped in the fake zone so bounded pumps drive the poll's
  // interval delays and the 1s expiry ticker.
  await tester.runAsync(() => GitHubService.I.signOut());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  isDismissible: false,
                  backgroundColor: Colors.transparent,
                  builder: (_) => GithubLoginSheet(client: client),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Bounded frames — never pumpAndSettle while the GitHub sheet is open.
Future<void> _frames(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _pumpToCodeView(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

void _mockClipboard(WidgetTester tester, void Function(String text) onCopy) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        onCopy((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

void main() {
  group('shared scaffold', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    testWidgets(
      'github code view renders code chip, copy, countdown and one primary',
      (tester) async {
        String? copied;
        _mockClipboard(tester, (text) => copied = text);

        await _openGithubSheet(tester, _githubClient());
        await _pumpToCodeView(tester);

        // One shared scaffold, one calm composition.
        expect(find.byType(ConnectAccountScaffold), findsOneWidget);
        expect(find.byType(AetherSheet), findsOneWidget);
        expect(find.text('Connect GitHub'), findsOneWidget);
        expect(find.text('GITHUB OAUTH'), findsOneWidget);
        // Code chip + copy + countdown.
        expect(find.text('ABCD-1234'), findsOneWidget);
        expect(find.byType(AetherField), findsOneWidget);
        expect(find.byType(ConnectAccountCopyChip), findsOneWidget);
        expect(find.textContaining('Waiting ·'), findsOneWidget);
        // One primary action; cancel stays a ghost.
        expect(find.byType(FilledButton), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

        await tester.tap(find.text('Copy'));
        await tester.pump();
        expect(copied, 'ABCD-1234');
        expect(find.text('Copied'), findsOneWidget);
        // Drain the chip's 2s "Copied" reset timer before teardown.
        await tester.pump(const Duration(seconds: 3));

        await tester.tap(find.text('Cancel'));
        await _frames(tester);
        expect(find.byType(GithubLoginSheet), findsNothing);
      },
    );

    testWidgets(
      'mcp view renders code chip, copy, open-in-browser and one primary',
      (tester) async {
        String? copied;
        _mockClipboard(tester, (text) => copied = text);

        final service = _FakeOAuthService();
        await _openMcpSheet(tester, service);

        expect(find.byType(ConnectAccountScaffold), findsOneWidget);
        expect(find.text('Connect Demo Server'), findsOneWidget);
        expect(find.text('MCP OAUTH'), findsOneWidget);
        // The authorization URL is the code chip, with the same copy action.
        expect(
          find.textContaining('https://auth.example.test/authorize'),
          findsWidgets,
        );
        expect(find.byType(ConnectAccountCopyChip), findsOneWidget);
        // Open in browser steps back to secondary; Complete is the one
        // primary action of the waiting state.
        expect(
          find.widgetWithText(OutlinedButton, 'Open in browser'),
          findsOneWidget,
        );
        expect(find.byType(FilledButton), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Complete'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('mcp-oauth-callback-field')),
          findsOneWidget,
        );

        await tester.tap(find.text('Copy'));
        await tester.pump();
        expect(copied, service.authUrl);
        expect(find.text('Copied'), findsOneWidget);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('mcp-oauth-cancel')));
        await tester.pumpAndSettle();
      },
    );
  });

  group('mcp oauth flow', () {
    testWidgets('complete calls the service with the pasted callback', (
      tester,
    ) async {
      final service = _FakeOAuthService();
      await _openMcpSheet(tester, service);

      const callback = 'ovid://oauth/callback?provider=mcp&code=abc&state=abc';
      await tester.enterText(
        find.byKey(const ValueKey('mcp-oauth-callback-field')),
        callback,
      );
      await tester.tap(find.byKey(const ValueKey('mcp-oauth-complete')));
      await tester.pumpAndSettle();

      expect(service.completeCalls, [('srv', callback)]);
      expect(find.byType(McpOAuthSheet), findsNothing);
    });

    testWidgets('cancel discards the attempt without completing', (
      tester,
    ) async {
      final service = _FakeOAuthService();
      await _openMcpSheet(tester, service);

      await tester.tap(find.byKey(const ValueKey('mcp-oauth-cancel')));
      await tester.pumpAndSettle();

      expect(service.cancelCalls, ['srv']);
      expect(service.completeCalls, isEmpty);
      expect(find.byType(McpOAuthSheet), findsNothing);
    });

    testWidgets('complete failure shows a calm error and the sheet recovers', (
      tester,
    ) async {
      final service = _FakeOAuthService()..completeError = 'bad redirect';
      await _openMcpSheet(tester, service);

      const callback = 'ovid://oauth/callback?provider=mcp&code=abc&state=abc';
      await tester.enterText(
        find.byKey(const ValueKey('mcp-oauth-callback-field')),
        callback,
      );
      await tester.tap(find.byKey(const ValueKey('mcp-oauth-complete')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Could not complete authorization'),
        findsOneWidget,
      );
      expect(find.byType(McpOAuthSheet), findsOneWidget);

      // The error clears on retry and the same primary completes the flow.
      service.completeError = '';
      final retry = find.byKey(const ValueKey('mcp-oauth-complete'));
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(service.completeCalls, [('srv', callback), ('srv', callback)]);
      expect(find.byType(McpOAuthSheet), findsNothing);
    });

    testWidgets('verifying state suspends the primary while completing', (
      tester,
    ) async {
      final gate = Completer<void>();
      final service = _FakeOAuthService()..completeGate = () => gate.future;
      await _openMcpSheet(tester, service);

      await tester.enterText(
        find.byKey(const ValueKey('mcp-oauth-callback-field')),
        'ovid://oauth/callback?provider=mcp&code=abc&state=abc',
      );
      await tester.tap(find.byKey(const ValueKey('mcp-oauth-complete')));
      await tester.pump();
      await tester.pump();

      expect(find.text('Verifying the callback…'), findsOneWidget);
      // The one primary action is suspended while the service verifies.
      final primary = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(primary.onPressed, isNull);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(McpOAuthSheet), findsNothing);
    });
  });

  group('github device flow', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    testWidgets('cancel stops waiting and closes without a token', (
      tester,
    ) async {
      await _openGithubSheet(tester, _githubClient());
      await _pumpToCodeView(tester);
      expect(find.text('ABCD-1234'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.byType(GithubLoginSheet), findsNothing);
      expect(GitHubService.I.token, isNull);
    });

    testWidgets('start failure shows the error state and retry recovers', (
      tester,
    ) async {
      var attempts = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/login/oauth/access_token') {
          return http.Response('{"error":"authorization_pending"}', 200);
        }
        attempts++;
        if (attempts == 1) return http.Response('{}', 503);
        return http.Response(
          jsonEncode({
            'device_code': 'device-code',
            'user_code': 'ABCD-1234',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 1,
          }),
          200,
        );
      });
      await _openGithubSheet(tester, client);
      await _frames(tester);

      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await _frames(tester);
      expect(attempts, greaterThan(1));
      expect(find.text('ABCD-1234'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(find.byType(GithubLoginSheet), findsNothing);
    });

    testWidgets('an expired device code reaches the expired state', (
      tester,
    ) async {
      await _openGithubSheet(tester, _githubClient(tokenBehavior: 'expired'));
      await _pumpToCodeView(tester);

      // The poll waits one interval before its first request; advance fake
      // time in bounded steps until the service reports the expiry.
      for (
        var i = 0;
        i < 8 && find.text('Code expired').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.text('Code expired'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(find.byType(GithubLoginSheet), findsNothing);
    });
  });

  group('viewports', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    void viewport(
      WidgetTester tester,
      Size physical, {
      double dpr = 1,
      double keyboard = 0,
    }) {
      tester.view.physicalSize = physical;
      tester.view.devicePixelRatio = dpr;
      if (keyboard > 0) {
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
    }

    testWidgets('github code view at 360x640 @2x renders without overflow', (
      tester,
    ) async {
      viewport(tester, const Size(720, 1280), dpr: 2);
      await _openGithubSheet(tester, _githubClient());
      await _pumpToCodeView(tester);

      expect(find.byType(ConnectAccountScaffold), findsOneWidget);
      expect(find.text('ABCD-1234'), findsOneWidget);
      expect(find.byType(ConnectAccountCopyChip), findsOneWidget);
      expect(find.textContaining('Waiting ·'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);
    });

    testWidgets('github code view on a wide surface renders without overflow', (
      tester,
    ) async {
      viewport(tester, const Size(1280, 800));
      await _openGithubSheet(tester, _githubClient());
      await _pumpToCodeView(tester);

      expect(find.byType(ConnectAccountScaffold), findsOneWidget);
      expect(find.text('ABCD-1234'), findsOneWidget);
      expect(find.textContaining('Waiting ·'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);
    });

    testWidgets('keyboard keeps the mcp complete action reachable', (
      tester,
    ) async {
      viewport(tester, const Size(720, 1280), dpr: 2, keyboard: 280);
      final service = _FakeOAuthService();
      await _openMcpSheet(tester, service);

      const callback = 'ovid://oauth/callback?provider=mcp&code=abc&state=abc';
      await tester.enterText(
        find.byKey(const ValueKey('mcp-oauth-callback-field')),
        callback,
      );
      final complete = find.byKey(const ValueKey('mcp-oauth-complete'));
      await tester.ensureVisible(complete);
      await tester.pumpAndSettle();
      await tester.tap(complete);
      await tester.pumpAndSettle();

      expect(service.completeCalls, [('srv', callback)]);
      expect(tester.takeException(), isNull);
      expect(find.byType(McpOAuthSheet), findsNothing);
    });
  });
}
