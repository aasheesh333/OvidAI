import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/account_settings_client.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/memory_screen.dart';
import 'package:ovid_ai/ui/settings_presets_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sid = '0190a6b2-7c4e-7a10-8000-0000000000aa';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<http.Request> requests;
  var shared = false;
  var failRead = false;
  final preset = {'id': 'custom-safe', 'label': 'Safe', 'description': '', 'deniedTools': ['run_shell'], 'model': null, 'temperature': 0.4};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    requests = [];
    shared = false;
    failRead = false;
    memorySessionIdForTest = sid;
    final client = MockClient((r) async {
      requests.add(r);
      http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
      if (r.url.path.endsWith('/memory')) return json({'items': [{'name': 'notes.md', 'sizeBytes': 5}], 'scope': shared ? 'shared' : 'chat'});
      if (r.url.path.contains('/memory/')) {
        if (r.method == 'GET' && failRead) return json({'error': {'code': 'unavailable', 'message': 'failed'}}, 503);
        if (r.method == 'DELETE') return http.Response('', 204);
        return json({'name': 'notes.md', 'content': 'hello', 'revision': 'a' * 64});
      }
      if (r.url.path.endsWith('/presets')) return json({'builtIn': ['standard'], 'custom': [preset], 'toolGroups': [{'id': 'shell', 'label': 'Shell', 'tools': ['run_shell']}], 'maxCustom': 20});
      if (r.method == 'DELETE') return http.Response('', 204);
      if (r.url.path.endsWith('/preset')) return json({'sessionId': sid, 'presetId': 'custom-safe'});
      if (r.method == 'PUT') return json({...jsonDecode(r.body) as Map<String, dynamic>, 'id': 'custom-safe'});
      return json({}, 404);
    });
    AccountSettingsClient.installForTest(AccountSettingsClient(rest: CloudRestClient(httpClient: client, headers: CloudHeaders.forTest(), restBase: 'https://api.test/cloud/v1')));
  });
  tearDown(() {
    memorySessionIdForTest = null;
    serverSessionIdForTest = null;
    AccountSettingsClient.installForTest(null);
    AppState.resetTestInstance();
  });

  testWidgets('Memory names current-chat scope and every request carries the explicit server chat', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Current chat only'), findsOneWidget);
    expect(requests.single.url.queryParameters['sessionId'], sid);
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('memory-content')), 'changed');
    await tester.tap(find.byKey(const ValueKey('memory-save')));
    await tester.pumpAndSettle();
    final put = requests.singleWhere((r) => r.method == 'PUT');
    expect(put.url.queryParameters['sessionId'], sid);
    expect(jsonDecode(put.body), {'content': 'changed', 'ifRevision': 'a' * 64});
  });

  testWidgets('shared scope is explicit, not confused with current-chat memory', (tester) async {
    shared = true;
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Shared memory is on'), findsOneWidget);
    expect(find.textContaining('Current chat only'), findsNothing);
  });

  testWidgets('unsent chat does not query global memory or offer a working-looking create action', (tester) async {
    memorySessionIdForTest = null;
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.textContaining('Open a cloud chat first'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('memory-new'))).onPressed, isNull);
  });

  testWidgets('failed memory read cannot overwrite a file without a loaded revision', (tester) async {
    failRead = true;
    await tester.pumpWidget(const MaterialApp(home: MemoryEditorScreen(name: 'notes.md', sessionId: sid)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('memory-save'))).onPressed, isNull);
    expect(requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  testWidgets('custom preset applies server-side and does not get overwritten by a built-in on send', (tester) async {
    AppState.I.newSession();
    final s = AppState.I.activeSession!;
    serverSessionIdForTest = (_) => sid;
    await tester.pumpWidget(const MaterialApp(home: PresetsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use in this chat'));
    await tester.pumpAndSettle();
    final apply = requests.singleWhere((r) => r.url.path.endsWith('/preset'));
    expect(jsonDecode(apply.body), {'presetId': 'custom-safe'});
    expect(s.customPresetId, 'custom-safe');
    expect(s.presetId, '');
  });

  testWidgets('custom preset delete confirms before touching the server', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PresetsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
  });
}
