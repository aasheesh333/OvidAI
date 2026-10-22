// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
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
    this.searchHint = 'Search',
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
    return OScreen(
      title: 'Search settings',
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
                    semanticLabel: 'Clear search',
                    tooltip: 'Clear search',
                    onPressed: _clearSearch,
                  ),
          ),
          const SizedBox(height: OSpace.m),
          Expanded(child: _buildBody(context)),
        ],
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
      message: 'Settings appear when your account is ready.',
      action: widget.onRetry == null
          ? null
          : OButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              onPressed: widget.onRetry,
            ),
    );
  }

  /// Empty query: show the sections as chips, so a person can reach results
  /// without typing anything.
  Widget _browse(BuildContext context) {
    final sections = widget.data.sections
        .where((section) => section.items.isNotEmpty)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      children: [
        const OSectionTitle(title: 'Sections'),
        Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          children: [
            for (final section in sections)
              OChip(
                label: section.title,
                onTap: () => _setQuery(section.title),
              ),
          ],
        ),
      ],
    );
  }

  Widget _results(BuildContext context) {
    final query = _query.trim();
    final groups = widget.data.groups(query);
    if (groups.isEmpty) {
      return OEmptyState(
        icon: Icons.search_off_rounded,
        title: 'No settings found',
        message: 'Nothing matches “$query”.',
        action: OButton(
          label: 'Clear search',
          variant: OButtonVariant.secondary,
          onPressed: _clearSearch,
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final c = OColors.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OSectionTitle(title: group.sectionTitle),
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (
                    var row = 0;
                    row < group.results.length;
                    row++
                  ) ...[
                    if (row > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: 64,
                        color: c.hairline,
                      ),
                    _ResultRow(
                      result: group.results[row],
                      actionable: _canActivate(group.results[row].item),
                      onTap: () => _open(group.results[row]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.actionable,
    required this.onTap,
  });

  final V2SettingsSearchResult result;
  final bool actionable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = result.item;
    return OListRow(
      key: ValueKey<String>('search-result-${item.id}'),
      icon: item.icon,
      title: item.label,
      danger: item.danger,
      enabled: actionable,
      showChevron: actionable,
      onTap: actionable ? onTap : null,
    );
  }
}
