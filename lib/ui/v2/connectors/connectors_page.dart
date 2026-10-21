import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ConnectorsTab { installed, available }

enum V2ConnectorsStatus { loading, content, error }

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
    this.icon = Icons.extension_outlined,
    this.enabled = true,
    this.popular = false,
  });

  final String id;
  final String name;
  final String description;
  final bool connected;
  final String category;
  final IconData icon;
  final bool enabled;
  final bool popular;
}

/// Everything the connectors screen needs. The page filters and switches tabs
/// locally; the wiring layer only supplies the catalog and persists changes.
@immutable
class V2ConnectorsData {
  const V2ConnectorsData({
    this.connectors = const <V2Connector>[],
    this.status = V2ConnectorsStatus.content,
    this.tab = V2ConnectorsTab.installed,
    this.category = allCategories,
    this.availableTotal,
    this.planNote = 'Free plan: 0 custom connectors. Go: 5.',
    this.errorMessage = 'The connector list did not load.',
  });

  /// Sentinel category that matches every connector.
  static const allCategories = 'All';

  final List<V2Connector> connectors;
  final V2ConnectorsStatus status;
  final V2ConnectorsTab tab;
  final String category;

  /// Size of the whole catalog. Defaults to the connectors supplied, so no
  /// made-up number reaches production; the wiring layer passes a larger value
  /// when the list it hands over is only the first page.
  final int? availableTotal;
  final String planNote;
  final String errorMessage;

  int get catalogTotal => availableTotal ?? available.length;

  List<V2Connector> get installed =>
      connectors.where((connector) => connector.connected).toList();

  List<V2Connector> get available =>
      connectors.where((connector) => !connector.connected).toList();

  int get activeCount =>
      installed.where((connector) => connector.enabled).length;

  /// Categories in catalog order, with duplicates removed.
  List<String> get categories {
    final seen = <String>{};
    final result = <String>[];
    for (final connector in connectors) {
      if (connector.category.trim().isEmpty) continue;
      if (seen.add(connector.category)) result.add(connector.category);
    }
    return result;
  }
}

/// Connector catalog with installed apps, a search field and popular picks.
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
    this.onTabChanged,
    this.onCategoryChanged,
    this.onMenu,
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
  final ValueChanged<V2ConnectorsTab>? onTabChanged;
  final ValueChanged<String>? onCategoryChanged;
  final VoidCallback? onMenu;

  @override
  State<ConnectorsPage> createState() => _ConnectorsPageState();
}

