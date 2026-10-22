import 'package:flutter/foundation.dart';

// TODO(l10n): move catalog names, descriptions, and risk copy to the ARB
// files in the next wave.

/// How an integration is delivered to Ovid.
///
/// Connectors are hosted apps, plugins are local agent capabilities, and MCP
/// servers speak the Model Context Protocol. Plugins and MCP share one visual
/// section in the catalog, but the distinction still matters for setup.
enum V2CatalogKind {
  connector('Connector', 'Connectors'),
  plugin('Plugin', 'Plugins & add-ons'),
  mcp('Add-on', 'Plugins & add-ons');

  const V2CatalogKind(this.label, this.sectionTitle);

  /// Short label for a detail row or a filter chip.
  final String label;

  /// Section heading the catalog groups this kind under.
  final String sectionTitle;
}

/// The credential an integration needs before it can be enabled.
///
/// The catalog records the *primary* auth type; GitHub, for example, supports
/// both OAuth and personal access tokens, and the setup flow picks one. Never
/// carry a token in this model: it only says what the person will be asked for.
enum V2CatalogAuth {
  none('No auth'),
  oauth('OAuth'),
  apiKey('API key'),
  personalAccessToken('Personal access token'),
  botToken('Bot token'),
  basic('Username and password'),
  serviceAccount('Service account'),
  connectionString('Connection string'),
  kubeconfig('Kubeconfig');

  const V2CatalogAuth(this.label);

  /// User-facing label for the auth row in the connector detail page.
  final String label;

  /// Whether setup must collect a secret before the integration can run.
  bool get needsSecret => this != V2CatalogAuth.none;
}

/// Blast radius if the agent is tricked into misusing an integration.
///
/// Low is read-only public data, medium is read/write content the person can
/// recover, and high is money movement, code execution, or private
/// infrastructure. The catalog shows this before the person grants access.
enum V2CatalogRisk {
  low('Low'),
  medium('Medium'),
  high('High');

  const V2CatalogRisk(this.label);

  /// User-facing label for the risk badge.
  final String label;

  /// One sentence explaining the badge without jargon.
  String get summary => switch (this) {
    V2CatalogRisk.low => 'Read-only access to public or low-sensitivity data.',
    V2CatalogRisk.medium => 'Can read and change content in this service.',
    V2CatalogRisk.high =>
      'Can move money, run code, or reach private infrastructure.',
  };
}

/// One immutable row in the integration catalog.
///
/// Equality is by [id] so a live adapter can diff catalog entries against
/// saved connection state without comparing display copy.
@immutable
class V2CatalogEntry {
  const V2CatalogEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.kind,
    required this.auth,
    required this.risk,
    this.builtIn = true,
  });

  /// Stable slug shared with the connector contract and persisted state.
  final String id;

  /// Display name, unique across the catalog.
  final String name;

  /// One-line description of what the agent can do with it.
  final String description;

  /// Catalog group such as `Code`, `Files`, or `Database`.
  final String category;

  /// Delivery mechanism: connector, plugin, or MCP server.
  final V2CatalogKind kind;

  /// Credential the setup flow must collect.
  final V2CatalogAuth auth;

  /// Blast radius of granting access.
  final V2CatalogRisk risk;

  /// Whether Ovid ships this entry in the default catalog. Community MCP
  /// servers are still listed, but are marked so the UI can explain that the
  /// person is adding third-party software.
  final bool builtIn;

  bool get isConnector => kind == V2CatalogKind.connector;

  bool get isPlugin => kind == V2CatalogKind.plugin;

  bool get isMcp => kind == V2CatalogKind.mcp;

  /// Whether setup must collect a credential before enabling.
  bool get requiresCredentials => auth.needsSecret;

  String get sectionTitle => kind.sectionTitle;

  /// Lower-cased haystack for [searchV2Catalog].
  String get searchText =>
      '$id $name $description $category ${kind.label}'.toLowerCase();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is V2CatalogEntry && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'V2CatalogEntry($id, ${kind.name})';
}

/// Aggregate counts for the catalog header and filter chips.
@immutable
class V2CatalogStats {
  const V2CatalogStats({
    required this.total,
    required this.connectors,
    required this.plugins,
    required this.mcp,
    required this.builtIn,
    required this.custom,
    required this.highRisk,
  });

