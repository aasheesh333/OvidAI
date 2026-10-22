// TODO(l10n): move the filter bar's copy to the ARB files in the localization pass.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// The type families the library filter bar exposes.
///
/// [page] covers HTML and rendered pages, [doc] covers documents and PDFs, and
/// [other] catches anything the four named families do not describe.
enum V2ArtifactTypeFilter { all, image, page, code, doc, other }

extension V2ArtifactTypeFilterX on V2ArtifactTypeFilter {
  String get label => switch (this) {
    V2ArtifactTypeFilter.all => 'All',
    V2ArtifactTypeFilter.image => 'Image',
    V2ArtifactTypeFilter.page => 'Page',
    V2ArtifactTypeFilter.code => 'Code',
    V2ArtifactTypeFilter.doc => 'Doc',
    V2ArtifactTypeFilter.other => 'Other',
  };

  IconData get icon => switch (this) {
    V2ArtifactTypeFilter.all => Icons.apps_rounded,
    V2ArtifactTypeFilter.image => Icons.image_rounded,
    V2ArtifactTypeFilter.page => Icons.web_rounded,
    V2ArtifactTypeFilter.code => Icons.code_rounded,
    V2ArtifactTypeFilter.doc => Icons.description_rounded,
    V2ArtifactTypeFilter.other => Icons.category_rounded,
  };
}

/// When an artifact was added. The page applies it against the library's
/// injectable clock, so a preview or a test never depends on wall time.
enum V2ArtifactDateFilter { all, today, week, month }

extension V2ArtifactDateFilterX on V2ArtifactDateFilter {
  String get label => switch (this) {
    V2ArtifactDateFilter.all => 'Any time',
    V2ArtifactDateFilter.today => 'Today',
    V2ArtifactDateFilter.week => 'Last 7 days',
    V2ArtifactDateFilter.month => 'Last 30 days',
  };

  String get description => switch (this) {
    V2ArtifactDateFilter.all => 'Every date',
    V2ArtifactDateFilter.today => 'Added since midnight',
    V2ArtifactDateFilter.week => 'Added in the last week',
    V2ArtifactDateFilter.month => 'Added in the last 30 days',
  };

  IconData get icon => switch (this) {
    V2ArtifactDateFilter.all => Icons.event_available_outlined,
    V2ArtifactDateFilter.today => Icons.today_rounded,
    V2ArtifactDateFilter.week => Icons.date_range_rounded,
    V2ArtifactDateFilter.month => Icons.calendar_month_rounded,
  };
}

/// Where an artifact came from. [all] keeps generated and uploaded files.
enum V2ArtifactSourceFilter { all, generated, uploaded }

extension V2ArtifactSourceFilterX on V2ArtifactSourceFilter {
  String get label => switch (this) {
    V2ArtifactSourceFilter.all => 'Any source',
    V2ArtifactSourceFilter.generated => 'Generated',
    V2ArtifactSourceFilter.uploaded => 'Uploaded',
  };

  String get description => switch (this) {
    V2ArtifactSourceFilter.all => 'Generated and uploaded',
    V2ArtifactSourceFilter.generated => 'Made by Ovid',
    V2ArtifactSourceFilter.uploaded => 'Added by you',
  };

  IconData get icon => switch (this) {
    V2ArtifactSourceFilter.all => Icons.filter_alt_outlined,
    V2ArtifactSourceFilter.generated => Icons.auto_awesome_rounded,
    V2ArtifactSourceFilter.uploaded => Icons.upload_rounded,
  };
}

/// Ordering options for the artifact grid.
enum V2ArtifactSort { newest, oldest, largest, name }

extension V2ArtifactSortX on V2ArtifactSort {
  String get label => switch (this) {
    V2ArtifactSort.newest => 'Newest first',
    V2ArtifactSort.oldest => 'Oldest first',
    V2ArtifactSort.largest => 'Largest first',
    V2ArtifactSort.name => 'Name A–Z',
  };

  String get description => switch (this) {
    V2ArtifactSort.newest => 'Most recent at the top',
    V2ArtifactSort.oldest => 'Earliest first',
    V2ArtifactSort.largest => 'Biggest files first',
    V2ArtifactSort.name => 'Alphabetical by file name',
  };

  IconData get icon => switch (this) {
    V2ArtifactSort.newest => Icons.schedule_rounded,
    V2ArtifactSort.oldest => Icons.history_rounded,
    V2ArtifactSort.largest => Icons.data_usage_rounded,
    V2ArtifactSort.name => Icons.sort_by_alpha_rounded,
  };
}

