import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'code_viewer.dart';
import 'file_tree.dart';
import 'studio_gate.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// What the workspace is doing right now.
enum V2WorkspaceStatus { loading, content, empty, error }

/// One folder or file in the workspace tree.
@immutable
class V2FileNode {
  const V2FileNode({
    required this.name,
    this.path,
    this.children = const <V2FileNode>[],
    this.changed = false,
  });

  final String name;
  final String? path;
  final List<V2FileNode> children;
  final bool changed;

  bool get isFolder => children.isNotEmpty;
  String get id => path ?? name;
}

/// One line in the open file.
@immutable
class V2CodeLine {
  const V2CodeLine({required this.number, required this.text});

  final int number;
  final String text;
}

/// Everything the workspace needs to render. Supplied by the wiring layer.
@immutable
class V2StudioWorkspaceData {
  const V2StudioWorkspaceData({
    required this.repoName,
    required this.branch,
    this.status = V2WorkspaceStatus.content,
    this.filesChanged = 0,
    this.additions = 0,
    this.deletions = 0,
    this.syncCount = 0,
    this.fileTree = const <V2FileNode>[],
    this.openFileName = '',
    this.openFilePath = '',
    this.codeLines = const <V2CodeLine>[],
    this.saved = true,
    this.errorMessage,
  });

  final V2WorkspaceStatus status;
  final String repoName;
  final String branch;
  final int filesChanged;
  final int additions;
  final int deletions;
  final int syncCount;
  final List<V2FileNode> fileTree;
  final String openFileName;
  final String openFilePath;
  final List<V2CodeLine> codeLines;
  final bool saved;
  final String? errorMessage;
}

/// The code workspace: one tree column, one editor, one branch chip.
///
/// Wide layout (600 dp+) keeps the tree beside the editor. Below 600 dp the
/// tree fills the screen and picking a file pushes the full code viewer.
class V2StudioWorkspacePage extends StatefulWidget {
  const V2StudioWorkspacePage({
    super.key,
    required this.data,
    this.onBranchTap,
    this.onSync,
    this.onSelectFile,
    this.onCommit,
    this.onPreview,
    this.onPickRepo,
    this.onRetry,
    this.onCopyFile,
  });

  final V2StudioWorkspaceData data;
  final VoidCallback? onBranchTap;
  final VoidCallback? onSync;
  final ValueChanged<String>? onSelectFile;
  final VoidCallback? onCommit;
  final VoidCallback? onPreview;
  final VoidCallback? onPickRepo;
  final VoidCallback? onRetry;
  final VoidCallback? onCopyFile;

  @override
  State<V2StudioWorkspacePage> createState() => _V2StudioWorkspacePageState();
}

class _V2StudioWorkspacePageState extends State<V2StudioWorkspacePage> {
  /// A file the user picked whose code the wiring layer has not delivered yet.
  /// On a narrow screen the viewer opens as soon as the code arrives.
  String? _pendingViewerPath;

  bool get _isBound =>
      widget.data.repoName.trim().isNotEmpty &&
      widget.data.branch.trim().isNotEmpty;

  bool get _isWide => _columnWidth >= OBreakpoints.tablet;

  /// The width the page actually gets. The shell removes its navigation column
  /// before laying the page out, so at a 600 dp window the page only has 320 dp
  /// even though `MediaQuery` still reports 600. Two-pane decisions follow the
  /// column, not the window.
  double _columnWidth = 0;