  factory V2CatalogStats.from(Iterable<V2CatalogEntry> entries) {
    var total = 0;
    var connectors = 0;
    var plugins = 0;
    var mcp = 0;
    var builtIn = 0;
    var highRisk = 0;

    for (final entry in entries) {
      total += 1;
      switch (entry.kind) {
        case V2CatalogKind.connector:
          connectors += 1;
        case V2CatalogKind.plugin:
          plugins += 1;
        case V2CatalogKind.mcp:
          mcp += 1;
      }
      if (entry.builtIn) builtIn += 1;
      if (entry.risk == V2CatalogRisk.high) highRisk += 1;
    }

    return V2CatalogStats(
      total: total,
      connectors: connectors,
      plugins: plugins,
      mcp: mcp,
      builtIn: builtIn,
      custom: total - builtIn,
      highRisk: highRisk,
    );
  }

  final int total;
  final int connectors;
  final int plugins;
  final int mcp;
  final int builtIn;
  final int custom;
  final int highRisk;

  int get pluginsAndMcp => plugins + mcp;
}

/// Every integration Ovid can offer.
///
/// Order is stable and grouped by [V2CatalogKind] — connectors, then plugins,
/// then MCP servers — so screens can walk it directly. The live adapter in
/// `lib/ui/v2/app/` owns connection state; this list is display truth only.
const v2Catalog = <V2CatalogEntry>[
  // ── Connectors: code and delivery ─────────────────────────────────────
  V2CatalogEntry(
    id: 'github',
    name: 'GitHub',
    description: 'Repositories, issues, pull requests, and Actions runs.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'gitlab',
    name: 'GitLab',
    description: 'Merge requests, pipelines, and repository review.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'bitbucket',
    name: 'Bitbucket',
    description: 'Branches, pull requests, and deployment status.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'azure-devops',
    name: 'Azure DevOps',
    description: 'Repos, boards, pipelines, and test plans.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.personalAccessToken,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'gitea',
    name: 'Gitea',
    description: 'Self-hosted repositories, issues, and releases.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.personalAccessToken,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'buildkite',
    name: 'Buildkite',
    description: 'CI pipelines, builds, and deploy steps.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'circleci',
    name: 'CircleCI',
    description: 'Pipeline runs, artifacts, and build logs.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'jenkins',
    name: 'Jenkins',
    description: 'Job builds, console logs, and deploy gates.',
    category: 'Code',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.basic,
    risk: V2CatalogRisk.high,
  ),

  // ── Connectors: mail ──────────────────────────────────────────────────
  V2CatalogEntry(
    id: 'gmail',
    name: 'Gmail',
    description: 'Search threads, summarize mail, and draft replies.',
    category: 'Mail',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'outlook',
    name: 'Outlook',
    description: 'Mail, contacts, and Microsoft 365 calendar.',
    category: 'Mail',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'fastmail',
    name: 'Fastmail',
    description: 'Read mail, manage labels, and draft messages.',
    category: 'Mail',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: calendar ──────────────────────────────────────────────
  V2CatalogEntry(
    id: 'google-calendar',
    name: 'Google Calendar',
    description: 'Read events, find free time, and schedule meetings.',
    category: 'Calendar',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'calendly',
    name: 'Calendly',
    description: 'Booking links, availability, and scheduled events.',
    category: 'Calendar',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'cal-com',
    name: 'Cal.com',
    description: 'Availability, event types, and confirmed bookings.',
    category: 'Calendar',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),

  // ── Connectors: files and storage ─────────────────────────────────────
  V2CatalogEntry(
    id: 'google-drive',
    name: 'Google Drive',
    description: 'Search files, import docs, and manage folders.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'dropbox',
    name: 'Dropbox',
    description: 'Read shared files and organize team folders.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'onedrive',
    name: 'OneDrive',
    description: 'Find Microsoft 365 files and share links.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'box',
    name: 'Box',
    description: 'Search team folders, documents, and approvals.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'sharepoint',
    name: 'SharePoint',
    description: 'Team sites, pages, lists, and document libraries.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'amazon-s3',
    name: 'Amazon S3',
    description: 'Buckets, objects, and presigned upload URLs.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'google-cloud-storage',
    name: 'Google Cloud Storage',
    description: 'Buckets, objects, and lifecycle policies.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.serviceAccount,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'azure-blob-storage',
    name: 'Azure Blob Storage',
    description: 'Containers, blobs, and access policies.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'backblaze-b2',
    name: 'Backblaze B2',
    description: 'Bucket backups and large file archives.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'egnyte',
    name: 'Egnyte',
    description: 'Governed file shares and team folders.',
    category: 'Files',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: chat and support ──────────────────────────────────────
  V2CatalogEntry(
    id: 'slack',
    name: 'Slack',
    description: 'Channels, threads, and workspace notifications.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'discord',
    name: 'Discord',
    description: 'Servers, channels, and bot notifications.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.botToken,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'microsoft-teams',
    name: 'Microsoft Teams',
    description: 'Channels, chats, and meeting recordings.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'telegram',
    name: 'Telegram',
    description: 'Bot messages, groups, and channel updates.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.botToken,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'whatsapp-business',
    name: 'WhatsApp Business',
    description: 'Template messages and customer conversations.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'zoom',
    name: 'Zoom',
    description: 'Meetings, recordings, and transcript exports.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'intercom',
    name: 'Intercom',
    description: 'Customer conversations, contacts, and help articles.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'zendesk',
    name: 'Zendesk',
    description: 'Support tickets, macros, and customer history.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'freshdesk',
    name: 'Freshdesk',
    description: 'Tickets, knowledge base, and SLA reports.',
    category: 'Chat',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: notes and docs ────────────────────────────────────────
  V2CatalogEntry(
    id: 'notion',
    name: 'Notion',
    description: 'Pages, databases, and project wikis.',
    category: 'Notes',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'confluence',
    name: 'Confluence',
    description: 'Spaces, pages, and team documentation.',
    category: 'Notes',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'google-docs',
    name: 'Google Docs',
    description: 'Read docs, suggest edits, and export PDFs.',
    category: 'Notes',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'coda',
    name: 'Coda',
    description: 'Docs, tables, and lightweight workflows.',
    category: 'Notes',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'evernote',
    name: 'Evernote',
    description: 'Notes, notebooks, and clipped research.',
    category: 'Notes',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'slab',
    name: 'Slab',
    description: 'Knowledge base topics and team posts.',
    category: 'Notes',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: project and work ──────────────────────────────────────
  V2CatalogEntry(
    id: 'linear',
    name: 'Linear',
    description: 'Issues, projects, cycles, and triage.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'jira',
    name: 'Jira',
    description: 'Issues, sprints, boards, and JQL search.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'asana',
    name: 'Asana',
    description: 'Tasks, projects, and team timelines.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'trello',
    name: 'Trello',
    description: 'Boards, cards, checklists, and comments.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'clickup',
    name: 'ClickUp',
    description: 'Tasks, docs, goals, and time tracking.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'monday',
    name: 'Monday.com',
    description: 'Boards, items, and workflow automations.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'basecamp',
    name: 'Basecamp',
    description: 'Projects, message boards, and to-dos.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'height',
    name: 'Height',
    description: 'Tasks, lists, and product feedback.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'shortcut',
    name: 'Shortcut',
    description: 'Stories, epics, and sprint iterations.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'airtable',
    name: 'Airtable',
    description: 'Bases, tables, records, and views.',
    category: 'Project',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.personalAccessToken,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: design ────────────────────────────────────────────────
  V2CatalogEntry(
    id: 'figma',
    name: 'Figma',
    description: 'Files, frames, comments, and design tokens.',
    category: 'Design',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'canva',
    name: 'Canva',
    description: 'Designs, brand kits, and export jobs.',
    category: 'Design',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'miro',
    name: 'Miro',
    description: 'Boards, sticky notes, and workshop templates.',
    category: 'Design',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'framer',
    name: 'Framer',
    description: 'Sites, components, and publish previews.',
    category: 'Design',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'webflow',
    name: 'Webflow',
    description: 'Sites, CMS collections, and publishes.',
    category: 'Design',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),

  // ── Connectors: payments and finance ──────────────────────────────────
  V2CatalogEntry(
    id: 'stripe',
    name: 'Stripe',
    description: 'Payments, customers, invoices, and refunds.',
    category: 'Payments',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'paypal',
    name: 'PayPal',
    description: 'Orders, payouts, and transaction history.',
    category: 'Payments',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'square',
    name: 'Square',
    description: 'Payments, catalogs, and merchant reports.',
    category: 'Payments',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'razorpay',
    name: 'Razorpay',
    description: 'Orders, payments, refunds, and settlements.',
    category: 'Payments',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'quickbooks',
    name: 'QuickBooks',
    description: 'Invoices, expenses, and ledger reports.',
    category: 'Payments',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'xero',
    name: 'Xero',
    description: 'Invoices, bank feeds, and reconciliation.',
    category: 'Payments',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'plaid',
    name: 'Plaid',
    description: 'Bank links, balances, and transactions.',
    category: 'Payments',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),

  // ── Connectors: commerce and CRM ──────────────────────────────────────
  V2CatalogEntry(
    id: 'shopify',
    name: 'Shopify',
    description: 'Products, orders, inventory, and discounts.',
    category: 'Commerce',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'woocommerce',
    name: 'WooCommerce',
    description: 'Products, orders, coupons, and stock.',
    category: 'Commerce',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'hubspot',
    name: 'HubSpot',
    description: 'Contacts, deals, pipelines, and marketing email.',
    category: 'CRM',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'salesforce',
    name: 'Salesforce',
    description: 'Leads, opportunities, cases, and reports.',
    category: 'CRM',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'pipedrive',
    name: 'Pipedrive',
    description: 'Deals, activities, and sales pipelines.',
    category: 'CRM',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'zoho-crm',
    name: 'Zoho CRM',
    description: 'Contacts, deals, and sales workflows.',
    category: 'CRM',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'mailchimp',
    name: 'Mailchimp',
    description: 'Audiences, campaigns, and automation journeys.',
    category: 'Marketing',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'sendgrid',
    name: 'SendGrid',
    description: 'Transactional email and delivery stats.',
    category: 'Marketing',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'klaviyo',
    name: 'Klaviyo',
    description: 'Profiles, segments, and email campaigns.',
    category: 'Marketing',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: analytics and data ────────────────────────────────────
  V2CatalogEntry(
    id: 'google-analytics',
    name: 'Google Analytics',
    description: 'Traffic, conversions, and audience reports.',
    category: 'Analytics',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'mixpanel',
    name: 'Mixpanel',
    description: 'Product events, funnels, and cohorts.',
    category: 'Analytics',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'amplitude',
    name: 'Amplitude',
    description: 'Event analytics, retention, and experiments.',
    category: 'Analytics',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'posthog',
    name: 'PostHog',
    description: 'Product analytics, flags, and session replay.',
    category: 'Analytics',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'segment',
    name: 'Segment',
    description: 'Event pipelines, sources, and destinations.',
    category: 'Analytics',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'bigquery',
    name: 'BigQuery',
    description: 'Warehouse datasets, queries, and exports.',
    category: 'Data',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.serviceAccount,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'snowflake',
    name: 'Snowflake',
    description: 'Warehouses, schemas, and SQL worksheets.',
    category: 'Data',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.basic,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'databricks',
    name: 'Databricks',
    description: 'Notebooks, jobs, and Unity Catalog tables.',
    category: 'Data',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.personalAccessToken,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'redash',
    name: 'Redash',
    description: 'Saved queries, dashboards, and alerts.',
    category: 'Data',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'metabase',
    name: 'Metabase',
    description: 'Questions, dashboards, and embedded charts.',
    category: 'Data',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: search and web ────────────────────────────────────────
  V2CatalogEntry(
    id: 'brave-search',
    name: 'Brave Search',
    description: 'Web and news results without tracking.',
    category: 'Search',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'exa',
    name: 'Exa',
    description: 'Semantic web search and page contents.',
    category: 'Search',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'tavily',
    name: 'Tavily',
    description: 'Research search with extracted answers.',
    category: 'Search',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'serpapi',
    name: 'SerpAPI',
    description: 'Google results, maps, and shopping data.',
    category: 'Search',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'algolia',
    name: 'Algolia',
    description: 'Search indexes, synonyms, and analytics.',
    category: 'Search',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'google-search-console',
    name: 'Google Search Console',
    description: 'Queries, coverage, and sitemap health.',
    category: 'Search',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.low,
  ),

  // ── Connectors: media ─────────────────────────────────────────────────
  V2CatalogEntry(
    id: 'youtube',
    name: 'YouTube',
    description: 'Videos, playlists, comments, and captions.',
    category: 'Media',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'vimeo',
    name: 'Vimeo',
    description: 'Uploads, privacy, and video analytics.',
    category: 'Media',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'spotify',
    name: 'Spotify',
    description: 'Playlists, saved tracks, and listening data.',
    category: 'Media',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'imgur',
    name: 'Imgur',
    description: 'Image uploads and album organization.',
    category: 'Media',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'cloudinary',
    name: 'Cloudinary',
    description: 'Image transforms, uploads, and delivery.',
    category: 'Media',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'mux',
    name: 'Mux',
    description: 'Video uploads, playback IDs, and metrics.',
    category: 'Media',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),

  // ── Connectors: automation, observability, infrastructure ─────────────
  V2CatalogEntry(
    id: 'zapier',
    name: 'Zapier',
    description: 'Trigger and manage connected Zaps.',
    category: 'Automation',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'make',
    name: 'Make',
    description: 'Scenarios, runs, and automation blueprints.',
    category: 'Automation',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'n8n',
    name: 'n8n',
    description: 'Workflows, executions, and credentials.',
    category: 'Automation',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'pagerduty',
    name: 'PagerDuty',
    description: 'Incidents, on-call schedules, and escalations.',
    category: 'Observability',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'datadog',
    name: 'Datadog',
    description: 'Metrics, monitors, logs, and incidents.',
    category: 'Observability',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'sentry',
    name: 'Sentry',
    description: 'Issues, releases, and error stack traces.',
    category: 'Observability',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'grafana',
    name: 'Grafana',
    description: 'Dashboards, alerts, and data sources.',
    category: 'Observability',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'terraform-cloud',
    name: 'Terraform Cloud',
    description: 'Workspaces, runs, and state versions.',
    category: 'Infrastructure',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),

  // ── Connectors: productivity ──────────────────────────────────────────
  V2CatalogEntry(
    id: 'google-sheets',
    name: 'Google Sheets',
    description: 'Spreadsheets, formulas, and chart data.',
    category: 'Productivity',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'google-slides',
    name: 'Google Slides',
    description: 'Decks, layouts, and speaker notes.',
    category: 'Productivity',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'google-forms',
    name: 'Google Forms',
    description: 'Forms, responses, and answer summaries.',
    category: 'Productivity',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'typeform',
    name: 'Typeform',
    description: 'Forms, responses, and hidden fields.',
    category: 'Productivity',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'docusign',
    name: 'DocuSign',
    description: 'Envelopes, signatures, and audit trails.',
    category: 'Productivity',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.oauth,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'twilio',
    name: 'Twilio',
    description: 'SMS, voice calls, and delivery status.',
    category: 'Productivity',
    kind: V2CatalogKind.connector,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
  ),

  // ── Plugins: agent capabilities that ship with Ovid ───────────────────
  V2CatalogEntry(
    id: 'superpowers',
    name: 'Superpowers',
    description: 'Structured planning, review, and debugging skills.',
    category: 'Developer',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'code-review',
    name: 'Code Review',
    description: 'Review diffs for bugs, style, and missing tests.',
    category: 'Quality',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'test-runner',
    name: 'Test Runner',
    description: 'Run focused test suites and summarize failures.',
    category: 'Quality',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'lint-fixer',
    name: 'Lint Fixer',
    description: 'Apply safe lints and formatting fixes.',
    category: 'Quality',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'git-commit',
    name: 'Git Commit',
    description: 'Stage changes and write clear commit messages.',
    category: 'Developer',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'changelog',
    name: 'Changelog',
    description: 'Draft changelogs from commits and merged PRs.',
    category: 'Developer',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'release-notes',
    name: 'Release Notes',
    description: 'Turn shipped work into customer-facing notes.',
    category: 'Developer',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'docs-writer',
    name: 'Docs Writer',
    description: 'Write and update READMEs and developer guides.',
    category: 'Content',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'pdf-tools',
    name: 'PDF Tools',
    description: 'Extract text, merge files, and fill PDF forms.',
    category: 'Content',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'spreadsheet-tools',
    name: 'Spreadsheet Tools',
    description: 'Clean, join, and analyze CSV and Excel data.',
    category: 'Data',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'image-tools',
    name: 'Image Tools',
    description: 'Resize, crop, and convert images in the workspace.',
    category: 'Media',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'ocr',
    name: 'OCR',
    description: 'Read text from screenshots, scans, and photos.',
    category: 'Media',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'transcription',
    name: 'Transcription',
    description: 'Turn meeting audio into searchable notes.',
    category: 'Media',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'translation',
    name: 'Translation',
    description: 'Translate documents while keeping formatting.',
    category: 'Content',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'deep-research',
    name: 'Deep Research',
    description: 'Plan multi-source research and cite findings.',
    category: 'Research',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'data-analysis',
    name: 'Data Analysis',
    description: 'Profile datasets and explain trends in plain words.',
    category: 'Data',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'chart-maker',
    name: 'Chart Maker',
    description: 'Build charts from tables and query results.',
    category: 'Data',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'slide-builder',
    name: 'Slide Builder',
    description: 'Draft decks with speaker notes and layouts.',
    category: 'Content',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'diagram-maker',
    name: 'Diagram Maker',
    description: 'Draw architecture and flow diagrams as code.',
    category: 'Design',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'accessibility-audit',
    name: 'Accessibility Audit',
    description: 'Check contrast, labels, targets, and focus order.',
    category: 'Quality',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'security-scan',
    name: 'Security Scan',
    description: 'Look for secrets, injection risks, and unsafe deps.',
    category: 'Security',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'dependency-audit',
    name: 'Dependency Audit',
    description: 'Flag outdated or vulnerable package versions.',
    category: 'Security',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'benchmark',
    name: 'Benchmark',
    description: 'Measure changes against a saved performance baseline.',
    category: 'Quality',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'browser-control',
    name: 'Browser Control',
    description: 'Drive a browser tab with clicks and typing.',
    category: 'Browser',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'desktop-control',
    name: 'Desktop Control',
    description: 'Move the pointer and type into desktop apps.',
    category: 'Local',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'shell',
    name: 'Shell',
    description: 'Run commands inside the isolated workspace.',
    category: 'Local',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'notifications',
    name: 'Notifications',
    description: 'Send concise progress and completion alerts.',
    category: 'Productivity',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'meeting-notes',
    name: 'Meeting Notes',
    description: 'Summarize calls into decisions and action items.',
    category: 'Productivity',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'calendar-planner',
    name: 'Calendar Planner',
    description: 'Find focus blocks without double-booking.',
    category: 'Productivity',
    kind: V2CatalogKind.plugin,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),

  // ── MCP servers ───────────────────────────────────────────────────────
  V2CatalogEntry(
    id: 'context7',
    name: 'Context7',
    description: 'Fresh, version-specific library documentation.',
    category: 'Developer',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'filesystem',
    name: 'Filesystem',
    description: 'Read and write files inside approved folders.',
    category: 'Local',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'fetch',
    name: 'Fetch',
    description: 'Fetch web pages and convert them to markdown.',
    category: 'Web',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'memory',
    name: 'Memory',
    description: 'Store facts in a persistent knowledge graph.',
    category: 'AI',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'puppeteer',
    name: 'Puppeteer',
    description: 'Automate Chromium for screenshots and scraping.',
    category: 'Browser',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'postgres',
    name: 'Postgres',
    description: 'Query and inspect PostgreSQL databases.',
    category: 'Database',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.connectionString,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'sqlite',
    name: 'SQLite',
    description: 'Read and update local SQLite database files.',
    category: 'Database',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
  ),
  V2CatalogEntry(
    id: 'mysql',
    name: 'MySQL',
    description: 'Run read and write SQL against MySQL.',
    category: 'Database',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.connectionString,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'mongodb',
    name: 'MongoDB',
    description: 'Query collections and inspect document shapes.',
    category: 'Database',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.connectionString,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'redis',
    name: 'Redis',
    description: 'Inspect keys, values, and stream contents.',
    category: 'Database',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.connectionString,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'github-mcp',
    name: 'GitHub tools',
    description: 'Issues, pull requests, and code search.',
    category: 'Code',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.personalAccessToken,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'git',
    name: 'Git',
    description: 'Inspect history, diffs, and working tree state.',
    category: 'Code',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'brave-search-mcp',
    name: 'Brave Search tools',
    description: 'Web search from a local add-on.',
    category: 'Search',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'google-maps',
    name: 'Google Maps',
    description: 'Places, directions, and travel-time lookups.',
    category: 'Search',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'slack-mcp',
    name: 'Slack tools',
    description: 'Read channels and post updates as a bot.',
    category: 'Chat',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.botToken,
    risk: V2CatalogRisk.medium,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'notion-mcp',
    name: 'Notion tools',
    description: 'Search pages and append blocks.',
    category: 'Notes',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'sentry-mcp',
    name: 'Sentry tools',
    description: 'Pull issues, events, and release health.',
    category: 'Observability',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'stripe-mcp',
    name: 'Stripe tools',
    description: 'Inspect payments and customers.',
    category: 'Payments',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'aws',
    name: 'AWS',
    description: 'Inspect accounts, resources, and CloudWatch logs.',
    category: 'Infrastructure',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'kubernetes',
    name: 'Kubernetes',
    description: 'List pods, read logs, and inspect workloads.',
    category: 'Infrastructure',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.kubeconfig,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'docker',
    name: 'Docker',
    description: 'Manage local containers, images, and volumes.',
    category: 'Infrastructure',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'terraform',
    name: 'Terraform',
    description: 'Plan and apply infrastructure changes.',
    category: 'Infrastructure',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'playwright',
    name: 'Playwright',
    description: 'Run browser tests and capture traces.',
    category: 'Browser',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'selenium',
    name: 'Selenium',
    description: 'Automate legacy browser test suites.',
    category: 'Browser',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'sequential-thinking',
    name: 'Sequential Thinking',
    description: 'Break hard problems into reviewable steps.',
    category: 'AI',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'time',
    name: 'Time',
    description: 'Current time and timezone conversions.',
    category: 'Utilities',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.low,
  ),
  V2CatalogEntry(
    id: 'weather',
    name: 'Weather',
    description: 'Forecasts and current conditions by location.',
    category: 'Utilities',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.low,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'e2b',
    name: 'E2B',
    description: 'Run generated code in a disposable sandbox.',
    category: 'Infrastructure',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'cloudflare',
    name: 'Cloudflare',
    description: 'Workers, DNS records, and cache rules.',
    category: 'Infrastructure',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.high,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'graphql',
    name: 'GraphQL',
    description: 'Introspect schemas and run safe queries.',
    category: 'Developer',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
  V2CatalogEntry(
    id: 'openapi',
    name: 'OpenAPI',
    description: 'Turn REST specs into callable tools.',
    category: 'Developer',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.apiKey,
    risk: V2CatalogRisk.medium,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'obsidian',
    name: 'Obsidian',
    description: 'Search and update a local Obsidian vault.',
    category: 'Notes',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
    builtIn: false,
  ),
  V2CatalogEntry(
    id: 'excel',
    name: 'Excel',
    description: 'Read and edit local Excel workbooks.',
    category: 'Productivity',
    kind: V2CatalogKind.mcp,
    auth: V2CatalogAuth.none,
    risk: V2CatalogRisk.medium,
  ),
];

/// Look up an entry by its stable slug.
///
/// Trims surrounding whitespace and ignores case so a deep link such as
/// `?connector=GitHub` resolves to the same row as the persisted id.
V2CatalogEntry? v2CatalogEntryById(String id) {
  final needle = id.trim().toLowerCase();
  if (needle.isEmpty) return null;
  for (final entry in v2Catalog) {
    if (entry.id == needle) return entry;
  }
  return null;
}

/// All entries of [kind], in catalog order.
List<V2CatalogEntry> v2CatalogEntriesOfKind(V2CatalogKind kind) =>
    List.unmodifiable(v2Catalog.where((entry) => entry.kind == kind));

/// All entries in [category], compared case-insensitively.
List<V2CatalogEntry> v2CatalogEntriesInCategory(String category) {
  final needle = category.trim().toLowerCase();
  if (needle.isEmpty) return const <V2CatalogEntry>[];
  return List.unmodifiable(
    v2Catalog.where((entry) => entry.category.toLowerCase() == needle),
  );
}

/// Unique category names in case-insensitive alphabetical order.
List<String> get v2CatalogCategories {
  final categories = <String>{for (final entry in v2Catalog) entry.category};
  final sorted = categories.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return List.unmodifiable(sorted);
}

/// Free-text search over id, name, description, category, and kind.
///
/// Terms are AND-ed, so `google drive` narrows to Google Drive instead of
/// every Google integration. An empty or whitespace-only query returns the
/// whole catalog in its stable order.
List<V2CatalogEntry> searchV2Catalog(String query) {
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList();
  if (terms.isEmpty) return List.unmodifiable(v2Catalog);
  return List.unmodifiable(
    v2Catalog.where((entry) {
      final haystack = entry.searchText;
      return terms.every(haystack.contains);
    }),
  );
}

/// Aggregate counts for the current catalog.
V2CatalogStats get v2CatalogStats => V2CatalogStats.from(v2Catalog);
