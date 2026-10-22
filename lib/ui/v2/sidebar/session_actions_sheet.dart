import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

enum V2SessionActionsStatus { loading, content, empty, error }

/// Immutable view data for the chat actions sheet.
@immutable
class V2SessionActionsData {
  const V2SessionActionsData({
    this.status = V2SessionActionsStatus.content,
    this.title = '',
    this.modelLabel = 'Auto',
    this.timeLabel = '',
    this.messageCount = 0,
    this.projectName,
    this.pinned = false,
    this.errorMessage,
  });

  final V2SessionActionsStatus status;
  final String title;
  final String modelLabel;
  final String timeLabel;
  final int messageCount;
  final String? projectName;
  final bool pinned;
  final String? errorMessage;

  /// At most [_metaWordBudget] words, in priority order.
  ///
  /// The header subtitle is capped at six words by the UI contract (§3). The
  /// time and size are what a person checks before acting on a chat; the model
  /// is the first fact dropped when the line is already full.
  String get meta {
    final parts = <String>[];
    var words = 0;
    void add(String part) {
      final count = part
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .length;
      if (words + count > _metaWordBudget) return;
      parts.add(part);
      words += count;
    }

    if (timeLabel.isNotEmpty) add(timeLabel);
    if (messageCount > 0) {
      add(messageCount == 1 ? '1 message' : '$messageCount messages');
    }
    if (modelLabel.isNotEmpty) add(modelLabel);
    return parts.join(' · ');
  }

  static const int _metaWordBudget = 6;
}

/// The work behind each row of [SessionActionsSheet].
///
/// Every callback returns a future that completes only after the write has
/// landed. The sheet uses that boundary to show a per-row busy state, keep a
/// failure inline, and close only once success is true. A row without a
/// handler is not rendered at all.
///
/// Success feedback belongs to the handler, not the sheet: only the handler
/// knows where an export landed (a file, the clipboard, a share target) and
/// what a duplicate was called. The sheet never announces a success of its
/// own, so it cannot claim more than the handler did.
@immutable
class V2SessionActionsHandlers {
  const V2SessionActionsHandlers({
    this.setPinned,
    this.rename,
    this.addToProject,
    this.share,
    this.duplicate,
    this.exportMarkdown,
    this.delete,
  });

  final Future<void> Function(bool pinned)? setPinned;
  final Future<void> Function(String title)? rename;
  final Future<void> Function()? addToProject;
  final Future<void> Function()? share;
  final Future<void> Function()? duplicate;
  final Future<void> Function()? exportMarkdown;
  final Future<void> Function()? delete;
}

/// The chat actions sheet: pin, rename, add to a project, share, duplicate,
/// export as Markdown and delete.
///
/// Every row is driven by a real handler and is hidden when that handler is
/// missing. Async work is per-row: the affected row shows progress and the
/// other rows stop accepting taps until it settles. Failures stay in the
/// sheet, next to the row that failed, so the person can retry or leave.
///
/// The legacy callbacks are still accepted so hosts can migrate one at a
/// time; passing [handlers] takes precedence. A legacy callback that returns a
/// future is awaited, so it gets the same busy state, inline failure and
/// close-on-success as a handler.
class SessionActionsSheet extends StatefulWidget {
  const SessionActionsSheet({
    super.key,
    required this.data,
    this.handlers,
    this.onClose,
    this.onTogglePin,
    this.onRename,
    this.onMoveToProject,
    this.onShare,
    this.onDuplicate,
    this.onExportMarkdown,
    this.onDelete,
    this.onRetry,
  });

  final V2SessionActionsData data;

  /// Real async handlers. Preferred over the legacy callbacks below.
  final V2SessionActionsHandlers? handlers;

  final VoidCallback? onClose;

  /// Legacy optimistic pin callback, used only when [handlers] has no
  /// [V2SessionActionsHandlers.setPinned].
  final ValueChanged<bool>? onTogglePin;

  /// Legacy rename callback. Used only when [handlers] has no
  /// [V2SessionActionsHandlers.rename]; the host owns the editor then, so the
  /// sheet waits for it and keeps a failure inline but cannot validate the
  /// name itself.
  final Future<void> Function()? onRename;

  final Future<void> Function()? onMoveToProject;
  final Future<void> Function()? onShare;
  final VoidCallback? onDuplicate;
  final Future<void> Function()? onExportMarkdown;

