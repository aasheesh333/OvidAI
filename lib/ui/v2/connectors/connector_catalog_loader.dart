import 'package:flutter/material.dart';

import '../../../core/connectors/connector_api.dart';
import '../../../core/connectors/remote_connector_controller.dart';
import 'catalog_data.dart';
import 'connectors_page.dart';

/// Builds the connectors screen from the gateway's own catalog.
///
/// The built-in [v2BuiltInCatalog] is a design reference, not a data source:
/// it lists far more integrations than the gateway can actually run, and
/// enabling one of those changed nothing the agent could use. This loader
/// shows exactly what the server serves — curated servers with the user's
/// configured state, plus their custom MCP servers.
Future<V2ConnectorsData> loadConnectorCatalog(ConnectorApi api) async {
  final catalog = await api.listCatalog();
  final servers = await api.listServers();

  final configuredByCurated = <String, ConnectorServer>{
    for (final server in servers)
      if (server.curatedId != null) server.curatedId!: server,
  };

  final rows = <V2Connector>[
    for (final entry in catalog)
      V2Connector(
        id: entry.curatedId,
        name: entry.displayName,
        description: entry.description,
        connected: configuredByCurated.containsKey(entry.curatedId),
        category: 'Apps',
        kind: V2ConnectorKind.app,
        enabled: configuredByCurated[entry.curatedId]?.enabled ?? false,
        builtIn: true,
        tools: entry.toolNames,
        configurationFields: entry.configurationFields,
        auth: entry.credentialFields.isEmpty
            ? V2CatalogAuth.none
            : V2CatalogAuth.apiKey,
        // A hosted integration can read and change the user's data; the
        // catalog has no per-entry risk yet, so never claim "low".
        risk: V2CatalogRisk.medium,
      ),
    // Custom MCP servers are the user's own: no curated id, and their URL is
    // the only description the server stores.
    for (final server in servers)
      if (server.curatedId == null)
        V2Connector(
          id: server.id,
          name: server.name,
          description: server.url ?? 'Custom MCP server',
          connected: true,
          category: 'Custom',
          kind: V2ConnectorKind.mcp,
          enabled: server.enabled,
          endpoint: server.url ?? '',
          auth: V2CatalogAuth.apiKey,
          risk: V2CatalogRisk.high,
        ),
  ];

  return V2ConnectorsData(
    connectors: rows,
    // Never fall back to the built-in list: a row the gateway cannot serve
    // would look installable and do nothing.
    useBuiltInCatalog: false,
    status: V2ConnectorsStatus.content,
  );
}

V2Connector _remoteRow(
  ConnectorCatalogEntry entry,
  ConnectorConnection? connection,
) {
  final canActivate = connectorCanActivateAgent(
    definition: entry,
    connection: connection,
  );
  return V2Connector(
    id: connection?.connectionId ?? entry.providerId,
    providerId: entry.providerId,
    connectionId: connection?.connectionId,
    name: connection?.name ?? entry.displayName,
    description: entry.description,
    connected: connection != null && !connection.isDisconnected,
    configured: entry.configured,
    disconnectedHistory: connection?.isDisconnected ?? false,
    category: 'Apps',
    kind: V2ConnectorKind.app,
    icon: connectorIconFor(entry.providerId),
    enabled: connection?.enabled ?? false,
    agentEnabled: connection?.agentEnabled ?? false,
    builtIn: true,
    tools: entry.toolNames,
    auth: entry.credentialFields.isEmpty
        ? V2CatalogAuth.none
        : V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
    authState: connection?.authState,
    healthState: connection?.healthState,
    lastCheckedAt: connection?.lastCheckedAt,
    lastSuccessAt: connection?.lastSuccessAt,
    credentialFields: entry.credentialFields,
    configurationFields: entry.configurationFields,
    operations: entry.operations,
    supportsAgentActivation: canActivate,
  );
}

/// Maps the one remote cache without ever consulting legacy local connector
/// state. Catalog configuration flags do not install or connect anything.
List<V2Connector> remoteConnectorRows(ConnectorViewState state) {
  final rows = <V2Connector>[];
  final matched = <String>{};
  for (final entry in state.catalog) {
    if (!entry.isSupported) continue;
    final connections = state.connections
        .where((connection) => connection.providerId == entry.providerId)
        .toList(growable: false);
    if (connections.isEmpty) {
      rows.add(_remoteRow(entry, null));
      continue;
    }
    for (final connection in connections) {
      matched.add(connection.connectionId);
      rows.add(_remoteRow(entry, connection));
    }
  }
  for (final connection in state.connections) {
    if (matched.contains(connection.connectionId)) continue;
    rows.add(
      V2Connector(
        id: connection.connectionId,
        providerId: connection.providerId,
        connectionId: connection.connectionId,
        name: connection.name,
        description: connection.approvedSourceId == null
            ? 'Configured connector'
            : 'Approved source ${connection.approvedSourceId}',
        connected: !connection.isDisconnected,
        disconnectedHistory: connection.isDisconnected,
        category: 'Custom',
        kind: V2ConnectorKind.mcp,
        icon: connectorIconFor(connection.providerId),
        enabled: connection.enabled,
        agentEnabled: connection.agentEnabled,
        auth: V2CatalogAuth.apiKey,
        risk: V2CatalogRisk.high,
        authState: connection.authState,
        healthState: connection.healthState,
        lastCheckedAt: connection.lastCheckedAt,
        lastSuccessAt: connection.lastSuccessAt,
        approvedSourceId: connection.approvedSourceId,
        approvedDigest: connection.approvedDigest,
      ),
    );
  }
  return rows;
}

V2ConnectorsData connectorCatalogForState(ConnectorViewState state) {
  return V2ConnectorsData(
    connectors: remoteConnectorRows(state),
    useBuiltInCatalog: false,
    status: switch (state.status) {
      ConnectorViewStatus.loading => V2ConnectorsStatus.loading,
      ConnectorViewStatus.error => V2ConnectorsStatus.error,
      ConnectorViewStatus.empty ||
      ConnectorViewStatus.content => V2ConnectorsStatus.content,
    },
    errorMessage: state.errorMessage.isEmpty
        ? RemoteConnectorController.loadError
        : state.errorMessage,
  );
}

/// The screen's error state, with copy the user can act on.
V2ConnectorsData connectorCatalogError() => const V2ConnectorsData(
  connectors: <V2Connector>[],
  useBuiltInCatalog: false,
  status: V2ConnectorsStatus.error,
  errorMessage: 'Connectors did not load. Check your connection and retry.',
);

/// Icon for a curated id, so the list does not regress to a generic glyph.
IconData connectorIconFor(String id) => switch (id) {
  'github' || 'github-mcp' || 'gitlab' || 'bitbucket' => Icons.code_rounded,
  'gmail' || 'outlook' || 'fastmail' => Icons.mail_outline_rounded,
  'google-drive' || 'dropbox' || 'onedrive' || 'box' => Icons.cloud_outlined,
  'slack' || 'discord' || 'telegram' => Icons.forum_outlined,
  'notion' || 'confluence' || 'google-docs' => Icons.description_outlined,
  'jira' || 'linear' || 'asana' || 'trello' => Icons.checklist_rounded,
  'figma' || 'canva' => Icons.brush_outlined,
  'sentry' => Icons.bug_report_outlined,
  'postgres' ||
  'mysql' ||
  'mongodb' ||
  'redis' ||
  'supabase' => Icons.storage_rounded,
  'fetch' || 'exa' || 'brave-search' => Icons.travel_explore_rounded,
  _ => Icons.extension_outlined,
};
