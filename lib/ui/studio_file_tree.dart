import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/studio_files.dart';
import '../core/cloud/studio_remote_client.dart';
import '../core/theme.dart';
import 'studio_errors.dart';
import 'studio_file_actions.dart';
import 'studio_layout.dart';
import 'widgets/aether_primitives.dart';

// ── Studio file tree ────────────────────────────────────────────────────────
// The explorer binds to the user's cloud workspace manifest
// (StudioRemoteClient). Directories come from the server's nested FileNode
// tree, so an empty directory is still a directory and a failed file fetch is
// a visible, retryable row. Rows open on tap; a long-press (or right-click)
// opens rename / delete / new-file-here (ST-008). Folders the <5 KB manifest
// pruned get a "Show N more" row that lists them from the live workspace
// (ST-015).

/// What one tree row is.
enum StudioTreeRowKind { file, directory, more }

/// One row of the tree.
class StudioTreeNode {
  const StudioTreeNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.depth,
    this.kind,
    this.hiddenCount = 0,
  });

  /// Full workspace path, normalised (no leading `/`, no empty segments). For
  /// a [StudioTreeRowKind.more] row: the pruned folder's path.
  final String path;

  /// Leaf name shown in the row.
  final String name;

  final bool isDirectory;

  /// Indent level; 0 is the workspace root.
  final int depth;

  final StudioTreeRowKind? kind;

  /// Entries the manifest left out of a pruned folder (a "more" row).
  final int hiddenCount;

  StudioTreeRowKind get rowKind =>
      kind ??
      (isDirectory ? StudioTreeRowKind.directory : StudioTreeRowKind.file);

  bool get isMore => rowKind == StudioTreeRowKind.more;

  @override
  String toString() => 'StudioTreeNode($path, dir=$isDirectory, d=$depth'
      '${isMore ? ', more=$hiddenCount' : ''})';
}

String _leaf(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Entries of a folder the manifest did not include: siblings it dropped to
/// stay under budget (`omitted`), or the whole content of a folder pruned at
/// the depth cap (rollups with no children).
int _hiddenEntries(FileNode dir) {
  if (dir.omitted > 0) return dir.omitted;
  if (dir.children.isEmpty) return (dir.files ?? 0) + (dir.dirs ?? 0);
  return 0;
}

/// Flattens the server's nested manifest tree into rows, revealing the
/// children of every directory in [expandedDirs]. An expanded folder the
/// manifest pruned ends with a "more" row — unless it is in [loadedDirs]
/// (already listed from the live workspace).
List<StudioTreeNode> flattenStudioTree(
  FileNode? root,
  Set<String> expandedDirs, {
  Set<String> loadedDirs = const <String>{},
}) {
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
        final hidden = _hiddenEntries(child);
        if (hidden > 0 && !loadedDirs.contains(child.path)) {
          out.add(StudioTreeNode(
            path: child.path,
            name: 'Show $hidden more',
            isDirectory: false,
            depth: depth + 1,
            kind: StudioTreeRowKind.more,
            hiddenCount: hidden,
          ));
        }
      }
    }
  }

  walk(root, 0);
  return out;
}

/// [flattenStudioTree] call counter for rebuild-scope tests (debug only).
@visibleForTesting
int debugStudioTreeBuilds = 0;

/// Tree-row type size (ST-020: 12px mono was too small on a phone).
const double kStudioTreeFontSize = 13.5;

/// The cloud workspace file explorer bound to [StudioRemoteClient].
class StudioFileTree extends StatefulWidget {
  const StudioFileTree({super.key, this.sessionId});

  /// The Studio bucket key; null is the user's workspace
  /// ([kStudioWorkspaceKey]).
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
  Set<String> _loadedAtBuild = const <String>{};
  List<StudioTreeNode> _tree = const [];

  String get _sid => widget.sessionId ?? kStudioWorkspaceKey;
  StudioRemoteClient get _remote => StudioRemoteClient.I;

