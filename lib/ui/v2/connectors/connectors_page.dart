import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'add_connector_page.dart';
import 'catalog_data.dart';
import 'connector_detail_page.dart';
import 'connector_probe.dart';
import 'connector_store.dart';
import 'connector_upgrade.dart';

export 'connector_models.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ConnectorsStatus { loading, content, error }

/// Everything the connectors screen needs. The page filters and groups rows
/// locally; the wiring layer supplies the catalog and persists changes.

@immutable
class V2ConnectorsData {
  const V2ConnectorsData({
    this.connectors = const <V2Connector>[],
    this.useBuiltInCatalog = true,
    this.status = V2ConnectorsStatus.content,
    this.category = allCategories,
    this.availableTotal,
    this.planNote = 'Custom connectors — Free: 0 · Go: 5 · Plus & Pro: 20.',
    this.errorMessage = 'The connector list did not load.',
  });

  /// Sentinel category that matches every connector.
  static const allCategories = 'All';

  /// Rows the wiring layer supplies. Empty while a live catalog is still
  /// loading, so [catalog] falls back to the built-in list unless the caller
  /// opts out with [useBuiltInCatalog].
  final List<V2Connector> connectors;
  final bool useBuiltInCatalog;
  final V2ConnectorsStatus status;
  final String category;

  /// Size of the whole catalog. Defaults to the connectors supplied, so no
  /// made-up number reaches production; the wiring layer passes a larger value
  /// when the list it hands over is only the first page.
  final int? availableTotal;
  final String planNote;
  final String errorMessage;

  /// The rows the screen shows: the injected list, or the full 168-entry
  /// catalog when the wiring layer has not supplied one yet.
  List<V2Connector> get catalog => connectors.isNotEmpty || !useBuiltInCatalog
      ? connectors
      : v2BuiltInCatalog;

  int get catalogTotal => availableTotal ?? catalog.length;

  List<V2Connector> get installed =>
      catalog.where((connector) => connector.connected).toList();

  List<V2Connector> get available =>
      catalog.where((connector) => !connector.connected).toList();

  List<V2Connector> get apps => catalog
      .where((connector) => connector.kind == V2ConnectorKind.app)
      .toList();

  List<V2Connector> get plugins => catalog
      .where((connector) => connector.kind == V2ConnectorKind.plugin)
      .toList();

  /// MCP server rows only.
  List<V2Connector> get mcpServers => catalog
      .where((connector) => connector.kind == V2ConnectorKind.mcp)
      .toList();

  /// Everything in the "Plugins & MCP" section: plugins and MCP servers.
  List<V2Connector> get pluginsAndMcp => catalog
      .where((connector) => connector.kind != V2ConnectorKind.app)
      .toList();

  int get activeCount =>
      installed.where((connector) => connector.enabled).length;

  /// Categories in catalog order, with duplicates removed.
  List<String> get categories {
    final seen = <String>{};
    final result = <String>[];
    for (final connector in catalog) {
      if (connector.category.trim().isEmpty) continue;
      if (seen.add(connector.category)) result.add(connector.category);
    }
    return result;
  }
}

/// Connector catalog: built-in apps, then built-in plugins and MCP servers.
class ConnectorsPage extends StatefulWidget {
  const ConnectorsPage({
    super.key,
    required this.data,
    this.onToggle,
    this.onOpen,
    this.onConnect,
    this.onAddCustom,
    this.onBrowseConnectors,
    this.onUpgrade,
    this.onRetry,
    this.onSearchChanged,
    this.onCategoryChanged,
    this.onMenu,
    this.store,
    this.secrets,
    this.probe,
    this.plan,
  });

  final V2ConnectorsData data;
  final void Function(String id, bool enabled)? onToggle;
  final ValueChanged<String>? onOpen;
  final ValueChanged<String>? onConnect;
  final VoidCallback? onAddCustom;
  final VoidCallback? onBrowseConnectors;
  final VoidCallback? onUpgrade;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onSearchChanged;
  final ValueChanged<String>? onCategoryChanged;
  final VoidCallback? onMenu;

  /// Persisted connector state. Defaults to the app-wide store.
  final V2ConnectorStore? store;
  final V2ConnectorSecrets? secrets;

