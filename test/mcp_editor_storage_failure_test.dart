import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

class _FailingSecureStorage extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  String? failure;
  int writes = 0;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failure == 'read' || failure == 'decrypt') {
      throw PlatformException(code: failure!);
    }
    if (failure == 'json') return '{broken';
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    writes++;
    if (failure == 'write') throw PlatformException(code: 'write');
    values[key] = value;
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => values.containsKey(key);
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => values.remove(key);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      values.clear();
  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(values);
}

void main() {
  late _FailingSecureStorage backend;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    backend = _FailingSecureStorage();
    FlutterSecureStoragePlatform.instance = backend;
    AppState.createForTest();
  });
  tearDown(() {
    AppState.resetTestInstance();
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final failure in ['read', 'decrypt', 'json', 'write']) {
    testWidgets(
      '$failure failure aborts editor save without erasing credentials or config',
      (tester) async {
        final app = AppState.I;
        final server = McpServer(
          name: 'storage-fixture',
          author: 'test',
          description: '',
          category: 'Custom',
          command: 'node',
          custom: true,
          envHint: 'TOKEN',
        );
        await app.setMcpEnv(server.canonicalId, {'TOKEN': 'fixture-value'});
        final original = Map<String, String>.of(backend.values);
        await tester.pumpWidget(
          MaterialApp(home: McpDetailScreen(server: server)),
        );
        await tester.tap(find.byTooltip('Edit config'));
        await tester.pumpAndSettle();
        final config =
            jsonDecode(
                  tester
                      .widget<TextField>(find.byType(TextField))
                      .controller!
                      .text,
                )
                as Map;
        (config['mcpServers'] as Map).values.single['args'] = ['--changed'];
        await tester.enterText(find.byType(TextField), jsonEncode(config));
        backend.failure = failure;
        final writesBefore = backend.writes;
        await tester.tap(find.text('Save config'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Could not save config'), findsOneWidget);
        expect(server.args, isEmpty);
        expect(backend.values.keys, original.keys);
        expect(
          backend.values.entries.every((e) => original[e.key] == e.value),
          isTrue,
        );
        if (failure != 'write') expect(backend.writes, writesBefore);
        backend.failure = null;
        await tester.tap(find.text('Save config'));
        await tester.pumpAndSettle();
        expect(server.args, ['--changed']);
        expect(
          (await app.getMcpEnv(server.canonicalId))['TOKEN'] == 'fixture-value',
          isTrue,
        );
      },
    );
  }

  testWidgets('initial credential read failure does not open an empty editor', (
    tester,
  ) async {
    backend.failure = 'decrypt';
    final server = McpServer(
      name: 'storage-fixture',
      author: 'test',
      description: '',
      category: 'Custom',
      command: 'node',
      custom: true,
    );
    await tester.pumpWidget(MaterialApp(home: McpDetailScreen(server: server)));
    await tester.tap(find.byTooltip('Edit config'));
    await tester.pumpAndSettle();
    expect(find.text('Edit mcp.json'), findsNothing);
    expect(find.textContaining('Could not load credentials'), findsOneWidget);
    expect(backend.writes, 0);
  });
}
