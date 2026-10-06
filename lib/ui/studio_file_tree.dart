import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/repo_cache.dart';
import '../core/theme.dart';
import 'studio_errors.dart';
import 'studio_layout.dart';
import 'widgets/aether_primitives.dart';

// ── Studio file tree ────────────────────────────────────────────────────────
// Extracted from studio_screen.dart and rewritten (2026-09-30 audit).
//
// Two bugs lived in the old tree:
//  * directories were guessed as "the next sorted path starts with `p/`", so
//    a directory whose children were all dropped by RepoCache's skip-list
//    rendered as a *file*, and tapping it opened an empty editor buffer that
//    was indistinguishable from a genuinely empty file;
//  * `_openUnknownFile` swallowed every fetch failure into `openStudioFile(p,
//    '')`, which is exactly that indistinguishable blank buffer.
//
// Directories are now derived from the path set itself (a node is a directory
// iff some path lives under it), and an unreachable file becomes a visible,
// labelled error row that retries on tap.

/// One row of the tree.
class StudioTreeNode {
  const StudioTreeNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.depth,
  });

  /// Full repository path, normalised (no leading `/`, no empty segments).
  final String path;

  /// Leaf name shown in the row.
  final String name;

  final bool isDirectory;

  /// Indent level; 0 is the repository root.
  final int depth;

  @override
  String toString() => 'StudioTreeNode($path, dir=$isDirectory, d=$depth)';
}

List<String> _segments(String path) =>
    path.split('/').where((s) => s.isNotEmpty).toList();

