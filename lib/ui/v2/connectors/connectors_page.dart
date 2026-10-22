import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
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

/// Everything the connectors list needs. The wiring layer supplies the rows
/// and persists changes; the page only filters them locally.
@immutable
class V2ConnectorsData {
  const V2ConnectorsData({
    this.connectors = const <V2Connector>[],
    this.useBuiltInCatalog = true,
    this.status = V2ConnectorsStatus.content,
    this.errorMessage = 'The connector list did not load.',
  });

  /// Rows the wiring layer supplies. Empty while a live catalog is still
  /// loading, so [catalog] falls back to the built-in list unless the caller
  /// opts out with [useBuiltInCatalog].
  final List<V2Connector> connectors;
  final bool useBuiltInCatalog;
  final V2ConnectorsStatus status;
  final String errorMessage;

  /// The rows the screen shows: the injected list, or the full catalog when the
  /// wiring layer has not supplied one yet.
  List<V2Connector> get catalog => connectors.isNotEmpty || !useBuiltInCatalog
      ? connectors
      : v2BuiltInCatalog;
}

/// One list of connectors: search, one filter menu, and a switch per row.
class ConnectorsPage extends StatefulWidget {
  const ConnectorsPage({
    super.key,
    required this.data,
    this.onToggle,
    this.onOpen,
    this.onConnect,
    this.onAddCustom,
    this.onUpgrade,
    this.onRetry,
    this.onSearchChanged,
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
  final VoidCallback? onUpgrade;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onSearchChanged;

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

/// The one filter menu. Kinds are a filter, not a row of chips.
enum _Filter {
  all('All'),
  connected('Connected'),
  apps('Apps'),
  plugins('Plugins'),
  mcp('Add-ons');

  const _Filter(this.label);

  final String label;

  bool matches(V2Connector connector) => switch (this) {
    _Filter.all => true,
    _Filter.connected => connector.connected,
    _Filter.apps => connector.kind == V2ConnectorKind.app,
    _Filter.plugins => connector.kind == V2ConnectorKind.plugin,
    _Filter.mcp => connector.kind == V2ConnectorKind.mcp,
  };
}

class _ConnectorsPageState extends State<ConnectorsPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  _Filter _filter = _Filter.all;

  /// Saved connections, keyed by id. Empty until the store answers, and empty
  /// when the platform has no preferences (previews).
  Map<String, V2ConnectorConnection> _connections = const {};

  /// The plan the add flow enforces. Resolved once, from the injected value or
  /// the cached tier.
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

  int get _customUsed =>
      _connections.values.where((connection) => connection.custom).length;

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

  V2Connector? _rowFor(String id) =>
      _catalog.where((row) => row.id == id).firstOrNull;

  Future<V2ConnectorPlan> _resolvePlan() async {
    final plan = _plan ?? await v2LoadConnectorPlan();
    if (mounted && _plan != plan) setState(() => _plan = plan);
    return plan;
  }

  Future<void> _openUpgrade() async {
    final external = widget.onUpgrade;
    if (external != null) {
      external();
      return;
    }
    final plan = await _resolvePlan();
    if (!mounted) return;
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
      showOSnack(context, 'Could not save that change.');
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

  bool _matches(V2Connector connector) {
    if (!_filter.matches(connector)) return false;
    if (_query.isEmpty) return true;
    if (connector.name.toLowerCase().contains(_query)) return true;
    if (connector.description.toLowerCase().contains(_query)) return true;
    return connector.tools.any((tool) => tool.toLowerCase().contains(_query));
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Connectors',
      maxWidth: 640,
      actions: [
        OIconButton(
          icon: Icons.add_rounded,
          semanticLabel: 'Add connector',
          onPressed: _customCapReached ? null : _openAddCustom,
        ),
      ],
      child: OFadeSlide(child: _body(context)),
    );
  }

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
    final catalog = _catalog;
    final filtered = catalog.where(_matches).toList();
    // Connected rows first, so what the person already uses is not buried.
    final rows = [
      ...filtered.where((connector) => connector.connected),
      ...filtered.where((connector) => !connector.connected),
    ];

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_customCapReached) ...[
                _CapLine(
                  plan: _plan!,
                  onUpgrade: _openUpgrade,
                ),
                const SizedBox(height: OSpace.m),
              ],
              Row(
                children: [
                  Expanded(
                    child: OSearchField(
                      controller: _search,
                      hint: 'Search connectors',
                      onChanged: _onSearch,
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  _FilterButton(
                    value: _filter,
                    onSelected: (value) => setState(() => _filter = value),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.l),
            ],
          ),
        ),
        if (catalog.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _catalogEmpty(),
          )
        else if (rows.isEmpty)
          SliverFillRemaining(hasScrollBody: false, child: _searchEmpty())
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final connector = rows[index];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (index > 0)
                      Divider(
                        height: 1,
                        color: OColors.of(context).hairline,
                      ),
                    _ConnectorRow(
                      connector: connector,
                      onTap: () => _openConnector(connector.id),
                      onToggle: (value) => _toggle(connector.id, value),
                      onConnect: () => _connect(connector.id),
                    ),
                  ],
                );
              },
              childCount: rows.length,
            ),
          ),
      ],
    );
  }

  Widget _catalogEmpty() {
    return OEmptyState(
      compact: true,
      icon: Icons.hub_outlined,
      title: 'No connectors',
      message: 'New connectors appear here.',
      action: OButton(
        label: 'Add connector',
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
      message: 'Try a different search.',
      action: OButton(
        label: 'Clear search',
        variant: OButtonVariant.secondary,
        onPressed: _clearSearch,
      ),
    );
  }
}

