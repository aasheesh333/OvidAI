// TODO(l10n): move the English copy in this screen to the ARB files.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'settings_rows.dart';
import 'settings_search.dart';

/// The four states every settings list can be in.
enum V2SettingsHubStatus { loading, ready, empty, error }

@immutable
class V2SettingsProfile {
  const V2SettingsProfile({
    required this.name,
    required this.email,
    this.planLabel = 'Free plan',
    this.initials,
    this.image,
  });

  final String name;
  final String email;
  final String planLabel;
  final String? initials;
  final ImageProvider? image;
}

@immutable
class V2SettingsItem {
  const V2SettingsItem({
    required this.id,
    required this.label,
    required this.icon,
    this.value,
    this.subtitle,
    this.onTap,
    this.danger = false,
    this.enabled = true,
  });

  final String id;
  final String label;
  final IconData icon;

  /// A real value shown at the end of the row ("Free plan", "3 GB", "On").
  ///
  /// Only values belong here. Explanations ("Theme, text size and motion")
  /// are not values: the minimal UI deletes them.
  final String? value;

  /// Legacy descriptive copy. Kept so older wiring layers still compile; the
  /// hub does not render it.
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;
  final bool enabled;
}

@immutable
class V2SettingsSection {
  const V2SettingsSection({required this.title, this.items = const []});

  final String title;
  final List<V2SettingsItem> items;
}

@immutable
class V2SettingsHubData {
  const V2SettingsHubData({
    this.status = V2SettingsHubStatus.ready,
    this.profile,
    this.storageLabel,
    this.account = const V2SettingsSection(title: 'Account'),
    this.chat = const V2SettingsSection(title: 'Chat'),
    this.models = const V2SettingsSection(title: 'Models'),
    this.dataControl = const V2SettingsSection(title: 'Data control'),
    this.advanced = const V2SettingsSection(title: 'Advanced'),
    this.showReasoning = true,
    this.onReasoningChanged,
    this.onAddConnector,
    this.onProfileTap,
    this.onSignOut,
    this.onRetry,
    this.errorMessage = 'We could not load your settings.',
  });

  final V2SettingsHubStatus status;
  final V2SettingsProfile? profile;

  /// The account's real storage figure ("1.2 of 3 GB"), supplied by the route
  /// that reads the quota. Null means the row shows no value; the hub never
  /// invents a number.
  final String? storageLabel;
  final V2SettingsSection account;
  final V2SettingsSection chat;
  final V2SettingsSection models;
  final V2SettingsSection dataControl;
  final V2SettingsSection advanced;
  final bool showReasoning;
  final ValueChanged<bool>? onReasoningChanged;

  /// Retained for hosts that still pass it. Adding a connector belongs to the
  /// Connectors page, so the hub row keeps a single action: open connectors.
  final VoidCallback? onAddConnector;
  final VoidCallback? onProfileTap;
  final VoidCallback? onSignOut;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Settings home: one header, one search action, at most five sections of
/// one-line rows. Rows only call the callbacks carried by [data]; the hub never
/// pushes another settings page. A row without a handler is removed rather
/// than rendered as a control that cannot act.
///
/// It owns two pieces of view state: which row search should reveal, and the
/// transient highlight that shows the person where that row landed.
class SettingsHubPage extends StatefulWidget {
  const SettingsHubPage({super.key, required this.data});

  final V2SettingsHubData data;

  @override
  State<SettingsHubPage> createState() => _SettingsHubPageState();
}

class _SettingsHubPageState extends State<SettingsHubPage> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  String? _highlightedId;
  Timer? _highlightTimer;

