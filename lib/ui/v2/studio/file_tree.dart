// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// What the file tree is doing right now.
enum V2FileTreeStatus { loading, content, empty, error }

/// The kind of working-tree change attached to a file.
enum V2FileChange {
  added('A', 'added'),
  modified('M', 'modified'),
  removed('D', 'removed');

  const V2FileChange(this.badge, this.semanticLabel);

  /// Compact badge letter shown at the end of the row.
  final String badge;

  /// Spoken form, used in the row's semantic label.
  final String semanticLabel;
}

/// One folder or file in a workspace tree.
///
/// [path] is the full workspace path and should be unique across the tree; it
/// is also the stable id used for expansion. A node without a path falls back
/// to [name], which is only safe for flat test fixtures.
@immutable
class V2FileTreeEntry {
  const V2FileTreeEntry({
    required this.name,
    this.path,
    this.isFolder = false,
    this.children = const <V2FileTreeEntry>[],
    this.change,
  });

  final String name;
  final String? path;
  final bool isFolder;
  final List<V2FileTreeEntry> children;

  /// Set for changed files. Folders aggregate their descendants instead.
  final V2FileChange? change;

  /// Stable identity for expansion and test keys.
  String get id => path ?? name;

  /// Only a folder that actually has children can be expanded. An empty folder
  /// (or a folder whose children have not arrived) must not show a chevron,
  /// because tapping it would reveal nothing.
  bool get canExpand => isFolder && children.isNotEmpty;

  bool get isChanged => change != null;