  List<StudioTreeNode> _nodes() {
    final snapshot = _remote.snapshotFor(_sid);
    final loaded = {
      for (final dir in _expanded)
        if (_remote.subtreeLoaded(_sid, dir)) dir,
    };
    // The snapshot's IDENTITY does not change when the user expands a folder,
    // so the expansion set is part of the cache key. Keying on the snapshot
    // alone made a tap flip the chevron but never render the children.
    if (identical(snapshot, _treeKey) &&
        setEquals(_expanded, _expandedAtBuild) &&
        setEquals(loaded, _loadedAtBuild)) {
      return _tree;
    }
    _treeKey = snapshot;
    _expandedAtBuild = Set<String>.of(_expanded);
    _loadedAtBuild = loaded;
    return _tree =
        flattenStudioTree(snapshot?.root, _expanded, loadedDirs: loaded);
  }

  @override
  void initState() {
    super.initState();
    // StudioScreen refreshes on open; a tree used standalone (tests) fetches
    // here. refreshWorkspace is single-flight, so this never doubles a GET.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_remote.snapshotFor(_sid) == null && !_remote.treeLoading(_sid)) {
        _remote.refreshWorkspace(_sid);
      }
    });
  }

  /// Opens a file, toggles a directory, or loads a pruned folder.
  Future<void> _activate(StudioTreeNode node) async {
    if (node.isMore) return _loadMore(node.path);
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
      showStudioToast(context, StudioFailure.messageOf(error), error: true);
    }
  }

  Future<void> _loadMore(String dir) async {
    try {
      await _remote.loadStudioSubtree(_sid, dir);
    } catch (error) {
      if (!mounted) return;
      final waking = error is CloudApiException && error.code == 'not_warm';
      showStudioToast(
        context,
        waking
            ? 'Waking your workspace to list this folder — try again in a '
                'moment.'
            : StudioFailure.messageOf(error),
        error: !waking,
      );
    }
  }

  void _showActions(StudioTreeNode node) {
    if (node.isMore) return;
    showStudioPathActions(
      context,
      _sid,
      path: node.path,
      isFolder: node.isDirectory,
    );
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
              SliverToBoxAdapter(
                child: _TreeHeader(
                  onNewFile: () => studioNewFile(context, _sid),
                  onNewFolder: () => studioNewFolder(context, _sid),
                ),
              ),
              SliverToBoxAdapter(
                child: Divider(height: 1, thickness: 1, color: Aether.hairline),
              ),
              if (nodes.isEmpty)
                SliverToBoxAdapter(
                  child: _TreeEmpty(
                    loading: _remote.treeLoading(_sid) && snapshot == null,
                    loaded: snapshot != null,
                  ),
                )
              else
                SliverList.builder(
                  itemCount: nodes.length,
                  itemBuilder: (_, i) => _row(nodes[i], active),
                ),
              SliverToBoxAdapter(
                child: _TreeFooter(
                  ready: snapshot != null,
                  count: snapshot?.fileCount ?? 0,
                  truncated: snapshot?.truncated ?? false,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(StudioTreeNode node, String? active) {
    if (node.isMore) {
      return _MoreRow(
        node: node,
        loading: _remote.subtreeLoading(_sid, node.path),
        onActivate: () => _activate(node),
      );
    }
    final selected = !node.isDirectory && active == node.path;
    return _FileTreeRow(
      node: node,
      selected: selected,
      failed: _failed.contains(node.path),
      loading: _loading.contains(node.path),
      dirty: !node.isDirectory && _remote.isStudioFileDirty(_sid, node.path),
      expanded: _expanded.contains(node.path),
      onActivate: () => _activate(node),
      onActions: () => _showActions(node),
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
    required this.dirty,
    required this.expanded,
    required this.onActivate,
    required this.onActions,
  });

  final StudioTreeNode node;
  final bool selected;
  final bool failed;
  final bool loading;
  final bool dirty;
  final bool expanded;
  final VoidCallback onActivate;
  final VoidCallback onActions;

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
            : '${node.name}, file'
                '${widget.dirty ? ', unsaved changes' : ''}'
                '${selected ? ', open' : ''}';

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
      child: Listener(
        // Right-click / secondary tap opens the same actions as long-press.
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.mouse &&
              event.buttons == kSecondaryMouseButton) {
            widget.onActions();
          }
        },
        child: Semantics(
          onLongPressHint: 'show file actions',
          child: StudioTapTarget(
            onTap: widget.onActivate,
            onLongPress: widget.onActions,
            label: label,
            selected: selected,
            minWidth: 0,
            child: LayoutBuilder(
              builder: (context, constraints) => AnimatedContainer(
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOut,
                color: background,
                // Deep directory nesting must still leave room for the
                // filename. The full path remains available through a tooltip.
                padding: EdgeInsets.only(
                    left: indent.clamp(
                        8.0, (constraints.maxWidth * 0.25).clamp(8.0, 80.0)),
                    right: 8),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(icon, size: 16, color: iconColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Tooltip(
                        message: node.path,
                        // Hover only: a touch long-press belongs to the row's
                        // file actions, not to the tooltip.
                        triggerMode: TooltipTriggerMode.manual,
                        child: Text(
                          node.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: kStudioTreeFontSize,
                            fontFamily: Aether.mono,
                            fontFamilyFallback: kStudioMonoFallback,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected
                                ? Aether.accent
                                : failed
                                    ? Aether.danger
                                    : node.isDirectory
                                        ? Aether.text
                                        : Aether.textMuted,
                          ),
                        ),
                      ),
                    ),
                    if (widget.dirty)
                      ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(Icons.circle,
                              size: 7, color: Aether.warnLight),
                        ),
                      ),
                    if (node.isDirectory)
                      Icon(
                        widget.expanded
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 16,
                        color: Aether.textFaint,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Show N more" under a folder the manifest pruned (ST-015).
class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.node,
    required this.loading,
    required this.onActivate,
  });

  final StudioTreeNode node;
  final bool loading;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final indent = 8.0 + node.depth * 14.0;
    final noun = node.hiddenCount == 1 ? 'item' : 'items';
    return StudioTapTarget(
      onTap: loading ? null : onActivate,
      label: 'Show ${node.hiddenCount} more $noun in ${_leaf(node.path)}',
      minWidth: 0,
      child: LayoutBuilder(
        builder: (context, constraints) => Container(
          padding: EdgeInsets.only(
              left: indent.clamp(
                  8.0, (constraints.maxWidth * 0.25).clamp(8.0, 80.0)),
              right: 8),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.more_horiz, size: 16, color: Aether.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Show ${node.hiddenCount} more $noun',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Aether.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TreeHeader extends StatelessWidget {
  const _TreeHeader({required this.onNewFile, required this.onNewFolder});

  final VoidCallback onNewFile;
  final VoidCallback onNewFolder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 2, 2),
      child: Row(
        children: [
          Icon(Icons.folder_copy_outlined, size: 14, color: Aether.textFaint),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'FILES',
                style: AetherType.label.copyWith(
                  letterSpacing: 1.4,
                  color: Aether.textFaint,
                ),
              ),
            ),
          ),
          StudioIconButton(
            key: studioTreeNewFileKey,
            icon: Icons.note_add_outlined,
            tooltip: 'New file',
            iconSize: 18,
            onPressed: onNewFile,
          ),
          StudioIconButton(
            key: studioTreeNewFolderKey,
            icon: Icons.create_new_folder_outlined,
            tooltip: 'New folder',
            iconSize: 18,
            onPressed: onNewFolder,
          ),
        ],
      ),
    );
  }
}

/// Tree header actions (tests target them).
const Key studioTreeNewFileKey = Key('studio-tree-new-file');
const Key studioTreeNewFolderKey = Key('studio-tree-new-folder');

/// Empty tree body. Load errors are NOT repeated here — the screen's single
/// status strip owns them (ST-010).
class _TreeEmpty extends StatelessWidget {
  const _TreeEmpty({required this.loading, required this.loaded});

  final bool loading;
  final bool loaded;

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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        loaded
            ? 'No files yet. Ask Ovid in chat to create some, or add one '
                'with New file.'
            : 'Your files appear here.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, height: 1.5, color: Aether.textMuted),
      ),
    );
  }
}

/// File count and the pruned-manifest hint. Not a live region: it changes on
/// every refresh and must not re-announce (ST-020).
class _TreeFooter extends StatelessWidget {
  const _TreeFooter({
    required this.ready,
    required this.count,
    required this.truncated,
  });

  final bool ready;
  final int count;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    if (!ready) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Aether.hairline)),
      ),
      child: Text(
        truncated
            ? '$count ${count == 1 ? 'file' : 'files'} · large folders load '
                'when you open them'
            : '$count ${count == 1 ? 'file' : 'files'}',
        style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
      ),
    );
  }
}