  @override
  void didUpdateWidget(covariant V2StudioWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pendingViewerPath;
    final data = widget.data;
    if (pending != null &&
        pending == data.openFilePath &&
        data.codeLines.isNotEmpty) {
      _pendingViewerPath = null;
      if (!_isWide) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _pendingViewerPath != null) return;
          if (widget.data.openFilePath == pending) _openCodeViewer();
        });
      }
    }
  }

  /// Maps a workspace node onto the shared tree.
  V2FileTreeEntry _treeEntry(V2FileNode node) {
    return V2FileTreeEntry(
      name: node.name,
      path: node.path,
      isFolder: node.isFolder,
      change: node.changed ? V2FileChange.modified : null,
      children: [for (final child in node.children) _treeEntry(child)],
    );
  }

  V2CodeViewerData _viewerData() {
    final data = widget.data;
    return V2CodeViewerData(
      fileName: data.openFileName,
      filePath: data.openFilePath,
      lines: [
        for (final line in data.codeLines)
          V2CodeViewerLine(number: line.number, text: line.text),
      ],
    );
  }

  void _openCodeViewer() {
    final data = widget.data;
    if (data.openFilePath.trim().isEmpty && data.codeLines.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (viewerContext) => V2CodeViewerPage(
          data: _viewerData(),
          onCopy: widget.onCopyFile,
          onBack: () => Navigator.of(viewerContext).maybePop(),
        ),
      ),
    );
  }

  void _selectFile(String path) {
    widget.onSelectFile?.call(path);
    final data = widget.data;
    if (path == data.openFilePath && data.codeLines.isNotEmpty) {
      _pendingViewerPath = null;
      if (!_isWide) _openCodeViewer();
      return;
    }
    // With a wiring callback the adapter rebuilds this page with the selected
    // file; on a narrow screen the viewer opens once its code arrives.
    _pendingViewerPath = widget.onSelectFile == null ? null : path;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final hasRepo = data.status == V2WorkspaceStatus.content;
    final repoLabel = data.repoName.trim();
    return OScreen(
      title: hasRepo && repoLabel.isNotEmpty ? repoLabel : 'Studio',
      padding: false,
      actions: hasRepo && _isBound
          ? [
              _HeaderActions(
                branch: data.branch,
                syncCount: data.syncCount,
                onBranchTap: widget.onBranchTap,
                onSync: widget.onSync,
              ),
            ]
          : const <Widget>[],
      child: switch (data.status) {
        V2WorkspaceStatus.loading => const OSkeletonList(rows: 6),
        V2WorkspaceStatus.error => OErrorState(
          message: data.errorMessage ?? 'This workspace did not open.',
          onRetry: widget.onRetry,
        ),
        V2WorkspaceStatus.empty => OEmptyState(
          icon: Icons.folder_off_outlined,
          title: 'No repository open',
          message: '',
          action: OButton(
            label: 'Pick a repository',
            icon: Icons.folder_open_rounded,
            onPressed: widget.onPickRepo,
          ),
        ),
        V2WorkspaceStatus.content => _buildWorkspace(context),
      },
    );
  }

  Widget _buildWorkspace(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The page column, not the window: the shell has already removed its
        // navigation column from the width MediaQuery still reports.
        final width = constraints.maxWidth;
        _columnWidth = width;
        final c = OColors.of(context);
        final data = widget.data;
        final wide = width >= OBreakpoints.tablet;
        // The 320 dp tree is only worth its cost when the column has the wide
        // band's full 720; a 600 dp column beside the rail keeps 280.
        final treeWidth =
            width >= OBreakpoints.contentMaxWidth(OBreakpoints.wide)
            ? 320.0
            : 280.0;
        final tree = SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: OSpace.l),
          child: V2FileTree(
            key: const Key('studio-file-tree'),
            data: V2FileTreeData(
              status: data.fileTree.isEmpty
                  ? V2FileTreeStatus.empty
                  : V2FileTreeStatus.content,
              nodes: [for (final node in data.fileTree) _treeEntry(node)],
              selectedPath: data.openFilePath.trim().isEmpty
                  ? null
                  : data.openFilePath,
            ),
            onSelectFile: _selectFile,
            onRetry: widget.onRetry,
            onRefresh: widget.onRetry ?? widget.onSync,
          ),
        );

        final body = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    key: const Key('studio-tree-column'),
                    width: treeWidth,
                    child: tree,
                  ),
                  VerticalDivider(width: 1, thickness: 1, color: c.hairline),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: OSpace.l),
                      child: _isBound
                          ? _EditorPane(
                              data: data,
                              onOpenViewer: data.codeLines.isEmpty
                                  ? null
                                  : _openCodeViewer,
                            )
                          : V2StudioGate(onPickRepo: widget.onPickRepo),
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_isBound) V2StudioGate(onPickRepo: widget.onPickRepo),
                  Expanded(child: tree),
                ],
              );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.m,
                  OSpace.l,
                  0,
                ),
                child: body,
              ),
            ),
            if (_isBound)
              _StatusBar(
                filesChanged: data.filesChanged,
                additions: data.additions,
                deletions: data.deletions,
                onChanges: widget.onCommit,
                onPreview: widget.onPreview,
              ),
          ],
        );
      },
    );
  }
}

