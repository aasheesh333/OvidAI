// TODO(l10n): move this sheet's English copy to the ARB files in the next wave.

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// What the commit sheet is doing right now.
enum V2CommitSheetStatus { loading, content, empty, error }

/// The hard limit for a commit subject line. The counter and the guidance copy
/// both read from this so the copy can never drift from the rule.
const int v2CommitMessageLimit = 72;

/// How many changed files are listed before the summary collapses the rest.
const int v2CommitFilePreviewLimit = 4;

/// One file that will go into the commit.
@immutable
class V2CommitFile {
  const V2CommitFile({
    required this.path,
    this.additions = 0,
    this.deletions = 0,
  });

  final String path;
  final int additions;
  final int deletions;

  String get name {
    final slash = path.lastIndexOf('/');
    return slash == -1 ? path : path.substring(slash + 1);
  }

  String get directory {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '' : path.substring(0, slash);
  }
}

/// Everything the commit sheet needs to render. Presentational: the worktree,
/// branch and remote state are all injected.
@immutable
class V2CommitSheetData {
  const V2CommitSheetData({
    this.status = V2CommitSheetStatus.content,
    this.files = const <V2CommitFile>[],
    this.initialMessage = '',
    this.branchLabel,
    this.behindCount = 0,
    this.protectedBranch = false,
    this.pushNote,
    this.errorMessage,
  }) : assert(behindCount >= 0, 'behindCount cannot be negative');

  final V2CommitSheetStatus status;
  final List<V2CommitFile> files;

  /// Draft message the sheet opens with, for example a persisted draft.
  final String initialMessage;

  /// Branch the commit will land on, for example `feature/hero-revamp`.
  final String? branchLabel;

  /// Upstream commits the local branch is behind.
  final int behindCount;

  /// True when the branch rejects direct pushes, so Ovid opens a pull request.
  final bool protectedBranch;

  /// Overrides the default push protection note.
  final String? pushNote;

  final String? errorMessage;

  bool get hasChanges => files.isNotEmpty;

  int get additions => files.fold(0, (total, file) => total + file.additions);

  int get deletions => files.fold(0, (total, file) => total + file.deletions);

  String get filesLabel =>
      files.length == 1 ? '1 changed file' : '${files.length} changed files';
}

/// The "Commit changes" sheet. Host it with [showOSheet] and pass
/// `showHandle: false` when the host already draws a grabber.
class V2CommitSheet extends StatefulWidget {
  const V2CommitSheet({
    super.key,
    required this.data,
    this.onCommit,
    this.onSync,
    this.onRetry,
    this.onClose,
    this.showHandle = true,
  });

  final V2CommitSheetData data;

  /// Receives the trimmed commit message.
  final ValueChanged<String>? onCommit;
  final VoidCallback? onSync;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;
  final bool showHandle;

  @override
  State<V2CommitSheet> createState() => _V2CommitSheetState();
}

class _V2CommitSheetState extends State<V2CommitSheet> {
  late final TextEditingController _message;

  @override
  void initState() {
    super.initState();
    _message = TextEditingController(text: widget.data.initialMessage);
  }

  @override
  void didUpdateWidget(covariant V2CommitSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.initialMessage != widget.data.initialMessage &&
        _message.text != widget.data.initialMessage) {
      _message.text = widget.data.initialMessage;
    }
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  int get _length => _message.text.runes.length;

  String get _trimmed => _message.text.trim();

  bool get _tooLong => _length > v2CommitMessageLimit;

  bool get _canCommit =>
      widget.onCommit != null &&
      widget.data.hasChanges &&
      _trimmed.isNotEmpty &&
      !_tooLong;