/// A chat or run that produced artifacts, shown in the session filter sheet.
@immutable
class V2ArtifactSession {
  const V2ArtifactSession({
    required this.id,
    required this.title,
    this.count = 0,
  }) : assert(id != '', 'A session filter option needs an id');

  final String id;
  final String title;

  /// Number of artifacts that belong to this session, when known.
  final int count;

  /// `12 files` when a count was supplied, otherwise null so the row stays
  /// compact.
  String? get countLabel {
    if (count <= 0) return null;
    return '$count ${count == 1 ? 'file' : 'files'}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is V2ArtifactSession &&
          other.id == id &&
          other.title == title &&
          other.count == count;

  @override
  int get hashCode => Object.hash(id, title, count);
}

const Object _unsetFilterValue = Object();

/// Sheet result that means "every session". Kept out of the id space.
const String _allSessionsValue = '__all_sessions__';

/// The full filter state owned by the wiring layer.
///
/// The bar never mutates this directly; it reports the next state through
/// [ArtifactFilterBar.onChanged] so the page can re-query or re-sort.
@immutable
class V2ArtifactFilters {
  const V2ArtifactFilters({
    this.type = V2ArtifactTypeFilter.all,
    this.source = V2ArtifactSourceFilter.all,
    this.date = V2ArtifactDateFilter.all,
    this.sessionId,
    this.sort = V2ArtifactSort.newest,
  });

  final V2ArtifactTypeFilter type;
  final V2ArtifactSourceFilter source;

  /// When the artifact was added. The page resolves it against its clock.
  final V2ArtifactDateFilter date;

  /// `null` means every session, including uploads with no session.
  final String? sessionId;
  final V2ArtifactSort sort;

  /// True when anything differs from the defaults, so the bar can offer Clear.
  bool get isActive =>
      type != V2ArtifactTypeFilter.all ||
      source != V2ArtifactSourceFilter.all ||
      date != V2ArtifactDateFilter.all ||
      sessionId != null ||
      sort != V2ArtifactSort.newest;

  /// Copies the state. Pass `sessionId: null` explicitly to clear the session.
  V2ArtifactFilters copyWith({
    V2ArtifactTypeFilter? type,
    V2ArtifactSourceFilter? source,
    V2ArtifactDateFilter? date,
    V2ArtifactSort? sort,
    Object? sessionId = _unsetFilterValue,
  }) {
    return V2ArtifactFilters(
      type: type ?? this.type,
      source: source ?? this.source,
      date: date ?? this.date,
      sort: sort ?? this.sort,
      sessionId: identical(sessionId, _unsetFilterValue)
          ? this.sessionId
          : sessionId as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is V2ArtifactFilters &&
          other.type == type &&
          other.source == source &&
          other.date == date &&
          other.sessionId == sessionId &&
          other.sort == sort;

  @override
  int get hashCode => Object.hash(type, source, date, sessionId, sort);
}

/// Size and count line shown under the controls.
///
/// The library page passes the totals it already knows; the bar formats them.
@immutable
class V2ArtifactSizeSummary {
  const V2ArtifactSizeSummary({
    this.totalBytes = 0,
    this.totalCount = 0,
    this.visibleCount,
    this.sizeLabel,
    this.storageLimitLabel,
  }) : assert(totalBytes >= 0),
       assert(totalCount >= 0),
       assert(visibleCount == null || visibleCount >= 0);

  /// Total stored bytes for the whole library. Ignored when [sizeLabel] is
  /// supplied.
  final int totalBytes;
  final int totalCount;

  /// How many artifacts match the filters. Null means "all of them".
  final int? visibleCount;

  /// Pre-formatted total from the wiring layer, for example `2.4 MB`.
  final String? sizeLabel;

  /// Optional plan storage limit, for example `3 GB`.
  final String? storageLimitLabel;

  int get shownCount => visibleCount ?? totalCount;

  bool get isFiltered => shownCount != totalCount;

  String get resolvedSizeLabel => sizeLabel ?? formatArtifactBytes(totalBytes);

  /// `1 of 4 files · 2.4 MB of 3 GB`, degrading gracefully when size or count
  /// is unknown.
  String get text {
    final files = totalCount == 1 ? '1 file' : '$totalCount files';
    final scope = isFiltered ? '$shownCount of $files' : files;
    final size = resolvedSizeLabel;
    if (size.isEmpty) return scope;
    final limit = storageLimitLabel;
    if (limit == null || limit.isEmpty) return '$scope · $size';
    return '$scope · $size of $limit';
  }
}

/// Formats a byte count for the size summary. Zero or negative bytes return an
/// empty string so the summary can hide the size instead of saying `0 B`.
String formatArtifactBytes(int bytes) {
  if (bytes <= 0) return '';
  const kilo = 1024;
  if (bytes < kilo) return '$bytes B';
  final kb = bytes / kilo;
  if (kb < kilo) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / kilo;
  if (mb < kilo) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / kilo;
  return '${gb.toStringAsFixed(1)} GB';
}

/// Filter bar for the artifacts library: type chips, source, session, sort and
/// a size summary.
///
/// Presentational and controlled: [filters] is the single source of truth and
/// every change is reported through [onChanged]. Session and sort choices open
/// the shared bottom sheet; the sheet never mutates state by itself.
class ArtifactFilterBar extends StatelessWidget {
  const ArtifactFilterBar({
    super.key,
    required this.filters,
    required this.summary,
    this.sessions = const <V2ArtifactSession>[],
    this.onChanged,
    this.enabled = true,
  });

  final V2ArtifactFilters filters;
  final V2ArtifactSizeSummary summary;
  final List<V2ArtifactSession> sessions;
  final ValueChanged<V2ArtifactFilters>? onChanged;

  /// False while the library is loading, so the controls announce as disabled.
  final bool enabled;

  bool get _interactive => enabled && onChanged != null;

  V2ArtifactSession? get _selectedSession {
    final id = filters.sessionId;
    if (id == null) return null;
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  String get _sessionLabel {
    if (filters.sessionId == null) return 'All sessions';
    return _selectedSession?.title ?? 'Session';
  }

  void _change(V2ArtifactFilters next) {
    if (!_interactive || next == filters) return;
    onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      label: 'Artifact filters',
      enabled: enabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _typeChips(),
          const SizedBox(height: OSpace.s),
          _controls(context),
          const SizedBox(height: OSpace.s),
          _summaryRow(c),
        ],
      ),
    );
  }

