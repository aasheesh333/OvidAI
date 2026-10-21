// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'settings_hub.dart';

/// The three states the settings search index can be in. A query with no
/// matches is an empty state inside [ready]; it is not a data error.
enum V2SettingsSearchStatus { loading, ready, error }

/// One hit from the settings index. The row keeps its owning section so a
/// result can say where it lives without re-reading the whole index.
@immutable
class V2SettingsSearchResult {
  const V2SettingsSearchResult({
    required this.sectionTitle,
    required this.item,
  });

  final String sectionTitle;
  final V2SettingsItem item;
}

/// Results grouped under their owning section, ready for rendering.
@immutable
class V2SettingsSearchGroup {
  const V2SettingsSearchGroup({
    required this.sectionTitle,
    required this.results,
  });

  final String sectionTitle;
  final List<V2SettingsSearchResult> results;
}

/// Everything the settings search page needs. The caller injects the same
/// sections the settings hub renders, so the index can never drift from the
/// rows a person can actually open.
@immutable
class V2SettingsSearchData {
  const V2SettingsSearchData({
    this.sections = const <V2SettingsSection>[],
    this.status = V2SettingsSearchStatus.ready,
    this.initialQuery = '',
    this.searchHint = 'Search sections and rows',
    this.errorMessage,
    this.canActivate,
  });

  /// Reuse the hub's sections verbatim. Loading and error states carry over;
  /// an empty hub becomes an empty index, which the page explains.
  factory V2SettingsSearchData.fromHub(V2SettingsHubData hub) {
    return V2SettingsSearchData(
      sections: <V2SettingsSection>[
        hub.account,
        hub.chat,
        hub.models,
        hub.dataControl,
        hub.advanced,
      ],
      status: switch (hub.status) {
        V2SettingsHubStatus.loading => V2SettingsSearchStatus.loading,
        V2SettingsHubStatus.error => V2SettingsSearchStatus.error,
        V2SettingsHubStatus.ready => V2SettingsSearchStatus.ready,
        V2SettingsHubStatus.empty => V2SettingsSearchStatus.ready,
      },
      errorMessage: hub.errorMessage,
      canActivate: (item) {
        if (!item.enabled) return false;
        // The hub owns the reasoning switch; it has no row `onTap`.
        if (item.id == 'show_reasoning') return hub.onReasoningChanged != null;
        return item.onTap != null;
      },
    );
  }

  final List<V2SettingsSection> sections;
  final V2SettingsSearchStatus status;
  final String initialQuery;
  final String searchHint;
  final String? errorMessage;

  /// Whether tapping [item] really does something. The hub passes its own
  /// resolver because a row can act without carrying an `onTap` (the reasoning
  /// switch). A result that cannot act is shown disabled, never as a tap that
  /// silently goes nowhere.
  final bool Function(V2SettingsItem item)? canActivate;

  /// True when the page can act on [item]: either the host handles results
  /// through `onResultTap`, or the row carries its own handler.
  bool isActionable(V2SettingsItem item, {required bool hasHostHandler}) {
    if (!item.enabled) return false;
    final resolver = canActivate;
    if (resolver != null) return resolver(item);
    return hasHostHandler || item.onTap != null;
  }

  /// True when the injected index has no rows at all, independent of a query.
  bool get isEmpty => !sections.any((section) => section.items.isNotEmpty);

  /// All rows that match [query] across section and row titles.
  ///
  /// * Matching is case-insensitive and ignores surrounding whitespace.
  /// * Matching a section title returns every row in that section.
  /// * Order follows the injected index, so the hub's canonical order wins.
  List<V2SettingsSearchResult> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <V2SettingsSearchResult>[];
    final results = <V2SettingsSearchResult>[];
    for (final section in sections) {
      if (section.items.isEmpty) continue;
      final sectionMatches = section.title.toLowerCase().contains(needle);
      for (final item in section.items) {
        final rowMatches = item.label.toLowerCase().contains(needle);
        if (sectionMatches || rowMatches) {
          results.add(
            V2SettingsSearchResult(sectionTitle: section.title, item: item),
          );
        }
      }
    }
    return results;
  }

  /// [search] results grouped by section in index order.
  List<V2SettingsSearchGroup> groups(String query) {
    final matches = search(query);
    if (matches.isEmpty) return const <V2SettingsSearchGroup>[];
    final bySection = <String, List<V2SettingsSearchResult>>{};
    for (final result in matches) {
      bySection.putIfAbsent(result.sectionTitle, () => []).add(result);
    }
    return <V2SettingsSearchGroup>[
      for (final entry in bySection.entries)
        V2SettingsSearchGroup(sectionTitle: entry.key, results: entry.value),
    ];
  }
}