  /// Lower-case extension without the leading dot, or an empty string.
  ///
  /// Dotfiles such as `.env` keep their whole name (`env`), which lets the
  /// language mapping recognise them as configuration.
  String get extension {
    final dot = name.lastIndexOf('.');
    if (dot == -1 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}

/// Immutable snapshot for [V2FileTree].
@immutable
class V2FileTreeData {
  const V2FileTreeData({
    this.status = V2FileTreeStatus.content,
    this.nodes = const <V2FileTreeEntry>[],
    this.selectedPath,
    this.expandedPaths = const <String>{},
    this.initialQuery = '',
    this.searchHint = 'Search files',
    this.emptyTitle = 'No files yet',
    this.emptyMessage = 'Files in this branch will appear here.',
    this.errorMessage,
  });

  final V2FileTreeStatus status;
  final List<V2FileTreeEntry> nodes;

  /// The file currently open in the editor; its ancestor folders are expanded
  /// automatically so the selection is always visible.
  final String? selectedPath;

  /// Folders expanded on first paint. Expansion after that is local UI state.
  final Set<String> expandedPaths;

  /// Seeds the search field (deep links, restored state).
  final String initialQuery;

  final String searchHint;
  final String emptyTitle;
  final String emptyMessage;
  final String? errorMessage;

  /// Files below [nodes], used for the explorer's count.
  int get fileCount => _countFiles(nodes);

  /// Changed files below [nodes].
  int get changedFileCount => _countChanged(nodes);
}

/// A searchable, expandable workspace file tree.
///
/// The widget is presentational: data and callbacks are injected. It renders a
/// plain [Column] rather than owning a scroll view, so it works both inside a
/// page scroll view and inside a bounded explorer panel.
///
/// Search is keyboard-free by design: the field never autofocuses, filtering
/// happens on every character, and tapping a row dismisses the keyboard. While
/// a query is active every matching branch is revealed, so results are visible
/// without arrow keys. Tapping a folder in that state clears the query and
/// reveals the folder in its normal tree position.
class V2FileTree extends StatefulWidget {
  const V2FileTree({
    super.key,
    required this.data,
    this.onSelectFile,
    this.onRetry,
    this.onRefresh,
    this.onQueryChanged,
  });

  final V2FileTreeData data;

  /// Called with the full path (or name when path is null) of a tapped file.
  final ValueChanged<String>? onSelectFile;

  /// Retries a failed load.
  final VoidCallback? onRetry;

  /// "Next action" for an empty tree (for example, re-fetch the branch).
  final VoidCallback? onRefresh;

  /// Reports each search query change, for wiring/analytics.
  final ValueChanged<String>? onQueryChanged;

  @override
  State<V2FileTree> createState() => _V2FileTreeState();
}

class _V2FileTreeState extends State<V2FileTree> {
  late final TextEditingController _search;
  late String _query;
  late final Set<String> _expanded;

  @override
  void initState() {
    super.initState();
    _query = widget.data.initialQuery;
    _search = TextEditingController(text: _query);
    _expanded = <String>{...widget.data.expandedPaths};
    _expandAncestors(widget.data.nodes, widget.data.selectedPath);
  }

  @override
  void didUpdateWidget(covariant V2FileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.initialQuery != widget.data.initialQuery &&
        _search.text != widget.data.initialQuery) {
      _setSearchText(widget.data.initialQuery);
      _query = widget.data.initialQuery;
    }
    if (!setEquals(oldWidget.data.expandedPaths, widget.data.expandedPaths)) {
      _expanded.addAll(widget.data.expandedPaths);
    }
    if (oldWidget.data.selectedPath != widget.data.selectedPath) {
      _expandAncestors(widget.data.nodes, widget.data.selectedPath);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setSearchText(String value) {
    _search.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    widget.onQueryChanged?.call(value);
  }

  void _clearSearch() {
    _search.clear();
    if (_query.isNotEmpty) setState(() => _query = '');
    widget.onQueryChanged?.call('');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Opens every folder that contains [target]. Returns true when [target] is
  /// somewhere below [nodes].
  bool _expandAncestors(List<V2FileTreeEntry> nodes, String? target) {
    if (target == null || target.isEmpty) return false;
    var found = false;
    for (final node in nodes) {
      if (!node.isFolder) {
        if ((node.path ?? node.name) == target) found = true;
        continue;
      }
      if (_expandAncestors(node.children, target)) {
        _expanded.add(node.id);
        found = true;
      }
    }
    return found;
  }

  void _activate(V2FileTreeEntry entry, {required bool searching}) {
    // Tapping anything in the tree ends text entry, so the result list is
    // usable without dismissing a mobile keyboard first.
    FocusManager.instance.primaryFocus?.unfocus();
    if (!entry.isFolder) {
      widget.onSelectFile?.call(entry.path ?? entry.name);
      return;
    }
    if (!entry.canExpand) {
      // An empty folder has nothing to reveal; the row is not interactive.
      return;
    }
    if (searching) {
      // A folder in search results is shown in context, not toggled in place:
      // search reveals every matching branch, so toggling would have no effect.
      _search.clear();
      setState(() {
        _query = '';
        _expanded.add(entry.id);
      });
      widget.onQueryChanged?.call('');
      return;
    }
    setState(() {
      if (!_expanded.remove(entry.id)) _expanded.add(entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    switch (data.status) {
      case V2FileTreeStatus.loading:
        return Semantics(
          label: 'Loading files',
          // The skeleton list owns a ListView; bound it so the tree still
          // renders when it is embedded in a page scroll view.
          child: const SizedBox(height: 320, child: OSkeletonList(rows: 6)),
        );
      case V2FileTreeStatus.error:
        return OErrorState(
          title: 'Files did not load',
          message:
              data.errorMessage ??
              'We could not list the files in this workspace. Check your '
                  'connection and try again.',
          onRetry: widget.onRetry,
        );
      case V2FileTreeStatus.empty:
        return _buildEmpty();
      case V2FileTreeStatus.content:
        if (data.nodes.isEmpty) return _buildEmpty();
        return _buildContent(context);
    }
  }

  Widget _buildEmpty() {
    return OEmptyState(
      compact: true,
      icon: Icons.folder_open_rounded,
      title: widget.data.emptyTitle,
      message: widget.data.emptyMessage,
      action: widget.onRefresh == null
          ? null
          : OButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              variant: OButtonVariant.secondary,
              onPressed: widget.onRefresh,
            ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final query = _query.trim();
    final searching = query.isNotEmpty;
    final visible = searching
        ? _filterNodes(widget.data.nodes, query.toLowerCase())
        : widget.data.nodes;
    final rows = _buildRows(
      visible,
      forceExpanded: searching,
      searching: searching,
    );
    final matches = searching ? _countFiles(visible) : 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.s, OSpace.s, OSpace.s, 0),
          child: OSearchField(
            controller: _search,
            hint: widget.data.searchHint,
            autofocus: false,
            onChanged: _onQueryChanged,
            onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            trailing: _query.isEmpty
                ? null
                : OIconButton(
                    icon: Icons.close_rounded,
                    semanticLabel: 'Clear search',
                    size: 18,
                    onPressed: _clearSearch,
                  ),
          ),
        ),
        if (searching && rows.isNotEmpty) _ResultCount(count: matches),
        if (rows.isEmpty)
          _NoMatches(query: query, onClear: _clearSearch)
        else if (searching)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          )
        else
          OStagger(children: rows),
      ],
    );
  }

  /// Drops non-matching files while keeping their ancestor folders.
  ///
  /// A folder whose own name or path matches keeps its whole subtree, so
  /// searching for `assets` still shows every asset beneath it.
  List<V2FileTreeEntry> _filterNodes(
    List<V2FileTreeEntry> nodes,
    String query,
  ) {
    final result = <V2FileTreeEntry>[];
    for (final node in nodes) {
      final matches =
          node.name.toLowerCase().contains(query) ||
          (node.path ?? '').toLowerCase().contains(query);
      if (!node.isFolder) {
        if (matches) result.add(node);
        continue;
      }
      if (matches) {
        result.add(node);
        continue;
      }
      final children = _filterNodes(node.children, query);
      if (children.isEmpty) continue;
      result.add(
        V2FileTreeEntry(
          name: node.name,
          path: node.path,
          isFolder: true,
          children: children,
          change: node.change,
        ),
      );
    }
    return result;
  }

  List<Widget> _buildRows(
    List<V2FileTreeEntry> nodes, {
    required bool forceExpanded,
    required bool searching,
  }) {
    // Post-order counts, computed once per build rather than per row.
    final changedCounts = <String, int>{};
    final fileCounts = <String, int>{};
    int count(entry) {
      if (!entry.isFolder) {
        changedCounts[entry.id] = entry.isChanged ? 1 : 0;
        fileCounts[entry.id] = 1;
        return entry.isChanged ? 1 : 0;
      }
      var changed = entry.isChanged ? 1 : 0;
      var files = 0;
      for (final child in entry.children) {
        changed += count(child);
        files += fileCounts[child.id] ?? 0;
      }
      changedCounts[entry.id] = changed;
      fileCounts[entry.id] = files;
      return changed;
    }

    for (final node in nodes) {
      count(node);
    }

    final rows = <_TreeRowData>[];
    void walk(V2FileTreeEntry entry, int depth) {
      final expanded =
          entry.canExpand && (forceExpanded || _expanded.contains(entry.id));
      rows.add(
        _TreeRowData(
          entry: entry,
          depth: depth,
          expanded: expanded,
          fileCount: fileCounts[entry.id] ?? 0,
          changedCount: changedCounts[entry.id] ?? 0,
        ),
      );
      if (!expanded) return;
      for (final child in entry.children) {
        walk(child, depth + 1);
      }
    }

    for (final node in nodes) {
      walk(node, 0);
    }

    return [
      for (final row in rows)
        _FileTreeRow(
          key: ValueKey<String>('v2-file-tree-row-${row.entry.id}'),
          entry: row.entry,
          depth: row.depth,
          expanded: row.expanded,
          selected:
              !row.entry.isFolder &&
              widget.data.selectedPath != null &&
              (row.entry.path ?? row.entry.name) == widget.data.selectedPath,
          fileCount: row.fileCount,
          changedCount: row.changedCount,
          searching: searching,
          interactive:
              row.entry.canExpand ||
              (!row.entry.isFolder && widget.onSelectFile != null),
          onTap: () => _activate(row.entry, searching: searching),
        ),
    ];
  }
}

class _TreeRowData {
  const _TreeRowData({
    required this.entry,
    required this.depth,
    required this.expanded,
    required this.fileCount,
    required this.changedCount,
  });

  final V2FileTreeEntry entry;
  final int depth;
  final bool expanded;
  final int fileCount;
  final int changedCount;
}

class _FileTreeRow extends StatelessWidget {
  const _FileTreeRow({
    super.key,
    required this.entry,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.fileCount,
    required this.changedCount,
    required this.searching,
    required this.interactive,
    required this.onTap,
  });

  final V2FileTreeEntry entry;
  final int depth;
  final bool expanded;
  final bool selected;
  final int fileCount;
  final int changedCount;
  final bool searching;
  final bool interactive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final language = _languageFor(entry);
    final indent = OSpace.s + math.min(depth, 4) * 14.0;
    final fg = selected ? c.accent : c.text;
    final iconColor = selected
        ? c.accent
        : entry.isFolder
        ? (expanded ? c.accent : c.textMuted)
        : language.color(c);
    final badge = _badgeFor(c);

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      child: Padding(
        padding: EdgeInsets.fromLTRB(indent, OSpace.xs, OSpace.s, OSpace.xs),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: entry.canExpand
                  ? AnimatedRotation(
                      key: Key('v2-file-tree-expander-${entry.id}'),
                      turns: expanded ? 0.25 : 0,
                      duration: OMove.duration(context, OMotion.fast),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: c.textFaint,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: OSpace.xs),
            Icon(
              entry.isFolder
                  ? (expanded
                        ? Icons.folder_open_rounded
                        : Icons.folder_rounded)
                  : language.icon,
              size: 19,
              color: iconColor,
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.bodySm.copyWith(
                  color: fg,
                  fontWeight: selected || entry.isFolder
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
            if (badge != null) ...[const SizedBox(width: OSpace.xs), badge],
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      label: _semanticLabel(language),
      hint: entry.canExpand && searching
          ? 'Clears the search and shows this folder in the tree'
          : null,
      button: interactive,
      enabled: interactive ? true : null,
      selected: entry.isFolder ? null : selected,
      expanded: entry.canExpand ? expanded : null,
      onTap: interactive ? onTap : null,
      child: ExcludeSemantics(
        child: Material(
          color: selected ? c.accentSoft : Colors.transparent,
          child: InkWell(
            onTap: interactive ? onTap : null,
            borderRadius: BorderRadius.circular(ORadius.m),
            child: content,
          ),
        ),
      ),
    );
  }

  String _semanticLabel(_Language language) {
    if (entry.isFolder) {
      final files = fileCount == 1 ? '1 file' : '$fileCount files';
      final changed = changedCount > 0 ? ', $changedCount changed' : '';
      if (!entry.canExpand) return 'Folder ${entry.name}, empty';
      return 'Folder ${entry.name}, $files$changed';
    }
    final change = entry.change;
    final suffix = change == null ? '' : ', ${change.semanticLabel}';
    return '${entry.name}, ${language.label}$suffix';
  }

  Widget? _badgeFor(OColors c) {
    if (entry.isFolder) {
      if (changedCount == 0) return null;
      return _TreeBadge(
        label: '$changedCount',
        foreground: c.accent,
        background: c.accentSoft,
      );
    }
    final change = entry.change;
    if (change == null) return null;
    final (foreground, background) = switch (change) {
      V2FileChange.added => (c.success, c.success.withValues(alpha: 0.12)),
      V2FileChange.modified => (c.warn, c.warn.withValues(alpha: 0.12)),
      V2FileChange.removed => (c.danger, c.danger.withValues(alpha: 0.12)),
    };
    return _TreeBadge(
      label: change.badge,
      foreground: foreground,
      background: background,
    );
  }
}

class _TreeBadge extends StatelessWidget {
  const _TreeBadge({
    required this.label,
    required this.foreground,
    required this.background,
  });

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    // No fixed height: at 200 % text the badge grows instead of clipping.
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(ORadius.s),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: OType.caption.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }
}

class _ResultCount extends StatelessWidget {
  const _ResultCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = count == 1 ? '1 file found' : '$count files found';
    return Semantics(
      container: true,
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.m,
            OSpace.s,
            OSpace.m,
            OSpace.xs,
          ),
          child: Text(label, style: OType.caption.copyWith(color: c.textMuted)),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return OEmptyState(
      compact: true,
      icon: Icons.search_off_rounded,
      title: 'No matching files',
      message: 'Nothing matches “$query”. Try a different name or path.',
      action: OButton(
        label: 'Clear search',
        icon: Icons.close_rounded,
        variant: OButtonVariant.secondary,
        onPressed: onClear,
      ),
    );
  }
}

enum _LanguageTone { accent, warn, success, muted }

class _Language {
  const _Language(this.label, this.icon, this.tone);

  final String label;
  final IconData icon;
  final _LanguageTone tone;

  Color color(OColors c) => switch (tone) {
    _LanguageTone.accent => c.accent,
    _LanguageTone.warn => c.warn,
    _LanguageTone.success => c.success,
    _LanguageTone.muted => c.textMuted,
  };
}

/// Maps an extension to a language icon and spoken label. The icon set covers
/// the languages that appear in Studio workspaces; everything else falls back
/// to a neutral document.
_Language _languageFor(V2FileTreeEntry entry) {
  final name = entry.name.toLowerCase();
  if (name == 'dockerfile' ||
      name.startsWith('dockerfile.') ||
      name == 'makefile' ||
      name == 'procfile' ||
      name == 'brewfile') {
    return const _Language(
      'Config file',
      Icons.settings_outlined,
      _LanguageTone.warn,
    );
  }
  if (name == 'readme' || name.startsWith('readme.') || name == 'license') {
    return const _Language(
      'Document',
      Icons.article_outlined,
      _LanguageTone.muted,
    );
  }
  return switch (entry.extension) {
    'dart' => const _Language(
      'Dart file',
      Icons.flutter_dash,
      _LanguageTone.accent,
    ),
    'js' || 'mjs' || 'cjs' || 'jsx' => const _Language(
      'JavaScript file',
      Icons.javascript_rounded,
      _LanguageTone.warn,
    ),
    'ts' || 'tsx' => const _Language(
      'TypeScript file',
      Icons.code_rounded,
      _LanguageTone.accent,
    ),
    'html' || 'htm' => const _Language(
      'HTML file',
      Icons.html_rounded,
      _LanguageTone.warn,
    ),
    'css' || 'scss' || 'sass' || 'less' => const _Language(
      'CSS file',
      Icons.css_rounded,
      _LanguageTone.accent,
    ),
    'json' ||
    'jsonc' ||
    'yaml' ||
    'yml' ||
    'toml' ||
    'xml' ||
    'csv' => const _Language(
      'Data file',
      Icons.data_object_rounded,
      _LanguageTone.success,
    ),
    'md' || 'mdx' || 'txt' || 'rst' => const _Language(
      'Document',
      Icons.article_outlined,
      _LanguageTone.muted,
    ),
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' || 'ico' || 'bmp' =>
      const _Language('Image', Icons.image_outlined, _LanguageTone.accent),
    'sh' || 'bash' || 'zsh' || 'fish' || 'ps1' => const _Language(
      'Shell script',
      Icons.terminal_rounded,
      _LanguageTone.success,
    ),
    'lock' => const _Language(
      'Lockfile',
      Icons.lock_outline_rounded,
      _LanguageTone.muted,
    ),
    'env' || 'gitignore' || 'editorconfig' => const _Language(
      'Config file',
      Icons.settings_outlined,
      _LanguageTone.warn,
    ),
    'py' ||
    'rb' ||
    'go' ||
    'rs' ||
    'java' ||
    'kt' ||
    'swift' ||
    'c' ||
    'h' ||
    'cc' ||
    'cpp' ||
    'hpp' ||
    'cs' ||
    'php' ||
    'lua' ||
    'sql' => const _Language(
      'Source file',
      Icons.code_rounded,
      _LanguageTone.accent,
    ),
    _ => const _Language(
      'File',
      Icons.description_outlined,
      _LanguageTone.muted,
    ),
  };
}

int _countFiles(List<V2FileTreeEntry> nodes) {
  var total = 0;
  for (final node in nodes) {
    total += node.isFolder ? _countFiles(node.children) : 1;
  }
  return total;
}

int _countChanged(List<V2FileTreeEntry> nodes) {
  var total = 0;
  for (final node in nodes) {
    if (node.isFolder) {
      total += _countChanged(node.children);
    } else if (node.isChanged) {
      total += 1;
    }
  }
  return total;
}
