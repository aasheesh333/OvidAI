import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
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

/// The code workspace: repository, branch, files and editor.
class V2StudioWorkspacePage extends StatefulWidget {
  const V2StudioWorkspacePage({
    super.key,
    required this.data,
    this.onBranchTap,
    this.onSync,
    this.onSelectFile,
    this.onCommit,
    this.onPreview,
    this.onMenu,
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
  final VoidCallback? onMenu;
  final VoidCallback? onPickRepo;
  final VoidCallback? onRetry;
  final VoidCallback? onCopyFile;

  @override
  State<V2StudioWorkspacePage> createState() => _V2StudioWorkspacePageState();
}

class _V2StudioWorkspacePageState extends State<V2StudioWorkspacePage> {
  /// A file the user picked whose code the wiring layer has not delivered yet.
  /// The viewer opens as soon as [V2StudioWorkspaceData.openFilePath] and the
  /// code lines catch up, so a live adapter can load file content in the
  /// background without the page inventing it.
  String? _pendingViewerPath;

  bool get _isBound =>
      widget.data.repoName.trim().isNotEmpty &&
      widget.data.branch.trim().isNotEmpty;

  @override
  void didUpdateWidget(covariant V2StudioWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pendingViewerPath;
    final data = widget.data;
    if (pending != null &&
        pending == data.openFilePath &&
        data.codeLines.isNotEmpty) {
      _pendingViewerPath = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pendingViewerPath != null) return;
        if (widget.data.openFilePath == pending) _openCodeViewer();
      });
    }
  }

  /// Maps a workspace node onto the shared searchable tree. The legacy
  /// [V2FileNode.changed] flag has no add/delete distinction, so it becomes a
  /// modification badge.
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
      _openCodeViewer();
      return;
    }
    // With a wiring callback the adapter will rebuild this page with the
    // selected file; didUpdateWidget opens the viewer once its code arrives.
    _pendingViewerPath = widget.onSelectFile == null ? null : path;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final hasRepo = data.status == V2WorkspaceStatus.content;
    final repoLabel = data.repoName.trim();
    return OScaffold(
      appBar: OAppBar(
        title: hasRepo && repoLabel.isNotEmpty ? repoLabel : 'Studio',
        subtitle: hasRepo ? 'Studio workspace' : 'Workspace',
        actions: [
          if (hasRepo) ...[
            OIconButton(
              icon: Icons.sync_rounded,
              semanticLabel: 'Sync changes',
              tooltip: 'Sync changes',
              onPressed: widget.onSync,
            ),
            if (widget.onMenu != null)
              OIconButton(
                icon: Icons.more_vert_rounded,
                semanticLabel: 'Workspace options',
                tooltip: 'Workspace options',
                onPressed: widget.onMenu,
              ),
          ],
        ],
      ),
      bottomNavigationBar: hasRepo ? _buildDock(context) : null,
      body: switch (data.status) {
        V2WorkspaceStatus.loading => const OSkeletonList(rows: 5),
        V2WorkspaceStatus.error => OErrorState(
          message:
              data.errorMessage ??
              'We could not open this repository. Check your connection and try again.',
          onRetry: widget.onRetry,
        ),
        V2WorkspaceStatus.empty => OEmptyState(
          icon: Icons.folder_off_outlined,
          title: 'No repository open',
          message: 'Pick a repository to start editing your files.',
          action: OButton(
            label: 'Pick a repository',
            icon: Icons.folder_open_rounded,
            onPressed: widget.onPickRepo,
          ),
        ),
        V2WorkspaceStatus.content => _buildContent(context),
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final data = widget.data;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: OFadeSlide(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (data.repoName.trim().isNotEmpty) ...[
                  _BindingChip(
                    repo: data.repoName.trim(),
                    branch: data.branch.trim(),
                  ),
                  const SizedBox(height: OSpace.m),
                ],
                if (data.branch.trim().isNotEmpty) ...[
                  _BranchBar(
                    branch: data.branch,
                    onBranchTap: widget.onBranchTap,
                  ),
                  const SizedBox(height: OSpace.m),
                ],
                if (data.syncCount > 0) ...[
                  _SyncBanner(count: data.syncCount, onSync: widget.onSync),
                  const SizedBox(height: OSpace.m),
                ],
                V2FileTree(
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
                const SizedBox(height: OSpace.m),
                if (_isBound)
                  _EditorPanel(
                    fileName: data.openFileName,
                    lines: data.codeLines,
                    saved: data.saved,
                    onOpenViewer: data.codeLines.isEmpty
                        ? null
                        : _openCodeViewer,
                    onCopyFile: data.openFileName.trim().isEmpty
                        ? null
                        : widget.onCopyFile,
                  )
                else
                  V2StudioGate(onPickRepo: widget.onPickRepo),
                if (_isBound) ...[
                  const SizedBox(height: OSpace.m),
                  const _LiveNote(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDock(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(
          OSpace.l,
          OSpace.m,
          OSpace.l,
          OSpace.m,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(
                    Icons.edit_note_rounded,
                    size: 21,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.filesChanged == 1
                            ? '1 file changed'
                            : '${data.filesChanged} files changed',
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '+${data.additions} / −${data.deletions} lines',
                        style: OType.caption.copyWith(color: c.success),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.m),
            Row(
              children: [
                Expanded(
                  child: OButton(
                    label: 'Commit',
                    variant: OButtonVariant.secondary,
                    onPressed: widget.onCommit,
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: OButton(
                    label: 'Preview',
                    icon: Icons.visibility_rounded,
                    onPressed: widget.onPreview,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BindingChip extends StatelessWidget {
  const _BindingChip({required this.repo, required this.branch});

  final String repo;
  final String branch;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = branch.isEmpty
        ? 'Bound to $repo'
        : 'Bound to $repo @ $branch';
    return Container(
      key: const Key('studio-binding-chip'),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.link_rounded, size: 18, color: c.accent),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              label,
              style: OType.bodySm.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchBar extends StatelessWidget {
  const _BranchBar({required this.branch, this.onBranchTap});

  final String branch;
  final VoidCallback? onBranchTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: OPressable(
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
            OButton(
              key: const Key('studio-change-branch'),
              label: 'Change branch',
              icon: Icons.alt_route_rounded,
              variant: OButtonVariant.secondary,
              size: OButtonSize.compact,
              onPressed: onBranchTap,
            ),
          ],
        );
      },
    );
  }
}

class _SyncBanner extends StatelessWidget {
  const _SyncBanner({required this.count, this.onSync});

  final int count;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Remote has $count new ${count == 1 ? 'change' : 'changes'}',
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$count ${count == 1 ? 'commit' : 'commits'} behind origin',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Align(
            alignment: Alignment.centerRight,
            child: _SyncChip(onTap: onSync),
          ),
        ],
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onTap != null;
    return OPressable(
      onTap: onTap,
      semanticLabel: 'Sync latest changes',
      child: Container(
        key: const Key('studio-sync-chip'),
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.m,
          vertical: OSpace.s,
        ),
        decoration: BoxDecoration(
          color: c.accentSoft,
          borderRadius: BorderRadius.circular(ORadius.pill),
          border: Border.all(color: c.accentFill.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.sync_rounded,
              size: 18,
              color: enabled ? c.accent : c.textFaint,
            ),
            const SizedBox(width: OSpace.xs),
            Flexible(
              child: Text(
                'Sync latest changes',
                style: OType.label.copyWith(
                  color: enabled ? c.accent : c.textFaint,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorPanel extends StatelessWidget {
  const _EditorPanel({
    required this.fileName,
    required this.lines,
    required this.saved,
    this.onOpenViewer,
    this.onCopyFile,
  });

  final String fileName;
  final List<V2CodeLine> lines;
  final bool saved;
  final VoidCallback? onOpenViewer;
  final VoidCallback? onCopyFile;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: c.surfaceAlt,
            padding: const EdgeInsets.fromLTRB(OSpace.m, 0, OSpace.s, 0),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: OSpace.s,
                    runSpacing: OSpace.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: OSpace.s,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: c.codeBg,
                          borderRadius: BorderRadius.circular(ORadius.s),
                        ),
                        child: Text(
                          fileName.trim().isEmpty ? 'No file open' : fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodySm.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      OPill(
                        label: saved ? 'Saved' : 'Unsaved',
                        tone: saved ? OPillTone.success : OPillTone.warn,
                        dot: true,
                      ),
                    ],
                  ),
                ),
                OIconButton(
                  key: const Key('studio-open-code-viewer'),
                  icon: Icons.open_in_full_rounded,
                  semanticLabel: 'Open file in code viewer',
                  tooltip: 'Open in viewer',
                  onPressed: onOpenViewer,
                ),
                if (onCopyFile != null)
                  OIconButton(
                    key: const Key('studio-copy-file'),
                    icon: Icons.copy_rounded,
                    semanticLabel: 'Copy file contents',
                    tooltip: 'Copy',
                    onPressed: onCopyFile,
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: c.hairline),
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.all(OSpace.xl),
              child: Text(
                'Choose a file to start editing.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: OSpace.m),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in lines) _CodeLineRow(line: line),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CodeLineRow extends StatelessWidget {
  const _CodeLineRow({required this.line});

  final V2CodeLine line;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: OSpace.m, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              line.number.toString().padLeft(2, '0'),
              textAlign: TextAlign.right,
              style: OType.mono.copyWith(color: c.textFaint),
            ),
          ),
          const SizedBox(width: OSpace.m),
          Text(
            line.text,
            softWrap: false,
            style: OType.mono.copyWith(color: c.text),
          ),
        ],
      ),
    );
  }
}

class _LiveNote extends StatelessWidget {
  const _LiveNote();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(
              Icons.lightbulb_outline_rounded,
              size: 19,
              color: c.accent,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cloud workspace connected',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Files load from your branch. Ovid writes edits in the '
                  'cloud workspace.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