  /// Runs the real connection test from the detail screen. Defaults to the
  /// HTTP probe; tests inject a deterministic one.
  final V2ConnectorProbe? probe;

  /// Server-confirmed allowance. Null reads the cached tier, which is the best
  /// answer this screen can get without the billing stack.
  final V2ConnectorPlan? plan;

  @override
  State<ConnectorsPage> createState() => _ConnectorsPageState();
}

/// Kind filter across the one catalog: hosted connectors, plugins, and MCP
/// servers. Plugins and MCP share the "Plugins & MCP" section, but the MCP tab
/// keeps the third kind reachable without mixing them.
enum _CatalogFilter { all, apps, plugins, mcp }

class _ConnectorsPageState extends State<ConnectorsPage> {
  late String _category = widget.data.category;
  late _CatalogFilter _kind = _CatalogFilter.all;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// Saved connections, keyed by id. Empty until the store answers, and empty
  /// when the platform has no preferences (previews).
  Map<String, V2ConnectorConnection> _connections = const {};

  /// The plan the add flow will enforce. Resolved once, from the injected
  /// value or the cached tier.
  V2ConnectorPlan? _plan;

  V2ConnectorStore get _store => widget.store ?? v2ConnectorStore;
  V2ConnectorSecrets get _secrets => widget.secrets ?? v2ConnectorSecrets;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    _reload();
  }

  Future<void> _reload() async {
    try {
      final saved = await _store.load();
      if (!mounted) return;
      setState(() {
        _connections = {for (final connection in saved) connection.id: connection};
      });
    } catch (_) {
      // No readable store: the built-in catalog is still shown, all
      // disconnected, which is the truth when nothing can be loaded.
      if (!mounted) return;
      setState(() => _connections = const {});
    }
    if (_plan != null) return;
    final plan = await v2LoadConnectorPlan();
    if (!mounted) return;
    setState(() => _plan = plan);
  }

  int get _customUsed => _connections.values
      .where((connection) => connection.custom)
      .length;

  bool get _customCapReached {
    final plan = _plan;
    return plan != null && _customUsed >= plan.connectorLimit;
  }

  /// The catalog with saved connections overlaid, plus the custom connectors
  /// the person added. Rows only claim "connected" when a saved connection
  /// exists.
  List<V2Connector> get _catalog {
    final base = widget.data.catalog;
    final rows = <V2Connector>[];
    for (final row in base) {
      final saved = _connections[row.id];
      rows.add(
        saved == null
            ? row
            : row.copyWith(
                connected: true,
                enabled: saved.enabled,
                endpoint: saved.endpoint,
                description: row.description,
              ),
      );
    }
    final baseIds = {for (final row in base) row.id};
    for (final saved in _connections.values) {
      if (!saved.custom || baseIds.contains(saved.id)) continue;
      rows.insert(0, saved.toRow());
    }
    return rows;
  }

  List<String> get _categories {
    final seen = <String>{};
    final result = <String>[];
    for (final connector in _catalog) {
      if (connector.category.trim().isEmpty) continue;
      if (seen.add(connector.category)) result.add(connector.category);
    }
    return result;
  }

  // ── Wiring ───────────────────────────────────────────────────────────────

  V2Connector? _rowFor(String id) =>
      _catalog.where((row) => row.id == id).firstOrNull;

  Future<V2ConnectorPlan> _resolvePlan() async {
    final plan = _plan ?? await v2LoadConnectorPlan();
    if (mounted && _plan != plan) setState(() => _plan = plan);
    return plan;
  }

  Future<void> _openUpgrade(BuildContext context) async {
    final plan = await _resolvePlan();
    if (!context.mounted) return;
    await v2ShowConnectorUpgrade(context, plan);
  }

  Future<void> _openConnector(String id) async {
    final external = widget.onOpen;
    if (external != null) {
      external(id);
      return;
    }
    final row = _rowFor(id);
    if (row == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectorDetailPage(
          data: v2ConnectorDetailForRow(row, connection: _connections[id]),
          store: _store,
          secrets: _secrets,
          probe: widget.probe,
          plan: _plan,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _toggle(String id, bool enabled) async {
    final external = widget.onToggle;
    if (external != null) {
      external(id, enabled);
      return;
    }
    final current = _connections[id];
    if (current == null) return;
    setState(() {
      _connections = {
        ..._connections,
        id: current.copyWith(enabled: enabled),
      };
    });
    try {
      await _store.setEnabled(id, enabled);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _connections = {..._connections, id: current};
      });
      showOSnack(context, 'Could not save that change. Try again.');
    }
  }

  V2AddConnectorData _setupDataFor(V2Connector row, V2ConnectorPlan plan) {
    return V2AddConnectorData(
      plan: plan,
      customConnectorsUsed: _customUsed,
      presetId: row.id,
      presetName: row.name,
      presetDescription: row.description,
      presetCategory: row.category,
      presetKind: switch (row.kind) {
        V2ConnectorKind.app => 'app',
        V2ConnectorKind.plugin => 'plugin',
        V2ConnectorKind.mcp => 'mcp',
      },
      target: row.kind == V2ConnectorKind.plugin
          ? V2ConnectorTarget.command
          : V2ConnectorTarget.url,
      auth: switch (row.auth) {
        V2CatalogAuth.none => V2ConnectorAuth.none,
        V2CatalogAuth.oauth => V2ConnectorAuth.oauth,
        _ => V2ConnectorAuth.apiKey,
      },
      authRequiredMessage:
          'This connector uses ${row.auth.label}. Enter the server Ovid '
          'should reach and the credential you use for it.',
    );
  }

  Future<void> _connect(String id) async {
    final external = widget.onConnect;
    if (external != null) {
      external(id);
      return;
    }
    final row = _rowFor(id);
    if (row == null) return;
    final plan = await _resolvePlan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddConnectorPage(
          data: _setupDataFor(row, plan),
          store: _store,
          secrets: _secrets,
          probe: widget.probe,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _openAddCustom() async {
    final external = widget.onAddCustom;
    if (external != null) {
      external();
      return;
    }
    final plan = await _resolvePlan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddConnectorPage(
          data: V2AddConnectorData(
            plan: plan,
            customConnectorsUsed: _customUsed,
          ),
          store: _store,
          secrets: _secrets,
          probe: widget.probe,
        ),
      ),
    );
    await _reload();
  }

  @override
  void didUpdateWidget(covariant ConnectorsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.category != widget.data.category) {
      _category = widget.data.category;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    setState(() => _query = value.trim().toLowerCase());
    widget.onSearchChanged?.call(value);
  }

  void _clearSearch() {
    _search.clear();
    _onSearch('');
  }

  void _clearFilters() {
    _search.clear();
    setState(() {
      _query = '';
      _category = V2ConnectorsData.allCategories;
      _kind = _CatalogFilter.all;
    });
    widget.onSearchChanged?.call('');
    widget.onCategoryChanged?.call(V2ConnectorsData.allCategories);
  }

  void _setCategory(String category) {
    if (_category == category) return;
    setState(() => _category = category);
    widget.onCategoryChanged?.call(category);
  }

  void _setKind(_CatalogFilter kind) {
    if (_kind == kind) return;
    setState(() => _kind = kind);
  }

  bool _matchesKind(V2Connector connector) => switch (_kind) {
    _CatalogFilter.all => true,
    _CatalogFilter.apps => connector.kind == V2ConnectorKind.app,
    _CatalogFilter.plugins => connector.kind == V2ConnectorKind.plugin,
    _CatalogFilter.mcp => connector.kind == V2ConnectorKind.mcp,
  };

  bool _matches(V2Connector connector) {
    if (!_matchesKind(connector)) return false;
    final categoryMatches =
        _category == V2ConnectorsData.allCategories ||
        connector.category == _category;
    if (!categoryMatches) return false;
    if (_query.isEmpty) return true;
    if (connector.name.toLowerCase().contains(_query)) return true;
    if (connector.description.toLowerCase().contains(_query)) return true;
    if (connector.category.toLowerCase().contains(_query)) return true;
    return connector.tools.any((tool) => tool.toLowerCase().contains(_query));
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(
        title: 'Connectors',
        subtitle: 'Apps and tools Ovid can use',
        actions: [
          // The pill label squeezes the title off a 320 dp screen, and at large
          // text sizes it no longer fits next to it at all. Fall back to the
          // icon control (same action, same 48 dp target, same label for
          // screen readers) instead of clipping the title.
          if (_compactAppBar(context))
            OIconButton(
              icon: Icons.add_rounded,
              semanticLabel: _customCapReached
                  ? 'Add custom connector, plan limit reached'
                  : 'Add custom connector',
              onPressed: _customCapReached ? null : _openAddCustom,
            )
          else
            OButton(
              label: 'Add custom',
              icon: Icons.add_rounded,
              variant: OButtonVariant.ghost,
              onPressed: _customCapReached ? null : _openAddCustom,
            ),
        ],
      ),
      body: OFadeSlide(child: _body(context)),
    );
  }

  /// True when the app bar cannot hold the labelled "Add custom" pill next to
  /// the title: narrow phones, or text at 1.3× or more.
  bool _compactAppBar(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 360 ||
      MediaQuery.textScalerOf(context).scale(14) > 18;

  Widget _body(BuildContext context) {
    return switch (widget.data.status) {
      V2ConnectorsStatus.loading => const OSkeletonList(rows: 6),
      V2ConnectorsStatus.error => OErrorState(
        message: widget.data.errorMessage,
        // The screen owns a reload, so a retry is never a dead button.
        onRetry: widget.onRetry ?? _reload,
      ),
      V2ConnectorsStatus.content => _content(context),
    };
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final catalog = _catalog;
    final filtered = catalog.where(_matches).toList();
    // Connected rows first inside each section, so the things the person
    // already uses are not buried under the rest of the catalog.
    final apps = _connectedFirst(
      filtered.where((connector) => connector.kind == V2ConnectorKind.app),
    );
    // The "Plugins & MCP" section keeps plugins and MCP servers together, as
    // the shared catalog contract defines; the MCP tab above narrows to just
    // MCP servers.
    final plugins = _connectedFirst(
      filtered.where((connector) => connector.kind != V2ConnectorKind.app),
    );
    final total = widget.data.availableTotal ?? catalog.length;
    final installed = catalog.where((connector) => connector.connected);
    final active = installed.where((connector) => connector.enabled);
    final categories = _categories;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.xl,
      ),
      children: [
        OSearchField(
          controller: _search,
          hint: total > 0
              ? 'Search $total integrations…'
              : 'Search integrations…',
          onChanged: _onSearch,
          trailing: _query.isEmpty
              ? null
              : OIconButton(
                  icon: Icons.close_rounded,
                  semanticLabel: 'Clear search',
                  onPressed: _clearSearch,
                ),
        ),
        if (_customCapReached) ...[
          const SizedBox(height: OSpace.m),
          _CapBanner(
            plan: _plan!,
            used: _customUsed,
            onUpgrade: () => _openUpgrade(context),
          ),
        ],
        if (catalog.isNotEmpty) ...[
          const SizedBox(height: OSpace.m),
          _KindStrip(selected: _kind, onSelected: _setKind),
          if (categories.length > 1) ...[
            const SizedBox(height: OSpace.m),
            _CategoryStrip(
              categories: categories,
              selected: _category,
              onSelected: _setCategory,
            ),
          ],
        ],
        const SizedBox(height: OSpace.l),
        if (catalog.isEmpty)
          _catalogEmpty()
        else if (filtered.isEmpty)
          _searchEmpty()
        else ...[
          if (apps.isNotEmpty) ...[
            OSectionHeader(
              label: 'Connectors',
              padding: const EdgeInsets.fromLTRB(
                OSpace.xs,
                0,
                OSpace.xs,
                OSpace.s,
              ),
              trailing: _CountBadge(
                key: const Key('connectors-count'),
                count: apps.length,
                semanticLabel: '${apps.length} connectors',
              ),
            ),
            ..._rows(apps),
          ],
          if (plugins.isNotEmpty) ...[
            if (apps.isNotEmpty) const SizedBox(height: OSpace.m),
            OSectionHeader(
              label: 'Plugins & MCP',
              padding: const EdgeInsets.fromLTRB(
                OSpace.xs,
                0,
                OSpace.xs,
                OSpace.s,
              ),
              trailing: _CountBadge(
                key: const Key('plugins-count'),
                count: plugins.length,
                semanticLabel: '${plugins.length} plugins and MCP servers',
              ),
            ),
            ..._rows(plugins),
          ],
          const SizedBox(height: OSpace.s),
          Text(
            '${installed.length} installed · ${active.length} on',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
        const SizedBox(height: OSpace.l),
        _PlanNote(
          note: widget.data.planNote,
          onUpgrade: widget.onUpgrade,
        ),
      ],
    );
  }

  List<V2Connector> _connectedFirst(Iterable<V2Connector> connectors) => [
    ...connectors.where((connector) => connector.connected),
    ...connectors.where((connector) => !connector.connected),
  ];

  Widget _catalogEmpty() {
    return OEmptyState(
      compact: true,
      icon: Icons.hub_outlined,
      title: 'No connectors available',
      message: 'New connectors will show up here as they are added.',
      action: OButton(
        label: 'Add custom',
        icon: Icons.add_rounded,
        onPressed: _customCapReached ? null : _openAddCustom,
      ),
    );
  }

  Widget _searchEmpty() {
    return OEmptyState(
      compact: true,
      icon: Icons.search_off_rounded,
      title: 'No matches',
      message: 'Try a different search or category.',
      action: OButton(
        label: 'Clear filters',
        variant: OButtonVariant.secondary,
        onPressed: _clearFilters,
      ),
    );
  }

  List<Widget> _rows(List<V2Connector> connectors) {
    final rows = <Widget>[
      for (final connector in connectors)
        Padding(
          padding: const EdgeInsets.only(bottom: OSpace.s),
          child: _CatalogRow(
            connector: connector,
            onTap: () => _openConnector(connector.id),
            onToggle: (value) => _toggle(connector.id, value),
            onConnect: () => _connect(connector.id),
          ),
        ),
    ];
    if (rows.length <= 8) return [OStagger(children: rows)];
    return [OStagger(children: rows.take(8).toList()), ...rows.skip(8)];
  }
}

