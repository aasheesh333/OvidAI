// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'commit_sheet.dart';

/// What the changes screen is doing right now.
enum V2ChangesStatus { loading, content, empty, error }

/// The role of one line in a unified diff.
enum V2DiffKind { context, added, removed }

/// One line of a unified diff.
@immutable
class V2DiffLine {
  const V2DiffLine({
    required this.kind,
    required this.text,
    this.oldNumber,
    this.newNumber,
  });

  final V2DiffKind kind;
  final String text;
  final int? oldNumber;
  final int? newNumber;
}

/// A contiguous hunk inside one changed file.
@immutable
class V2DiffHunk {
  const V2DiffHunk({required this.header, required this.lines});

  final String header;
  final List<V2DiffLine> lines;
}

/// One changed file.
@immutable
class V2ChangedFile {
  const V2ChangedFile({
    required this.path,
    this.directory = '',
    this.additions = 0,
    this.deletions = 0,
    this.hunks = const <V2DiffHunk>[],
    this.initiallyExpanded = false,
  });

  final String path;
  final String directory;
  final int additions;
  final int deletions;
  final List<V2DiffHunk> hunks;
  final bool initiallyExpanded;

  /// A file is only expandable when the wiring layer supplied real hunks.
  /// Otherwise the row must not offer a chevron that reveals an empty box.
  bool get canExpand => hunks.isNotEmpty;

  String get name => path.split('/').last;

  String get fileType {
    final dot = path.lastIndexOf('.');
    return dot == -1 ? 'FILE' : path.substring(dot + 1).toUpperCase();
  }
}

/// Everything the changes screen needs to render.
@immutable
class V2ChangesData {
  const V2ChangesData({
    this.status = V2ChangesStatus.content,
    this.files = const <V2ChangedFile>[],
    this.commitMessage = '',
    this.behindCount = 0,
    this.branchLabel,
    this.errorMessage,
  });

  final V2ChangesStatus status;
  final List<V2ChangedFile> files;
  final String commitMessage;
  final int behindCount;
  final String? branchLabel;
  final String? errorMessage;

  int get additions => files.fold(0, (total, file) => total + file.additions);

  int get deletions => files.fold(0, (total, file) => total + file.deletions);
}

/// Review local changes and commit them.
class V2ChangesPage extends StatefulWidget {
  const V2ChangesPage({
    super.key,
    required this.data,
    this.onCommit,
    this.onSync,
    this.onBack,
    this.onRetry,
    this.onCopyDiff,
    this.onMenu,
  });

  final V2ChangesData data;
  final ValueChanged<String>? onCommit;
  final VoidCallback? onSync;
  final VoidCallback? onBack;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onCopyDiff;
  final VoidCallback? onMenu;

  @override
  State<V2ChangesPage> createState() => _V2ChangesPageState();
}