String _leaf(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Builds the flattened, depth-annotated row list for [paths], revealing the
/// children of every directory in [expandedDirs].
///
/// Pure so the directory rules are pinned without a widget pump. Rows come out
/// in display order: within a level, directories first, then case-insensitive
/// by name.
List<StudioTreeNode> buildStudioTree(
  Iterable<String> paths,
  Set<String> expandedDirs,
) {
  final dirs = <String>{};
  final files = <String>{};
  for (final raw in paths) {
    final segs = _segments(raw);
    if (segs.isEmpty) continue;
    for (var i = 1; i < segs.length; i++) {
      dirs.add(segs.sublist(0, i).join('/'));
    }
    files.add(segs.join('/'));
  }
  // A path that is also somebody's directory prefix is a directory. Git cannot
  // produce that, but an agent-created buffer can, and picking "file" there
  // would hide the subtree.
  files.removeWhere(dirs.contains);

  final isDir = <String, bool>{
    for (final d in dirs) d: true,
    for (final f in files) f: false,
  };

  final byParent = <String, List<String>>{};
  for (final p in isDir.keys) {
    final i = p.lastIndexOf('/');
    (byParent[i < 0 ? '' : p.substring(0, i)] ??= <String>[]).add(p);
  }
  int compare(String a, String b) {
    final ad = isDir[a]!, bd = isDir[b]!;
    if (ad != bd) return ad ? -1 : 1;
    final byName = _leaf(a).toLowerCase().compareTo(_leaf(b).toLowerCase());
    return byName != 0 ? byName : a.compareTo(b);
  }

  for (final siblings in byParent.values) {
    siblings.sort(compare);
  }

  final out = <StudioTreeNode>[];
  void walk(String parent, int depth) {
    for (final p in byParent[parent] ?? const <String>[]) {
      final directory = isDir[p]!;
      out.add(StudioTreeNode(
        path: p,
        name: _leaf(p),
        isDirectory: directory,
        depth: depth,
      ));
      if (directory && expandedDirs.contains(p)) walk(p, depth + 1);
    }
  }

  walk('', 0);
  return out;
}

// ── Source-control model ────────────────────────────────────────────────────
// Everything below is derived from RepoCache's public surface only: pending
// paths, staged modes/deletions, the tree path set and the working copy. The
// cache never exposes a pre-edit original, so the widget keeps the last
// content it observed *clean* as the diff baseline (see _trackPristine).

/// How a pending (dirty) path differs from the synced repository state.
enum StudioChangeKind {
  /// Never synced; exists only in the pending set (agent/user-created).
  added,

  /// Synced before, now carrying uncommitted edits.
  modified,

  /// Content removed through [RepoCache.stageDeletion].
  deleted,
}

/// Classifies a pending path. [tracked] is membership in
/// [RepoCache.treePaths] — the last synced git tree.
StudioChangeKind studioChangeKind({
  required bool stagedDeletion,
  required bool tracked,
}) {
  if (stagedDeletion) return StudioChangeKind.deleted;
  return tracked ? StudioChangeKind.modified : StudioChangeKind.added;
}

/// Case-insensitive substring filter over whole repository paths. An empty
/// (or whitespace-only) query keeps every path.
Set<String> filterStudioPaths(Iterable<String> paths, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return paths.toSet();
  return {
    for (final p in paths)
      if (p.toLowerCase().contains(q)) p,
  };
}

/// One rendered line of an inline diff.
enum StudioDiffLineKind { context, added, removed }

class StudioDiffLine {
  const StudioDiffLine(this.kind, this.text);

  final StudioDiffLineKind kind;
  final String text;

  @override
  String toString() => 'StudioDiffLine(${kind.name}, $text)';
}

List<String> _splitDiffLines(String? text) {
  if (text == null || text.isEmpty) return const <String>[];
  final parts = text.split('\n');
  if (parts.last.isEmpty) parts.removeLast();
  return parts;
}

/// Line-level unified view of [before] → [after]. A `null` side means "file
/// absent" (every line of the other side is added/removed), matching the
/// semantics of [CommitApproval.diff]. Identical content yields all-context
/// lines so callers can recognise "no content change".
///
/// Common prefixes/suffixes are trimmed first, so the LCS table only spans
/// the changed middle; beyond 400×400 changed lines the diff degrades to a
/// removed block followed by an added block rather than interleaving — still
/// exact, just coarser — keeping a paste of a huge file bounded.
List<StudioDiffLine> buildStudioLineDiff(String? before, String? after) {
  if (before == null) {
    return [
      for (final l in _splitDiffLines(after))
        StudioDiffLine(StudioDiffLineKind.added, l),
    ];
  }
  if (after == null) {
    return [
      for (final l in _splitDiffLines(before))
        StudioDiffLine(StudioDiffLineKind.removed, l),
    ];
  }
  final a = _splitDiffLines(before);
  final b = _splitDiffLines(after);
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final out = <StudioDiffLine>[
    for (var i = 0; i < start; i++)
      StudioDiffLine(StudioDiffLineKind.context, a[i]),
  ];
  final midA = endA - start, midB = endB - start;
  if (midA > 0 && midB > 0 && midA * midB <= 160000) {
    final dp = List.generate(
        midA + 1, (_) => List<int>.filled(midB + 1, 0, growable: false),
        growable: false);
    for (var i = midA - 1; i >= 0; i--) {
      for (var j = midB - 1; j >= 0; j--) {
        dp[i][j] = a[start + i] == b[start + j]
            ? dp[i + 1][j + 1] + 1
            : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < midA && j < midB) {
      if (a[start + i] == b[start + j]) {
        out.add(StudioDiffLine(StudioDiffLineKind.context, a[start + i]));
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        out.add(StudioDiffLine(StudioDiffLineKind.removed, a[start + i]));
        i++;
      } else {
        out.add(StudioDiffLine(StudioDiffLineKind.added, b[start + j]));
        j++;
      }
    }
    while (i < midA) {
      out.add(StudioDiffLine(StudioDiffLineKind.removed, a[start + i]));
      i++;
    }
    while (j < midB) {
      out.add(StudioDiffLine(StudioDiffLineKind.added, b[start + j]));
      j++;
    }
  } else {
    for (var i = start; i < endA; i++) {
      out.add(StudioDiffLine(StudioDiffLineKind.removed, a[i]));
    }
    for (var j = start; j < endB; j++) {
      out.add(StudioDiffLine(StudioDiffLineKind.added, b[j]));
    }
  }
  for (var i = endA; i < a.length; i++) {
    out.add(StudioDiffLine(StudioDiffLineKind.context, a[i]));
  }
  return out;
}

/// Filled dot on a tree row.
Color _changeColor(StudioChangeKind kind) => switch (kind) {
      StudioChangeKind.added => Aether.success,
      StudioChangeKind.modified => Aether.warn,
      StudioChangeKind.deleted => Aether.danger,
    };

/// Small text (status letter badge, diff lines) — theme-contrast variants.
Color _changeTextColor(StudioChangeKind kind) => switch (kind) {
      StudioChangeKind.added => Aether.successLight,
      StudioChangeKind.modified => Aether.warnLight,
      StudioChangeKind.deleted => Aether.dangerC,
    };

String _changeLetter(StudioChangeKind kind) => switch (kind) {
      StudioChangeKind.added => 'A',
      StudioChangeKind.modified => 'M',
      StudioChangeKind.deleted => 'D',
    };

String _changeLabel(StudioChangeKind kind) => switch (kind) {
      StudioChangeKind.added => 'added',
      StudioChangeKind.modified => 'modified',
      StudioChangeKind.deleted => 'deletion staged',
    };

/// The repository file explorer bound to [RepoCache].
class StudioFileTree extends StatefulWidget {
  const StudioFileTree({super.key});

  @override
  State<StudioFileTree> createState() => _StudioFileTreeState();
}

class _StudioFileTreeState extends State<StudioFileTree> {
  final Set<String> _expanded = <String>{};
  final Set<String> _failed = <String>{};
  final Set<String> _loading = <String>{};
  final TextEditingController _filter = TextEditingController();

  /// Last content observed while a path was clean. RepoCache deliberately
  /// keeps no pre-edit original; this session-scoped baseline is what the
  /// Changes panel diffs a modified file against. Entries are string
  /// references, never copies, and are pruned as paths vanish.
  final Map<String, String> _pristine = <String, String>{};
  String _query = '';
  bool _changesExpanded = true;
  String? _diffPath;
  int _generation = RepoCache.I.bindingGeneration;

  @override
  void initState() {
    super.initState();
    RepoCache.I.addListener(_bindingChanged);
  }

  void _bindingChanged() {
    if (_generation == RepoCache.I.bindingGeneration) return;
    _generation = RepoCache.I.bindingGeneration;
    _expanded.clear();
    _failed.clear();
    _loading.clear();
    _pristine.clear();
    _diffPath = null;
    if (_query.isNotEmpty) {
      _filter.clear();
      _query = '';
    }
  }

  @override
  void dispose() {
    RepoCache.I.removeListener(_bindingChanged);
    _filter.dispose();
    super.dispose();
  }

  void _onFilterChanged(String value) {
    if (_query == value) return;
    setState(() => _query = value);
  }

  /// Refreshes the diff baseline from the cache's current state. Clean files
  /// re-record their synced content; dirty files keep the baseline captured
  /// while they were last clean; vanished paths are dropped.
  void _trackPristine(RepoCache cache) {
    final dirty = cache.pendingPaths.toSet();
    cache.files.forEach((path, content) {
      if (!dirty.contains(path)) _pristine[path] = content;
    });
    _pristine.removeWhere(
        (path, _) => !dirty.contains(path) && !cache.files.containsKey(path));
  }

  /// Every ancestor directory of [paths] — filtering ignores the manual
  /// collapse state so a matching child of a folded directory stays visible.
  static Set<String> _ancestorDirs(Set<String> paths) {
    final dirs = <String>{};
    for (final p in paths) {
      final segs = _segments(p);
      for (var i = 1; i < segs.length; i++) {
        dirs.add(segs.sublist(0, i).join('/'));
      }
    }
    return dirs;
  }

  /// Stages the regular Git mode through the exact same RepoCache contract as
  /// the row's staging menu; metadata only, never disk bytes or permissions.
  void _stageChange(String path) {
    try {
      RepoCache.I.stageMode(path, '100644');
      showStudioToast(context, 'Staged $path',
          detail: 'Git mode 100644 staged. No disk files or permissions changed.');
    } catch (e) {
      showStudioToast(context, 'Could not stage $path', detail: '$e', error: true);
    }
  }

  /// Discards what is safely discardable for [path]:
  ///  * an added (never-synced) file is removed from the pending set after
  ///    confirmation — that content exists nowhere else;
  ///  * a modified file with a staged mode resets to regular (100644);
  ///  * anything else has no safe offline discard — content edits are kept
  ///    until commit, never silently destroyed.
  Future<void> _discardChange(String path, StudioChangeKind kind) async {
    if (kind == StudioChangeKind.added) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Discard new file?'),
          content: Text(
              '$path exists only in the pending set. Discarding removes it and cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        RepoCache.I.remove(path);
        if (AgentService.I.studioOpenFiles.contains(path)) {
          AgentService.I.closeStudioFile(path);
        }
        // RepoCache.remove() does not notify; rebuild from the new state.
        setState(() {
          if (_diffPath == path) _diffPath = null;
          _pristine.remove(path);
        });
        if (mounted) {
          showStudioToast(context, 'Discarded $path',
              detail: 'The uncommitted new file was removed from the pending set.');
        }
      } catch (e) {
        if (mounted) {
          showStudioToast(context, 'Could not discard $path', detail: '$e', error: true);
        }
      }
      return;
    }
    if (kind == StudioChangeKind.modified) {
      try {
        RepoCache.I.stageMode(path, '100644');
        if (mounted) {
          showStudioToast(context, 'Reset staged mode for $path',
              detail: 'Regular Git mode 100644 staged. Content edits stay pending.');
        }
      } catch (e) {
        if (mounted) {
          showStudioToast(context, 'Could not reset $path', detail: '$e', error: true);
        }
      }
    }
  }

  /// Opens a file, or toggles a directory.
  ///
  /// A miss in the in-memory working copy falls back to a real fetch. Only a
  /// `null` result — never an exception — means "unavailable"; an empty string
  /// is a real, empty file and opens normally.
  Future<void> _activate(StudioTreeNode node) async {
    if (node.isDirectory) {
      setState(() {
        if (!_expanded.remove(node.path)) _expanded.add(node.path);
      });
      return;
    }
    final cache = RepoCache.I;
    final generation = cache.bindingGeneration;
    final buffers = AgentService.I.fileBuffer;
    final cached = cache.read(node.path);
    if (cached != null) {
      if (_failed.contains(node.path)) setState(() => _failed.remove(node.path));
      AgentService.I.openStudioFile(node.path, cached);
      return;
    }
    setState(() {
      _loading.add(node.path);
      _failed.remove(node.path);
    });
    FetchResult result;
    try {
      result = await cache.fetchFileResult(node.path);
    } catch (error) {
      if (!mounted || generation != cache.bindingGeneration ||
          !identical(buffers, AgentService.I.fileBuffer)) {
        return;
      }
      setState(() { _loading.remove(node.path); _failed.add(node.path); });
      showStudioToast(context, StudioFailure.of(error).message, error: true);
      return;
    }
    final content = result.content;
    if (!mounted || generation != cache.bindingGeneration ||
        !identical(buffers, AgentService.I.fileBuffer)) {
      return;
    }
    setState(() => _loading.remove(node.path));
    if (content == null) {
      setState(() => _failed.add(node.path));
      final failure = switch (result.failure) {
        FetchFailure.noToken => const StudioFailure('Sign in to GitHub before opening this file.', ''),
        FetchFailure.unauthorized => const StudioFailure('GitHub rejected the saved login. Sign in again and retry.', ''),
        FetchFailure.forbidden => const StudioFailure('You do not have permission to read this repository file.', ''),
        FetchFailure.notFound => const StudioFailure('GitHub could not find this file on the selected branch.', ''),
        FetchFailure.timeout => const StudioFailure('GitHub took too long to return this file. Retry when online.', ''),
        FetchFailure.server => const StudioFailure('GitHub is temporarily unavailable. Retry in a moment.', ''),
        FetchFailure.network => const StudioFailure('The file could not be reached. Check the network and retry.', ''),
        _ => const StudioFailure('That file could not be loaded from the repository.', ''),
      };
      showStudioToast(
        context,
        'Could not open ${node.name}',
        detail: failure.detail.isEmpty ? failure.message : failure.detail,
        error: true,
      );
      return;
    }
    AgentService.I.openStudioFile(node.path, content);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([RepoCache.I, AgentService.I]),
      builder: (context, _) {
        final cache = RepoCache.I;
        _trackPristine(cache);
        // Union of the tree and the live working copy: an agent-written file
        // that was never in the git tree still has to be reachable.
        final allPaths = <String>{
          ...cache.treePaths,
          ...cache.files.keys,
          ...cache.pendingPaths,
        };
        final pending = cache.pendingPaths;
        final pendingSet = pending.toSet();
        final trackedSet = cache.treePaths.toSet();
        final filtering = _query.trim().isNotEmpty;
        final visible = filterStudioPaths(allPaths, _query);
        final nodes = buildStudioTree(
          visible,
          filtering ? _ancestorDirs(visible) : _expanded,
        );
        final active = AgentService.I.activeFilePath;

        return Container(
          decoration: BoxDecoration(
            color: Aether.surface,
            border: Border(right: BorderSide(color: Aether.hairline)),
          ),
          child: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: _TreeHeader()),
              SliverToBoxAdapter(
                child: Divider(height: 1, thickness: 1, color: Aether.hairline),
              ),
              SliverToBoxAdapter(
                child: _TreeFilterBar(
                  controller: _filter,
                  onChanged: _onFilterChanged,
                ),
              ),
              if (active != null)
                SliverToBoxAdapter(child: _TreeBreadcrumb(path: active)),
              if (pending.isNotEmpty)
                SliverToBoxAdapter(
                  child: _ChangesPanel(
                    paths: pending,
                    expanded: _changesExpanded,
                    diffPath: _diffPath,
                    pristine: _pristine,
                    tracked: trackedSet,
                    cache: cache,
                    onToggle: () =>
                        setState(() => _changesExpanded = !_changesExpanded),
                    onToggleDiff: (path) => setState(
                        () => _diffPath = _diffPath == path ? null : path),
                    onStage: _stageChange,
                    onDiscard: _discardChange,
                  ),
                ),
              if (nodes.isEmpty)
                SliverToBoxAdapter(
                  child: filtering
                      ? _TreeNoMatches(query: _query.trim())
                      : const _TreeEmpty(),
                )
              else
                SliverList.builder(
                  itemCount: nodes.length,
                  itemBuilder: (_, i) =>
                      _row(nodes[i], active, cache, pendingSet, trackedSet),
                ),
              SliverToBoxAdapter(
                child: _TreeFooter(ready: cache.isReady, count: cache.files.length),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(
    StudioTreeNode node,
    String? active,
    RepoCache cache,
    Set<String> pendingSet,
    Set<String> trackedSet,
  ) {
    final selected = !node.isDirectory && active == node.path;
    final failed = _failed.contains(node.path);
    final loading = _loading.contains(node.path);
    final change = node.isDirectory || !pendingSet.contains(node.path)
        ? null
        : studioChangeKind(
            stagedDeletion: cache.isStagedDeletion(node.path),
            tracked: trackedSet.contains(node.path),
          );
    return _FileTreeRow(
      node: node,
      selected: selected,
      failed: failed,
      loading: loading,
      expanded: _expanded.contains(node.path),
      change: change,
      onActivate: () => _activate(node),
    );
  }
}

/// A hover-aware, selection-aware tree row.
///
/// Hover state is a `_FileTreeRow`-local flag driven by a `MouseRegion`; the
/// row paints `Aether.surfaceAlt` when hovered (and not selected), the accent
/// soft overlay when the row's file is the active tab, and transparent
/// otherwise. The 44dp tap-target invariant is preserved via [StudioTapTarget].
class _FileTreeRow extends StatefulWidget {
  const _FileTreeRow({
    required this.node,
    required this.selected,
    required this.failed,
    required this.loading,
    required this.expanded,
    required this.change,
    required this.onActivate,
  });

  final StudioTreeNode node;
  final bool selected;
  final bool failed;
  final bool loading;
  final bool expanded;

  /// Pending-commit status for this file, or null when clean / a directory.
  final StudioChangeKind? change;
  final VoidCallback onActivate;

  @override
  State<_FileTreeRow> createState() => _FileTreeRowState();
}

class _FileTreeRowState extends State<_FileTreeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final selected = widget.selected;
    final failed = widget.failed;
    final loading = widget.loading;
    final indent = 8.0 + node.depth * 14.0;

    final IconData icon;
    final Color iconColor;
    if (loading) {
      icon = Icons.hourglass_top_rounded;
      iconColor = Aether.accent;
    } else if (failed) {
      icon = Icons.error_outline;
      iconColor = Aether.dangerC;
    } else if (node.isDirectory) {
      icon = widget.expanded
          ? Icons.folder_open_outlined
          : Icons.folder_outlined;
      iconColor = Aether.textMuted;
    } else {
      icon = Icons.description_outlined;
      iconColor = selected ? Aether.accent : Aether.textFaint;
    }

    final change = widget.change;
    final label = failed
        ? '${node.name}, could not be loaded — tap to retry'
        : node.isDirectory
            ? '${node.name}, folder, '
                '${widget.expanded ? 'expanded' : 'collapsed'}'
            : '${node.name}, file${selected ? ', open' : ''}'
                '${change == null ? '' : ', ${_changeLabel(change)}, pending commit'}';

    // Selected > hover > plain. Hover tint only when not already selected so
    // the accent overlay never gets swapped out from under the pointer.
    final Color background;
    if (selected) {
      background = Aether.accentSoft;
    } else if (_hover) {
      background = Aether.surfaceAlt;
    } else {
      background = Colors.transparent;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: StudioTapTarget(
        onTap: widget.onActivate,
        label: label,
        selected: selected,
        minWidth: 0,
        child: LayoutBuilder(builder: (context, constraints) => AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          color: background,
          // Deep directory nesting must still leave room for the filename and
          // staging action. The full path remains available through a tooltip.
          padding: EdgeInsets.only(
              left: indent.clamp(8.0, (constraints.maxWidth * 0.25).clamp(8.0, 80.0)),
              right: 8),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Icon(icon, size: 15, color: iconColor),
              const SizedBox(width: 6),
              Expanded(
                child: Tooltip(message: node.path, child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: Aether.mono,
                    fontFamilyFallback: kStudioMonoFallback,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? Aether.accent
                        : failed
                            ? Aether.dangerC
                            : node.isDirectory
                                ? Aether.text
                                : Aether.textMuted,
                  ),
                )),
              ),
              if (node.isDirectory)
                Icon(
                  widget.expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 15,
                  color: Aether.textFaint,
                ),
              if (!node.isDirectory && change != null)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Tooltip(
                    message: switch (change) {
                      StudioChangeKind.added => 'Added — pending commit',
                      StudioChangeKind.modified => 'Modified — pending commit',
                      StudioChangeKind.deleted =>
                        'Deletion staged — pending commit',
                    },
                    child: Container(
                      key: Key('studio-dirty-${node.path}'),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _changeColor(change),
                      ),
                    ),
                  ),
                ),
              if (!node.isDirectory)
                StudioStagingMenu(path: node.path),
            ],
          ),
        )),
      ),
    );
  }
}

