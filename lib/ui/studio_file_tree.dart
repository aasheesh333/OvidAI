import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/cloud/studio_files.dart';
import '../core/cloud/studio_remote_client.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'studio_errors.dart';
import 'studio_layout.dart';
import 'widgets/aether_primitives.dart';

// ── Studio file tree ────────────────────────────────────────────────────────
// The explorer now binds to the P7 workspace manifest (StudioRemoteClient)
// instead of the deleted local repo cache. Widget chrome survives; only the
// data binding and the removed staging menu changed.
//
// Directories are derived from the server's nested FileNode tree (the built
// `GET …/workspace/tree` response), so an empty directory is still a
// directory and a failed fetch is a visible, retryable row.

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

String _leaf(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Flattens the server's nested manifest tree into rows, revealing the
/// children of every directory in [expandedDirs]. Empty directories and
/// directory rollups from a pruned manifest are preserved: the server's tree
/// is authoritative (unlike the deleted path-set heuristic).
List<StudioTreeNode> flattenStudioTree(
  FileNode? root,
  Set<String> expandedDirs,
) {
  assert(() {
    debugStudioTreeBuilds++;
    return true;
  }());
  if (root == null) return const <StudioTreeNode>[];
  final out = <StudioTreeNode>[];
  void walk(FileNode node, int depth) {
    final children = [...node.children];
    children.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.path.compareTo(b.path);
    });
    for (final child in children) {
      out.add(StudioTreeNode(
        path: child.path,
        name: child.name.isEmpty ? _leaf(child.path) : child.name,
        isDirectory: child.isDir,
        depth: depth,
      ));
      if (child.isDir && expandedDirs.contains(child.path)) {
        walk(child, depth + 1);
      }
    }
  }

  walk(root, 0);
  return out;
}

/// [flattenStudioTree] call counter for rebuild-scope tests (debug only).
@visibleForTesting
int debugStudioTreeBuilds = 0;

/// The cloud workspace file explorer bound to [StudioRemoteClient].
class StudioFileTree extends StatefulWidget {
  const StudioFileTree({super.key, this.sessionId});

  /// Explicit server-session binding (tests); null falls back to [AppState].
  final String? sessionId;

  @override
  State<StudioFileTree> createState() => _StudioFileTreeState();
}

class _StudioFileTreeState extends State<StudioFileTree> {
  final Set<String> _expanded = <String>{};
  final Set<String> _failed = <String>{};
  final Set<String> _loading = <String>{};

  Object? _treeKey;
  Set<String> _expandedAtBuild = const <String>{};
  List<StudioTreeNode> _tree = const [];

  String get _sid => widget.sessionId ?? AppState.I.activeSession?.id ?? '';
  StudioRemoteClient get _remote => StudioRemoteClient.I;

  List<StudioTreeNode> _nodes() {
    final snapshot = _remote.snapshotFor(_sid);
    // The snapshot's IDENTITY does not change when the user expands a folder,
    // so the expansion set is part of the cache key. Keying on the snapshot
    // alone made a tap flip the chevron but never render the children.
    if (identical(snapshot, _treeKey) &&
        setEquals(_expanded, _expandedAtBuild)) {
      return _tree;
    }
    _treeKey = snapshot;
    _expandedAtBuild = Set<String>.of(_expanded);
    return _tree = flattenStudioTree(snapshot?.root, _expanded);
  }

  @override
  void initState() {
    super.initState();
    // Opening the tree is the explicit refresh: the manifest is the <100 ms
    // SLA path on the server. StudioScreen already refreshes the manifest on
    // open; only fetch here when the tree is used standalone (tests) or the
    // screen's refresh has not started yet. This keeps one GET per open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_remote.snapshotFor(_sid) == null && !_remote.treeLoading(_sid)) {
        _remote.syncStudioTabs(_sid);
      }
    });
  }

  /// Opens a file, or toggles a directory.
  Future<void> _activate(StudioTreeNode node) async {
    if (node.isDirectory) {
      setState(() {
        if (!_expanded.remove(node.path)) _expanded.add(node.path);
      });
      return;
    }
    if (_loading.contains(node.path)) return;
    if (_remote.isStudioFileDirty(_sid, node.path)) {
      // An unsaved draft wins over the server bytes: bring its tab forward.
      _remote.focusStudioFile(_sid, node.path);
      return;
    }
    setState(() {
      _loading.add(node.path);
      _failed.remove(node.path);
    });
    try {
      await _remote.openStudioFile(_sid, node.path);
      if (mounted) setState(() => _loading.remove(node.path));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading.remove(node.path);
        _failed.add(node.path);
      });
      showStudioToast(context, StudioFailure.of(error).message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_remote, _remote.tabsFor(_sid)]),
      builder: (context, _) {
        final nodes = _nodes();
        final active = _remote.activeFilePath(_sid);
        final snapshot = _remote.snapshotFor(_sid);

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
                SliverToBoxAdapter(
                  child: _TreeEmpty(
                    loading: _remote.treeLoading(_sid),
                    error: _remote.treeError(_sid),
                    onRetry: () => _remote.syncStudioTabs(_sid),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: nodes.length,
                  itemBuilder: (_, i) => _row(nodes[i], active),
                ),
              SliverToBoxAdapter(
                child: _TreeFooter(
                  state: snapshot?.state ?? 'unknown',
                  ready: snapshot != null,
                  count: snapshot?.fileCount ?? 0,
                  truncated: snapshot?.truncated ?? false,
                  loading: _remote.treeLoading(_sid),
                  onRefresh: () => _remote.syncStudioTabs(_sid),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(StudioTreeNode node, String? active) {
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
      iconColor = Aether.danger;
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
          // Deep directory nesting must still leave room for the filename.
          // The full path remains available through a tooltip.
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
                            ? Aether.danger
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
            ],
          ),
        )),
      ),
    );
  }
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
  const _TreeEmpty({
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error == null
                  ? 'No files yet —\nthe cloud workspace appears here.'
                  : 'Could not load the workspace tree.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Aether.textFaint,
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TreeFooter extends StatelessWidget {
  const _TreeFooter({
    required this.state,
    required this.ready,
    required this.count,
    required this.truncated,
    required this.loading,
    required this.onRefresh,
  });

  final String state;
  final bool ready;
  final int count;
  final bool truncated;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final text = !ready
        ? (loading ? 'Loading workspace…' : 'Not connected')
        : '$state · $count files${truncated ? ' · pruned' : ''}';
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
              state == 'warm'
                  ? Icons.cloud_done_outlined
                  : state == 'hydrating'
                      ? Icons.hourglass_top_rounded
                      : Icons.cloud_off_outlined,
              size: 15,
              color: state == 'warm'
                  ? Aether.success
                  : state == 'hydrating'
                      ? Aether.warn
                      : Aether.textFaint,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, color: Aether.textMuted),
              ),
            ),
            StudioIconButton(
              icon: Icons.refresh,
              tooltip: 'Refresh workspace',
              iconSize: 16,
              onPressed: loading ? null : onRefresh,
            ),
          ],
        ),
      ),
    );
  }
}
