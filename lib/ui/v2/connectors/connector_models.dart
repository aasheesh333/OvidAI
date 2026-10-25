import 'package:flutter/material.dart';

import '../../../core/connectors/connector_api.dart';
import 'catalog_data.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// A hosted connector, a plugin, and an MCP server share one row model,
/// because the person sees one catalog. Plugins and MCP servers share the
/// "Plugins & MCP" section but stay separate kinds so the filter can tell
/// them apart.
enum V2ConnectorKind { app, plugin, mcp }

/// Credential a custom connector uses. The secret itself never lives in this
/// model or in SharedPreferences: [connector_store.dart] keeps it in the
/// platform keystore.
enum V2ConnectorAuth {
  oauth,
  apiKey,
  none;

  String get label => switch (this) {
    V2ConnectorAuth.oauth => 'OAuth',
    V2ConnectorAuth.apiKey => 'API key',
    V2ConnectorAuth.none => 'No credential',
  };

  /// Whether setup must collect a secret before the connector can run.
  bool get needsSecret => this != V2ConnectorAuth.none;
}

/// The kind of access a custom connector grants. The order is the order the
/// add form and the permissions screen render.
enum V2ConnectorPermissionKind {
  read,
  write,
  execute;

  String get title => switch (this) {
    V2ConnectorPermissionKind.read => 'Read data',
    V2ConnectorPermissionKind.write => 'Write & update',
    V2ConnectorPermissionKind.execute => 'Execute actions',
  };

  /// What turning the switch on actually lets Ovid do on a server it can
  /// reach. Kept deliberately concrete so the copy cannot promise more than
  /// the connector protocol provides.
  String get description => switch (this) {
    V2ConnectorPermissionKind.read =>
      'Call the read-only tools this server lists: search, list and fetch.',
    V2ConnectorPermissionKind.write =>
      'Call the tools that create, change or delete data on this server.',
    V2ConnectorPermissionKind.execute =>
      'Call tools that trigger actions or start jobs on this server.',
  };

  /// Short label for a detail row or pill.
  String get shortLabel => switch (this) {
    V2ConnectorPermissionKind.read => 'Read',
    V2ConnectorPermissionKind.write => 'Write',
    V2ConnectorPermissionKind.execute => 'Execute',
  };
}

/// How Ovid reaches a custom connector: an HTTPS server URL or a command that
/// runs inside the workspace.
enum V2ConnectorTarget { url, command }

/// The connector allowance that comes with each plan.
///
/// The numbers come from the product spec: Free has no connector slots, Go
/// includes 5, and Plus/Pro include 20. [forTier] maps the billing tier slugs
/// the app stores (`free`, `3x`, `7x`, `15x`) onto these names.
enum V2ConnectorPlan {
  free('Free', 0),
  go('Go', 5),
  plus('Plus', 20),
  pro('Pro', 20);

  const V2ConnectorPlan(this.label, this.connectorLimit);

  final String label;
  final int connectorLimit;

  /// Backwards-compatible alias for [connectorLimit].
  int get customConnectorLimit => connectorLimit;

  /// Maps a billing tier (`free`, `3x`, `7x`, `15x`) or a plan name onto the
  /// connector allowance. Unknown or missing tiers get Free, never a paid
  /// allowance the account did not prove.
  static V2ConnectorPlan forTier(String? tier) {
    return switch (tier?.trim().toLowerCase()) {
      '3x' || 'starter' || 'go' => V2ConnectorPlan.go,
      '7x' || 'plus' => V2ConnectorPlan.plus,
      '15x' || 'max' || 'pro' => V2ConnectorPlan.pro,
      _ => V2ConnectorPlan.free,
    };
  }
}