/// Search across every settings section and row. Filtering happens locally on
/// [data]; tapping a result reports it through [onResultTap]. The page owns no
/// navigation, so the wiring layer decides whether to open the row's page.
class SettingsSearchPage extends StatefulWidget {
  const SettingsSearchPage({
    super.key,
    required this.data,
    this.onResultTap,
    this.onRetry,
  });

  final V2SettingsSearchData data;

  /// Called when a result is tapped. When null, the row's own `onTap` is used;
  /// when neither exists the row is announced as disabled.
  final ValueChanged<V2SettingsSearchResult>? onResultTap;
  final VoidCallback? onRetry;

  @override
  State<SettingsSearchPage> createState() => _SettingsSearchPageState();
}

class _SettingsSearchPageState extends State<SettingsSearchPage> {
  late final TextEditingController _controller;
  late String _query;

  @override
  void initState() {
    super.initState();
    _query = widget.data.initialQuery;
    _controller = TextEditingController(text: _query);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) => setState(() => _query = value);

  void _setQuery(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    setState(() => _query = value);
  }

  void _clearSearch() {
    _controller.clear();
    setState(() => _query = '');
  }

  void _open(V2SettingsSearchResult result) {
    if (!_canActivate(result.item)) return;
    // Results are tap targets; closing the keyboard first means the tap is
    // never eaten by an input connection and the destination starts clean.
    FocusManager.instance.primaryFocus?.unfocus();
    final callback = widget.onResultTap;
    if (callback != null) {
      callback(result);
    } else {
      result.item.onTap?.call();
    }
  }

