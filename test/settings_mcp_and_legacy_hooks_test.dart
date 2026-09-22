import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.I;
    await app.initialize();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    app.mcpServers.removeWhere((s) => s.name.startsWith('settings-'));
  });

  tearDown(() {
    AppState.pluginCacheRootOverrideForTest = null;
  });

  group('B10: legacy hook import accepts CC-native names', () {
    test(
      'registerPluginHooks keeps CC-native keys under canonical names',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('ovid_cc_hooks_');
        addTearDown(() => tempDir.deleteSync(recursive: true));
        AppState.pluginCacheRootOverrideForTest = tempDir;

        final p = PluginItem(
          name: 'cc-hooked',
          author: 'you',
          description: '',
          version: '1.0',
          category: 'Tool',
          installed: true,
          enabled: true,
          source: 'acme/cc-hooked',
        );
        app.plugins.add(p);
        addTearDown(() => app.plugins.remove(p));

        final cacheDir = Directory(
          '${tempDir.path}/plugin-content/acme_cc-hooked',
        );
        Directory('${cacheDir.path}/hooks').createSync(recursive: true);
        File('${cacheDir.path}/hooks/hooks.json').writeAsStringSync(
          jsonEncode({
            'hooks': {
              'PreToolUse': 'exit 2',
              'SessionStart': 'echo start',
              'Notification': 'echo note',
              'Stop': 'echo stop',
            },
          }),
        );

        final n = await app.registerPluginHooks(p);
        expect(n, 4);
        expect(p.hooks['pre_tool'], 'exit 2');
        expect(p.hooks['session_start'], 'echo start');
        expect(p.hooks['notification'], 'echo note');
        expect(p.hooks['stop'], 'echo stop');
      },
    );

    test('registerPluginHooks keeps legacy on_* keys unchanged', () async {
      final tempDir = Directory.systemTemp.createTempSync('ovid_on_hooks_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      AppState.pluginCacheRootOverrideForTest = tempDir;

      final p = PluginItem(
        name: 'on-hooked',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        source: 'acme/on-hooked',
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));

      final cacheDir = Directory(
        '${tempDir.path}/plugin-content/acme_on-hooked',
      );
      Directory('${cacheDir.path}/hooks').createSync(recursive: true);
      File('${cacheDir.path}/hooks/hooks.json').writeAsStringSync(
        jsonEncode({
          'hooks': {
            'on_pre_tool': 'exit 2',
            'on_turn_start': {'command': 'echo start', 'matcher': 'run_*'},
          },
        }),
      );

      final n = await app.registerPluginHooks(p);
      expect(n, 2);
      expect(p.hooks['on_pre_tool'], 'exit 2');
      expect(p.hooks['on_turn_start'], 'echo start');
      expect(p.hookMatchers['on_turn_start'], 'run_*');
    });

    test('marketplace import keeps CC-native hook names', () {
      final merged = app.mergeMarketplaceCatalogForTest(
        {
          'plugins': [
            {
              'name': 'cc-market-hooks',
              'hooks': {'PreToolUse': 'exit 2', 'Stop': 'echo done'},
            },
          ],
        },
        'testowner',
        'testrepo',
      );
      expect(merged, contains('Imported 1 plugin'));
      final imported = app.plugins.firstWhere(
        (x) => x.name == 'cc-market-hooks',
      );
      addTearDown(() => app.plugins.remove(imported));
      expect(imported.hooks['pre_tool'], 'exit 2');
      expect(imported.hooks['stop'], 'echo done');
    });

    test('marketplace import keeps legacy on_* hook names', () {
      final merged = app.mergeMarketplaceCatalogForTest(
        {
          'plugins': [
            {
              'name': 'on-market-hooks',
              'hooks': {'on_turn_end': 'echo end'},
            },
          ],
        },
        'testowner',
        'testrepo',
      );
      expect(merged, contains('Imported 1 plugin'));
      final imported = app.plugins.firstWhere(
        (x) => x.name == 'on-market-hooks',
      );
      addTearDown(() => app.plugins.remove(imported));
      expect(imported.hooks['on_turn_end'], 'echo end');
    });
  });

  group('B11: settings-level MCP import', () {
    test('imports a stdio server from settings mcpServers', () async {
      final n = await app.importMcpFromSettings(
        jsonEncode({
          'mcpServers': {
            'settings-alpha': {
              'command': 'npx',
              'args': ['-y', 'alpha'],
            },
          },
        }),
      );
      expect(n, 1);
      final s = app.mcpServers.firstWhere((e) => e.name == 'settings-alpha');
      expect(s.command, 'npx');
      expect(s.args, ['-y', 'alpha']);
      expect(s.transport, 'stdio');
      expect(s.custom, isTrue);
    });

    test('imports an http server with url and headers', () async {
      final n = await app.importMcpFromSettings(
        jsonEncode({
          'mcpServers': {
            'settings-remote': {
              'url': 'https://example.com/mcp',
              'headers': {'Authorization': 'Bearer tok'},
            },
          },
        }),
      );
      expect(n, 1);
      final s = app.mcpServers.firstWhere((e) => e.name == 'settings-remote');
      expect(s.transport, 'http');
      expect(s.url, 'https://example.com/mcp');
      expect(s.headers['Authorization'], 'Bearer tok');
    });

    test('honors disabledMcpjsonServers', () async {
      final n = await app.importMcpFromSettings(
        jsonEncode({
          'mcpServers': {
            'settings-off': {'command': 'npx'},
            'settings-on': {'command': 'npx'},
          },
          'disabledMcpjsonServers': ['settings-off'],
        }),
      );
      expect(n, 1);
      expect(app.mcpServers.any((e) => e.name == 'settings-off'), isFalse);
      expect(app.mcpServers.any((e) => e.name == 'settings-on'), isTrue);
    });

    test('enabledMcpjsonServers is an allowlist', () async {
      final n = await app.importMcpFromSettings(
        jsonEncode({
          'mcpServers': {
            'settings-a': {'command': 'npx'},
            'settings-b': {'command': 'npx'},
          },
          'enabledMcpjsonServers': ['settings-a'],
        }),
      );
      expect(n, 1);
      expect(app.mcpServers.any((e) => e.name == 'settings-a'), isTrue);
      expect(app.mcpServers.any((e) => e.name == 'settings-b'), isFalse);
    });

    test('enableAllProjectMcpServers overrides the allowlist', () async {
      final n = await app.importMcpFromSettings(
        jsonEncode({
          'mcpServers': {
            'settings-a': {'command': 'npx'},
            'settings-b': {'command': 'npx'},
          },
          'enableAllProjectMcpServers': true,
          'enabledMcpjsonServers': ['settings-a'],
        }),
      );
      expect(n, 2);
    });

    test('never throws on malformed settings', () async {
      expect(await app.importMcpFromSettings('not json'), 0);
      expect(await app.importMcpFromSettings('{"mcpServers": 5}'), 0);
    });
  });

  group('P21: addCustomMcpServer accepts SSE', () {
    test('accepts sse and records the server', () {
      final err = app.addCustomMcpServer(
        name: 'settings-sse',
        command: '',
        transport: 'sse',
        url: 'https://example.com/sse',
      );
      expect(err, isNull);
      final s = app.mcpServers.firstWhere((e) => e.name == 'settings-sse');
      expect(s.transport, 'sse');
      expect(s.url, 'https://example.com/sse');
    });

    test('still rejects unknown transports without creating a dead row', () {
      final err = app.addCustomMcpServer(
        name: 'settings-bogus',
        command: '',
        transport: 'bogus',
        url: 'https://example.com/x',
      );
      expect(err, isNotNull);
      expect(err, contains('bogus'));
      expect(app.mcpServers.any((e) => e.name == 'settings-bogus'), isFalse);
    });

    test('still accepts stdio and http transports', () {
      expect(
        app.addCustomMcpServer(name: 'settings-stdio', command: 'npx'),
        isNull,
      );
      expect(
        app.addCustomMcpServer(
          name: 'settings-http',
          command: '',
          url: 'https://example.com/mcp',
          transport: 'http',
        ),
        isNull,
      );
      expect(
        app.mcpServers
            .firstWhere((e) => e.name == 'settings-stdio')
            .transport,
        'stdio',
      );
      expect(
        app.mcpServers
            .firstWhere((e) => e.name == 'settings-http')
            .transport,
        'http',
      );
    });
  });
}