String remoteConnectorStatusLabel({
  required bool enabled,
  required String? authState,
  required String? healthState,
  String? providerId,
}) {
  if (!enabled || healthState == 'disabled') return 'Disabled';
  switch (healthState) {
    case 'healthy':
      return 'Healthy';
    case 'checking':
      return 'Checking';
    case 'degraded':
      return 'Degraded';
    case 'needs_auth':
      return providerId == 'fetch'
          ? 'Resource requires authentication'
          : 'Needs authentication';
    case 'refreshing':
      return 'Refreshing access';
    case 'revoked':
      return 'Access revoked';
    case 'unavailable':
      return 'Unavailable';
    case 'never_checked':
      return switch (authState) {
        'authorized' => 'Authorized',
        'needs_auth' => providerId == 'fetch'
            ? 'Resource requires authentication'
            : 'Needs authentication',
        'revoked' => 'Access revoked',
        'missing' => 'Credentials missing',
        _ => 'Configured',
      };
    default:
      return 'Unavailable';
  }
}

/// One connector in the catalog. Matches the shared connector contract
/// (`id, name, description, connected, category`) plus display hints.
@immutable
class V2Connector {
  const V2Connector({
    required this.id,
    required this.name,
    required this.description,
    required this.connected,
    required this.category,
    this.kind = V2ConnectorKind.app,
    this.icon = Icons.extension_outlined,
    this.enabled = true,
    this.popular = false,
    this.builtIn = false,
    this.tools = const <String>[],
    this.auth = V2CatalogAuth.none,
    this.risk = V2CatalogRisk.low,
    this.endpoint = '',
    this.providerId,
    this.connectionId,
    this.configured = false,
    this.disconnectedHistory = false,
    this.agentEnabled = false,
    this.authState,
    this.healthState,
    this.lastCheckedAt,
    this.lastSuccessAt,
    this.credentialFields = const <ConnectorCredentialField>[],
    this.configurationFields = const <ConnectorConfigurationField>[],
    this.operations = const <ConnectorOperation>[],
    this.approvedSourceId,
    this.approvedDigest,
    this.supportsAgentActivation = false,
  });

  final String id;
  final String name;
  final String description;
  final bool connected;
  final String category;
  final V2ConnectorKind kind;
  final IconData icon;
  final bool enabled;
  final bool popular;
  final bool builtIn;
  final List<String> tools;

  /// Primary credential the setup flow collects, when the row came from the
  /// shared catalog. Detail screens use it to explain what a grant needs.
  final V2CatalogAuth auth;

  /// Blast radius of the integration. The detail page carries this into the
  /// permissions screen so risk badges stay honest.
  final V2CatalogRisk risk;

  /// Server URL or command a saved connection points at. Empty for a catalog
  /// row that has not been set up yet, so nothing pretends to be testable.
  final String endpoint;

  /// Remote identity and lifecycle metadata. A catalog [providerId] is never a
  /// substitute for the per-user server [connectionId].
  final String? providerId;
  final String? connectionId;
  final bool configured;
  final bool disconnectedHistory;
  final bool agentEnabled;
  final String? authState;
  final String? healthState;
  final DateTime? lastCheckedAt;
  final DateTime? lastSuccessAt;
  final List<ConnectorCredentialField> credentialFields;
  final List<ConnectorConfigurationField> configurationFields;
  final List<ConnectorOperation> operations;
  final String? approvedSourceId;
  final String? approvedDigest;
  final bool supportsAgentActivation;

  bool get isRemote => providerId != null;

  /// Server health/authentication words only. In particular, `configured` is
  /// not translated into a connectivity claim.
  String get statusLabel {
    if (!isRemote) return enabled ? 'Connected' : 'Paused';
    if (disconnectedHistory) return 'Disconnected';
    if (!connected) return 'Available';
    return remoteConnectorStatusLabel(
      enabled: enabled,
      authState: authState,
      healthState: healthState,
      providerId: providerId,
    );
  }

  bool get isMcp => kind == V2ConnectorKind.mcp;

  String get sectionTitle =>
      kind == V2ConnectorKind.app ? 'Connectors' : 'Plugins & add-ons';

