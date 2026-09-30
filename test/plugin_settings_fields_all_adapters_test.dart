import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/plugin_adapters.dart';

/// The declarative settings-field contribution must parse from EVERY adapter
/// that reads a plugin manifest, not only Claude's.
///
/// It shipped wired to `ClaudePluginAdapter` alone, so a Codex plugin
/// (`.codex-plugin/plugin.json`) or a pasted generic MCP config that declared
/// `configFields` had them preserved in `unknownFields` but never surfaced as
/// fields the settings panel could render — the same declaration, two formats,
/// one working.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory tree() {
    final r = Directory.systemTemp.createTempSync('ovid-settings-fields-');
    addTearDown(() {
      if (r.existsSync()) r.deleteSync(recursive: true);
    });
    return r;
  }

  const fields = [
    {'key': 'api_token', 'label': 'API token', 'secret': true},
    {'key': 'region', 'label': 'Region', 'hint': 'e.g. eu-west-1'},
  ];

  test('a Codex plugin.json configFields declaration is parsed', () async {
    final r = tree();
    Directory('${r.path}/.codex-plugin').createSync(recursive: true);
    File('${r.path}/.codex-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': 'codex-plug',
        'version': '1.0.0',
        'author': {'name': 'T'},
        'configFields': fields,
      }),
    );

    final m = await const CodexPluginAdapter().inspect(r);

    expect(m.settingsFields.map((f) => f.key), ['api_token', 'region']);
    expect(m.settingsFields.first.secret, isTrue);
    expect(m.settingsFields.last.hint, 'e.g. eu-west-1');
  });

  test('a generic MCP config can declare configFields too', () {
    final m = const GenericMcpAdapter().inspectConfig(
      jsonEncode({
        'mcpServers': {
          'remote': {'type': 'http', 'url': 'https://mcp.example.com'},
        },
        'configFields': fields,
      }),
      sourceId: 'pasted',
    );

    expect(m.settingsFields.map((f) => f.key), ['api_token', 'region']);
    expect(m.settingsFields.first.secret, isTrue);
  });

  test('an inline secret default is dropped in every adapter', () async {
    // The Claude adapter already refuses to persist a smuggled secret value;
    // the same must hold wherever the declaration is read from.
    final r = tree();
    Directory('${r.path}/.codex-plugin').createSync(recursive: true);
    File('${r.path}/.codex-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': 'leaky',
        'version': '1.0.0',
        'author': {'name': 'T'},
        'configFields': [
          {
            'key': 'api_token',
            'label': 'Token',
            'secret': true,
            'default': 'sk-SHOULD-NOT-PERSIST',
          },
        ],
      }),
    );

    final m = await const CodexPluginAdapter().inspect(r);
    final encoded = jsonEncode(m.toJson());
    expect(encoded, isNot(contains('sk-SHOULD-NOT-PERSIST')));
  });

  test('no declaration means no fields (and no digest churn)', () async {
    final r = tree();
    Directory('${r.path}/.codex-plugin').createSync(recursive: true);
    File('${r.path}/.codex-plugin/plugin.json').writeAsStringSync(
      jsonEncode({'name': 'plain', 'version': '1.0.0', 'author': {'name': 'T'}}),
    );

    final m = await const CodexPluginAdapter().inspect(r);
    expect(m.settingsFields, isEmpty);
    expect(m.toJson().containsKey('settingsFields'), isFalse,
        reason: 'an always-present empty key would re-digest every install');
  });
}