  String get _commitSemanticLabel {
    if (widget.onCommit == null) {
      return 'Commit & push, committing is not available yet';
    }
    if (!widget.data.hasChanges) return 'Commit & push, no changes to commit';
    if (_trimmed.isEmpty) return 'Commit & push, write a message first';
    if (_tooLong) {
      return 'Commit & push, shorten the message to $v2CommitMessageLimit '
          'characters';
    }
    return 'Commit & push';
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final showFooter =
        data.status == V2CommitSheetStatus.content && data.hasChanges;
    return Material(
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showHandle) ...[
              const SizedBox(height: OSpace.s),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.hairlineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
            Flexible(child: _buildBody(context)),
            if (showFooter) _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final data = widget.data;
    switch (data.status) {
      case V2CommitSheetStatus.loading:
        return const SizedBox(height: 300, child: OSkeletonList(rows: 4));
      case V2CommitSheetStatus.error:
        return SizedBox(
          height: 380,
          child: OErrorState(
            title: 'Could not prepare your commit',
            message:
                data.errorMessage ??
                'We could not read the working tree. Check your connection '
                    'and try again.',
            onRetry: widget.onRetry,
          ),
        );
      case V2CommitSheetStatus.empty:
        return _buildEmpty();
      case V2CommitSheetStatus.content:
        if (!data.hasChanges) return _buildEmpty();
        return _buildContent(context);
    }
  }

  Widget _buildEmpty() {
    return SizedBox(
      height: 380,
      child: OEmptyState(
        compact: true,
        icon: Icons.check_circle_outline_rounded,
        title: 'No changes to commit',
        message: 'Edits you make in Studio will show up here.',
        action: widget.onClose == null
            ? null
            : OButton(
                label: 'Back to workspace',
                variant: OButtonVariant.secondary,
                onPressed: widget.onClose,
              ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final branch = data.branchLabel?.trim() ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: OFadeSlide(
            child: OStagger(
              children: [
                _buildHeader(context, c, branch),
                if (branch.isNotEmpty) ...[
                  const SizedBox(height: OSpace.m),
                  _BranchRow(branch: branch),
                ],
                const SizedBox(height: OSpace.m),
                _ChangedFilesCard(data: data),
                if (data.behindCount > 0) ...[
                  const SizedBox(height: OSpace.m),
                  _SyncFirstCard(
                    count: data.behindCount,
                    onSync: widget.onSync,
                  ),
                ],
                const SizedBox(height: OSpace.l),
                _buildMessageField(context, c),
                const SizedBox(height: OSpace.m),
                _PushNote(
                  protectedBranch: data.protectedBranch,
                  branch: branch,
                  note: data.pushNote,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, OColors c, String branch) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Commit changes', style: OType.h2.copyWith(color: c.text)),
              const SizedBox(height: OSpace.xs),
              Text(
                branch.isEmpty
                    ? 'Review your changes before pushing.'
                    : 'Review your changes before pushing to $branch.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        if (widget.onClose != null)
          OIconButton(
            icon: Icons.close_rounded,
            semanticLabel: 'Close commit sheet',
            tooltip: 'Close',
            onPressed: widget.onClose,
          ),
      ],
    );
  }

  Widget _buildMessageField(BuildContext context, OColors c) {
    final length = _length;
    final tooLong = _tooLong;
    final helper = tooLong
        ? 'Too long by ${length - v2CommitMessageLimit} '
              '${length - v2CommitMessageLimit == 1 ? 'character' : 'characters'}. '
              'Shorten it to $v2CommitMessageLimit characters.'
        : 'Keep it short: aim for $v2CommitMessageLimit characters or fewer.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Commit message',
                style: OType.bodySm.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Semantics(
              label:
                  '$length of $v2CommitMessageLimit characters'
                  '${tooLong ? ', too long' : ''}',
              child: ExcludeSemantics(
                child: Text(
                  '$length/$v2CommitMessageLimit',
                  style: OType.caption.copyWith(
                    color: tooLong ? c.danger : c.textFaint,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.xs),
        Semantics(
          label: 'Commit message',
          child: TextField(
            key: const ValueKey('v2-commit-message'),
            controller: _message,
            onChanged: (_) => setState(() {}),
            minLines: 1,
            maxLines: 3,
            autofocus: false,
            textInputAction: TextInputAction.done,
            style: OType.bodySm.copyWith(color: c.text),
            decoration: InputDecoration(
              hintText: 'feat: update hero typography',
              hintStyle: OType.bodySm.copyWith(color: c.textFaint),
              prefixIcon: const Icon(Icons.edit_note_rounded),
            ),
          ),
        ),
        const SizedBox(height: OSpace.xs),
        Text(
          helper,
          style: OType.caption.copyWith(
            color: tooLong ? c.danger : c.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    final c = OColors.of(context);
    return Container(
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
          OButton(
            key: const ValueKey('v2-commit-submit'),
            label: 'Commit & push',
            icon: Icons.send_rounded,
            expand: true,
            semanticLabel: _commitSemanticLabel,
            onPressed: _canCommit
                ? () => widget.onCommit?.call(_trimmed)
                : null,
          ),
        ],
      ),
    );
  }
}

class _BranchRow extends StatelessWidget {
  const _BranchRow({required this.branch});

  final String branch;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      label: 'Branch, $branch',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
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
              Icon(Icons.alt_route_rounded, size: 19, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  branch,
                  style: OType.mono.copyWith(color: c.text),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: OSpace.s),
              Text('origin', style: OType.caption.copyWith(color: c.textFaint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangedFilesCard extends StatelessWidget {
  const _ChangedFilesCard({required this.data});

  final V2CommitSheetData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final visible = data.files.take(v2CommitFilePreviewLimit).toList();
    final hidden = data.files.length - visible.length;
    final total = data.additions + data.deletions;
    final addFlex = data.additions <= 0 ? 1 : data.additions;
    final removeFlex = data.deletions <= 0 ? 1 : data.deletions;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label:
          '${data.filesLabel}, +${data.additions} added, '
          '−${data.deletions} removed',
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
                        data.filesLabel,
                        style: OType.bodyStrong.copyWith(color: c.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Will be committed together',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '+${data.additions}',
                      style: OType.bodySm.copyWith(
                        color: c.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '−${data.deletions}',
                      style: OType.bodySm.copyWith(
                        color: c.danger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (total > 0) ...[
              const SizedBox(height: OSpace.m),
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
            const SizedBox(height: OSpace.m),
            Divider(height: 1, color: c.hairline),
            const SizedBox(height: OSpace.s),
            for (final file in visible) _FileRow(file: file),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(top: OSpace.xs),
                child: Text(
                  '+$hidden more ${hidden == 1 ? 'file' : 'files'}',
                  style: OType.caption.copyWith(
                    color: c.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});

  final V2CommitFile file;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(Icons.description_outlined, size: 16, color: c.textFaint),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              file.path,
              style: OType.caption.copyWith(color: c.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
        ],
      ),
    );
  }
}

class _SyncFirstCard extends StatelessWidget {
  const _SyncFirstCard({required this.count, this.onSync});

  final int count;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final commits = count == 1 ? 'commit' : 'commits';
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.warn.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.sync_rounded, size: 20, color: c.warn),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sync first',
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Remote has $count new $commits. Pull them in before you '
                      'push so this commit lands cleanly.',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          if (onSync != null)
            OButton(
              key: const ValueKey('v2-commit-sync'),
              label: 'Sync latest changes',
              icon: Icons.sync_rounded,
              variant: OButtonVariant.secondary,
              expand: true,
              semanticLabel: 'Sync latest changes, $count behind',
              onPressed: onSync,
            )
          else
            Text(
              key: const ValueKey('v2-commit-sync-unavailable'),
              'Syncing is not available yet. Pull the latest changes from '
              'Studio before you commit.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
        ],
      ),
    );
  }
}

class _PushNote extends StatelessWidget {
  const _PushNote({
    required this.protectedBranch,
    required this.branch,
    this.note,
  });

  final bool protectedBranch;
  final String branch;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final title = protectedBranch ? 'Protected branch' : 'Push protected';
    final body =
        note ??
        (protectedBranch
            ? '${branch.isEmpty ? 'This branch' : branch} is protected. Ovid '
                  'pushes a new branch and opens a pull request instead of '
                  'pushing directly.'
            : 'Your push is protected. Ovid uses a one-time credential helper, '
                  'so your GitHub token never lands in .git/config.');
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.textMuted),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: OType.caption.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: OType.caption.copyWith(color: c.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