/// True when text is large enough that a row's trailing action has to move to
/// its own line: from 1.3× a 48 dp button no longer leaves room for the label
/// beside it on a 320 dp screen.
bool _stacksActions(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) >= 14 * 1.3;

class _CountBadge extends StatelessWidget {
  const _CountBadge({
    super.key,
    required this.count,
    required this.semanticLabel,
  });

  final int count;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(child: OPill(label: '$count')),
    );
  }
}

class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final all = <String>['All', ...categories];
    return SizedBox(
      height: OSpace.touch,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: all.length,
        separatorBuilder: (_, _) => const SizedBox(width: OSpace.s),
        itemBuilder: (context, index) {
          final category = all[index];
          return _CategoryChip(
            label: category,
            selected: category == selected,
            onTap: () => onSelected(category),
          );
        },
      ),
    );
  }
}

class _KindStrip extends StatelessWidget {
  const _KindStrip({required this.selected, required this.onSelected});

  final _CatalogFilter selected;
  final ValueChanged<_CatalogFilter> onSelected;

  static const _options = <(_CatalogFilter, String, String)>[
    (_CatalogFilter.all, 'All', 'Show all connectors, plugins and MCP servers'),
    (_CatalogFilter.apps, 'Apps', 'Show hosted apps only'),
    (_CatalogFilter.plugins, 'Plugins', 'Show plugins only'),
    (_CatalogFilter.mcp, 'MCP', 'Show MCP servers only'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: OSpace.touch,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _options.length,
        separatorBuilder: (_, _) => const SizedBox(width: OSpace.s),
        itemBuilder: (context, index) {
          final (kind, label, semanticLabel) = _options[index];
          return _CategoryChip(
            key: Key('kind-${kind.name}'),
            label: label,
            semanticLabel: semanticLabel,
            selected: kind == selected,
            onTap: () => onSelected(kind),
          );
        },
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel: semanticLabel ?? '$label category',
      child: Semantics(
        selected: selected,
        child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            height: OSpace.touch,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? c.accentSoft : c.surface,
              borderRadius: BorderRadius.circular(ORadius.pill),
              border: Border.all(
                color: selected
                    ? c.accentFill.withValues(alpha: 0.5)
                    : c.hairline,
              ),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.label.copyWith(
                color: selected ? c.accent : c.textMuted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    required this.connector,
    this.onTap,
    this.onToggle,
    this.onConnect,
  });

  final V2Connector connector;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final details = OPressable(
      onTap: onTap,
      semanticLabel: '${connector.name}, ${connector.description}',
      // The label above replaces the raw text nodes, so a reader hears the
      // row once instead of once per line.
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ConnectorIcon(icon: connector.icon),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: OSpace.s,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        connector.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodyStrong.copyWith(color: c.text),
                      ),
                      if (connector.builtIn)
                        const OPill(label: 'Built in', tone: OPillTone.neutral),
                      if (connector.connected)
                        OPill(
                          label: connector.enabled ? 'On' : 'Paused',
                          tone: connector.enabled
                              ? OPillTone.success
                              : OPillTone.neutral,
                          dot: connector.enabled,
                        )
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    connector.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final action = connector.connected
        ? MergeSemantics(
            child: Semantics(
              label: '${connector.name} connector',
              child: SizedBox(
                height: OSpace.touch,
                child: Switch(value: connector.enabled, onChanged: onToggle),
              ),
            ),
          )
        : OButton(
            label: connector.kind == V2ConnectorKind.app ? 'Connect' : 'Add',
            semanticLabel:
                '${connector.kind == V2ConnectorKind.app ? 'Connect' : 'Add'} '
                '${connector.name}',
            icon: Icons.add_rounded,
            variant: OButtonVariant.secondary,
            expand: _stacksActions(context),
            onPressed: onConnect,
          );

    const padding = EdgeInsets.symmetric(
      horizontal: OSpace.m,
      vertical: OSpace.m,
    );
    // At large text the button no longer fits beside the description, so it
    // takes its own full-width line instead of squeezing the text away.
    if (!connector.connected && _stacksActions(context)) {
      return OCard(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            details,
            const SizedBox(height: OSpace.m),
            action,
          ],
        ),
      );
    }
    return OCard(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: details),
          const SizedBox(width: OSpace.s),
          action,
        ],
      ),
    );
  }
}