  /// Legacy delete callback. Used only when [handlers] has no
  /// [V2SessionActionsHandlers.delete]; the host owns the confirmation and
  /// the write then. The sheet waits for the flow and leaves once it settles.
  final Future<void> Function()? onDelete;

  final VoidCallback? onRetry;

  @override
  State<SessionActionsSheet> createState() => _SessionActionsSheetState();
}

class _SessionActionsSheetState extends State<SessionActionsSheet> {
  final TextEditingController _rename = TextEditingController();

  late String _title;
  late bool _pinned;

  /// The action currently writing, or null when the sheet is idle.
  String? _busy;

  /// The action whose inline error is visible.
  String? _errorAction;
  String? _errorMessage;

  bool _editingRename = false;
  String? _renameFieldError;

  @override
  void initState() {
    super.initState();
    _title = _displayTitle(widget.data.title);
    _pinned = widget.data.pinned;
  }

  @override
  void didUpdateWidget(SessionActionsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.pinned != oldWidget.data.pinned) {
      _pinned = widget.data.pinned;
    }
    // Follow the host when it hands over a renamed chat, but never overwrite
    // the field the person is editing right now.
    if (widget.data.title != oldWidget.data.title && !_editingRename) {
      _title = _displayTitle(widget.data.title);
    }
  }

  @override
  void dispose() {
    _rename.dispose();
    super.dispose();
  }

  String _displayTitle(String raw) {
    final clean = raw.trim();
    return clean.isEmpty ? 'Chat' : clean;
  }

  bool get _canPin =>
      widget.handlers?.setPinned != null || widget.onTogglePin != null;
  bool get _canRename =>
      widget.handlers?.rename != null || widget.onRename != null;
  bool get _canAddToProject =>
      widget.handlers?.addToProject != null || widget.onMoveToProject != null;
  bool get _canShare =>
      widget.handlers?.share != null || widget.onShare != null;
  bool get _canDuplicate =>
      widget.handlers?.duplicate != null || widget.onDuplicate != null;
  bool get _canExport =>
      widget.handlers?.exportMarkdown != null ||
      widget.onExportMarkdown != null;
  bool get _canDelete =>
      widget.handlers?.delete != null || widget.onDelete != null;

  String? get _projectName {
    final name = widget.data.projectName?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  bool get _hasActions =>
      _canPin ||
      _canRename ||
      _canAddToProject ||
      _canShare ||
      _canDuplicate ||
      _canExport ||
      _canDelete;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Material(
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            key: const ValueKey<String>('session-actions-surface'),
            constraints: const BoxConstraints(maxWidth: 560),
            child: _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final data = widget.data;
    final content = data.status == V2SessionActionsStatus.content;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Every state keeps one header and a way out. A sheet that loses its
          // title while loading reads as a broken surface, and a failed or
          // empty state with no close leaves the person trapped behind the
          // barrier.
          OSheetHeader(
            title: data.status == V2SessionActionsStatus.empty
                ? 'Chat actions'
                : _title,
            subtitle: content && data.meta.isNotEmpty ? data.meta : null,
            onClose: widget.onClose,
            closeLabel: 'Close chat actions',
            padding: EdgeInsets.zero,
          ),
          ...switch (data.status) {
            V2SessionActionsStatus.loading => const <Widget>[
              SizedBox(height: 240, child: OSkeletonList(rows: 5)),
            ],
            V2SessionActionsStatus.error => <Widget>[
              SizedBox(
                height: 300,
                child: OErrorState(
                  title: 'Chat actions failed',
                  message:
                      data.errorMessage ??
                      'Check your connection and try again.',
                  onRetry: widget.onRetry,
                ),
              ),
            ],
            V2SessionActionsStatus.empty => <Widget>[
              SizedBox(
                height: 320,
                child: OEmptyState(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'Chat not found',
                  message: 'This chat may have been deleted.',
                  action: OButton(label: 'Close', onPressed: _close),
                ),
              ),
            ],
            V2SessionActionsStatus.content => _buildContent(context),
          },
        ],
      ),
    );
  }

  List<Widget> _buildContent(BuildContext context) {
    final c = OColors.of(context);
    if (_editingRename) {
      return <Widget>[
        const SizedBox(height: OSpace.l),
        _buildRenameForm(),
      ];
    }
    if (!_hasActions) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: OSpace.m),
      Divider(color: c.hairline, height: 1),
      const SizedBox(height: OSpace.xs),
      ..._buildActions(context),
    ];
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  List<Widget> _buildActions(BuildContext context) {
    final c = OColors.of(context);

    return <Widget>[
      if (_canPin) ...[
        _actionRow(
          key: const ValueKey<String>('session-action-pin'),
          title: _pinned ? 'Unpin chat' : 'Pin chat',
          semanticLabel: '${_pinned ? 'Unpin' : 'Pin'} chat, $_title',
          hint: _pinned ? 'Pinned' : 'Not pinned',
          icon: _pinned
              ? Icons.push_pin_rounded
              : Icons.push_pin_outlined,
          busy: _busy == 'pin',
          liveRegion: true,
          onTap: _togglePin,
          showChevron: false,
        ),
        _errorLine('pin'),
      ],
      if (_canRename) ...[
        _actionRow(
          key: const ValueKey<String>('session-action-rename'),
          title: 'Rename chat',
          semanticLabel: 'Rename chat, $_title',
          icon: Icons.edit_outlined,
          busy: _busy == 'rename',
          onTap: _beginRename,
        ),
        _errorLine('rename'),
      ],
      if (_canAddToProject) ...[
        _actionRow(
          key: const ValueKey<String>('session-action-project'),
          title: 'Add to project',
          semanticLabel: 'Add to project, $_title',
          // The pill is visual only; without this hint a screen reader never
          // hears which project the chat is already in.
          hint: _projectName == null ? null : 'In $_projectName',
          icon: Icons.folder_outlined,
          busy: _busy == 'project',
          trailing: _ProjectTrailing(projectName: _projectName),
          onTap: _addToProject,
        ),
        _errorLine('project'),
      ],
      if (_canShare) ...[
        _actionRow(
          key: const ValueKey<String>('session-action-share'),
          title: 'Share chat',
          semanticLabel: 'Share chat, $_title',
          icon: Icons.share_outlined,
          busy: _busy == 'share',
          onTap: _share,
        ),
        _errorLine('share'),
      ],
      if (_canDuplicate) ...[
        _actionRow(
          key: const ValueKey<String>('session-action-duplicate'),
          title: 'Duplicate chat',
          semanticLabel: 'Duplicate chat, $_title',
          icon: Icons.content_copy_rounded,
          busy: _busy == 'duplicate',
          onTap: _duplicate,
        ),
        _errorLine('duplicate'),
      ],
      if (_canExport) ...[
        _actionRow(
          key: const ValueKey<String>('session-action-export'),
          title: 'Export Markdown',
          semanticLabel: 'Export Markdown, $_title',
          icon: Icons.download_outlined,
          busy: _busy == 'export',
          onTap: _exportMarkdown,
        ),
        _errorLine('export'),
      ],
      if (_canDelete) ...[
        const SizedBox(height: OSpace.s),
        Divider(color: c.hairline, height: 1),
        const SizedBox(height: OSpace.xs),
        // Destructive reads without colour: a separate zone below a divider, a
        // trash glyph instead of a chevron, and the irreversible consequence in
        // the spoken hint and the confirmation. No subtitle (§7).
        _actionRow(
          key: const ValueKey<String>('session-action-delete'),
          title: 'Delete chat',
          semanticLabel: 'Delete chat, $_title, destructive',
          hint: 'Cannot be undone',
          icon: Icons.delete_outline_rounded,
          danger: true,
          busy: _busy == 'delete',
          onTap: _confirmDelete,
          showChevron: false,
        ),
        _errorLine('delete'),
      ],
    ];
  }

  Widget _actionRow({
    required Key key,
    required String title,
    required String semanticLabel,
    required IconData icon,
    required VoidCallback onTap,
    String? hint,
    String? subtitle,
    Widget? trailing,
    bool danger = false,
    bool showChevron = true,
    bool busy = false,
    bool liveRegion = false,
  }) {
    final enabled = _busy == null;
    final c = OColors.of(context);
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      enabled: enabled,
      liveRegion: liveRegion,
      label: semanticLabel,
      hint: hint,
      onTap: enabled ? onTap : null,
      child: OListRow(
        key: key,
        title: title,
        subtitle: subtitle,
        icon: icon,
        danger: danger,
        enabled: enabled,
        showChevron: showChevron,
        trailing: busy
            ? ExcludeSemantics(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.textMuted,
                  ),
                ),
              )
            : trailing,
        onTap: enabled ? onTap : null,
      ),
    );
  }

  Widget _errorLine(String action) {
    final message = _errorMessage;
    if (_errorAction != action || message == null) {
      return const SizedBox.shrink();
    }
    final c = OColors.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      excludeSemantics: true,
      label: message,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          OSpace.l + OSpace.iconTile + OSpace.m,
          0,
          OSpace.l,
          OSpace.s,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: c.danger),
            const SizedBox(width: OSpace.xs),
            Expanded(
              child: Text(
                message,
                style: OType.caption.copyWith(color: c.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _errorCopy(String action) => switch (action) {
    'pin' => 'Pin did not update.',
    'rename' => 'Rename failed.',
    'project' => 'Project did not change.',
    'share' => 'Share failed.',
    'duplicate' => 'Duplicate failed.',
    'export' => 'Export failed.',
    'delete' => 'Delete failed. Nothing changed.',
    _ => 'Action failed.',
  };

  /// Runs [task] with a per-row busy state and keeps any failure inline.
  Future<void> _run(
    String action,
    Future<void> Function() task, {
    VoidCallback? onSuccess,
  }) async {
    if (_busy != null) return;
    setState(() {
      _busy = action;
      _errorAction = null;
      _errorMessage = null;
    });
    var succeeded = false;
    try {
      await task();
      succeeded = true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorAction = action;
          _errorMessage = _errorCopy(action);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (succeeded && mounted) onSuccess?.call();
  }

  // ── Pin ───────────────────────────────────────────────────────────────────

  Future<void> _togglePin() async {
    if (_busy != null) return;
    final next = !_pinned;
    final handler = widget.handlers?.setPinned;
    final legacy = widget.onTogglePin;
    if (handler == null && legacy == null) return;

    // Optimistic: the row flips at once so the tap has feedback, then reverts
    // if the write fails. The row is a live region, so the new state and the
    // new action are both announced.
    final previous = _pinned;
    setState(() {
      _pinned = next;
      _busy = 'pin';
      _errorAction = null;
      _errorMessage = null;
    });
    try {
      if (handler != null) {
        await handler(next);
      } else {
        legacy!(next);
      }
      if (!mounted) return;
      setState(() => _busy = null);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pinned = previous;
        _busy = null;
        _errorAction = 'pin';
        _errorMessage = _errorCopy('pin');
      });
    }
  }

  // ── Rename ────────────────────────────────────────────────────────────────

  Future<void> _beginRename() async {
    if (_busy != null) return;
    final handler = widget.handlers?.rename;
    if (handler == null) {
      final legacy = widget.onRename;
      if (legacy == null) return;
      // The host owns the editor; wait for it so the row shows progress and a
      // failure lands under the row instead of escaping.
      await _run('rename', legacy);
      return;
    }
    _rename.text = _title;
    _rename.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _title.length,
    );
    setState(() {
      _editingRename = true;
      _renameFieldError = null;
      _errorAction = null;
      _errorMessage = null;
    });
  }

  void _cancelRename() {
    if (_busy == 'rename') return;
    setState(() {
      _editingRename = false;
      _renameFieldError = null;
    });
  }

  Future<void> _submitRename() async {
    if (_busy != null) return;
    final clean = _rename.text.trim();
    if (clean.isEmpty) {
      setState(() => _renameFieldError = 'Enter a name.');
      return;
    }
    if (clean == _title) {
      setState(() {
        _editingRename = false;
        _renameFieldError = null;
      });
      return;
    }
    final handler = widget.handlers?.rename;
    if (handler == null) {
      await widget.onRename?.call();
      return;
    }

    setState(() {
      _busy = 'rename';
      _renameFieldError = null;
      _errorAction = null;
      _errorMessage = null;
    });
    try {
      await handler(clean);
      if (!mounted) return;
      setState(() {
        _title = clean;
        _editingRename = false;
        _busy = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _renameFieldError = 'Rename failed.';
      });
    }
  }

  Widget _buildRenameForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey<String>('session-rename-field'),
          controller: _rename,
          autofocus: true,
          enabled: _busy == null,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_renameFieldError != null) {
              setState(() => _renameFieldError = null);
            }
          },
          onSubmitted: (_) => _submitRename(),
          decoration: InputDecoration(
            labelText: 'Chat name',
            hintText: 'Name this chat',
            errorText: _renameFieldError,
            errorMaxLines: 2,
          ),
        ),
        const SizedBox(height: OSpace.m),
        Row(
          children: [
            Expanded(
              child: OButton(
                key: const ValueKey<String>('session-rename-cancel'),
                label: 'Cancel',
                variant: OButtonVariant.secondary,
                onPressed: _busy == null ? _cancelRename : null,
              ),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: OButton(
                key: const ValueKey<String>('session-rename-save'),
                label: 'Save',
                loading: _busy == 'rename',
                onPressed: _busy == null ? _submitRename : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Other actions ─────────────────────────────────────────────────────────

  Future<void> _addToProject() async {
    final handler = widget.handlers?.addToProject;
    if (handler != null) return _run('project', handler);
    final legacy = widget.onMoveToProject;
    if (legacy != null) await _run('project', legacy);
  }

  Future<void> _share() async {
    final handler = widget.handlers?.share;
    if (handler != null) return _run('share', handler);
    final legacy = widget.onShare;
    if (legacy != null) await _run('share', legacy);
  }

  Future<void> _duplicate() async {
    final handler = widget.handlers?.duplicate;
    if (handler != null) return _run('duplicate', handler);
    final legacy = widget.onDuplicate;
    if (legacy != null) await _run('duplicate', () async => legacy());
  }

  Future<void> _exportMarkdown() async {
    final handler = widget.handlers?.exportMarkdown;
    if (handler != null) return _run('export', handler);
    final legacy = widget.onExportMarkdown;
    // A legacy export owns its own confirmation: only it knows whether the
    // Markdown went to a file, the clipboard or a share target.
    if (legacy != null) await _run('export', legacy);
  }

  Future<void> _confirmDelete() async {
    if (_busy != null) return;
    final handler = widget.handlers?.delete;
    if (handler == null) {
      final legacy = widget.onDelete;
      if (legacy == null) return;
      // The legacy host owns both the confirmation and the write, so the sheet
      // does not prompt twice. It still waits for the flow and leaves only
      // once that flow settles.
      await _run('delete', legacy, onSuccess: _close);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final c = OColors.of(dialogContext);
        return AlertDialog(
          scrollable: true,
          title: Text('Delete “$_title”?'),
          content: const Text('This cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: c.danger),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    // The sheet closes only after the delete really lands. A failure leaves
    // the sheet open with the error next to the delete row.
    await _run('delete', handler, onSuccess: _close);
  }

  void _close() {
    final close = widget.onClose;
    if (close != null) {
      close();
      return;
    }
    Navigator.of(context).maybePop();
  }
}

class _ProjectTrailing extends StatelessWidget {
  const _ProjectTrailing({this.projectName});

  final String? projectName;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final name = projectName?.trim() ?? '';
    if (name.isEmpty) {
      return Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: OPill(label: name),
        ),
        const SizedBox(width: OSpace.xs),
        Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
      ],
    );
  }
}

/// Opens [SessionActionsSheet] in the shared bottom-sheet container.
Future<void> showSessionActionsSheet(
  BuildContext context, {
  required V2SessionActionsData data,
  V2SessionActionsHandlers? handlers,
  VoidCallback? onClose,
  ValueChanged<bool>? onTogglePin,
  Future<void> Function()? onRename,
  Future<void> Function()? onMoveToProject,
  Future<void> Function()? onShare,
  VoidCallback? onDuplicate,
  Future<void> Function()? onExportMarkdown,
  Future<void> Function()? onDelete,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => SessionActionsSheet(
      data: data,
      handlers: handlers,
      onClose: () {
        onClose?.call();
        Navigator.maybePop(sheetContext);
      },
      onTogglePin: onTogglePin,
      onRename: onRename,
      onMoveToProject: onMoveToProject,
      onShare: onShare,
      onDuplicate: onDuplicate,
      onExportMarkdown: onExportMarkdown,
      onDelete: onDelete,
      onRetry: onRetry,
    ),
  );
}