  V2SettingsHubData get data => widget.data;

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String id) =>
      _rowKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'settings-row-$id'));

  /// The handler a row really runs, ignoring whether the row is currently
  /// enabled. Null means the row has no destination at all.
  VoidCallback? _handlerFor(V2SettingsItem item) {
    if (item.id == 'show_reasoning') {
      final changed = data.onReasoningChanged;
      if (changed == null) return null;
      return () => changed(!data.showReasoning);
    }
    if (item.id == 'connectors') {
      // The connectors page is opened through the host's work routes; the
      // settings route table has no case for it. Prefer that handler so the
      // row cannot be a dead end.
      return data.onAddConnector ?? item.onTap;
    }
    return item.onTap;
  }

  /// The handler a row runs right now. A row the host has explicitly disabled
  /// stays visible but does nothing; a row with no handler at all is removed
  /// by [_visibleItems].
  VoidCallback? _rowTapFor(V2SettingsItem item) =>
      item.enabled ? _handlerFor(item) : null;

  /// Scrolls the row into view and flashes it, so a search result that lives
  /// on the hub (rather than on its own page) never "scrolls nowhere".
  Future<void> _revealRow(String id) async {
    final target = _rowKeys[id]?.currentContext;
    if (target == null) return;
    await Scrollable.ensureVisible(
      target,
      duration: OMove.reduced(context) ? Duration.zero : OMotion.medium,
      curve: OMotion.emphasized,
      alignment: 0.2,
    );
    if (!mounted) return;
    setState(() => _highlightedId = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  /// The one order every settings list uses.
  static const _canonicalOrder = <String, List<String>>{
    'account': ['account', 'plan_billing', 'usage', 'credentials'],
    'chat': [
      'appearance',
      'memory',
      'shared_memory',
      'memory_files',
      'show_reasoning',
    ],
    'models': ['connectors', 'agent_presets', 'response_wait_limit'],
    'data_control': [
      'export_import',
      'permissions',
      'crash_reports',
      'storage',
      'delete_data',
      'reset_memory',
    ],
    'advanced': ['notifications', 'app_lock', 'account_health', 'about'],
  };

  /// Older wiring layers use short row ids. They still land in the same slot
  /// instead of drifting to the end of their card.
  static const _rowAliases = <String, String>{
    'presets': 'agent_presets',
    'response_wait': 'response_wait_limit',
    'export': 'export_import',
    'crash': 'crash_reports',
    'delete': 'delete_data',
  };

  /// Memory, shared memory and memory files are one destination: the memory
  /// hub owns the switch, the shared flag and the files.
  static const _memoryRowIds = <String>{
    'memory',
    'shared_memory',
    'memory_files',
  };

  @override
  Widget build(BuildContext context) {
    final sections = _visibleSections();
    final hasContent =
        data.profile != null ||
        sections.any((section) => section.items.isNotEmpty);

    final Widget body;
    switch (data.status) {
      case V2SettingsHubStatus.loading:
        body = const OSkeletonList(rows: 8);
      case V2SettingsHubStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2SettingsHubStatus.empty:
        body = _emptyState();
      case V2SettingsHubStatus.ready:
        body = hasContent ? _content(sections) : _emptyState();
    }

    return OScreen(
      title: 'Settings',
      actions: [
        OIconButton(
          key: const ValueKey('settings-search'),
          icon: Icons.search_rounded,
          semanticLabel: 'Search settings',
          tooltip: 'Search settings',
          onPressed: () => _openSearch(context, sections),
        ),
      ],
      child: OFadeSlide(child: body),
    );
  }

  /// Opens the shared settings search over this hub's own (already ordered)
  /// sections, so the index can never drift from the rows on screen.
  Future<void> _openSearch(
    BuildContext context,
    List<V2SettingsSection> sections,
  ) {
    final status = switch (data.status) {
      V2SettingsHubStatus.loading => V2SettingsSearchStatus.loading,
      V2SettingsHubStatus.error => V2SettingsSearchStatus.error,
      V2SettingsHubStatus.ready ||
      V2SettingsHubStatus.empty => V2SettingsSearchStatus.ready,
    };
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => SettingsSearchPage(
          data: V2SettingsSearchData(
            sections: sections,
            status: status,
            errorMessage: data.errorMessage,
            // Only rows that really do something are offered as results.
            canActivate: (item) => _rowTapFor(item) != null,
          ),
          onResultTap: (result) async {
            final tap = _rowTapFor(result.item);
            if (tap == null) return;
            // Close search first: the row's handler navigates from the hub,
            // so it would otherwise push on top of the search page.
            await Navigator.of(routeContext).maybePop();
            if (!mounted) return;
            final hubLocal = result.item.id == 'show_reasoning';
            tap();
            if (hubLocal) await _revealRow(result.item.id);
          },
          onRetry: data.onRetry,
        ),
      ),
    );
  }

  /// At most five sections, in one order, with no row that cannot act.
  ///
  /// A row whose handler is missing is dropped: a settings row that cannot
  /// reach real state is a dead control, not a disabled one.
  List<V2SettingsSection> _visibleSections() {
    final sections = <V2SettingsSection>[
      _ordered('account', data.account),
      _ordered('chat', data.chat),
      _ordered('models', data.models),
      _ordered('data_control', data.dataControl),
      _ordered('advanced', data.advanced),
    ];
    final visible = <V2SettingsSection>[];
    for (final section in sections.take(_maxSections)) {
      final items = _visibleItems(section.items);
      final keepsProfile =
          data.profile != null && section.title == data.account.title;
      if (items.isEmpty && !keepsProfile) continue;
      visible.add(V2SettingsSection(title: section.title, items: items));
    }
    return visible;
  }

  static const int _maxSections = 5;

  List<V2SettingsItem> _visibleItems(List<V2SettingsItem> items) {
    final seen = <String>{};
    final visible = <V2SettingsItem>[];
    for (final item in _mergeMemoryRows(items)) {
      // No handler means no destination: remove the row entirely.
      if (_handlerFor(item) == null) continue;
      // One row per id: two copies would also collide on the reveal key.
      if (!seen.add(item.id)) continue;
      visible.add(_withValue(item));
    }
    return visible;
  }

  /// Fills a row's trailing value from real data the hub already owns.
  ///
  /// An explicit [V2SettingsItem.value] always wins. The plan name comes from
  /// the profile; the storage figure comes from [V2SettingsHubData.storageLabel].
  /// Nothing is substituted when a source is absent.
  V2SettingsItem _withValue(V2SettingsItem item) {
    final value =
        item.value ??
        switch (item.id) {
          'plan_billing' => data.profile?.planLabel,
          'storage' => data.storageLabel,
          _ => null,
        };
    if (value == null || value.trim().isEmpty || value == item.value) {
      return item;
    }
    return V2SettingsItem(
      id: item.id,
      label: item.label,
      icon: item.icon,
      value: value,
      subtitle: item.subtitle,
      onTap: item.onTap,
      danger: item.danger,
      enabled: item.enabled,
    );
  }

  /// Collapses memory, shared memory and memory files into one "Memory" row.
  ///
  /// The kept row is the memory hub when it exists; otherwise the first memory
  /// row is kept under its own label so a wiring layer that only exposes the
  /// files page still reaches it.
  List<V2SettingsItem> _mergeMemoryRows(List<V2SettingsItem> items) {
    final memory = <V2SettingsItem>[
      for (final item in items)
        if (_memoryRowIds.contains(item.id)) item,
    ];
    if (memory.length < 2) return items;

    final keep = memory.firstWhere(
      (item) => item.id == 'memory',
      orElse: () => memory.first,
    );
    VoidCallback? tap = keep.onTap;
    for (final item in memory) {
      tap ??= item.onTap;
    }
    final merged = V2SettingsItem(
      id: keep.id,
      label: keep.id == 'memory' ? 'Memory' : keep.label,
      icon: Icons.psychology_outlined,
      value: keep.value,
      onTap: tap,
      enabled: keep.enabled,
    );
    final result = <V2SettingsItem>[];
    var emitted = false;
    for (final item in items) {
      if (!_memoryRowIds.contains(item.id)) {
        result.add(item);
      } else if (!emitted) {
        result.add(merged);
        emitted = true;
      }
    }
    return result;
  }

  V2SettingsSection _ordered(String key, V2SettingsSection section) {
    final order = _canonicalOrder[key] ?? const <String>[];
    int rank(String id) {
      final canonical = _rowAliases[id] ?? id;
      final index = order.indexOf(canonical);
      return index == -1 ? order.length : index;
    }

    // Stable sort: rows that are not in the canonical list keep their order.
    final positions = List<int>.generate(section.items.length, (i) => i);
    positions.sort((a, b) {
      final byRank = rank(section.items[a].id);
      final against = rank(section.items[b].id);
      if (byRank != against) return byRank.compareTo(against);
      return a.compareTo(b);
    });
    return V2SettingsSection(
      title: section.title,
      items: [for (final index in positions) section.items[index]],
    );
  }

  Widget _emptyState() {
    return OEmptyState(
      icon: Icons.tune_rounded,
      title: 'No settings yet',
      message: 'Settings appear when your account is ready.',
      // No retry callback means there is nothing to retry: do not offer a
      // button that cannot do anything.
      action: data.onRetry == null
          ? null
          : OButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              onPressed: data.onRetry,
            ),
    );
  }

  Widget _content(List<V2SettingsSection> sections) {
    final groups = <Widget>[
      for (final section in sections)
        if (section.items.isNotEmpty ||
            (data.profile != null && section.title == data.account.title))
          _SectionGroup(
            section: section,
            profile: section.title == data.account.title ? data.profile : null,
            onProfileTap: data.onProfileTap,
            showReasoning: data.showReasoning,
            onReasoningChanged: data.onReasoningChanged,
            tapFor: _rowTapFor,
            keyFor: _keyFor,
            highlightedId: _highlightedId,
          ),
    ];

    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...groups,
          if (data.onSignOut != null)
            Padding(
              padding: const EdgeInsets.only(top: OSpace.xl),
              child: OButton(
                label: 'Sign out',
                icon: Icons.logout_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: data.onSignOut,
              ),
            ),
        ],
      ),
    );
  }
}