class _ConnectorIcon extends StatelessWidget {
  const _ConnectorIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    const size = 40.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Icon(icon, size: size * 0.5, color: c.textMuted),
    );
  }
}

class _PlanNote extends StatelessWidget {
  const _PlanNote({required this.note, this.onUpgrade});

  final String note;
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = Row(
      children: [
        Icon(Icons.info_outline_rounded, size: 18, color: c.textMuted),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(note, style: OType.caption.copyWith(color: c.textMuted)),
        ),
      ],
    );
    final upgrade = OButton(
      label: 'Upgrade',
      variant: OButtonVariant.ghost,
      onPressed: onUpgrade,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OSpace.m,
        OSpace.s,
        OSpace.s,
        OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      // At large text the button would leave the note a couple of pixels wide,
      // so it moves onto its own line.
      child: _stacksActions(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                label,
                const SizedBox(height: OSpace.s),
                Align(alignment: Alignment.centerRight, child: upgrade),
              ],
            )
          : Row(
              children: [
                Expanded(child: label),
                const SizedBox(width: OSpace.s),
                upgrade,
              ],
            ),
    );
  }
}

/// The plan cap, explained on the list with the real upgrade path next to it.
class _CapBanner extends StatelessWidget {
  const _CapBanner({
    required this.plan,
    required this.used,
    required this.onUpgrade,
  });

  final V2ConnectorPlan plan;
  final int used;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final message = plan.connectorLimit == 0
        ? 'The ${plan.label} plan includes no custom connectors. Built-in '
              'apps still connect without a slot.'
        : 'You have used all ${plan.connectorLimit} custom connector slots on '
              '${plan.label} ($used in use). Built-in apps still connect '
              'without a slot.';
    final upgrade = OButton(
      key: const Key('connector-cap-upgrade'),
      label: 'See plans',
      variant: OButtonVariant.ghost,
      onPressed: onUpgrade,
    );
    final copy = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, size: 18, color: c.warn),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            message,
            style: OType.caption.copyWith(color: c.text),
          ),
        ),
      ],
    );
    return Container(
      key: const Key('connector-cap-banner'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.warn.withValues(alpha: 0.35)),
      ),
      child: _stacksActions(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                copy,
                const SizedBox(height: OSpace.s),
                Align(alignment: Alignment.centerRight, child: upgrade),
              ],
            )
          : Row(
              children: [
                Expanded(child: copy),
                const SizedBox(width: OSpace.s),
                upgrade,
              ],
            ),
    );
  }
}
