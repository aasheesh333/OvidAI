// The connectors screen must show what the gateway knows, not a local list.

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/connectors/connector_api.dart';
import 'package:ovid_ai/ui/v2/connectors/catalog_data.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_catalog_loader.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';

class _FakeApi implements ConnectorApi {
  _FakeApi({this.catalog = const [], this.servers = const []});

  final List<ConnectorCatalogEntry> catalog;
  final List<ConnectorServer> servers;
  int catalogCalls = 0;

  @override
  Future<List<ConnectorCatalogEntry>> listCatalog() async {
    catalogCalls++;
    return catalog;
  }

  @override
  Future<List<ConnectorServer>> listServers() async => servers;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConnectorCatalogEntry _entry(String id, {bool configured = false}) =>
    ConnectorCatalogEntry(
      curatedId: id,
      displayName: id.toUpperCase(),
      description: 'about $id',
      credentialFields: const [
        ConnectorCredentialField(key: 'TOKEN', label: 'Token', secret: true),
      ],
      toolNames: ['${id}_search'],
      configured: configured,
    );

ConnectorServer _server({
  required String id,
  String? curatedId,
  bool enabled = true,
}) =>
    ConnectorServer(
      id: id,
      name: curatedId ?? id,
      transport: 'http',
      enabled: enabled,
      hasSecrets: true,
      needsAuth: false,
      curatedId: curatedId,
    );

void main() {
  test('a configured curated server shows as connected, the rest as available',
      () async {
    final data = await loadConnectorCatalog(
      _FakeApi(
        catalog: [_entry('github', configured: true), _entry('notion')],
        servers: [_server(id: 'srv-1', curatedId: 'github')],
      ),
    );

    expect(data.status, V2ConnectorsStatus.content);
    // The built-in display list must NOT be used any more.
    expect(data.useBuiltInCatalog, isFalse);
    expect(data.catalog.map((c) => c.id), ['github', 'notion']);

    final github = data.catalog.firstWhere((c) => c.id == 'github');
    final notion = data.catalog.firstWhere((c) => c.id == 'notion');
    expect(github.connected, isTrue);
    expect(github.enabled, isTrue);
    expect(notion.connected, isFalse);
    expect(github.tools, ['github_search']);
    expect(github.kind, V2ConnectorKind.app);
  });

  test('a custom server (no curated id) is listed with its endpoint', () async {
    final data = await loadConnectorCatalog(
      _FakeApi(
        catalog: [_entry('github')],
        servers: [
          _server(id: 'custom-1', enabled: false),
        ],
      ),
    );

    final custom = data.catalog.firstWhere((c) => c.id == 'custom-1');
    expect(custom.connected, isTrue);
    expect(custom.enabled, isFalse);
    expect(custom.kind, V2ConnectorKind.mcp);
  });

  test('an empty catalog is a real empty state, not the built-in list', () async {
    final data = await loadConnectorCatalog(_FakeApi());
    expect(data.catalog, isEmpty);
    expect(data.useBuiltInCatalog, isFalse);
  });
}
