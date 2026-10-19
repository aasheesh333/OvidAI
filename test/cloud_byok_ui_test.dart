// Wave 4 (SE-004 / SE-017): "Your API keys" — the one key screen, pinned to
// the built server contract (cloud/apps/gateway/src/routes/byok.ts and
// accountSettings.ts). The raw key must appear nowhere in the widget tree
// after upload and nothing key-shaped may land in SharedPreferences.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/account_settings_client.dart';
import 'package:ovid_ai/core/cloud/byok_client.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/l10n/l10n.dart';
import 'package:ovid_ai/ui/settings_keys_screen.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _apiKey = 'sk-ant-super-secret-9f3a';
const _keyId = '0190a6b2-7c4e-7a10-8000-0000000000aa';

Map<String, dynamic> _keyJson() => {
  'id': _keyId,
  'providerId': 'anthropic',
  'endpoint': 'https://api.anthropic.com/v1',
  'label': 'Work key',
  'status': 'untested',
  'lastTestAt': null,
  'lastTestOk': null,
  'createdAt': '2026-10-18T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> posted;
  late List<Map<String, dynamic>> settingsPatches;
  late List<String> deletes;
  late List<Map<String, dynamic>> stored;
  Map<String, dynamic>? byokDefault;
  var listFails = false;
  Completer<http.Response>? testGate;
  var testsSent = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    Distribution.byokOverrideForTest = true;
    posted = [];
    settingsPatches = [];
    deletes = [];
    stored = [];
    byokDefault = null;
    listFails = false;
    testGate = null;
    testsSent = 0;

    final server = MockClient((request) async {
      final path = request.url.path;
      http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
      if (path.endsWith('/settings')) {
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          settingsPatches.add(body);
          if (body.containsKey('byokDefault')) {
            byokDefault = body['byokDefault'] as Map<String, dynamic>?;
          }
        }
        return json({'notificationsEnabled': true, 'byokDefault': byokDefault});
      }
      if (request.method == 'POST' && path.endsWith('/test')) {
        testsSent++;
        if (testGate != null) return testGate!.future;
        stored[0] = {...stored[0], 'lastTestAt': DateTime.now().toUtc().toIso8601String(), 'lastTestOk': true, 'status': 'ok'};
        return json({'ok': true});
      }
      if (request.method == 'GET' && path.endsWith('/byok')) {
        if (listFails) return json({'error': {'code': 'unavailable', 'message': 'internal upstream 10.0.0.5'}}, 503);
        return json({'items': stored});
      }
      if (request.method == 'POST' && path.endsWith('/byok')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['endpoint'] == 'https://evil.test/v1') {
          return json({
            'error': {
              'code': 'endpoint_rejected',
              'message': 'The provider endpoint is not an allowed endpoint identity.',
            },
          }, 400);
        }
        posted.add(body);
        stored.add(_keyJson());
        return json(_keyJson(), 201);
      }
      if (request.method == 'DELETE') {
        deletes.add(path);
        stored.clear();
        return http.Response('', 204);
      }
      return json({'error': {'code': 'not_found', 'message': 'x'}}, 404);
    });
    final rest = CloudRestClient(
      httpClient: server,
      headers: CloudHeaders.forTest(),
      restBase: 'https://api.test/cloud/v1',
    );
    ByokClient.installForTest(ByokClient(rest: rest));
    AccountSettingsClient.installForTest(AccountSettingsClient(rest: rest));
  });

  tearDown(() {
    Distribution.byokOverrideForTest = null;
    ByokClient.resetForTest();
    AccountSettingsClient.installForTest(null);
    AppState.resetTestInstance();
  });

  Future<void> pumpKeys(WidgetTester tester) async {
    tester.view.physicalSize = const Size(540, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: KeysScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> fillForm(WidgetTester tester, {String? endpoint}) async {
    await tester.tap(find.byKey(const ValueKey('keys-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('byok-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();
    if (endpoint != null) {
      await tester.tap(find.byKey(const ValueKey('byok-provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other (OpenAI-compatible)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('byok-provider-name')),
        'myco',
      );
      await tester.enterText(find.byKey(const ValueKey('byok-endpoint')), endpoint);
    }
    await tester.enterText(find.byKey(const ValueKey('byok-api-key')), _apiKey);
    await tester.enterText(find.byKey(const ValueKey('byok-label')), 'Work key');
    await tester.tap(find.byKey(const ValueKey('byok-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('Settings has ONE key screen and no device Providers row', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pump();
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Your API keys'), 250, scrollable: list);
    expect(find.text('Your API keys'), findsOneWidget);
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Bring your own keys'), findsNothing);
  });

  testWidgets('upload POSTs the real server body, confirms, never shows the key', (
    tester,
  ) async {
    await pumpKeys(tester);
    expect(find.byKey(const ValueKey('byok-empty')), findsOneWidget);
    await fillForm(tester);

    expect(posted.single, {
      'providerId': 'anthropic',
      'endpoint': 'https://api.anthropic.com/v1',
      'apiKey': _apiKey,
      'label': 'Work key',
    });
    expect(find.text('Key saved.'), findsOneWidget);
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('Not tested yet'), findsOneWidget);
    expect(find.textContaining('sk-'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    final dump = {for (final k in prefs.getKeys()) k: prefs.get(k)};
    expect(jsonEncode(dump), isNot(contains(_apiKey)));
  });

  testWidgets('a non-https endpoint is refused inline before any request', (
    tester,
  ) async {
    await pumpKeys(tester);
    await fillForm(tester, endpoint: 'http://api.example.com/v1');
    expect(posted, isEmpty);
    expect(find.text("Use the provider's official https:// API address."), findsOneWidget);
  });

  testWidgets('a rejected endpoint shows human copy, not server jargon', (
    tester,
  ) async {
    await pumpKeys(tester);
    await fillForm(tester, endpoint: 'https://evil.test/v1');
    expect(find.text("Use the provider's official HTTPS API address."), findsOneWidget);
    expect(find.textContaining('endpoint identity'), findsNothing);
  });

  testWidgets('Remove asks for confirmation; cancel keeps the key', (tester) async {
    stored.add(_keyJson());
    await pumpKeys(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this key?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deletes, isEmpty);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove key'));
    await tester.pumpAndSettle();
    expect(deletes.single, endsWith('/byok/$_keyId'));
    expect(find.text('Key removed.'), findsOneWidget);
  });

  testWidgets('Use for my chats sets the BYOK default with a model', (tester) async {
    stored.add(_keyJson());
    await pumpKeys(tester);
    expect(find.textContaining('Ovid models, counted'), findsOneWidget);
    await tester.tap(find.text('Use for my chats'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('keys-model')), 'claude-x');
    await tester.tap(find.widgetWithText(FilledButton, 'Use for my chats'));
    await tester.pumpAndSettle();
    expect(settingsPatches.single, {
      'byokDefault': {'keyId': _keyId, 'model': 'claude-x'},
    });
    expect(find.textContaining('claude-x with your Anthropic key'), findsOneWidget);
    expect(find.text('Used for chats'), findsOneWidget);
  });

  testWidgets('a device-only key can be deleted after confirmation', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'ovid_provider_key_groq': 'gsk_device_key_123456',
    });
    await AppState.I.loadProviderCredentials();
    await pumpKeys(tester);
    expect(find.text('Keys saved on this phone only'), findsOneWidget);
    expect(find.text('Groq'), findsOneWidget);
    expect(find.textContaining('gsk_device_key_123456'), findsNothing);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(AppState.I.legacyDeviceKeys, isEmpty);
    expect(find.text('Keys saved on this phone only'), findsNothing);
  });

  testWidgets('failed key loading offers Retry and recovers the server list', (tester) async {
    listFails = true;
    await pumpKeys(tester);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('10.0.0.5'), findsNothing);
    listFails = false;
    stored.add(_keyJson());
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('byok-row-$_keyId')), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('testing disables only that row and does not label Remove as Testing', (tester) async {
    stored.add(_keyJson());
    testGate = Completer<http.Response>();
    await pumpKeys(tester);
    await tester.tap(find.text('Test'));
    await tester.pump();
    expect(testsSent, 1);
    expect(find.text('Testing…'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('Removing…'), findsNothing);
    testGate!.complete(http.Response(jsonEncode({'ok': false}), 200));
    await tester.pumpAndSettle();
    expect(find.text('Test'), findsOneWidget);
    expect(find.text('Testing…'), findsNothing);
  });

  testWidgets('add-key form stays usable on a narrow screen at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
      home: const AddKeyScreen(),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('byok-save')), 150, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(const ValueKey('byok-save')));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('byok-save')));
    await tester.pumpAndSettle();
    expect(posted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('validateKeyEndpoint', () {
    final l = appLocalizationsFallback;
    expect(validateKeyEndpoint(l, 'https://api.openai.com/v1'), isNull);
    expect(validateKeyEndpoint(l, ''), isNotNull);
    expect(validateKeyEndpoint(l, 'ftp://x'), isNotNull);
    expect(validateKeyEndpoint(l, 'https://user:pw@x.com'), isNotNull);
  });
}