/// The file filter field pinned above the tree. Local, case-insensitive and
/// debounce-free: the path set is already in memory.
class _TreeFilterBar extends StatelessWidget {
  const _TreeFilterBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: SizedBox(
        height: 34,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => TextField(
            key: const Key('studio-tree-filter'),
            controller: controller,
            onChanged: onChanged,
            style: TextStyle(
              fontSize: 12,
              fontFamily: Aether.mono,
              fontFamilyFallback: kStudioMonoFallback,
              color: Aether.text,
            ),
            cursorColor: Aether.accent,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter files',
              hintStyle: TextStyle(fontSize: 12, color: Aether.textFaint),
              prefixIcon: Icon(Icons.search, size: 15, color: Aether.textFaint),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 30, minHeight: 30),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear file filter',
                      iconSize: 14,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        controller.clear();
                        onChanged('');
                      },
                      icon: Icon(Icons.close, color: Aether.textFaint),
                    ),
              filled: true,
              fillColor: Aether.surfaceAlt,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: Aether.hairlineStrong),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The open file's repository path as a calm breadcrumb. Display-only; the
/// full path stays available from the row tooltip and this semantics label.
class _TreeBreadcrumb extends StatelessWidget {
  const _TreeBreadcrumb({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final segments = _segments(path);
    return Container(
      key: const Key('studio-tree-breadcrumb'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: Semantics(
        label: 'Open file: $path',
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 12, color: Aether.textFaint),
              const SizedBox(width: 6),
              for (var i = 0; i < segments.length; i++) ...[
                if (i > 0)
                  Icon(Icons.chevron_right, size: 12, color: Aether.textFaint),
                Text(
                  segments[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: Aether.mono,
                    fontFamilyFallback: kStudioMonoFallback,
                    fontWeight: i == segments.length - 1
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: i == segments.length - 1
                        ? Aether.accentC
                        : Aether.textFaint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TreeNoMatches extends StatelessWidget {
  const _TreeNoMatches({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          'No files match “$query”.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, height: 1.6, color: Aether.textFaint),
        ),
      ),
    );
  }
}

/// The collapsible pending-commit review panel. Rows are read straight off
/// RepoCache's public state; staging flows through the same [RepoCache]
/// staging contract as the per-row menu, and review is an inline line diff
/// instead of a raw-diff dump.
class _ChangesPanel extends StatelessWidget {
  const _ChangesPanel({
    required this.paths,
    required this.expanded,
    required this.diffPath,
    required this.pristine,
    required this.tracked,
    required this.cache,
    required this.onToggle,
    required this.onToggleDiff,
    required this.onStage,
    required this.onDiscard,
  });

  /// Pending paths, already sorted by [RepoCache.pendingPaths].
  final List<String> paths;
  final bool expanded;
  final String? diffPath;

  /// Session diff baseline; see [_StudioFileTreeState._pristine].
  final Map<String, String> pristine;
  final Set<String> tracked;
  final RepoCache cache;
  final VoidCallback onToggle;
  final ValueChanged<String> onToggleDiff;
  final ValueChanged<String> onStage;
  final void Function(String path, StudioChangeKind kind) onDiscard;

  /// A repo with hundreds of pending paths stays scrollable; the rest are
  /// one summary line away.
  static const int _maxRows = 200;

  @override
  Widget build(BuildContext context) {
    final shown =
        paths.length > _maxRows ? paths.sublist(0, _maxRows) : paths;
    return Container(
      key: const Key('studio-changes-panel'),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StudioTapTarget(
            minWidth: 0,
            onTap: onToggle,
            label: 'Changes, ${paths.length} pending, '
                '${expanded ? 'expanded' : 'collapsed'}',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
              child: Row(
                children: [
                  Icon(Icons.change_circle_outlined,
                      size: 14, color: Aether.textFaint),
                  const SizedBox(width: 8),
                  Text(
                    'CHANGES',
                    style: AetherType.label.copyWith(
                      letterSpacing: 1.4,
                      color: Aether.textFaint,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Aether.accentSoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${paths.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Aether.accentC,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Aether.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            for (final path in shown)
              _ChangeRow(
                key: Key('studio-change-row-$path'),
                path: path,
                kind: studioChangeKind(
                  stagedDeletion: cache.isStagedDeletion(path),
                  tracked: tracked.contains(path),
                ),
                stagedMode: cache.stagedMode(path),
                diffOpen: diffPath == path,
                before: pristine[path],
                after: cache.files[path],
                onToggleDiff: () => onToggleDiff(path),
                onStage: () => onStage(path),
                onDiscard: onDiscard,
              ),
            if (paths.length > shown.length)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 10, 8),
                  child: Text(
                    '… and ${paths.length - shown.length} more pending',
                    style: TextStyle(fontSize: 12, color: Aether.textFaint),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// One pending-change row: status badge, stage and discard affordances, and
/// a tap-to-open inline diff.
class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    super.key,
    required this.path,
    required this.kind,
    required this.stagedMode,
    required this.diffOpen,
    required this.before,
    required this.after,
    required this.onToggleDiff,
    required this.onStage,
    required this.onDiscard,
  });

  final String path;
  final StudioChangeKind kind;
  final String? stagedMode;
  final bool diffOpen;

  /// Session baseline (null when the edit predates this session).
  final String? before;

  /// Working-copy content (null for a staged deletion).
  final String? after;
  final VoidCallback onToggleDiff;
  final VoidCallback onStage;
  final void Function(String path, StudioChangeKind kind) onDiscard;

  /// Rendered diff lines stay capped; the remainder is a summary line.
  static const int _maxDiffLines = 200;

  bool get _canDiscard => switch (kind) {
        StudioChangeKind.added => true,
        StudioChangeKind.modified => stagedMode != null,
        StudioChangeKind.deleted => false,
      };

  ({String? note, List<StudioDiffLine> lines}) get _diff {
    final ({String? note, List<StudioDiffLine> lines}) result;
    switch (kind) {
      case StudioChangeKind.added:
        result = (note: null, lines: buildStudioLineDiff(null, after));
      case StudioChangeKind.deleted:
        result = before == null
            ? (
                note:
                    'Staged for deletion; the original content is unavailable.',
                lines: const <StudioDiffLine>[],
              )
            : (note: null, lines: buildStudioLineDiff(before, null));
      case StudioChangeKind.modified:
        if (before == null) {
          result = (
            note: 'Edited before this session; the synced original is '
                'unavailable, so the current content is shown.',
            lines: [
              for (final l in _splitDiffLines(after))
                StudioDiffLine(StudioDiffLineKind.context, l),
            ],
          );
        } else {
          final lines = buildStudioLineDiff(before, after);
          result = lines.every((l) => l.kind == StudioDiffLineKind.context)
              ? (
                  note: 'No content changes; only Git metadata is staged.',
                  lines: const <StudioDiffLine>[],
                )
              : (note: null, lines: lines);
        }
    }
    if (result.lines.isEmpty && result.note == null) {
      return (note: 'Nothing to show — the file is empty.', lines: result.lines);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final name = _leaf(path);
    final staged = stagedMode != null;
    final kindLabel = _changeLabel(kind);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        StudioTapTarget(
          minWidth: 0,
          onTap: onToggleDiff,
          selected: diffOpen,
          label: '$name, $kindLabel, '
              '${diffOpen ? 'diff open' : 'tap to review diff'}',
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            color: diffOpen ? Aether.surfaceAlt : Colors.transparent,
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(
                  switch (kind) {
                    StudioChangeKind.added => Icons.add_circle_outline,
                    StudioChangeKind.modified => Icons.edit_outlined,
                    StudioChangeKind.deleted => Icons.remove_circle_outline,
                  },
                  size: 14,
                  color: _changeColor(kind),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: path,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: Aether.mono,
                        fontFamilyFallback: kStudioMonoFallback,
                        fontWeight: FontWeight.w500,
                        color: Aether.text,
                      ),
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.only(right: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: _changeColor(kind).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _changeLetter(kind),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: _changeTextColor(kind),
                    ),
                  ),
                ),
                IconButton(
                  key: Key('studio-change-stage-$path'),
                  tooltip: staged
                      ? 'Staged Git mode $stagedMode'
                      : 'Stage regular mode (100644)',
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed: onStage,
                  icon: Icon(
                    staged ? Icons.check_circle : Icons.check_circle_outline,
                    color: staged ? Aether.accent : Aether.textFaint,
                  ),
                ),
                IconButton(
                  key: Key('studio-change-discard-$path'),
                  tooltip: switch (kind) {
                    StudioChangeKind.added =>
                      'Discard new file (removes it from the pending set)',
                    StudioChangeKind.modified => staged
                        ? 'Reset the staged mode to regular (100644)'
                        : 'Content edits stay pending until commit',
                    StudioChangeKind.deleted =>
                      'Deletion staging is managed from the file menu',
                  },
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      _canDiscard ? () => onDiscard(path, kind) : null,
                  icon: Icon(
                    Icons.undo_rounded,
                    color: _canDiscard ? Aether.textMuted : Aether.textFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (diffOpen) _buildDiffView(),
      ],
    );
  }

  Widget _buildDiffView() {
    final diff = _diff;
    final lines = diff.lines.length > _maxDiffLines
        ? diff.lines.sublist(0, _maxDiffLines)
        : diff.lines;
    return Container(
      key: Key('studio-change-diffview-$path'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 8, 8),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Aether.codeBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (diff.note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Text(
                diff.note!,
                style: TextStyle(
                    fontSize: 12, height: 1.4, color: Aether.textFaint),
              ),
            ),
          for (final line in lines) _DiffLineView(line: line),
          if (diff.lines.length > lines.length)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
              child: Text(
                '… ${diff.lines.length - lines.length} more lines',
                style: TextStyle(fontSize: 12, color: Aether.textFaint),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiffLineView extends StatelessWidget {
  const _DiffLineView({required this.line});

  final StudioDiffLine line;

  @override
  Widget build(BuildContext context) {
    final sign = switch (line.kind) {
      StudioDiffLineKind.added => '+',
      StudioDiffLineKind.removed => '-',
      StudioDiffLineKind.context => ' ',
    };
    return Container(
      width: double.infinity,
      color: switch (line.kind) {
        StudioDiffLineKind.added => Aether.success.withValues(alpha: 0.08),
        StudioDiffLineKind.removed => Aether.danger.withValues(alpha: 0.08),
        StudioDiffLineKind.context => null,
      },
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0.5),
      child: Text(
        '$sign ${line.text}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          height: 1.45,
          fontFamily: Aether.mono,
          fontFamilyFallback: kStudioMonoFallback,
          color: switch (line.kind) {
            StudioDiffLineKind.added => Aether.successLight,
            StudioDiffLineKind.removed => Aether.dangerC,
            StudioDiffLineKind.context => Aether.textMuted,
          },
        ),
      ),
    );
  }
}

/// Shared by the actual explorer and commit selection. These actions stage Git
/// metadata only; checkout deletion requires a path already removed on disk.
class StudioStagingMenu extends StatefulWidget {
  const StudioStagingMenu({super.key, required this.path, this.enabled = true});
  final String path;
  final bool enabled;

  @override
  State<StudioStagingMenu> createState() => _StudioStagingMenuState();
}

class _StudioStagingMenuState extends State<StudioStagingMenu> {
  int? _openedBinding;
  String? _openedPath;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Stage ${widget.path}',
    enabled: widget.enabled,
    icon: const Icon(Icons.more_vert, size: 18),
    onOpened: () {
      _openedBinding = RepoCache.I.bindingGeneration;
      _openedPath = widget.path;
    },
    onSelected: (operation) {
      final path = _openedPath!;
      try {
        if (_openedBinding != RepoCache.I.bindingGeneration) {
          throw StateError('Repository binding changed; reopen staging');
        }
        if (operation == 'delete') {
          RepoCache.I.stageDeletion(path);
        } else {
          RepoCache.I.stageMode(path, operation);
        }
        showStudioToast(context, 'Staged $path',
            detail: 'Git ${operation == 'delete' ? 'deletion' : 'mode $operation'} staged. No disk files or permissions changed.');
      } catch (e) {
        showStudioToast(context, 'Could not stage $path', detail: '$e', error: true);
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: '100755', child: Text('Stage executable (100755)')),
      const PopupMenuItem(value: '100644', child: Text('Stage regular (100644)')),
      PopupMenuItem(value: 'delete', child: Text(RepoCache.I.workspaceFolder == null
          ? 'Stage deletion' : 'Stage deletion (already missing)')),
    ],
  );
}

class _TreeHeader extends StatelessWidget {
  const _TreeHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      child: Row(
        children: [
          Icon(Icons.folder_copy_outlined, size: 14, color: Aether.textFaint),
          const SizedBox(width: 8),
          Semantics(
            header: true,
            child: Text(
              'FILES',
              style: AetherType.label.copyWith(
                letterSpacing: 1.4,
                color: Aether.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeEmpty extends StatelessWidget {
  const _TreeEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          'Connect a repo —\nfiles appear here live.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.6,
            color: Aether.textFaint,
          ),
        ),
      ),
    );
  }
}

class _TreeFooter extends StatelessWidget {
  const _TreeFooter({required this.ready, required this.count});

  final bool ready;
  final int count;

  @override
  Widget build(BuildContext context) {
    final text = ready ? 'Synced · $count files' : 'Not connected';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Aether.hairline)),
      ),
      child: Semantics(
        liveRegion: true,
        label: text,
        child: Row(
          children: [
            Icon(
              ready ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              size: 15,
              color: ready ? Aether.successLight : Aether.textFaint,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, color: Aether.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
