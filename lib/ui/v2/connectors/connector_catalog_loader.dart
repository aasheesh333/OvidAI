import 'package:flutter/material.dart';

import '../../../core/connectors/connector_api.dart';
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
      'postgres' || 'mysql' || 'mongodb' || 'redis' || 'supabase' =>
        Icons.storage_rounded,
      'fetch' || 'exa' || 'brave-search' => Icons.travel_explore_rounded,
      _ => Icons.extension_outlined,
    };