  bool _canActivate(V2SettingsItem item) => widget.data.isActionable(
    item,
    hasHostHandler: widget.onResultTap != null,
  );

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Search settings'),
      body: OFadeSlide(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: OSpace.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: OSpace.s),
              OSearchField(
                controller: _controller,
                hint: widget.data.searchHint,
                autofocus: true,
                onChanged: _onChanged,
                trailing: _query.isEmpty
                    ? null
                    : OIconButton(
                        icon: Icons.close_rounded,
                        size: 18,
                        semanticLabel: 'Clear settings search',
                        tooltip: 'Clear settings search',
                        onPressed: _clearSearch,
                      ),
              ),
              const SizedBox(height: OSpace.m),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (widget.data.status) {
      case V2SettingsSearchStatus.loading:
        return Semantics(
          label: 'Loading settings search',
          child: const OSkeletonList(rows: 6),
        );
      case V2SettingsSearchStatus.error:
        return OErrorState(
          title: 'Settings search did not load',
          message:
              widget.data.errorMessage ??
              'Check your connection and try again.',
          onRetry: widget.onRetry,
        );
      case V2SettingsSearchStatus.ready:
        if (widget.data.isEmpty) return _emptyIndex();
        if (_query.trim().isEmpty) return _browse(context);
        return _results(context);
    }
  }

  Widget _emptyIndex() {
    return OEmptyState(
      icon: Icons.tune_rounded,
      title: 'No settings to search',
      message: 'Your settings will appear here when your account is ready.',
      action: OButton(
        label: 'Refresh settings',
        icon: Icons.refresh_rounded,
        onPressed: widget.onRetry,
      ),
    );
  }

  /// Empty query: show tappable section names, so a person can reach results
  /// without typing anything.
  Widget _browse(BuildContext context) {
    final c = OColors.of(context);
    final sections = widget.data.sections
        .where((section) => section.items.isNotEmpty)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      children: [
        Text(
          'Search sections and rows by name. Tap a section to see its '
          'settings, or type to filter.',
          style: OType.caption.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: OSpace.s),
        OSectionHeader(
          label: 'Browse settings',
          padding: const EdgeInsets.fromLTRB(0, OSpace.s, 0, OSpace.s),
        ),
        Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          children: [
            for (final section in sections)
              OChip(
                label: section.title,
                icon: Icons.search_rounded,
                onTap: () => _setQuery(section.title),
              ),
          ],
        ),
      ],
    );
  }

  Widget _results(BuildContext context) {
    final c = OColors.of(context);
    final query = _query.trim();
    final groups = widget.data.groups(query);
    if (groups.isEmpty) {
      return OEmptyState(
        icon: Icons.search_off_rounded,
        title: 'No settings found',
        message:
            'No section or row matches “$query”. Try another name, like '
            '“Account” or “Storage”.',
        action: OButton(
          label: 'Clear search',
          variant: OButtonVariant.secondary,
          onPressed: _clearSearch,
        ),
      );
    }

    final count = groups.fold<int>(
      0,
      (total, group) => total + group.results.length,
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            count == 1
                ? '1 result for “$query”'
                : '$count results for “$query”',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
        const SizedBox(height: OSpace.s),
        OStagger(
          children: [
            for (final group in groups)
              Padding(
                padding: const EdgeInsets.only(bottom: OSpace.m),
                child: _GroupCard(
                  group: group,
                  query: query,
                  onTap: _open,
                  canActivate: _canActivate,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.query,
    required this.onTap,
    required this.canActivate,
  });

  final V2SettingsSearchGroup group;
  final String query;
  final ValueChanged<V2SettingsSearchResult> onTap;
  final bool Function(V2SettingsItem item) canActivate;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final rows = <Widget>[];
    for (var index = 0; index < group.results.length; index++) {
      final result = group.results[index];
      rows.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ResultRow(
              result: result,
              query: query,
              actionable: canActivate(result.item),
              onTap: () => onTap(result),
            ),
            if (index != group.results.length - 1)
              Divider(height: 1, thickness: 1, indent: 64, color: c.hairline),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.xs, 0, OSpace.xs, OSpace.s),
          child: Row(
            children: [
              Expanded(
                child: _HighlightedText(
                  text: group.sectionTitle.toUpperCase(),
                  query: query,
                  style: OType.overline.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Text(
                group.results.length == 1
                    ? '1 row'
                    : '${group.results.length} rows',
                style: OType.caption.copyWith(color: c.textFaint),
              ),
            ],
          ),
        ),
        OCard(
          padding: EdgeInsets.zero,
          child: OStagger(children: rows),
        ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.query,
    required this.actionable,
    required this.onTap,
  });

  final V2SettingsSearchResult result;
  final String query;
  final bool actionable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final item = result.item;
    final fg = item.danger ? c.danger : c.text;
    final baseTitle = OType.body.copyWith(
      color: fg,
      fontWeight: FontWeight.w500,
    );
    final baseSubtitle = OType.caption.copyWith(color: c.textMuted);
    final enabled = actionable;
    return OPressable(
      onTap: enabled ? onTap : null,
      semanticLabel: [
        item.label,
        result.sectionTitle,
        if (!enabled) 'disabled',
      ].join(', '),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.listRow),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.l,
            vertical: OSpace.s,
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: item.danger
                      ? c.danger.withValues(alpha: 0.10)
                      : c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  item.icon,
                  size: 19,
                  color: item.danger ? c.danger : c.textMuted,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _HighlightedText(
                      text: item.label,
                      query: query,
                      style: enabled
                          ? baseTitle
                          : baseTitle.copyWith(color: c.textFaint),
                    ),
                    if (item.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: baseSubtitle,
                      ),
                    ],
                  ],
                ),
              ),
              if (enabled) ...[
                const SizedBox(width: OSpace.s),
                Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A single text run with every case-insensitive occurrence of [query]
/// highlighted. Section headers reuse it with their uppercase label.
class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.query,
    required this.style,
  });

  final String text;
  final String query;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final highlight = style.copyWith(
      color: c.accent,
      backgroundColor: c.accentSoft,
      fontWeight: FontWeight.w600,
    );
    return Text.rich(
      TextSpan(children: _spans(text, query, style, highlight)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

List<TextSpan> _spans(
  String text,
  String query,
  TextStyle base,
  TextStyle highlight,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || text.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: base)];
  }
  final lower = text.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final index = lower.indexOf(needle, start);
    if (index < 0) break;
    if (index > start) {
      spans.add(TextSpan(text: text.substring(start, index), style: base));
    }
    spans.add(
      TextSpan(
        text: text.substring(index, index + needle.length),
        style: highlight,
      ),
    );
    start = index + needle.length;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: base));
  }
  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: base));
  }
  return spans;
}