class _ConnectorsPageState extends State<ConnectorsPage> {
  late V2ConnectorsTab _tab = widget.data.tab;
  late String _category = widget.data.category;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void didUpdateWidget(covariant ConnectorsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.tab != widget.data.tab) {
      _tab = widget.data.tab;
    }
    if (oldWidget.data.category != widget.data.category) {
      _category = widget.data.category;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setTab(V2ConnectorsTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    widget.onTabChanged?.call(tab);
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
    });
    widget.onSearchChanged?.call('');
    widget.onCategoryChanged?.call(V2ConnectorsData.allCategories);
  }

  void _setCategory(String category) {
    if (_category == category) return;
    setState(() => _category = category);
    widget.onCategoryChanged?.call(category);
  }

  bool _matches(V2Connector connector) {
    final categoryMatches =
        _category == V2ConnectorsData.allCategories ||
        connector.category == _category;
    if (!categoryMatches) return false;
    if (_query.isEmpty) return true;
    return connector.name.toLowerCase().contains(_query) ||
        connector.description.toLowerCase().contains(_query) ||
        connector.category.toLowerCase().contains(_query);
  }

  void _browse() {
    _setTab(V2ConnectorsTab.available);
    widget.onBrowseConnectors?.call();
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(
        title: 'Connectors',
        subtitle: 'Let Ovid use your apps',
        actions: [
          // The pill label squeezes the title off a 320 dp screen, and at large
          // text sizes it no longer fits next to it at all. Fall back to the
          // icon control (same action, same 48 dp target, same label for
          // screen readers) instead of clipping the title.
          if (_compactAppBar(context))
            OIconButton(
              icon: Icons.add_rounded,
              semanticLabel: 'Add custom connector',
              onPressed: widget.onAddCustom,
            )
          else
            OButton(
              label: 'Add custom',
              icon: Icons.add_rounded,
              variant: OButtonVariant.ghost,
              onPressed: widget.onAddCustom,
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
        onRetry: widget.onRetry,
      ),
      V2ConnectorsStatus.content => _content(context),
    };
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final installed = widget.data.installed.where(_matches).toList();
    final available = widget.data.available.where(_matches).toList();
    final popular = widget.data.available
        .where((connector) => connector.popular && _matches(connector))
        .toList();
    final total = widget.data.catalogTotal;

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
          hint: total > 0 ? 'Search $total connectors…' : 'Search connectors…',
          onChanged: _onSearch,
          trailing: _query.isEmpty
              ? null
              : OIconButton(
                  icon: Icons.close_rounded,
                  semanticLabel: 'Clear search',
                  onPressed: _clearSearch,
                ),
        ),
        const SizedBox(height: OSpace.m),
        _SegmentedTabs(
          tab: _tab,
          installedCount: widget.data.installed.length,
          availableCount: total,
          onChanged: _setTab,
        ),
        if (widget.data.categories.length > 1) ...[
          const SizedBox(height: OSpace.m),
          _CategoryStrip(
            categories: widget.data.categories,
            selected: _category,
            onSelected: _setCategory,
          ),
        ],
        const SizedBox(height: OSpace.l),
        if (_tab == V2ConnectorsTab.installed) ...[
          OSectionHeader(
            label: 'Installed (${widget.data.installed.length})',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: c.success,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${widget.data.activeCount} active',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.success),
                  ),
                ),
              ],
            ),
          ),
          if (widget.data.installed.isEmpty)
            _installedEmpty()
          else if (installed.isEmpty)
            _searchEmpty('No installed connectors match')
          else
            ..._installedRows(installed),
          if (popular.isNotEmpty) ...[
            const SizedBox(height: OSpace.m),
            OSectionHeader(
              label: 'Popular connectors',
              trailing: Text(
                'View all $total',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.accent),
              ),
            ),
            _PopularGrid(connectors: popular, onConnect: widget.onConnect),
          ],
        ] else ...[
          OSectionHeader(
            label: 'Available ($total)',
            trailing: Text(
              '${widget.data.available.length} shown',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          if (widget.data.connectors.isEmpty)
            _catalogEmpty()
          else if (available.isEmpty)
            widget.data.available.isEmpty
                ? _everythingConnected()
                : _searchEmpty('No connectors match')
          else
            ..._availableRows(available),
        ],
        const SizedBox(height: OSpace.l),
        _PlanNote(note: widget.data.planNote, onUpgrade: widget.onUpgrade),
      ],
    );
  }

  Widget _catalogEmpty() {
    return OEmptyState(
      compact: true,
      icon: Icons.hub_outlined,
      title: 'No connectors available',
      message: 'New connectors will show up here as they are added.',
      action: OButton(
        label: 'Add custom',
        icon: Icons.add_rounded,
        onPressed: widget.onAddCustom,
      ),
    );
  }

  Widget _installedEmpty() {
    return OEmptyState(
      compact: true,
      icon: Icons.hub_outlined,
      title: 'No connectors yet',
      message:
          'Connect an app and Ovid can read, write, and act inside it '
          'for you.',
      action: OButton(
        label: 'Browse connectors',
        icon: Icons.search_rounded,
        onPressed: _browse,
      ),
    );
  }

  Widget _searchEmpty(String title) {
    return OEmptyState(
      compact: true,
      icon: Icons.search_off_rounded,
      title: title,
      message: 'Try a different search or category.',
      action: OButton(
        label: 'Clear filters',
        variant: OButtonVariant.secondary,
        onPressed: _clearFilters,
      ),
    );
  }

  Widget _everythingConnected() {
    return OEmptyState(
      compact: true,
      icon: Icons.check_circle_outline_rounded,
      title: 'Everything is connected',
      message: 'You have added every connector in the catalog.',
      action: OButton(
        label: 'See installed',
        variant: OButtonVariant.secondary,
        onPressed: () => _setTab(V2ConnectorsTab.installed),
      ),
    );
  }

  List<Widget> _installedRows(List<V2Connector> connectors) {
    final rows = <Widget>[
      for (final connector in connectors)
        Padding(
          padding: const EdgeInsets.only(bottom: OSpace.s),
          child: _InstalledRow(
            connector: connector,
            onTap: widget.onOpen == null
                ? null
                : () => widget.onOpen!(connector.id),
            onToggle: widget.onToggle == null
                ? null
                : (value) => widget.onToggle!(connector.id, value),
          ),
        ),
    ];
    if (rows.length <= 8) return [OStagger(children: rows)];
    return [OStagger(children: rows.take(8).toList()), ...rows.skip(8)];
  }

  List<Widget> _availableRows(List<V2Connector> connectors) {
    final rows = <Widget>[
      for (final connector in connectors)
        Padding(
          padding: const EdgeInsets.only(bottom: OSpace.s),
          child: _AvailableRow(
            connector: connector,
            onConnect: widget.onConnect == null
                ? null
                : () => widget.onConnect!(connector.id),
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

class _SegmentedTabs extends StatelessWidget {
  const _SegmentedTabs({
    required this.tab,
    required this.installedCount,
    required this.availableCount,
    required this.onChanged,
  });

  final V2ConnectorsTab tab;
  final int installedCount;
  final int availableCount;
  final ValueChanged<V2ConnectorsTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          _Segment(
            label: 'Installed',
            count: installedCount,
            selected: tab == V2ConnectorsTab.installed,
            onTap: () => onChanged(V2ConnectorsTab.installed),
          ),
          _Segment(
            label: 'Available',
            count: availableCount,
            selected: tab == V2ConnectorsTab.available,
            onTap: () => onChanged(V2ConnectorsTab.available),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // At large text the label and its count no longer fit side by side in half
    // a 320 dp screen, so they stack and the bar grows instead of clipping.
    final stacked = _stacksActions(context);
    final labelText = Text(
      label,
      maxLines: stacked ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: OType.label.copyWith(color: selected ? c.text : c.textMuted),
    );
    final countBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? c.accentSoft : c.surface,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        '$count',
        maxLines: 1,
        style: OType.caption.copyWith(
          color: selected ? c.accent : c.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return Expanded(
      child: OPressable(
        onTap: onTap,
        semanticLabel: '$label, $count',
        child: Semantics(
          selected: selected,
          child: ExcludeSemantics(
            child: AnimatedContainer(
              duration: OMotion.fast,
              curve: OMotion.standard,
              constraints: const BoxConstraints(minHeight: OSpace.touch),
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.s,
                vertical: OSpace.xs,
              ),
              decoration: BoxDecoration(
                color: selected ? c.surface : c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.pill),
                border: Border.all(
                  color: selected ? c.hairline : c.surfaceAlt,
                ),
              ),
              child: stacked
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        labelText,
                        const SizedBox(height: 2),
                        countBadge,
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(child: labelText),
                        const SizedBox(width: OSpace.xs),
                        countBadge,
                      ],
                    ),
            ),
          ),
        ),
      ),
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

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel: '$label category',
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

class _InstalledRow extends StatelessWidget {
  const _InstalledRow({required this.connector, this.onTap, this.onToggle});

  final V2Connector connector;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.m,
      ),
      // The tap target is the text block rather than the whole card: OCard's
      // tappable form excludes its subtree from semantics, which would hide the
      // switch from screen readers.
      child: Row(
        children: [
          Expanded(
            child: OPressable(
              onTap: onTap,
              semanticLabel: '${connector.name}, ${connector.description}',
              // The label above replaces the raw text nodes, so a reader hears
              // the row once instead of once per line.
              child: ExcludeSemantics(
                child: Row(
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
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.bodyStrong.copyWith(color: c.text),
                              ),
                              OPill(
                                label: connector.enabled
                                    ? 'Connected'
                                    : 'Paused',
                                tone: connector.enabled
                                    ? OPillTone.success
                                    : OPillTone.neutral,
                                dot: connector.enabled,
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            connector.description,
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
          MergeSemantics(
            child: Semantics(
              label: '${connector.name} connector',
              child: SizedBox(
                height: OSpace.touch,
                child: Switch(value: connector.enabled, onChanged: onToggle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailableRow extends StatelessWidget {
  const _AvailableRow({required this.connector, this.onConnect});

  final V2Connector connector;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final details = Row(
      children: [
        _ConnectorIcon(icon: connector.icon),
        const SizedBox(width: OSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                connector.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.bodyStrong.copyWith(color: c.text),
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
    );
    final stacked = _stacksActions(context);
    final button = OButton(
      label: 'Connect',
      semanticLabel: 'Connect ${connector.name}',
      icon: Icons.add_rounded,
      variant: OButtonVariant.secondary,
      onPressed: onConnect,
      expand: stacked,
    );
    const padding = EdgeInsets.symmetric(
      horizontal: OSpace.m,
      vertical: OSpace.m,
    );
    // At large text the button no longer fits beside the description, so it
    // takes its own full-width line instead of squeezing the text away.
    if (stacked) {
      return OCard(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            details,
            const SizedBox(height: OSpace.m),
            button,
          ],
        ),
      );
    }
    return OCard(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: details),
          const SizedBox(width: OSpace.m),
          button,
        ],
      ),
    );
  }
}

class _PopularGrid extends StatelessWidget {
  const _PopularGrid({required this.connectors, this.onConnect});

  final List<V2Connector> connectors;
  final ValueChanged<String>? onConnect;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: connectors.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 220,
        crossAxisSpacing: OSpace.m,
        mainAxisSpacing: OSpace.m,
      ),
      itemBuilder: (context, index) {
        final connector = connectors[index];
        return _PopularCard(
          connector: connector,
          onConnect: onConnect == null ? null : () => onConnect!(connector.id),
        );
      },
    );
  }
}

class _PopularCard extends StatelessWidget {
  const _PopularCard({required this.connector, this.onConnect});

  final V2Connector connector;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ConnectorIcon(icon: connector.icon, size: 36),
          const SizedBox(height: OSpace.s),
          Text(
            connector.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.bodyStrong.copyWith(color: c.text),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: Text(
              connector.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: 'Connect',
            semanticLabel: 'Connect ${connector.name}',
            icon: Icons.add_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: onConnect,
          ),
        ],
      ),
    );
  }
}

class _ConnectorIcon extends StatelessWidget {
  const _ConnectorIcon({required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
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
          child: Text(
            note,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
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