  V2Connector copyWith({
    bool? connected,
    bool? enabled,
    bool? agentEnabled,
    String? endpoint,
    String? description,
    String? category,
    IconData? icon,
  }) {
    return V2Connector(
      id: id,
      name: name,
      description: description ?? this.description,
      connected: connected ?? this.connected,
      category: category ?? this.category,
      kind: kind,
      icon: icon ?? this.icon,
      enabled: enabled ?? this.enabled,
      popular: popular,
      builtIn: builtIn,
      tools: tools,
      auth: auth,
      risk: risk,
      endpoint: endpoint ?? this.endpoint,
      providerId: providerId,
      connectionId: connectionId,
      configured: configured,
      disconnectedHistory: disconnectedHistory,
      agentEnabled: agentEnabled ?? this.agentEnabled,
      authState: authState,
      healthState: healthState,
      lastCheckedAt: lastCheckedAt,
      lastSuccessAt: lastSuccessAt,
      credentialFields: credentialFields,
      configurationFields: configurationFields,
      operations: operations,
      approvedSourceId: approvedSourceId,
      approvedDigest: approvedDigest,
      supportsAgentActivation: supportsAgentActivation,
    );
  }
}

/// Maps a catalog category to the icon a row shows. Categories are shared
/// across connectors, plugins, and MCP servers, so one map keeps the visual
/// language consistent while [V2CatalogEntry] stays free of Flutter imports.
IconData v2ConnectorIconFor(V2CatalogEntry entry) {
  return switch (entry.category.toLowerCase()) {
    'code' || 'developer' => Icons.code_rounded,
    'quality' => Icons.rule_rounded,
    'mail' => Icons.mail_outline_rounded,
    'calendar' => Icons.calendar_month_outlined,
    'files' || 'documents' => Icons.folder_outlined,
    'chat' => Icons.forum_outlined,
    'notes' => Icons.edit_note_rounded,
    'project' => Icons.view_kanban_outlined,
    'design' => Icons.draw_outlined,
    'payments' || 'finance' => Icons.credit_card_rounded,
    'commerce' => Icons.storefront_outlined,
    'crm' || 'sales' => Icons.support_agent_rounded,
    'marketing' => Icons.campaign_outlined,
    'analytics' => Icons.insights_rounded,
    'data' || 'database' => Icons.storage_rounded,
    'search' || 'research' => Icons.search_rounded,
    'media' => Icons.image_outlined,
    'automation' => Icons.bolt_rounded,
    'observability' => Icons.monitor_heart_outlined,
    'infrastructure' || 'cloud' => Icons.cloud_outlined,
    'productivity' => Icons.task_alt_rounded,
    'content' => Icons.article_outlined,
    'security' => Icons.security_rounded,
    'browser' || 'web' => Icons.public_rounded,
    'local' => Icons.computer_rounded,
    'ai' => Icons.psychology_outlined,
    'utilities' => Icons.schedule_rounded,
    _ => switch (entry.kind) {
      V2CatalogKind.connector => Icons.extension_outlined,
      V2CatalogKind.plugin => Icons.widgets_outlined,
      V2CatalogKind.mcp => Icons.dns_outlined,
    },
  };
}

/// Maps a catalog entry to the row model this screen renders.
///
/// Connection state is owned by the wiring layer; the built-in list is
/// therefore all-disconnected and display truth only.
V2Connector v2ConnectorFromCatalogEntry(
  V2CatalogEntry entry, {
  bool connected = false,
  bool enabled = true,
}) {
  return V2Connector(
    id: entry.id,
    name: entry.name,
    description: entry.description,
    connected: connected,
    category: entry.category,
    kind: switch (entry.kind) {
      V2CatalogKind.connector => V2ConnectorKind.app,
      V2CatalogKind.plugin => V2ConnectorKind.plugin,
      V2CatalogKind.mcp => V2ConnectorKind.mcp,
    },
    icon: v2ConnectorIconFor(entry),
    enabled: enabled,
    builtIn: entry.builtIn,
    auth: entry.auth,
    risk: entry.risk,
  );
}

/// The full 168-entry catalog as row models.
///
/// This replaces the old hand-maintained `v2BuiltInApps` / `v2BuiltInPlugins`
/// lists: the catalog data file is the single source of truth, and every
/// connector, plugin, and MCP server comes through the same mapping.
final List<V2Connector> v2BuiltInCatalog = List<V2Connector>.unmodifiable(
  v2Catalog.map(v2ConnectorFromCatalogEntry),
);