class _V2ChangesPageState extends State<V2ChangesPage> {
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _expanded.addAll(
      widget.data.files
          .where((file) => file.initiallyExpanded)
          .map((file) => file.path),
    );
  }

  void _toggleFile(V2ChangedFile file) {
    setState(() {
      if (!_expanded.add(file.path)) {
        _expanded.remove(file.path);
      }
    });
  }

  /// Opens the shared commit sheet for the working tree. The page keeps the
  /// diff review; the sheet owns the message and the final commit action.
  Future<void> _openCommitSheet() async {
    final data = widget.data;
    if (data.files.isEmpty) return;
    final message = await showOSheet<String>(
      context,
      builder: (sheetContext) => V2CommitSheet(
        data: V2CommitSheetData(
          files: [
            for (final file in data.files)
              V2CommitFile(
                path: _commitPath(file),
                additions: file.additions,
                deletions: file.deletions,
              ),
          ],
          initialMessage: data.commitMessage,
          branchLabel: data.branchLabel,
          behindCount: data.behindCount,
        ),
        showHandle: false,
        onSync: widget.onSync,
        onRetry: widget.onRetry,
        onClose: () => Navigator.of(sheetContext).pop(),
        // The sheet disables its commit action when no real commit path is
        // wired. The page only supplies the pop-and-report handler when its
        // own [onCommit] exists, so an unwired page cannot fake a commit.
        onCommit: widget.onCommit == null
            ? null
            : (value) => Navigator.of(sheetContext).pop(value),
      ),
    );
    if (message != null) widget.onCommit?.call(message);
  }

  /// The commit sheet lists files by full path, while [V2ChangedFile] keeps the
  /// file name and its directory apart.
  String _commitPath(V2ChangedFile file) {
    final directory = file.directory.trim();
    if (directory.isEmpty || file.path.startsWith('$directory/')) {
      return file.path;
    }
    return '$directory/${file.path}';
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final hasContent =
        data.status == V2ChangesStatus.content && data.files.isNotEmpty;
    final branch = data.branchLabel?.trim() ?? '';
    return OScaffold(
      appBar: OAppBar(
        title: 'Changes',
        subtitle: hasContent && branch.isNotEmpty
            ? branch
            : 'Review and commit',
        actions: [
          if (hasContent && widget.onMenu != null)
            OIconButton(
              icon: Icons.more_vert_rounded,
              semanticLabel: 'More change options',
              tooltip: 'More options',
              onPressed: widget.onMenu,
            ),
        ],
      ),
      bottomNavigationBar: hasContent ? _buildCommitDock(context) : null,
      body: switch (data.status) {
        V2ChangesStatus.loading => const OSkeletonList(rows: 5),
        V2ChangesStatus.error => OErrorState(
          message:
              data.errorMessage ??
              'We could not load your changes. Check your connection and try again.',
          onRetry: widget.onRetry,
        ),
        V2ChangesStatus.empty => _buildEmpty(),
        V2ChangesStatus.content =>
          data.files.isEmpty ? _buildEmpty() : _buildContent(context),
      },
    );
  }

  Widget _buildEmpty() {
    return OEmptyState(
      icon: Icons.check_circle_outline_rounded,
      title: 'No changes to review',
      message: 'Edits you make in Studio will show up here.',
      action: widget.onBack == null
          ? null
          : OButton(
              label: 'Back to workspace',
              variant: OButtonVariant.secondary,
              onPressed: widget.onBack,
            ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final data = widget.data;
    final branch = data.branchLabel?.trim() ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.m,
        OSpace.screen,
        OSpace.xl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: OFadeSlide(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    const _MetaPill(
                      label: 'Working tree',
                      tone: OPillTone.success,
                      dot: true,
                    ),
                    if (branch.isNotEmpty)
                      _MetaPill(label: branch, tone: OPillTone.accent),
                    _MetaPill(
                      label:
                          '${data.files.length} changed · +${data.additions} −${data.deletions}',
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.m),
                _SummaryCard(data: data),
                const SizedBox(height: OSpace.m),
                OStagger(
                  children: [
                    for (final file in data.files)
                      Padding(
                        padding: const EdgeInsets.only(bottom: OSpace.s),
                        child: _DiffFileCard(
                          file: file,
                          expanded: _expanded.contains(file.path),
                          onToggle: () => _toggleFile(file),
                          onCopyDiff: () => widget.onCopyDiff?.call(file.path),
                        ),
                      ),
                  ],
                ),
                if (data.behindCount > 0) ...[
                  const SizedBox(height: OSpace.s),
                  _SyncRow(count: data.behindCount, onSync: widget.onSync),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCommitDock(BuildContext context) {
    final c = OColors.of(context);
    final files = widget.data.files.length;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              files == 1
                  ? '1 file ready to commit'
                  : '$files files ready to commit',
              style: OType.caption.copyWith(color: c.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: OSpace.xs),
            OButton(
              key: const Key('studio-open-commit-sheet'),
              label: 'Commit & push',
              icon: Icons.send_rounded,
              expand: true,
              semanticLabel: 'Commit & push, review files and write a message',
              onPressed: _openCommitSheet,
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.data});

  final V2ChangesData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final total = data.additions + data.deletions;
    final addFlex = data.additions <= 0 ? 1 : data.additions;
    final removeFlex = data.deletions <= 0 ? 1 : data.deletions;
    final filesLabel = data.files.length == 1
        ? '1 changed file'
        : '${data.files.length} changed files';
    return Semantics(
      container: true,
      excludeSemantics: true,
      label:
          '$filesLabel, +${data.additions} added, −${data.deletions} removed, ready to review and stage',
      child: OCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    Icons.difference_rounded,
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
                        data.files.length == 1
                            ? '1 changed file'
                            : '${data.files.length} changed files',
                        style: OType.bodyStrong.copyWith(color: c.text),
                      ),
                      Text(
                        'Ready to review and stage',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Text(
                  '+${data.additions}',
                  style: OType.bodySm.copyWith(
                    color: c.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Text(
                  '−${data.deletions}',
                  style: OType.bodySm.copyWith(
                    color: c.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.m),
            if (total > 0)
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 6,
                  child: Row(
                    children: [
                      Expanded(
                        flex: addFlex,
                        child: ColoredBox(
                          color: c.success,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        flex: removeFlex,
                        child: ColoredBox(
                          color: c.danger,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DiffFileCard extends StatelessWidget {
  const _DiffFileCard({
    required this.file,
    required this.expanded,
    required this.onToggle,
    this.onCopyDiff,
  });

  final V2ChangedFile file;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onCopyDiff;

  IconData get _icon {
    return switch (file.fileType) {
      'HTML' => Icons.html_rounded,
      'CSS' => Icons.css_rounded,
      'JS' => Icons.javascript_rounded,
      'TSX' || 'TS' || 'JSX' => Icons.code_rounded,
      _ => Icons.description_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.s,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.s),
              ),
              child: Icon(_icon, size: 19, color: c.accent),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (file.directory.isNotEmpty)
                    Text(
                      file.directory,
                      style: OType.caption.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (!file.canExpand)
                    Text(
                      'No diff available',
                      key: ValueKey<String>('v2-diff-unavailable-${file.path}'),
                      style: OType.caption.copyWith(color: c.textFaint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            Text(
              '+${file.additions}',
              style: OType.caption.copyWith(
                color: c.success,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: OSpace.xs),
            Text(
              '−${file.deletions}',
              style: OType.caption.copyWith(
                color: c.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: OSpace.xs),
            if (file.canExpand)
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: OMove.duration(context, OMotion.fast),
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 20,
                  color: c.textFaint,
                ),
              ),
          ],
        ),
      ),
    );
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
          Material(
            color: Colors.transparent,
            child: file.canExpand
                ? InkWell(
                    onTap: onToggle,
                    child: Semantics(
                      label:
                          '${file.name}, +${file.additions} −${file.deletions}',
                      button: true,
                      expanded: expanded,
                      child: row,
                    ),
                  )
                : Semantics(
                    label:
                        '${file.name}, +${file.additions} −${file.deletions}, '
                        'no diff available',
                    child: row,
                  ),
          ),
          if (file.canExpand && expanded) ...[
            Divider(height: 1, color: c.hairline),
            _DiffBody(file: file, onCopyDiff: onCopyDiff),
          ],
        ],
      ),
    );
  }
}

class _DiffBody extends StatelessWidget {
  const _DiffBody({required this.file, this.onCopyDiff});

  final V2ChangedFile file;
  final VoidCallback? onCopyDiff;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ColoredBox(
      color: c.codeBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final hunk in file.hunks) ...[
            Container(
              color: c.surfaceAlt,
              padding: const EdgeInsets.only(left: OSpace.m),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      hunk.header,
                      style: OType.mono.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onCopyDiff != null)
                    OIconButton(
                      icon: Icons.copy_rounded,
                      semanticLabel: 'Copy diff for ${file.name}',
                      tooltip: 'Copy',
                      size: 18,
                      onPressed: onCopyDiff,
                    ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in hunk.lines) _DiffLineRow(line: line),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({required this.line});

  final V2DiffLine line;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final background = switch (line.kind) {
      V2DiffKind.added => c.success.withValues(alpha: 0.12),
      V2DiffKind.removed => c.danger.withValues(alpha: 0.12),
      V2DiffKind.context => Colors.transparent,
    };
    final foreground = switch (line.kind) {
      V2DiffKind.added => c.success,
      V2DiffKind.removed => c.danger,
      V2DiffKind.context => c.textMuted,
    };
    final marker = switch (line.kind) {
      V2DiffKind.added => '+',
      V2DiffKind.removed => '−',
      V2DiffKind.context => ' ',
    };
    final style = OType.mono.copyWith(color: foreground);
    return ColoredBox(
      color: background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: OSpace.m, vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Text(
                line.oldNumber?.toString() ?? '',
                textAlign: TextAlign.right,
                style: style.copyWith(color: c.textFaint),
              ),
            ),
            const SizedBox(width: OSpace.s),
            SizedBox(
              width: 28,
              child: Text(
                line.newNumber?.toString() ?? '',
                textAlign: TextAlign.right,
                style: style.copyWith(color: c.textFaint),
              ),
            ),
            SizedBox(
              width: 20,
              child: Text(marker, textAlign: TextAlign.center, style: style),
            ),
            Text(line.text, softWrap: false, style: style),
          ],
        ),
      ),
    );
  }
}

class _SyncRow extends StatelessWidget {
  const _SyncRow({required this.count, this.onSync});

  final int count;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final wired = onSync != null;
    return OCard(
      onTap: onSync,
      semanticLabel: wired
          ? 'Sync latest first, $count behind'
          : 'Behind remote by $count, syncing is not available yet',
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.sync_rounded, size: 19, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  wired ? 'Sync latest first' : 'Behind remote',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  wired
                      ? 'Pulls $count upstream ${count == 1 ? 'commit' : 'commits'} safely'
                      : '$count upstream ${count == 1 ? 'commit' : 'commits'} to pull before pushing',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Flexible(
            flex: 2,
            child: _MetaPill(
              label: wired ? '$count behind' : 'Sync unavailable',
              tone: wired ? OPillTone.accent : OPillTone.warn,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small status pill that mirrors [OPill] but grows with the text scale instead
/// of clipping at a fixed 24 dp height.
class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.label,
    this.tone = OPillTone.neutral,
    this.dot = false,
  });

  final String label;
  final OPillTone tone;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (bg, fg) = switch (tone) {
      OPillTone.neutral => (c.surfaceAlt, c.textMuted),
      OPillTone.accent => (c.accentSoft, c.accent),
      OPillTone.success => (c.success.withValues(alpha: 0.12), c.success),
      OPillTone.warn => (c.warn.withValues(alpha: 0.12), c.warn),
      OPillTone.danger => (c.danger.withValues(alpha: 0.12), c.danger),
    };
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: OSpace.xs / 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
