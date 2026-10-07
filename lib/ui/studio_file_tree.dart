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
  }

  @override
  void dispose() {
    RepoCache.I.removeListener(_bindingChanged);
    super.dispose();
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
        // Union of the tree and the live working copy: an agent-written file
        // that was never in the git tree still has to be reachable.
        final paths = <String>{...cache.treePaths, ...cache.files.keys, ...cache.pendingPaths};
        final nodes = buildStudioTree(paths, _expanded);
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
              if (nodes.isEmpty)
                const SliverToBoxAdapter(child: _TreeEmpty())
              else
                SliverList.builder(
                  itemCount: nodes.length,
                  itemBuilder: (_, i) => _row(nodes[i], active, cache),
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

  Widget _row(StudioTreeNode node, String? active, RepoCache cache) {
    final selected = !node.isDirectory && active == node.path;
    final failed = _failed.contains(node.path);
    final loading = _loading.contains(node.path);
    return _FileTreeRow(
      node: node,
      selected: selected,
      failed: failed,
      loading: loading,
      expanded: _expanded.contains(node.path),
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
    required this.onActivate,
  });

  final StudioTreeNode node;
  final bool selected;
  final bool failed;
  final bool loading;
  final bool expanded;
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

    final label = failed
        ? '${node.name}, could not be loaded — tap to retry'
        : node.isDirectory
            ? '${node.name}, folder, '
                '${widget.expanded ? 'expanded' : 'collapsed'}'
            : '${node.name}, file${selected ? ', open' : ''}';

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
              if (!node.isDirectory)
                StudioStagingMenu(path: node.path),
            ],
          ),
        )),
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