  Widget _typeChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final type in V2ArtifactTypeFilter.values) ...[
            OChip(
              key: ValueKey<String>('artifact-type-${type.name}'),
              label: type.label,
              icon: type.icon,
              selected: filters.type == type,
              onTap: _interactive
                  ? () => _change(filters.copyWith(type: type))
                  : null,
            ),
            if (type != V2ArtifactTypeFilter.values.last)
              const SizedBox(width: OSpace.s),
          ],
        ],
      ),
    );
  }

  Widget _controls(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        return Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          children: [
            _FilterButton(
              key: const ValueKey<String>('artifact-filter-source'),
              icon: filters.source.icon,
              label: filters.source.label,
              semanticLabel: 'Source: ${filters.source.label}',
              hint: 'Opens the source filter',
              selected: filters.source != V2ArtifactSourceFilter.all,
              maxWidth: maxWidth,
              onTap: _interactive ? () => _pickSource(context) : null,
            ),
            _FilterButton(
              key: const ValueKey<String>('artifact-filter-session'),
              icon: Icons.chat_bubble_outline_rounded,
              label: _sessionLabel,
              semanticLabel: 'Session: $_sessionLabel',
              hint: 'Opens the session filter',
              selected: filters.sessionId != null,
              maxWidth: maxWidth,
              onTap: _interactive ? () => _pickSession(context) : null,
            ),
            _FilterButton(
              key: const ValueKey<String>('artifact-filter-date'),
              icon: filters.date.icon,
              label: filters.date.label,
              semanticLabel: 'Added: ${filters.date.label}',
              hint: 'Opens the date filter',
              selected: filters.date != V2ArtifactDateFilter.all,
              maxWidth: maxWidth,
              onTap: _interactive ? () => _pickDate(context) : null,
            ),
            _FilterButton(
              key: const ValueKey<String>('artifact-filter-sort'),
              icon: filters.sort.icon,
              label: filters.sort.label,
              semanticLabel: 'Sort: ${filters.sort.label}',
              hint: 'Opens the sort options',
              selected: filters.sort != V2ArtifactSort.newest,
              maxWidth: maxWidth,
              onTap: _interactive ? () => _pickSort(context) : null,
            ),
          ],
        );
      },
    );
  }

  Widget _summaryRow(OColors c) {
    return Row(
      children: [
        Icon(Icons.data_usage_rounded, size: 15, color: c.textMuted),
        const SizedBox(width: OSpace.xs),
        Expanded(
          child: Semantics(
            container: true,
            liveRegion: true,
            label: 'Size summary: ${summary.text}',
            child: ExcludeSemantics(
              child: Text(
                summary.text,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ),
        ),
        if (_interactive && filters.isActive)
          OButton(
            key: const ValueKey<String>('artifact-filter-clear'),
            label: 'Clear',
            variant: OButtonVariant.ghost,
            semanticLabel: 'Clear filters',
            onPressed: _interactive
                ? () => _change(const V2ArtifactFilters())
                : null,
          ),
      ],
    );
  }

  Future<void> _pickSource(BuildContext context) async {
    final picked = await showOSheet<V2ArtifactSourceFilter>(
      context,
      title: 'Source',
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: OSpace.l),
        children: [
          for (final source in V2ArtifactSourceFilter.values)
            OListRow(
              title: source.label,
              subtitle: source.description,
              icon: source.icon,
              showChevron: false,
              trailing: source == filters.source ? _check(sheetContext) : null,
              onTap: () => Navigator.of(sheetContext).pop(source),
            ),
        ],
      ),
    );
    if (!context.mounted || picked == null) return;
    _change(filters.copyWith(source: picked));
  }

  Future<void> _pickSession(BuildContext context) async {
    final picked = await showOSheet<String>(
      context,
      title: 'Session',
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: OSpace.l),
        children: [
          OListRow(
            title: 'All sessions',
            subtitle: 'Every chat and upload',
            icon: Icons.forum_outlined,
            showChevron: false,
            trailing: filters.sessionId == null ? _check(sheetContext) : null,
            onTap: () => Navigator.of(sheetContext).pop(_allSessionsValue),
          ),
          for (final session in sessions)
            OListRow(
              title: session.title,
              subtitle: session.countLabel,
              icon: Icons.chat_bubble_outline_rounded,
              showChevron: false,
              trailing: session.id == filters.sessionId
                  ? _check(sheetContext)
                  : null,
              onTap: () => Navigator.of(sheetContext).pop(session.id),
            ),
        ],
      ),
    );
    if (!context.mounted || picked == null) return;
    _change(
      filters.copyWith(sessionId: picked == _allSessionsValue ? null : picked),
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showOSheet<V2ArtifactDateFilter>(
      context,
      title: 'Added',
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: OSpace.l),
        children: [
          for (final date in V2ArtifactDateFilter.values)
            OListRow(
              title: date.label,
              subtitle: date.description,
              icon: date.icon,
              showChevron: false,
              trailing: date == filters.date ? _check(sheetContext) : null,
              onTap: () => Navigator.of(sheetContext).pop(date),
            ),
        ],
      ),
    );
    if (!context.mounted || picked == null) return;
    _change(filters.copyWith(date: picked));
  }

  Future<void> _pickSort(BuildContext context) async {
    final picked = await showOSheet<V2ArtifactSort>(
      context,
      title: 'Sort by',
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: OSpace.l),
        children: [
          for (final sort in V2ArtifactSort.values)
            OListRow(
              title: sort.label,
              subtitle: sort.description,
              icon: sort.icon,
              showChevron: false,
              trailing: sort == filters.sort ? _check(sheetContext) : null,
              onTap: () => Navigator.of(sheetContext).pop(sort),
            ),
        ],
      ),
    );
    if (!context.mounted || picked == null) return;
    _change(filters.copyWith(sort: picked));
  }

  Widget _check(BuildContext context) {
    return Icon(
      Icons.check_rounded,
      size: 20,
      color: OColors.of(context).accent,
    );
  }
}

/// Compact 48 dp trigger used for source, session and sort.
class _FilterButton extends StatelessWidget {
  const _FilterButton({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.hint,
    required this.selected,
    required this.maxWidth,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String semanticLabel;
  final String hint;
  final bool selected;
  final double maxWidth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onTap != null;
    final fg = selected ? c.accent : (enabled ? c.text : c.textFaint);
    final visual = Container(
      height: OSpace.touch,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: selected ? c.accentSoft : c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(
          color: selected ? c.accentFill.withValues(alpha: 0.5) : c.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.label.copyWith(
                color: fg,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.expand_more_rounded,
            size: 18,
            color: enabled ? c.textMuted : c.textFaint,
          ),
        ],
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Semantics(
        container: true,
        label: semanticLabel,
        hint: hint,
        button: true,
        enabled: enabled,
        selected: selected,
        onTap: onTap,
        child: ExcludeSemantics(
          child: OPressable(onTap: onTap, child: visual),
        ),
      ),
    );
  }
}
