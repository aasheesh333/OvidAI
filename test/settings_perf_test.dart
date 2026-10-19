import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/settings_backup_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _CountingPreferences extends InMemorySharedPreferencesStore {
  _CountingPreferences() : super.empty();

  final writes = <String, int>{};

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes.update(key, (n) => n + 1, ifAbsent: () => 1);
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(AppState.resetTestInstance);

  testWidgets('hint radio selection persists exactly once without a slider', (
    tester,
  ) async {
    final backend = _CountingPreferences();
    SharedPreferencesStorePlatform.instance = backend;
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    final tile = find.text('Responses');
    await tester.scrollUntilVisible(tile, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final choice = find.byKey(const ValueKey('hint-60'));
    await tester.scrollUntilVisible(choice, 200, scrollable: find.byType(Scrollable).last);
    var notifies = 0;
    void count() => notifies++;
    AppState.I.addListener(count);
    addTearDown(() => AppState.I.removeListener(count));
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(backend.writes['flutter.ovid_response_timeout_sec'], 1);
    expect(notifies, 1);
    expect(AppState.I.responseTimeoutSec, 60);
    expect((await SharedPreferences.getInstance()).getInt('ovid_response_timeout_sec'), 60);
  });

  test('chat export is written off the UI isolate as valid JSON', () async {
    final dir = await Directory.systemTemp.createTemp('export-sessions-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/out.json';
    final sessions = [
      for (var i = 0; i < 3; i++)
        {
          'id': 's$i',
          'messages': [
            {'role': 'user', 'content': 'hello "$i"\n' * 50},
          ],
        },
    ];
    await writeSessionsExport(
      path,
      exportedAt: '2026-10-11T00:00:00.000',
      sessions: sessions,
    );
    final raw = await File(path).readAsString();
    expect(raw, isNot(contains('\n  ')), reason: 'no indentation');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded['exportedAt'], '2026-10-11T00:00:00.000');
    expect(decoded['sessions'], sessions);
  });

  test('empty chat export is valid JSON', () async {
    final dir = await Directory.systemTemp.createTemp('export-sessions-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/out.json';
    await writeSessionsExport(path, exportedAt: 'now', sessions: const []);
    expect(jsonDecode(await File(path).readAsString()), {
      'exportedAt': 'now',
      'sessions': <Object>[],
    });
  });
}
