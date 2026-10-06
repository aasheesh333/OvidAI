import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/mcp_oauth_sheet.dart';

/// Fake seam over the OAuth flow. Records every call so the widget test can
/// prove the sheet's contract without touching secure storage or the network.
class _FakeOAuthService implements McpOAuthService {
  final List<String> beginCalls = [];
  final List<(String, String)> completeCalls = [];
  final List<String> cancelCalls = [];
  String authUrl = 'https://auth.example.test/authorize?state=abc&client_id=x';
  String completeError = '';

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
    if (completeError.isNotEmpty) throw StateError(completeError);
  }

  @override
  void cancelAuthorization(String serverKey) => cancelCalls.add(serverKey);
}

Widget _host({
  required McpOAuthService service,
  required McpOAuthLauncher launcher,
}) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showMcpOAuthSheet(
          context,
          serverKey: 'srv',
          serverName: 'Demo Server',
          service: service,
          launcher: launcher,
        ),
        child: const Text('open-sheet'),
      ),
    ),
  ),
);

void main() {
  testWidgets('begin is called and Open browser launches the authorization URL', (
    tester,
  ) async {
    final service = _FakeOAuthService();
    Uri? launched;
    await tester.pumpWidget(
      _host(
        service: service,
        launcher: (uri) async {
          launched = uri;
          return true;
        },
      ),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    expect(service.beginCalls, ['srv']);
    expect(find.textContaining('https://auth.example.test/authorize'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('mcp-oauth-open-browser')));
    await tester.pumpAndSettle();
    expect(launched, isNotNull);
    expect(launched.toString(), service.authUrl);
  });

  testWidgets('Complete passes the full callback URL to the service', (
    tester,
  ) async {
    final service = _FakeOAuthService();
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => true),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

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

  testWidgets('Cancel cancels the authorization attempt', (tester) async {
    final service = _FakeOAuthService();
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => true),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mcp-oauth-cancel')));
    await tester.pumpAndSettle();

    expect(service.cancelCalls, ['srv']);
    expect(service.completeCalls, isEmpty);
  });

  testWidgets('a failed browser launch surfaces a recoverable message', (
    tester,
  ) async {
    final service = _FakeOAuthService();
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => false),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mcp-oauth-open-browser')));
    await tester.pumpAndSettle();

    expect(find.text('Could not open the browser.'), findsOneWidget);
  });
}
