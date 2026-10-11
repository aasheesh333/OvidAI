import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/l10n/l10n.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l = appLocalizationsFallback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    providerModelsHttpClientForTest = null;
    AppState.resetTestInstance();
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  Future<void> fetchWith(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) handler,
  ) async {
    final app = AppState.createForTest();
    app.providers
      ..clear()
      ..add(
        ProviderConfig(
          id: 'gw',
          name: 'Gateway',
          description: 'Custom gateway',
          baseUrl: 'https://gw.example.test/v1',
          custom: true,
          models: ['kept'],
        ),
      );
    providerModelsHttpClientForTest = MockClient(handler);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
    final button = find.descendant(
      of: find.ancestor(
        of: find.text('Gateway'),
        matching: find.byType(AetherCard),
      ),
      matching: find.widgetWithText(TextButton, 'Fetch models'),
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  void expectNoRawText() {
    for (final raw in [
      'HTTP',
      'Exception',
      'Bad state',
      'is not a subtype',
      'Fetch failed',
    ]) {
      expect(find.textContaining(raw), findsNothing, reason: raw);
    }
  }

  // A bare JSON array is a valid listing (Together AI style, PR-6d); a
  // body with no model list at all is not.
  testWidgets('non-list body shows Unexpected response', (tester) async {
    await fetchWith(tester, (_) async => http.Response('"maintenance"', 200));
    expect(find.text(l.providerFetchUnexpectedResponse), findsOneWidget);
    expectNoRawText();
  });

  for (final (status, message) in [
    (401, l.providerFetchKeyRejected),
    (403, l.providerFetchKeyRejected),
    (404, l.providerFetchNoModelsEndpoint),
    (429, l.providerFetchRateLimited),
    (502, l.providerFetchServerError),
  ]) {
    testWidgets('HTTP $status shows friendly copy', (tester) async {
      await fetchWith(tester, (_) async => http.Response('nope', status));
      expect(find.text(message), findsOneWidget);
      expectNoRawText();
    });
  }

  testWidgets('socket failure shows Couldn\'t reach provider', (tester) async {
    await fetchWith(
      tester,
      (_) async => throw const SocketException('Failed host lookup'),
    );
    expect(find.text(l.providerFetchUnreachable), findsOneWidget);
    expectNoRawText();
  });

  testWidgets('object body still merges models', (tester) async {
    await fetchWith(
      tester,
      (_) async => http.Response('{"data":[{"id":"fresh"}]}', 200),
    );
    expect(find.textContaining('1 models fetched'), findsOneWidget);
  });
}
