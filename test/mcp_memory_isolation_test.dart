import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

McpServer _memoryServer({String name = 'Memory', String? ownerPluginId}) =>
    McpServer(
      name: name,
      author: 'modelcontextprotocol',
      description: 'Memory',
      category: 'Official',
      command: '',
      args: const [],
      transport: 'native',
      ownerPluginId: ownerPluginId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUp(() {
    docs = Directory.systemTemp.createTempSync('mcp_memory_isolation_');
  });
  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  test('distinct memory servers resolve distinct storage files', () async {
    final ownerless = _memoryServer(name: 'Memory');
    final pluginOwned = _memoryServer(
      name: 'Memory',
      ownerPluginId: 'plugin:acme/memory',
    );

    final a = await McpService.memoryStorageFileForTest(docs.path, ownerless);
    final b = await McpService.memoryStorageFileForTest(docs.path, pluginOwned);

    expect(a.path, isNot(equals(b.path)));
  });

  test('the same memory server resolves the same storage file on reconnect',
      () async {
    final server = _memoryServer(
      name: 'Memory',
      ownerPluginId: 'plugin:acme/memory',
    );

    final first = await McpService.memoryStorageFileForTest(docs.path, server);
    final second = await McpService.memoryStorageFileForTest(docs.path, server);

    expect(first.path, equals(second.path));
  });

  test('legacy shared memory file is migrated into the per-server file',
      () async {
    final legacy = File('${docs.path}/mcp_memory.json');
    legacy.writeAsStringSync(
      jsonEncode({
        'entities': [
          {
            'name': 'Legacy',
            'entityType': 'Test',
            'observations': ['from legacy'],
          }
        ],
        'relations': [],
      }),
    );

    final server = _memoryServer(name: 'Memory');
    final perServer = await McpService.memoryStorageFileForTest(
      docs.path,
      server,
    );

    expect(perServer.path, isNot(equals(legacy.path)));
    expect(perServer.existsSync(), isTrue);
    final migrated =
        jsonDecode(perServer.readAsStringSync()) as Map<String, dynamic>;
    expect((migrated['entities'] as List).single['name'], equals('Legacy'));
    expect(legacy.existsSync(), isTrue);
  });

  test('existing per-server file is not overwritten by legacy migration',
      () async {
    final server = _memoryServer(name: 'Memory');
    final perServer = await McpService.memoryStorageFileForTest(
      docs.path,
      server,
    );
    perServer.parent.createSync(recursive: true);
    perServer.writeAsStringSync(
      jsonEncode({
        'entities': [
          {'name': 'Fresh', 'entityType': 'Test', 'observations': []}
        ],
        'relations': [],
      }),
    );

    final legacy = File('${docs.path}/mcp_memory.json');
    legacy.writeAsStringSync(
      jsonEncode({
        'entities': [
          {'name': 'Legacy', 'entityType': 'Test', 'observations': []}
        ],
        'relations': [],
      }),
    );

    final resolved = await McpService.memoryStorageFileForTest(
      docs.path,
      server,
    );
    final content =
        jsonDecode(resolved.readAsStringSync()) as Map<String, dynamic>;
    expect((content['entities'] as List).single['name'], equals('Fresh'));
  });
}
