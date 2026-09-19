import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';

/// Real [CC] marketplaces use OBJECT shapes for `owner`, `author`, `metadata`
/// and `source`. Ovid cast `author` to `String?`, so importing a spec-shaped
/// marketplace threw
/// `type '_Map<String, dynamic>' is not a subtype of type 'String?'`
/// and the whole import failed. These pin tolerant parsing for every field the
/// ecosystem varies on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() => AppState.resetTestInstance());

  String importJson(String json, {String owner = 'acme', String repo = 'tools'}) {
    return AppState.I.mergeMarketplaceCatalogForTest(
      jsonDecode(json) as Map<String, dynamic>,
      owner,
      repo,
    );
  }

  test('object author is accepted and its name is used', () {
    final msg = importJson(r'''
{ "plugins": [ { "name": "widget",
  "author": { "name": "Jane Dev", "email": "jane@acme.test" },
  "source": "./widget", "category": "Tool" } ] }''');
    expect(msg, contains('Imported 1 plugin'));
    final p = AppState.I.plugins.firstWhere((e) => e.name == 'widget');
    expect(p.author, 'Jane Dev');
  });

  test('string author is still accepted', () {
    importJson(r'''
{ "plugins": [ { "name": "strplugin", "author": "Acme", "source": "./s" } ] }''');
    expect(
      AppState.I.plugins.firstWhere((e) => e.name == 'strplugin').author,
      'Acme',
    );
  });

  test('a root owner object does not break the import', () {
    final msg = importJson(r'''
{ "name": "acme", "owner": { "name": "Acme Inc", "email": "dev@acme.test" },
  "plugins": [ { "name": "owned", "source": "./o" } ] }''');
    expect(msg, contains('Imported 1 plugin'));
    // No author on the plugin → falls back to the marketplace owner slug.
    expect(
      AppState.I.plugins.firstWhere((e) => e.name == 'owned').author,
      'acme',
    );
  });

  test('root metadata object does not break the import', () {
    final msg = importJson(r'''
{ "metadata": { "description": "Acme tools", "version": "2.0" },
  "plugins": [ { "name": "metaok", "source": "./m" } ] }''');
    expect(msg, contains('Imported 1 plugin'));
  });

  test('object source (github) resolves without a cast error', () {
    final msg = importJson(r'''
{ "plugins": [ { "name": "remote",
  "source": { "source": "github", "repo": "other/repo" } } ] }''');
    expect(msg, contains('Imported 1 plugin'));
    expect(
      AppState.I.plugins.firstWhere((e) => e.name == 'remote').source,
      'other/repo',
    );
  });

  test('object source (url) resolves without a cast error', () {
    importJson(r'''
{ "plugins": [ { "name": "urlplug",
  "source": { "source": "url", "url": "https://github.com/o/r" } } ] }''');
    expect(
      AppState.I.plugins.firstWhere((e) => e.name == 'urlplug').source,
      'o/r',
    );
  });

  test('missing category defaults instead of rejecting', () {
    importJson(r'''
{ "plugins": [ { "name": "nocat", "source": "./n" } ] }''');
    expect(
      AppState.I.plugins.firstWhere((e) => e.name == 'nocat').category,
      isNotEmpty,
    );
  });

  test('MCP entries with an object author import too', () {
    final msg = importJson(r'''
{ "mcpServers": [ { "name": "srv",
  "author": { "name": "MCP Inc" }, "command": "npx" } ] }''');
    expect(msg, contains('MCP server'));
  });
}