/// Branch chip plus the one sync control. Kept in a single header slot so a
/// compact header never drops the branch.
class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.branch,
    required this.syncCount,
    this.onBranchTap,
    this.onSync,
  });

  final String branch;
  final int syncCount;
  final VoidCallback? onBranchTap;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 148),
          child: OPressable(
            key: const Key('studio-branch-chip'),
            onTap: onBranchTap,
            semanticLabel: 'Branch $branch',
            child: SizedBox(
              height: OSpace.touch,
              child: Center(
                widthFactor: 1,
                child: OChip(
                  label: branch,
                  icon: Icons.account_tree_outlined,
                  selected: true,
                ),
              ),
            ),
          ),
        ),
        OIconButton(
          key: const Key('studio-sync'),
          icon: Icons.sync_rounded,
          semanticLabel: 'Sync changes',
          tooltip: 'Sync',
          onPressed: onSync,
          badge: syncCount > 0
              ? Text(
                  '$syncCount',
                  style: OType.caption.copyWith(
                    color: OColors.of(context).onAccent,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

/// The editor beside the tree: one file name, one open control, the code.
class _EditorPane extends StatelessWidget {
  const _EditorPane({required this.data, this.onOpenViewer});

  final V2StudioWorkspaceData data;
  final VoidCallback? onOpenViewer;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final name = data.openFileName.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: OSpace.touch,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name.isEmpty ? 'No file open' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!data.saved)
                const OPill(label: 'Unsaved', tone: OPillTone.warn, dot: true),
              OIconButton(
                key: const Key('studio-open-code-viewer'),
                icon: Icons.open_in_full_rounded,
                semanticLabel: 'Open file in code viewer',
                tooltip: 'Open in viewer',
                onPressed: onOpenViewer,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: c.hairline),
        Expanded(
          child: data.codeLines.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(
                    top: OSpace.s,
                    bottom: OSpace.l,
                  ),
                  child: V2CodeBody(
                    key: ValueKey<String>(data.openFilePath),
                    data: V2CodeViewerData(
                      fileName: data.openFileName,
                      filePath: data.openFilePath,
                      lines: [
                        for (final line in data.codeLines)
                          V2CodeViewerLine(
                            number: line.number,
                            text: line.text,
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// IDE-style status bar: changes on the left, preview on the right. Both are
/// compact text actions, never full-width buttons.
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.filesChanged,
    required this.additions,
    required this.deletions,
    this.onChanges,
    this.onPreview,
  });

  final int filesChanged;
  final int additions;
  final int deletions;
  final VoidCallback? onChanges;
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final changes = filesChanged == 1 ? '1 change' : '$filesChanged changes';
    final diff = '+$additions −$deletions';
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: _BarAction(
              key: const Key('studio-open-changes'),
              icon: Icons.difference_rounded,
              label: changes,
              meta: diff,
              onTap: onChanges,
              semanticLabel: '$changes, $diff',
            ),
          ),
          Expanded(
            flex: 2,
            child: _BarAction(
              key: const Key('studio-open-preview'),
              icon: Icons.visibility_rounded,
              label: 'Preview',
              onTap: onPreview,
              semanticLabel: 'Open live preview',
            ),
          ),
        ],
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    super.key,
    required this.icon,
    required this.label,
    this.meta,
    this.onTap,
    this.semanticLabel,
  });

  final IconData icon;
  final String label;

  /// A count or diff summary that sits beside the label on the same line.
  final String? meta;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = onTap == null ? c.textFaint : c.textMuted;
    return OPressable(
      onTap: onTap,
      semanticLabel: semanticLabel ?? label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(color: color),
                ),
              ),
              if (meta != null) ...[
                const SizedBox(width: OSpace.xs),
                Flexible(
                  child: Text(
                    meta!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textFaint),
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
