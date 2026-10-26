// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
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
  const V2DiffHunk({
    required this.header,
    required this.lines,
    this.scopeLabel,
  });

  final String header;
  final List<V2DiffLine> lines;

  /// Actual source query for this hunk (`Staged` or `Unstaged`), when the
  /// host supplied separate patches. Null for an ordinary single diff.
  final String? scopeLabel;
}

/// One changed file.
@immutable
class V2ChangedFile {
  const V2ChangedFile({
    required this.path,
    this.directory = '',
    this.additions,
    this.deletions,
    this.hunks = const <V2DiffHunk>[],
    this.initiallyExpanded = false,
    this.scopeLabel,
  });

  final String path;
  final String directory;
  final int? additions;
  final int? deletions;
  final List<V2DiffHunk> hunks;
  final bool initiallyExpanded;

  /// Real patch scope(s) represented by this one file row. A same-path staged
  /// and unstaged pair is merged once and labeled `Staged + unstaged`.
  final String? scopeLabel;

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
    this.behindCount,
    this.branchLabel,
    this.errorMessage,
    bool? totalsKnown,
    this.coverageWarning,
  }) : _totalsKnown = totalsKnown; // ignore: prefer_initializing_formals

  final V2ChangesStatus status;
  final List<V2ChangedFile> files;
  final String commitMessage;
  final int? behindCount;
  final String? branchLabel;
  final String? errorMessage;

  /// False when staged/untracked coverage is incomplete, even if individual
  /// patch rows have real line counts. Overall totals then stay unknown.
  final bool? _totalsKnown;

  /// Defaults conservatively: loading/error/empty/unfetched data has no known
  /// total. Legacy complete content fixtures with real file records may omit
  /// the flag; every mapper-owned partial state passes false explicitly.
  bool get totalsKnown =>
      _totalsKnown ?? (status == V2ChangesStatus.content && files.isNotEmpty);

  /// Visible whenever real rows are only a partial view of the change set.
  /// For example, the current gateway cannot supply untracked files/content.
  final String? coverageWarning;

  int? get additions =>
      totalsKnown ? _knownTotal(files.map((file) => file.additions)) : null;

  int? get deletions =>
      totalsKnown ? _knownTotal(files.map((file) => file.deletions)) : null;

  static int? _knownTotal(Iterable<int?> values) {
    var total = 0;
    for (final value in values) {
      if (value == null) return null;
      total += value;
    }
    return total;
  }
}

/// Review local changes and commit them.
class V2ChangesPage extends StatefulWidget {
  const V2ChangesPage({
    super.key,
    required this.data,
    this.onCommit,
    this.onCommitAsync,
    this.onSync,
    this.onBack,
    this.onRetry,
    this.onCopyDiff,
  });

  final V2ChangesData data;

  /// Fire-and-forget commit. Kept for hosts that cannot report a result.
  final ValueChanged<String>? onCommit;

  /// Preferred over [onCommit]: commits [message] and returns null on success
  /// or the real failure copy. The screen shows exactly what this returns, so
  /// a commit can never be reported as successful when it was not.
  final Future<String?> Function(String message)? onCommitAsync;

  final VoidCallback? onSync;
  final VoidCallback? onBack;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onCopyDiff;

  /// True when some commit path is wired. Without one the screen is a review
  /// surface only and draws no commit control.
  bool get canCommit => onCommit != null || onCommitAsync != null;

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

  @override
  void didUpdateWidget(covariant V2ChangesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.files != widget.data.files) {
      _expanded
        ..clear()
        ..addAll(
          widget.data.files
              .where((file) => file.initiallyExpanded)
              .map((file) => file.path),
        );
    }
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
    if (data.files.isEmpty ||
        !widget.canCommit ||
        !data.totalsKnown ||
        data.behindCount == null ||
        data.files.any(
          (file) => file.additions == null || file.deletions == null,
        )) {
      return;
    }
    final message = await showOSheet<String>(
      context,
      builder: (sheetContext) => V2CommitSheet(
        data: V2CommitSheetData(
          files: [
            for (final file in data.files)
              V2CommitFile(
                path: _commitPath(file),
                additions: file.additions!,
                deletions: file.deletions!,
              ),
          ],
          initialMessage: data.commitMessage,
          branchLabel: data.branchLabel,
          behindCount: data.behindCount!,
        ),
        showHandle: false,
        onSync: widget.onSync,
        onRetry: widget.onRetry,
        onClose: () => Navigator.of(sheetContext).pop(),
        // The sheet only closes with a message; the page then runs the real
        // commit and reports its outcome.
        onCommit: (value) => Navigator.of(sheetContext).pop(value),
      ),
    );
    if (message == null || !mounted) return;

