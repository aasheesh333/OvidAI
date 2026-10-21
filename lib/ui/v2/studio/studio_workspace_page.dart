import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

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
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _expandFoldersForOpenFile(widget.data.fileTree);
  }

  @override
  void didUpdateWidget(covariant V2StudioWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.openFilePath != widget.data.openFilePath) {
      _expandFoldersForOpenFile(widget.data.fileTree);
    }
  }

  bool _containsOpenFile(V2FileNode node) {
    if (node.path == widget.data.openFilePath) return true;
    return node.children.any(_containsOpenFile);
  }

  void _expandFoldersForOpenFile(List<V2FileNode> nodes) {
    for (final node in nodes) {
      if (node.isFolder && _containsOpenFile(node)) {
        _expanded.add(node.id);
        _expandFoldersForOpenFile(node.children);
      }
    }
  }

  void _toggleFolder(V2FileNode node) {
    setState(() {
      if (!_expanded.add(node.id)) {
        _expanded.remove(node.id);
      }
    });
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
                _FileExplorer(
                  nodes: data.fileTree,
                  expanded: _expanded,
                  onToggleFolder: _toggleFolder,
                  onSelectFile: widget.onSelectFile,
                  openFilePath: data.openFilePath,
                  fileCount: _countFiles(data.fileTree),
                ),
                const SizedBox(height: OSpace.m),
                _EditorPanel(
                  fileName: data.openFileName,
                  lines: data.codeLines,
                  saved: data.saved,
                  onCopyFile: data.openFileName.trim().isEmpty
                      ? null
                      : widget.onCopyFile,
                ),
                const SizedBox(height: OSpace.m),
                const _LiveNote(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int _countFiles(List<V2FileNode> nodes) {
    var count = 0;
    for (final node in nodes) {
      if (node.isFolder) {
        count += _countFiles(node.children);
      } else {
        count += 1;
      }
    }
    return count;
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

class _BranchBar extends StatelessWidget {
  const _BranchBar({required this.branch, this.onBranchTap});

  final String branch;
  final VoidCallback? onBranchTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
          ),
          child: Icon(Icons.terminal_rounded, size: 20, color: c.accent),
        ),
        const SizedBox(width: OSpace.m),
        Flexible(
          child: OPressable(
            onTap: onBranchTap,
            semanticLabel: 'Branch $branch',
            child: SizedBox(
              height: OSpace.touch,
              // The chip keeps its natural width; a very long branch name
              // scrolls sideways instead of overflowing or clipping.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Center(
                  child: OChip(
                    label: branch,
                    icon: Icons.account_tree_outlined,
                    selected: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
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
            child: OButton(label: 'Sync latest changes', onPressed: onSync),
          ),
        ],
      ),
    );
  }
}

class _FileExplorer extends StatelessWidget {
  const _FileExplorer({
    required this.nodes,
    required this.expanded,
    required this.onToggleFolder,
    required this.openFilePath,
    required this.fileCount,
    this.onSelectFile,
  });

  final List<V2FileNode> nodes;
  final Set<String> expanded;
  final ValueChanged<V2FileNode> onToggleFolder;
  final ValueChanged<String>? onSelectFile;
  final String openFilePath;
  final int fileCount;

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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OSpace.l,
              OSpace.m,
              OSpace.l,
              OSpace.s,
            ),
            child: Row(
              children: [
                Icon(Icons.folder_open_rounded, size: 18, color: c.accent),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    'EXPLORER',
                    style: OType.overline.copyWith(color: c.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Text(
                  fileCount == 1 ? '1 file' : '$fileCount files',
                  style: OType.caption.copyWith(color: c.textFaint),
                  maxLines: 1,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.hairline),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: OSpace.xs),
            child: OStagger(
              children: [
                for (final node in nodes)
                  _FileTreeTile(
                    node: node,
                    depth: 0,
                    expanded: expanded,
                    openFilePath: openFilePath,
                    onToggleFolder: onToggleFolder,
                    onSelectFile: onSelectFile,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileTreeTile extends StatelessWidget {
  const _FileTreeTile({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.openFilePath,
    required this.onToggleFolder,
    this.onSelectFile,
  });

  final V2FileNode node;
  final int depth;
  final Set<String> expanded;
  final String openFilePath;
  final ValueChanged<V2FileNode> onToggleFolder;
  final ValueChanged<String>? onSelectFile;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final isOpen = expanded.contains(node.id);
    final isSelected =
        openFilePath.isNotEmpty &&
        !node.isFolder &&
        (node.path ?? node.name) == openFilePath;
    final canTap = node.isFolder || onSelectFile != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: isSelected ? c.accentSoft : Colors.transparent,
          child: InkWell(
            onTap: !canTap
                ? null
                : node.isFolder
                ? () => onToggleFolder(node)
                : () => onSelectFile?.call(node.path ?? node.name),
            child: Semantics(
              label: '${node.isFolder ? 'Folder' : 'File'} ${node.name}',
              button: canTap,
              enabled: canTap,
              expanded: node.isFolder ? isOpen : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: OSpace.touch),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: OSpace.m + depth * OSpace.l,
                    right: OSpace.l,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        node.isFolder
                            ? (isOpen
                                  ? Icons.folder_open_rounded
                                  : Icons.folder_rounded)
                            : Icons.description_outlined,
                        size: 19,
                        color: isSelected ? c.accent : c.textMuted,
                      ),
                      const SizedBox(width: OSpace.s),
                      Expanded(
                        child: Text(
                          node.name,
                          style: OType.bodySm.copyWith(
                            color: isSelected ? c.accent : c.text,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (node.changed)
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (node.isFolder) ...[
                        const SizedBox(width: OSpace.xs),
                        Icon(
                          isOpen
                              ? Icons.expand_more_rounded
                              : Icons.chevron_right_rounded,
                          size: 20,
                          color: c.textFaint,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (node.isFolder && isOpen)
          for (final child in node.children)
            _FileTreeTile(
              node: child,
              depth: depth + 1,
              expanded: expanded,
              openFilePath: openFilePath,
              onToggleFolder: onToggleFolder,
              onSelectFile: onSelectFile,
            ),
      ],
    );
  }
}

class _EditorPanel extends StatelessWidget {
  const _EditorPanel({
    required this.fileName,
    required this.lines,
    required this.saved,
    this.onCopyFile,
  });

  final String fileName;
  final List<V2CodeLine> lines;
  final bool saved;
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
                  'Live workspace active',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Edits save to your branch as you type.',
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