/// The single filter control: an icon that opens a menu, with a dot while a
/// filter is on so the state is visible after the menu closes.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.value, required this.onSelected});

  final _Filter value;
  final ValueChanged<_Filter> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return PopupMenuButton<_Filter>(
      key: const Key('connector-filter'),
      tooltip: 'Filter: ${value.label}',
      onSelected: onSelected,
      color: c.surface,
      itemBuilder: (context) => [
        for (final option in _Filter.values)
          CheckedPopupMenuItem<_Filter>(
            value: option,
            checked: option == value,
            child: Text(option.label),
          ),
      ],
      // A PopupMenuButton with a custom child emits a tap node with no label
      // and no enabled state, so TalkBack read an anonymous button.
      child: Semantics(
        label: 'Filter: ${value.label}',
        button: true,
        enabled: true,
        child: SizedBox(
        width: OSpace.touch,
        height: OSpace.touch,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.filter_list_rounded, size: 22, color: c.textMuted),
            if (value != _Filter.all)
              Positioned(
                top: OSpace.m,
                right: OSpace.m,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: c.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }
}

/// One connector: icon, name, one status line, switch.
class _ConnectorRow extends StatelessWidget {
  const _ConnectorRow({
    required this.connector,
    required this.onTap,
    required this.onToggle,
    required this.onConnect,
  });

  final V2Connector connector;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final status = !connector.connected
        ? 'Not connected'
        : connector.enabled
        ? 'On'
        : 'Paused';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.s),
      child: Row(
        children: [
          Expanded(
            child: OPressable(
              onTap: onTap,
              semanticLabel: '${connector.name}, $status',
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Container(
                      width: OSpace.iconTile,
                      height: OSpace.iconTile,
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(ORadius.m),
                        border: Border.all(color: c.hairline),
                      ),
                      child: Icon(
                        connector.icon,
                        size: 18,
                        color: c.textMuted,
                      ),
                    ),
                    const SizedBox(width: OSpace.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            connector.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.bodyStrong.copyWith(color: c.text),
                          ),
                          Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: OSpace.s),
          // One node for the toggle: the name and the on/off state must be
          // read together, otherwise TalkBack announces a bare "switch, off"
          // with no idea which connector it belongs to.
          MergeSemantics(
            child: Semantics(
              label: '${connector.name} connector',
              child: SizedBox(
              height: OSpace.touch,
              child: Switch(
                key: ValueKey('connector-switch-${connector.id}'),
                value: connector.connected && connector.enabled,
                // A row without a saved connection opens the setup form; the
                // switch never shows a state the store does not hold.
                  onChanged: connector.connected
                      ? onToggle
                      : (value) {
                          if (value) onConnect();
                        },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The plan cap: one line, one upgrade action.
class _CapLine extends StatelessWidget {
  const _CapLine({required this.plan, required this.onUpgrade});

  final V2ConnectorPlan plan;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final message = plan.connectorLimit == 0
        ? 'No custom connectors on ${plan.label}.'
        : 'All ${plan.connectorLimit} custom slots used on ${plan.label}.';
    return Container(
      key: const Key('connector-cap-banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.warn),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              message,
              style: OType.caption.copyWith(color: c.text),
            ),
          ),
          OTextAction(label: 'Upgrade', onPressed: onUpgrade),
        ],
      ),
    );
  }
}