    final asyncCommit = widget.onCommitAsync;
    if (asyncCommit != null) {
      String? failure;
      try {
        failure = await asyncCommit(message);
      } catch (_) {
        // The wiring layer owns error copy; a handler that throws instead of
        // returning a message still gets an honest line, never a fake success.
        failure = 'The commit did not finish.';
      }
      if (!mounted) return;
      showOSnack(context, failure ?? 'Committed.');
      return;
    }
    widget.onCommit?.call(message);
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
    // No diff source means no commit control. A permanently disabled check
    // mark would imply a commit path that does not exist.
    final commitable =
        hasContent &&
        widget.canCommit &&
        data.totalsKnown &&
        data.behindCount != null &&
        data.files.every(
          (file) => file.additions != null && file.deletions != null,
        );
    return OScreen(
      title: 'Changes',
      padding: false,
      leading: widget.onBack == null
          ? null
          : OIconButton(
              icon: Icons.arrow_back_rounded,
              semanticLabel: 'Back',
              onPressed: widget.onBack,
            ),
      actions: [
        if (commitable)
          OIconButton(
            key: const Key('studio-open-commit-sheet'),
            icon: Icons.check_rounded,
            semanticLabel: 'Commit & push',
            tooltip: 'Commit',
            onPressed: _openCommitSheet,
          ),
      ],
      child: switch (data.status) {
        V2ChangesStatus.loading => const OSkeletonList(rows: 6),
        V2ChangesStatus.error => OErrorState(
          message: data.errorMessage ?? 'Changes did not load.',
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
      message: '',
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
    final files = widget.data.files;
    final warning = widget.data.coverageWarning?.trim();
    final hasWarning = warning != null && warning.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.xl,
      ),
      itemCount: files.length + (hasWarning ? 1 : 0),
      itemBuilder: (context, index) {
        if (hasWarning && index == 0) {
          return _DiffCoverageWarning(message: warning);
        }
        final file = files[index - (hasWarning ? 1 : 0)];
        return _DiffFileRow(
          file: file,
          path: _commitPath(file),
          expanded: _expanded.contains(file.path),
          onToggle: () => _toggleFile(file),
          onCopyDiff: () => widget.onCopyDiff?.call(file.path),
        );
      },
    );
  }
}

String _diffCount(int? value) => value?.toString() ?? '—';

class _DiffCoverageWarning extends StatelessWidget {
  const _DiffCoverageWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = OColors.of(context);
    return ColoredBox(
      key: const Key('studio-diff-scope-warning'),
      color: colors.surfaceAlt,
      child: Padding(
        padding: const EdgeInsets.all(OSpace.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: colors.warn),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                message,
                style: OType.caption.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One changed file: full path on the left, +N −N on the right.
class _DiffFileRow extends StatelessWidget {
  const _DiffFileRow({
    required this.file,
    required this.path,
    required this.expanded,
    required this.onToggle,
    this.onCopyDiff,
  });

  final V2ChangedFile file;
  final String path;
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
          horizontal: OSpace.s,
          vertical: OSpace.s,
        ),
        child: Row(
          children: [
            Icon(_icon, size: 18, color: c.textMuted),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    path,
                    style: OType.bodySm.copyWith(color: c.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (file.scopeLabel != null)
                    Text(
                      file.scopeLabel!,
                      style: OType.caption.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            Text(
              '+${_diffCount(file.additions)}',
              style: OType.caption.copyWith(
                color: c.success,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: OSpace.xs),
            Text(
              '−${_diffCount(file.deletions)}',
              style: OType.caption.copyWith(
                color: c.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (file.canExpand) ...[
              const SizedBox(width: OSpace.xs),
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
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (file.canExpand)
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggle,
              child: Semantics(
                container: true,
                excludeSemantics: true,
                label:
                    '$path${file.scopeLabel == null ? '' : ', ${file.scopeLabel}'}, +${_diffCount(file.additions)} −${_diffCount(file.deletions)}',
                button: true,
                enabled: true,
                expanded: expanded,
                onTap: onToggle,
                child: row,
              ),
            ),
          )
        else
          Semantics(
            container: true,
            excludeSemantics: true,
            label:
                '$path${file.scopeLabel == null ? '' : ', ${file.scopeLabel}'}, +${_diffCount(file.additions)} −${_diffCount(file.deletions)}',
            child: row,
          ),
        if (file.canExpand && expanded)
          _DiffBody(file: file, onCopyDiff: onCopyDiff),
        Divider(height: 1, color: c.hairline),
      ],
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
                  if (hunk.scopeLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(right: OSpace.s),
                      child: Text(
                        hunk.scopeLabel!,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      label: 'Hunk ${hunk.header}',
                      excludeSemantics: true,
                      child: Text(
                        hunk.header,
                        style: OType.mono.copyWith(color: c.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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
    final number = switch (line.kind) {
      V2DiffKind.added => line.newNumber ?? line.oldNumber,
      V2DiffKind.removed => line.oldNumber ?? line.newNumber,
      V2DiffKind.context => line.newNumber ?? line.oldNumber,
    };
    final spoken = switch (line.kind) {
      V2DiffKind.added => 'Added line ${number ?? ''}: ${line.text}',
      V2DiffKind.removed => 'Removed line ${number ?? ''}: ${line.text}',
      V2DiffKind.context => 'Line ${number ?? ''}: ${line.text}',
    };
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: spoken,
      child: ColoredBox(
        color: background,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.m,
            vertical: 1,
          ),
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
      ),
    );
  }
}
