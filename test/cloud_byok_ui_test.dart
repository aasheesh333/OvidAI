// BYOK escrow UI (P8 Task 18) — pinned to the BUILT P9 server contract:
//   cloud/apps/gateway/src/routes/byok.ts
//   cloud/packages/db/src/schema.ts (byok_keys)
//
// There is NO fingerprint field. The UI shows providerId + endpoint + label +
// status only. The non-negotiable rule is stronger than the plan wording: the
// raw key must appear NOWHERE in the widget tree after upload, and nothing
// key-shaped may land in SharedPreferences.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/byok_client.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _apiKey = 'sk-ant-super-secret-9f3a';

/// The exact body the built route's `.strict()` schema accepts.
const _expectedBody = {
  'providerId': 'anthropic',
  'endpoint': 'https://api.anthropic.com/v1',
  'apiKey': _apiKey,
  'label': 'Work key',
};

Map<String, dynamic> _keyJson({
  String id = 'key-1',
  String status = 'untested',
  String? lastTestAt,
  bool? lastTestOk,
}) => {
  'id': id,
  'providerId': 'anthropic',
  'endpoint': 'https://api.anthropic.com/v1',
  'label': 'Work key',
  'status': status,
  'lastTestAt': lastTestAt,
  'lastTestOk': lastTestOk,
  'createdAt': '2026-10-18T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> posted;
  late List<http.Request> requests;
  late MockClient server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    Distribution.byokOverrideForTest = true;
    posted = [];
    requests = [];

    final stored = <Map<String, dynamic>>[];
    server = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (request.method == 'GET' && path.endsWith('/byok')) {
        return http.Response(
          jsonEncode({'items': stored}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' && path.endsWith('/byok')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        posted.add(body);
        final row = _keyJson();
        stored.add(row);
        return http.Response(
          jsonEncode(row),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'DELETE') {
        stored.removeWhere((r) => path.endsWith('/${r['id']}'));
        return http.Response('', 204);
      }
      if (request.method == 'POST' && path.endsWith('/test')) {
        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"error":{"code":"not_found"}}', 404);
    });

    ByokClient.installForTest(
      ByokClient(
        rest: CloudRestClient(
          httpClient: server,
          headers: CloudHeaders.forTest(),
          restBase: 'https://api.test/cloud/v1',
        ),
      ),
    );
  });

  tearDown(() {
    Distribution.byokOverrideForTest = null;
    ByokClient.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(540, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: SettingsScreen()),
    );
    await tester.pump();
  }

  Future<void> openByok(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Bring your own keys'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Bring your own keys'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bring your own keys'));
    await tester.pumpAndSettle();
  }

  testWidgets('upload POSTs the real server body and never shows the key',
      (tester) async {
    await pumpSettings(tester);
    await openByok(tester);

    expect(find.text('No keys yet'), findsOneWidget);

    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('byok-provider')),
      'anthropic',
    );
    await tester.enterText(
      find.byKey(const ValueKey('byok-endpoint')),
      'https://api.anthropic.com/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('byok-api-key')),
      _apiKey,
    );
    await tester.enterText(
      find.byKey(const ValueKey('byok-label')),
      'Work key',
    );
    await tester.tap(find.text('Save key'));
    await tester.pumpAndSettle();

    // The wire shape is the built route's strict schema, verbatim.
    expect(posted, hasLength(1));
    expect(posted.single, _expectedBody);
    expect(posted.single.keys.toSet(), _expectedBody.keys.toSet());

    // The row shows provider + endpoint + label + status — and NOTHING
    // key-shaped.
    expect(find.text('anthropic'), findsOneWidget);
    expect(find.text('https://api.anthropic.com/v1'), findsOneWidget);
    expect(find.text('Work key'), findsOneWidget);
    expect(find.text('untested'), findsOneWidget);
    expect(find.textContaining('sk-'), findsNothing);
    expect(find.textContaining(_apiKey), findsNothing);

    // No key-shaped value in any SharedPreferences entry.
    final prefs = await SharedPreferences.getInstance();
    final dump = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      dump[key] = prefs.get(key);
    }
    final encoded = jsonEncode(dump);
    expect(encoded, isNot(contains('sk-')));
    expect(encoded, isNot(contains(_apiKey)));
  });

  testWidgets('list renders metadata only, never key material', (tester) async {
    // Seed one key through the same client so GET returns it.
    final client = ByokClient.I;
    await client.upload(
      providerId: 'anthropic',
      endpoint: 'https://api.anthropic.com/v1',
      apiKey: _apiKey,
      label: 'Work key',
    );

    await pumpSettings(tester);
    await openByok(tester);

    expect(find.text('anthropic'), findsOneWidget);
    expect(find.text('https://api.anthropic.com/v1'), findsOneWidget);
    expect(find.text('untested'), findsOneWidget);
    expect(find.textContaining('sk-'), findsNothing);
    expect(find.textContaining('fingerprint'), findsNothing);
  });

  testWidgets('the section stays hidden when cloudByok is off', (tester) async {
    Distribution.byokOverrideForTest = false;
    await pumpSettings(tester);
    expect(find.text('Bring your own keys'), findsNothing);
  });
}
