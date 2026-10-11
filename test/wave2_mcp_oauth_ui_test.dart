import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_oauth_discovery.dart';
import 'package:ovid_ai/ui/mcp_oauth_sheet.dart';

/// Fake seam over the OAuth flow. Records every call so the widget test can
/// prove the sheet's contract without touching secure storage or the network.
class _FakeOAuthService implements McpOAuthService {
  final List<String> beginCalls = [];
  final List<(String, String)> completeCalls = [];
  final List<String> cancelCalls = [];
  String authUrl = 'https://auth.example.test/authorize?state=abc&client_id=x';
  String completeError = '';

  /// Errors thrown by the next completions, in order (then success).
  final List<Object> completeFailures = [];
  DateTime? expiry;

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
    if (completeFailures.isNotEmpty) throw completeFailures.removeAt(0);
    if (completeError.isNotEmpty) throw StateError(completeError);
  }

  @override
  void cancelAuthorization(String serverKey) => cancelCalls.add(serverKey);

  @override
  Future<DateTime?> attemptExpiry(String serverKey) async => expiry;
}

bool? _popped;

Widget _host({
  required McpOAuthService service,
  required McpOAuthLauncher launcher,
  Stream<Uri>? callbacks,
}) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          _popped = await showMcpOAuthSheet(
            context,
            serverKey: 'srv',
            serverName: 'Demo Server',
            service: service,
            launcher: launcher,
            callbacks: callbacks ?? const Stream<Uri>.empty(),
          );
        },
        child: const Text('open-sheet'),
      ),
    ),
  ),
);

Future<void> _openPaste(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mcp-oauth-show-paste')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'begin is called and Open browser launches the authorization URL',
    (tester) async {
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

      await tester.tap(find.byKey(const ValueKey('mcp-oauth-open-browser')));
      await tester.pumpAndSettle();
      expect(launched, isNotNull);
      expect(launched.toString(), service.authUrl);
    },
  );

  testWidgets('Complete passes the full callback URL to the service', (
    tester,
  ) async {
    final service = _FakeOAuthService();
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => true),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    await _openPaste(tester);
    expect(
      find.textContaining('https://auth.example.test/authorize'),
      findsWidgets,
    );

    const callback = 'ovid://oauth/callback?provider=mcp&code=abc&state=abc';
    await tester.enterText(
      find.byKey(const ValueKey('mcp-oauth-callback-field')),
      callback,
    );
    await tester.tap(find.byKey(const ValueKey('mcp-oauth-complete')));
    await tester.pumpAndSettle();

    expect(service.completeCalls, [('srv', callback)]);
    expect(find.byType(McpOAuthSheet), findsNothing);
    expect(_popped, isTrue);
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

    // Inline phase row (not a snackbar hidden behind the sheet barrier),
    // and the paste fallback opens by itself.
    expect(
      find.text('Could not open the browser — copy the link below'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mcp-oauth-callback-field')),
      findsOneWidget,
    );
  });

  testWidgets('phase is visible after opening the browser and the callback '
      'field never learns the code', (tester) async {
    final service = _FakeOAuthService();
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => true),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp-oauth-open-browser')));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for you to finish signing in'), findsOneWidget);

    await _openPaste(tester);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('mcp-oauth-callback-field')),
    );
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.keyboardType, TextInputType.url);
  });

  testWidgets('a consumed attempt restarts: begin runs twice and the second '
      'Complete pops true', (tester) async {
    final service = _FakeOAuthService()
      ..completeFailures.add(
        McpOAuthException(
          McpOAuthErrorKind.tokenExchange,
          'OAuth token exchange failed: HTTP 400',
          status: 400,
        ),
      );
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => true),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    await _openPaste(tester);
    final field = find.byKey(const ValueKey('mcp-oauth-callback-field'));
    await tester.enterText(field, 'ovid://oauth/callback?code=a&state=abc');
    await tester.tap(find.byKey(const ValueKey('mcp-oauth-complete')));
    await tester.pumpAndSettle();

    expect(service.beginCalls, ['srv', 'srv']);
    expect(
      find.text('Link refreshed — open the browser again.'),
      findsOneWidget,
    );
    expect(
      find.text('The server rejected the sign-in (HTTP 400).'),
      findsOneWidget,
    );
    expect(find.byType(McpOAuthSheet), findsOneWidget);

    await tester.enterText(field, 'ovid://oauth/callback?code=b&state=abc');
    await tester.ensureVisible(
      find.byKey(const ValueKey('mcp-oauth-complete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp-oauth-complete')));
    await tester.pumpAndSettle();
    expect(service.completeCalls, hasLength(2));
    expect(find.byType(McpOAuthSheet), findsNothing);
    expect(_popped, isTrue);
  });

  testWidgets('a wrong paste keeps the link (no restart)', (tester) async {
    final service = _FakeOAuthService()
      ..completeFailures.add(
        McpOAuthException(McpOAuthErrorKind.redirectMismatch, 'rejected'),
      );
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => true),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    await _openPaste(tester);
    await tester.enterText(
      find.byKey(const ValueKey('mcp-oauth-callback-field')),
      service.authUrl,
    );
    await tester.tap(find.byKey(const ValueKey('mcp-oauth-complete')));
    await tester.pumpAndSettle();
    expect(service.beginCalls, ['srv']);
    expect(find.textContaining('not the sign-in link'), findsOneWidget);
  });

  testWidgets('a captured redirect completes automatically; other states '
      'are ignored', (tester) async {
    final service = _FakeOAuthService();
    final callbacks = StreamController<Uri>.broadcast();
    addTearDown(callbacks.close);
    await tester.pumpWidget(
      _host(
        service: service,
        launcher: (_) async => true,
        callbacks: callbacks.stream,
      ),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    callbacks.add(
      Uri.parse('com.dhanuk.ovidai://oauth/callback?code=x&state=other'),
    );
    await tester.pumpAndSettle();
    expect(service.completeCalls, isEmpty);

    final good = Uri.parse(
      'com.dhanuk.ovidai://oauth/callback?code=x&state=abc',
    );
    callbacks.add(good);
    await tester.pumpAndSettle();
    expect(service.completeCalls, [('srv', good.toString())]);
    expect(find.byType(McpOAuthSheet), findsNothing);
    expect(_popped, isTrue);
  });

  testWidgets('shows the attempt expiry countdown', (tester) async {
    final service = _FakeOAuthService()
      ..expiry = DateTime.now().add(const Duration(minutes: 9, seconds: 30));
    await tester.pumpWidget(
      _host(service: service, launcher: (_) async => true),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Link expires in 9:'), findsOneWidget);
  });
}