/// One section: a short heading and its one-line rows on the page background.
/// The account section leads with the profile row instead of repeating it as
/// a destination.
class _SectionGroup extends StatelessWidget {
  const _SectionGroup({
    required this.section,
    required this.profile,
    required this.onProfileTap,
    required this.showReasoning,
    required this.onReasoningChanged,
    required this.tapFor,
    required this.keyFor,
    required this.highlightedId,
  });

  final V2SettingsSection section;
  final V2SettingsProfile? profile;
  final VoidCallback? onProfileTap;
  final bool showReasoning;
  final ValueChanged<bool>? onReasoningChanged;
  final VoidCallback? Function(V2SettingsItem item) tapFor;
  final GlobalKey Function(String id) keyFor;
  final String? highlightedId;

  @override
  Widget build(BuildContext context) {
    final items = profile == null
        ? section.items
        : section.items.where((item) => item.id != 'account').toList();
    final rows = <Widget>[
      if (profile != null) _ProfileRow(profile: profile!, onTap: onProfileTap),
      for (final item in items)
        _SettingsRow(
          key: keyFor(item.id),
          item: item,
          tap: tapFor(item),
          trailing: _trailing(item),
          highlighted: highlightedId == item.id,
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OSectionTitle(title: section.title),
        V2SettingsRowList(rows: rows),
      ],
    );
  }

  Widget? _trailing(V2SettingsItem item) {
    if (item.id != 'show_reasoning') return null;
    return _ReasoningToggle(
      value: showReasoning,
      onChanged: item.enabled ? onReasoningChanged : null,
    );
  }
}

/// Avatar + name + plan pill. One line on a phone; the pill drops under the
/// name when the text scale would squeeze the name to nothing.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.profile, required this.onTap});

  final V2SettingsProfile profile;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 20;
    final pill = OPill(label: profile.planLabel, tone: OPillTone.accent);
    final name = Text(
      profile.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.body.copyWith(color: c.text, fontWeight: FontWeight.w600),
    );
    // The row's own label already carries the name and the plan, so the
    // visible copies are decoration for a screen reader.
    final identity = ExcludeSemantics(
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                name,
                const SizedBox(height: OSpace.xs),
                Align(alignment: Alignment.centerLeft, child: pill),
              ],
            )
          : name,
    );
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Row(
          children: [
            OAvatar(
              initials: profile.initials ?? profile.name,
              image: profile.image,
              size: v2SettingsTileSize,
              semanticLabel: '${profile.name} profile photo',
            ),
            const SizedBox(width: OSpace.m),
            Expanded(child: identity),
            if (!stacked) ...[
              const SizedBox(width: OSpace.s),
              ExcludeSemantics(child: pill),
            ],
            if (onTap != null) ...[
              const SizedBox(width: OSpace.s),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
            ],
          ],
        ),
      ),
    );
    final label = '${profile.name}, ${profile.planLabel}';
    if (onTap == null) {
      // Identity, not a control: never announce a disabled button for a
      // profile the host has not wired a destination for. One node carries
      // the name and plan; the avatar is decoration next to it.
      return Semantics(
        container: true,
        label: label,
        excludeSemantics: true,
        child: content,
      );
    }
    return OPressable(onTap: onTap, semanticLabel: label, child: content);
  }
}

/// One line: icon, title, optional value. Descriptive subtitles are gone.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.item,
    required this.tap,
    required this.trailing,
    required this.highlighted,
  });

  final V2SettingsItem item;
  final VoidCallback? tap;
  final Widget? trailing;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final value = item.value;
    final fg = item.danger ? c.danger : (tap == null ? c.textFaint : c.text);

    return AnimatedContainer(
      duration: OMove.reduced(context) ? Duration.zero : OMotion.base,
      color: highlighted ? c.accentSoft : null,
      child: OPressable(
        key: ValueKey<String>('settings-row-${item.id}'),
        onTap: tap,
        semanticLabel: value == null ? item.label : '${item.label}, $value',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.listRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: OSpace.m),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // One line, always: the value gets a share of the row and
                // ellipsizes before the title is squeezed to nothing.
                final valueMax = (constraints.maxWidth * 0.38).clamp(
                  72.0,
                  160.0,
                );
                return Row(
                  children: [
                    V2SettingsTile(icon: item.icon, danger: item.danger),
                    const SizedBox(width: OSpace.m),
                    Expanded(
                      // The row's semantic label already carries the title
                      // and its value; leaving the Texts in the tree makes
                      // TalkBack read the row twice.
                      child: ExcludeSemantics(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.body.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (value != null) ...[
                      const SizedBox(width: OSpace.s),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: valueMax),
                        child: ExcludeSemantics(
                          child: Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ),
                      ),
                    ],
                    if (trailing != null) ...[
                      const SizedBox(width: OSpace.s),
                      trailing!,
                    ] else if (tap != null)
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: c.textFaint,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ReasoningToggle extends StatelessWidget {
  const _ReasoningToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: 'Show reasoning',
      toggled: value,
      enabled: onChanged != null,
      child: SizedBox(
        width: 52,
        height: OSpace.touch,
        child: Center(
          child: Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: c.onAccent,
            activeTrackColor: c.accentFill,
            inactiveThumbColor: c.textMuted,
            inactiveTrackColor: c.surfaceRaised,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ),
    );
  }
}
