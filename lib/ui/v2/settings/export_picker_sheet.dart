import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// Archive limits for a single export.
///
/// The same limits are enforced by `SettingsBackupService`: one backup may hold
/// up to 64 MB, 1,000 chats and 20,000 messages. When the account is larger
/// than any one of them, the scope sheet sends the person to this picker so
/// they choose a subset that fits.
const int v2ExportPickerByteLimit = 64 * 1024 * 1024;
const int v2ExportPickerChatLimit = 1000;
const int v2ExportPickerMessageLimit = 20000;

enum V2ExportPickerStatus { ready, loading, error }

/// One chat in the export picker.
@immutable
class V2ExportPickerSession {
  const V2ExportPickerSession({
    required this.id,
    required this.name,
    required this.sizeBytes,
    this.sizeLabel = '',
    this.messageCount = 0,
    this.detail = '',
    this.selected = true,
    this.heavyArtifacts = false,
  });

  final String id;
  final String name;
  final int sizeBytes;

  /// Pre-formatted size from the adapter. Falls back to a value derived from
  /// [sizeBytes] so the sheet never shows an empty size column.
  final String sizeLabel;

  final int messageCount;

  /// Optional line such as "42 messages · updated yesterday".
  final String detail;

  final bool selected;

  /// True when the chat holds videos or other large files that a transcript
  /// archive cannot include.
  final bool heavyArtifacts;

  String get displaySize =>
      sizeLabel.isEmpty ? _formatSize(sizeBytes) : sizeLabel;

  V2ExportPickerSession copyWith({bool? selected}) => V2ExportPickerSession(
    id: id,
    name: name,
    sizeBytes: sizeBytes,
    sizeLabel: sizeLabel,
    messageCount: messageCount,
    detail: detail,
    selected: selected ?? this.selected,
    heavyArtifacts: heavyArtifacts,
  );
}

/// Called with a chat id and its new selected state.
typedef V2ExportPickerToggle = void Function(String id, bool selected);

/// Called with the complete set of chat ids that should be selected.
///
/// Select-all passes the ids that fit; an empty list clears the selection. The
/// adapter applies the ids to its source list and rebuilds this sheet.
typedef V2ExportPickerSelectAll = void Function(List<String> ids);

/// Called with the complete selection when the person confirms the export.
typedef V2ExportPickerConfirm = void Function(Set<String> ids);

/// Injected state for [ExportPickerSheet].
///
/// The sheet keeps its own copy of the ticks, so the running totals move even
/// when the host does not rebuild the route; every change is also reported
/// through [onToggleSession] / [onSelectAll] so the host can persist it.
@immutable
class V2ExportPickerSheetData {
  const V2ExportPickerSheetData({
    this.sessions = const <V2ExportPickerSession>[],
    this.limitBytes = v2ExportPickerByteLimit,
    this.limitChats = v2ExportPickerChatLimit,
    this.limitMessages = v2ExportPickerMessageLimit,
    this.status = V2ExportPickerStatus.ready,
    this.errorMessage = 'We could not load your chats. Try again.',
    this.emptyActionLabel = 'Back to data control',
  }) : assert(limitBytes > 0, 'An archive always has a size limit'),
       assert(limitChats > 0, 'An archive always has a chat limit'),
       assert(limitMessages > 0, 'An archive always has a message limit');

  final List<V2ExportPickerSession> sessions;
  final int limitBytes;
  final int limitChats;
  final int limitMessages;
  final V2ExportPickerStatus status;
  final String errorMessage;
  final String emptyActionLabel;

  String get limitSizeLabel => _formatSize(limitBytes);

  int get selectedChatCount =>
      sessions.where((session) => session.selected).length;

  int get selectedBytes => sessions
      .where((session) => session.selected)
      .fold<int>(0, (sum, session) => sum + session.sizeBytes);

  int get selectedMessages => sessions
      .where((session) => session.selected)
      .fold<int>(0, (sum, session) => sum + session.messageCount);

  int get totalBytes => sessions.fold<int>(0, (sum, s) => sum + s.sizeBytes);

  int get totalMessages =>
      sessions.fold<int>(0, (sum, s) => sum + s.messageCount);

  bool get allSelected =>
      sessions.isNotEmpty && selectedChatCount == sessions.length;

  bool get noneSelected => selectedChatCount == 0;

  bool get overBytes => selectedBytes > limitBytes;
  bool get overMessages => selectedMessages > limitMessages;
  bool get overChats => selectedChatCount > limitChats;

  /// True when the running total is over any archive limit.
  bool get selectionOverLimit => overBytes || overMessages || overChats;

  bool get canExport => !noneSelected && !selectionOverLimit;

  /// The first limit the current selection breaks, if any.
  String? get overLimitHint {
    if (overBytes) {
      return 'Deselect chats until the total is $limitSizeLabel or less.';
    }
    if (overMessages) {
      return 'Deselect chats until '
          '${_formatCount(limitMessages)} messages or fewer are selected.';
    }
    if (overChats) {
      return 'Deselect chats until ${_formatCount(limitChats)} or fewer '
          'chats are selected.';
    }
    return null;
  }

  /// A chat can always be deselected. An unselected chat is only available if
  /// adding it keeps every running total within its limit.
  bool canAdd(V2ExportPickerSession session) =>
      session.selected || _blockedLimit(session) == null;

  /// The limit that stops [session] from being added, or null when it fits.
  _BlockedLimit? _blockedLimit(V2ExportPickerSession session) {
    if (session.selected) return null;
    if (selectedBytes + session.sizeBytes > limitBytes) {
      return _BlockedLimit.bytes;
    }
    if (selectedMessages + session.messageCount > limitMessages) {
      return _BlockedLimit.messages;
    }
    if (selectedChatCount + 1 > limitChats) {
      return _BlockedLimit.chats;
    }
    return null;
  }

  /// Every id that should be selected after "Select all".
  ///
  /// Chats that are already selected are kept even if the initial data is over
  /// a limit, so the control can always be used to clear the selection. New
  /// chats are added in list order only while all three totals stay in range.
  List<String> get fittingSelection {
    final ids = <String>[];
    var bytes = 0;
    var messages = 0;
    var chats = 0;
    for (final session in sessions) {
      if (session.selected) {
        ids.add(session.id);
        bytes += session.sizeBytes;
        messages += session.messageCount;
        chats++;
        continue;
      }
      final fits =
          chats + 1 <= limitChats &&
          bytes + session.sizeBytes <= limitBytes &&
          messages + session.messageCount <= limitMessages;
      if (!fits) continue;
      ids.add(session.id);
      bytes += session.sizeBytes;
      messages += session.messageCount;
      chats++;
    }
    return ids;
  }

  /// True when "Select all" would add at least one chat, or would clear an
  /// existing full selection.
  bool get canSelectAll =>
      allSelected || fittingSelection.length > selectedChatCount;

  /// This state with [selected] applied to the chat rows.
  V2ExportPickerSheetData withSelection(Map<String, bool> selected) =>
      V2ExportPickerSheetData(
        sessions: [
          for (final session in sessions)
            session.copyWith(
              selected: selected[session.id] ?? session.selected,
            ),
        ],
        limitBytes: limitBytes,
        limitChats: limitChats,
        limitMessages: limitMessages,
        status: status,
        errorMessage: errorMessage,
        emptyActionLabel: emptyActionLabel,
      );
}

enum _BlockedLimit { bytes, messages, chats }

/// Bottom sheet for choosing which chats go into an archive that is larger
/// than the 64 MB / 1,000 chat / 20,000 message limits.
///
/// The ticks are local so the totals move immediately; [onToggleSession],
/// [onSelectAll] and [onExportSelection] report every change to the owner.
class ExportPickerSheet extends StatefulWidget {
  const ExportPickerSheet({
    super.key,
    required this.data,
    this.onToggleSession,
    this.onSelectAll,
    this.onExport,
    this.onExportSelection,
    this.onRetry,
    this.onClose,
  });

  final V2ExportPickerSheetData data;
  final V2ExportPickerToggle? onToggleSession;
  final V2ExportPickerSelectAll? onSelectAll;

  /// Legacy confirm hook; [onExportSelection] wins when both are given.
  final VoidCallback? onExport;
  final V2ExportPickerConfirm? onExportSelection;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  @override
  State<ExportPickerSheet> createState() => _ExportPickerSheetState();
}

class _ExportPickerSheetState extends State<ExportPickerSheet> {
  late Map<String, bool> _selected = _selectionOf(widget.data);

  static Map<String, bool> _selectionOf(V2ExportPickerSheetData data) => {
    for (final session in data.sessions) session.id: session.selected,
  };

  @override
  void didUpdateWidget(ExportPickerSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data.sessions, widget.data.sessions)) {
      _selected = _selectionOf(widget.data);
    }
  }

  V2ExportPickerSheetData get _data => widget.data.withSelection(_selected);

  void _toggle(String id, bool selected) {
    setState(() => _selected[id] = selected);
    widget.onToggleSession?.call(id, selected);
  }

  void _selectAll(List<String> ids) {
    final next = ids.toSet();
    setState(() {
      for (final session in widget.data.sessions) {
        _selected[session.id] = next.contains(session.id);
      }
    });
    widget.onSelectAll?.call(ids);
  }

  void _confirmExport() {
    final ids = {
      for (final entry in _selected.entries)
        if (entry.value) entry.key,
    };
    if (ids.isEmpty) return;
    final confirm = widget.onExportSelection;
    if (confirm != null) {
      confirm(ids);
      return;
    }
    widget.onExport?.call();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final body = switch (data.status) {
      V2ExportPickerStatus.loading => _loading(context),
      V2ExportPickerStatus.error => _error(context),
      V2ExportPickerStatus.ready =>
        data.sessions.isEmpty ? _empty(context) : _content(context, data),
    };
    return OFadeSlide(offset: const Offset(0, 0.03), child: body);
  }

  Widget _shell({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(
      OSpace.xl,
      OSpace.s,
      OSpace.xl,
      OSpace.m,
    ),
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView(
            padding: padding,
            children: [
              OSheetHeader(
                icon: Icons.inventory_2_outlined,
                title: 'Export chats',
                padding: EdgeInsets.zero,
                onClose: widget.onClose,
              ),
              const SizedBox(height: OSpace.m),
              child,
            ],
          ),
        ),
      ],
    );
  }

  Widget _loading(BuildContext context) {
    return _shell(
      padding: const EdgeInsets.fromLTRB(OSpace.xl, OSpace.s, OSpace.xl, 0),
      child: const SizedBox(height: 280, child: OSkeletonList(rows: 5)),
    );
  }

  Widget _error(BuildContext context) {
    return _shell(
      child: SizedBox(
        height: 320,
        child: OErrorState(
          title: 'Could not load chats',
          message: widget.data.errorMessage,
          onRetry: widget.onRetry,
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return _shell(
      child: SizedBox(
        height: 360,
        child: OEmptyState(
          compact: true,
          icon: Icons.chat_bubble_outline_rounded,
          title: 'No chats to export',
          message: 'Start a chat, then come back.',
          action: OButton(
            label: widget.data.emptyActionLabel,
            onPressed: widget.onClose,
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, V2ExportPickerSheetData data) {
    // Header, summary, select-all, then one row per chat. The builder keeps
    // long 1,000-chat lists lazy.
    final leading = <Widget>[
      OSheetHeader(
        icon: Icons.inventory_2_outlined,
        title: 'Export chats',
        padding: EdgeInsets.zero,
        onClose: widget.onClose,
      ),
      const SizedBox(height: OSpace.m),
      _Summary(data: data),
      const SizedBox(height: OSpace.s),
      _SelectAllRow(
        data: data,
        onSelectAll: data.canSelectAll
            ? () => _selectAll(
                data.allSelected ? const <String>[] : data.fittingSelection,
              )
            : null,
      ),
      const SizedBox(height: OSpace.xs),
    ];
    final sessionCount = data.sessions.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              OSpace.xl,
              OSpace.s,
              OSpace.xl,
              OSpace.m,
            ),
            itemCount: leading.length + sessionCount,
            itemBuilder: (context, index) {
              if (index < leading.length) return leading[index];
              final session = data.sessions[index - leading.length];
              return _SessionRow(
                data: data,
                session: session,
                onToggle: _toggle,
              );
            },
          ),
        ),
        _Footer(
          data: data,
          onExport: data.canExport ? _confirmExport : null,
          onClose: widget.onClose,
        ),
      ],
    );
  }
}

/// Running totals against all three archive limits. The row is a single
/// semantics node so a screen reader hears the numbers once, in order.
class _Summary extends StatelessWidget {
  const _Summary({required this.data});

  final V2ExportPickerSheetData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final over = data.selectionOverLimit;
    final selectedSize = _formatSize(data.selectedBytes);
    final summary =
        '$selectedSize of ${data.limitSizeLabel} selected. '
        '${data.selectedChatCount} of ${_formatCount(data.limitChats)} chats. '
        '${_formatCount(data.selectedMessages)} of '
        '${_formatCount(data.limitMessages)} messages.';
    return Semantics(
      container: true,
      label: summary,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('export-picker-summary'),
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: over ? c.danger : c.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: OSpace.m,
                runSpacing: OSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '$selectedSize of ${data.limitSizeLabel} selected',
                    style: OType.bodyStrong.copyWith(
                      color: over ? c.danger : c.text,
                    ),
                  ),
                  Text(
                    '${data.selectedChatCount} of '
                    '${_formatCount(data.limitChats)} chats',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                  Text(
                    '${_formatCount(data.selectedMessages)} of '
                    '${_formatCount(data.limitMessages)} messages',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.s),
              OProgressBar(
                value: data.selectedBytes / data.limitBytes,
                height: 8,
              ),
              if (over) ...[
                const SizedBox(height: OSpace.s),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: c.danger,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        _overLimitLabel(data),
                        style: OType.caption.copyWith(color: c.danger),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _overLimitLabel(V2ExportPickerSheetData data) {
  if (data.overBytes) return 'Over the ${data.limitSizeLabel} limit.';
  if (data.overMessages) {
    return 'Over the ${_formatCount(data.limitMessages)} message limit.';
  }
  return 'Over the ${_formatCount(data.limitChats)} chat limit.';
}

class _SelectAllRow extends StatelessWidget {
  const _SelectAllRow({required this.data, this.onSelectAll});

  final V2ExportPickerSheetData data;
  final VoidCallback? onSelectAll;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onSelectAll != null;
    final mixed = !data.allSelected && !data.noneSelected;
    final someCannotFit =
        !data.allSelected &&
        data.fittingSelection.length < data.sessions.length;
    final hint = data.allSelected
        ? 'Clears the selection'
        : someCannotFit
        ? 'Adds only the chats that fit'
        : 'Adds every chat';
    return Semantics(
      container: true,
      label: 'Select all chats',
      hint: hint,
      checked: data.allSelected,
      mixed: mixed,
      enabled: enabled,
      onTap: onSelectAll,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const ValueKey('export-picker-select-all'),
              onTap: onSelectAll,
              borderRadius: BorderRadius.circular(ORadius.m),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: OSpace.touch),
                child: Row(
                  children: [
                    SizedBox(
                      width: OSpace.touch,
                      height: OSpace.touch,
                      child: Center(
                        child: Checkbox(
                          key: const ValueKey(
                            'export-picker-select-all-checkbox',
                          ),
                          tristate: true,
                          value: data.allSelected
                              ? true
                              : data.noneSelected
                              ? false
                              : null,
                          onChanged: enabled ? (_) => onSelectAll!() : null,
                          activeColor: c.accentFill,
                          checkColor: c.onAccent,
                        ),
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Select all',
                            style: OType.bodySm.copyWith(
                              color: enabled ? c.text : c.textMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${data.selectedChatCount} of '
                            '${data.sessions.length} chats selected',
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ],
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

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.data,
    required this.session,
    required this.onToggle,
  });

  final V2ExportPickerSheetData data;
  final V2ExportPickerSession session;
  final V2ExportPickerToggle onToggle;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final blocked = data._blockedLimit(session);
    final enabled = blocked == null;
    final stacked = _largeText(context);
    final detail = [
      if (session.detail.isNotEmpty) session.detail,
      if (stacked) session.displaySize,
      if (session.heavyArtifacts) 'Heavy files must be re-uploaded',
    ].join(' · ');
    final blockedLabel = blocked == null
        ? null
        : switch (blocked) {
            _BlockedLimit.bytes => 'Over the ${data.limitSizeLabel} limit',
            _BlockedLimit.messages =>
              'Over the ${_formatCount(data.limitMessages)} message limit',
            _BlockedLimit.chats =>
              'Over the ${_formatCount(data.limitChats)} chat limit',
          };
    final semanticsLabel = session.selected
        ? 'Exclude ${session.name}, ${session.displaySize}'
        : blocked != null
        ? 'Include ${session.name}, ${session.displaySize}. '
              'Not available: it would go over the '
              '${_blockedLimitCopy(data, blocked)}.'
        : 'Include ${session.name}, ${session.displaySize}';
    return Semantics(
      container: true,
      label: semanticsLabel,
      hint: enabled
          ? session.selected
                ? 'Deselects this chat'
                : 'Adds this chat to the export'
          : null,
      checked: session.selected,
      enabled: enabled,
      onTap: enabled ? () => onToggle(session.id, !session.selected) : null,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: OSpace.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: OSpace.touch,
                height: OSpace.touch,
                child: Center(
                  child: Checkbox(
                    key: ValueKey('export-picker-session-${session.id}'),
                    value: session.selected,
                    onChanged: enabled
                        ? (value) => onToggle(session.id, value ?? false)
                        : null,
                    activeColor: c.accentFill,
                    checkColor: c.onAccent,
                  ),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: InkWell(
                  onTap: enabled
                      ? () => onToggle(session.id, !session.selected)
                      : null,
                  borderRadius: BorderRadius.circular(ORadius.m),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: OSpace.touch),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: OSpace.m),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  session.name,
                                  style: OType.bodySm.copyWith(
                                    color: enabled ? c.text : c.textMuted,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (detail.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    detail,
                                    style: OType.caption.copyWith(
                                      color: session.heavyArtifacts
                                          ? c.warn
                                          : c.textMuted,
                                    ),
                                  ),
                                ],
                                if (blockedLabel != null) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    blockedLabel,
                                    style: OType.caption.copyWith(
                                      color: c.textFaint,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (!stacked) ...[
                            const SizedBox(width: OSpace.s),
                            Text(
                              session.displaySize,
                              style: OType.caption.copyWith(
                                color: enabled ? c.text : c.textFaint,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _blockedLimitCopy(V2ExportPickerSheetData data, _BlockedLimit limit) =>
    switch (limit) {
      _BlockedLimit.bytes => '${data.limitSizeLabel} limit',
      _BlockedLimit.messages =>
        '${_formatCount(data.limitMessages)} message limit',
      _BlockedLimit.chats => '${_formatCount(data.limitChats)} chat limit',
    };

class _Footer extends StatelessWidget {
  const _Footer({required this.data, this.onExport, this.onClose});

  final V2ExportPickerSheetData data;
  final VoidCallback? onExport;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final stacked = _largeText(context);
    final hint = data.overLimitHint;
    final status =
        hint ??
        (data.noneSelected
            ? 'Select at least one chat to export.'
            : '${_formatSize(data.selectedBytes)} · '
                  '${data.selectedChatCount} '
                  '${data.selectedChatCount == 1 ? 'chat' : 'chats'} ready');
    final export = OButton(
      key: const ValueKey('export-picker-export'),
      label: 'Export selection',
      icon: Icons.download_rounded,
      expand: true,
      onPressed: onExport,
    );
    final cancel = OButton(
      label: 'Cancel',
      variant: OButtonVariant.secondary,
      expand: true,
      onPressed: onClose,
    );
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.xl,
            OSpace.m,
            OSpace.xl,
            OSpace.m,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    hint == null
                        ? Icons.info_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 16,
                    color: hint == null ? c.textFaint : c.danger,
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Text(
                      status,
                      key: const ValueKey('export-picker-limit-hint'),
                      style: OType.caption.copyWith(
                        color: hint == null ? c.textMuted : c.danger,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.s),
              if (stacked) ...[
                export,
                const SizedBox(height: OSpace.s),
                cancel,
              ] else
                Row(
                  children: [
                    Expanded(child: export),
                    const SizedBox(width: OSpace.s),
                    Expanded(child: cancel),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Export scope ────────────────────────────────────────────────────────────

/// What the person chose in [ExportScopeSheet].
@immutable
class V2ExportScope {
  const V2ExportScope.all()
    : sessionIds = null,
      chooseChats = false,
      cancelled = false;

  const V2ExportScope.chooseChats()
    : sessionIds = null,
      chooseChats = true,
      cancelled = false;

  const V2ExportScope.cancelled()
    : sessionIds = null,
      chooseChats = false,
      cancelled = true;

  /// Null means every chat in the account.
  final Set<String>? sessionIds;

  /// True when the person asked to pick the chats themselves.
  final bool chooseChats;
  final bool cancelled;
}

/// Injected state for [ExportScopeSheet].
@immutable
class V2ExportScopeSheetData {
  const V2ExportScopeSheetData({
    this.summaryLabel = '',
    this.chatCount = 0,
    this.overLimit = false,
    this.limitLabel = '64 MB',
  });

  /// A real measured line, for example "42 chats · 12 MB".
  final String summaryLabel;

  /// How many chats this device has measured. Zero hides "Choose chats".
  final int chatCount;

  /// True when every chat together breaks the archive limit, so a subset is
  /// the only export that can fit.
  final bool overLimit;

  /// The enforced per-archive limit, already formatted ("64 MB").
  final String limitLabel;
}

/// One small sheet that says what the backup covers and where it goes.
///
/// The archive format is transcript-only (see `SettingsBackupService`), so the
/// only real scope choice is which chats go in. The 64 MB limit is printed
/// here because the service and [ExportPickerSheet] both enforce it.
class ExportScopeSheet extends StatefulWidget {
  const ExportScopeSheet({super.key, required this.data, this.onClose});

  final V2ExportScopeSheetData data;
  final VoidCallback? onClose;

  @override
  State<ExportScopeSheet> createState() => _ExportScopeSheetState();
}

class _ExportScopeSheetState extends State<ExportScopeSheet> {
  late bool _choose = widget.data.overLimit;

  bool get _canChoose => widget.data.chatCount > 0;

  void _finish(V2ExportScope scope) {
    Navigator.of(context).pop(scope);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final allDisabled = data.overLimit;
    final summary = data.summaryLabel.isEmpty
        ? 'Every chat in your account'
        : data.summaryLabel;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                OSpace.xl,
                OSpace.s,
                OSpace.xl,
                OSpace.m,
              ),
              children: [
                OSheetHeader(
                  icon: Icons.inventory_2_outlined,
                  title: 'Export scope',
                  padding: EdgeInsets.zero,
                  onClose: widget.onClose,
                ),
                const SizedBox(height: OSpace.m),
                _ScopeOption(
                  key: const ValueKey('export-scope-all'),
                  title: 'All chats',
                  subtitle: allDisabled ? null : summary,
                  note: allDisabled ? 'Over the archive limit' : null,
                  selected: !_choose,
                  enabled: !allDisabled,
                  onTap: () => setState(() => _choose = false),
                ),
                if (_canChoose)
                  _ScopeOption(
                    key: const ValueKey('export-scope-choose'),
                    title: 'Choose chats',
                    subtitle: 'Pick a subset',
                    selected: _choose,
                    enabled: true,
                    onTap: () => setState(() => _choose = true),
                  ),
                const SizedBox(height: OSpace.m),
                Text(
                  'Chats only. Files and memory stay online.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.s),
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: c.textFaint,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        '${data.limitLabel} per backup',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _SheetFooter(
            primary: OButton(
              key: const ValueKey('export-scope-export'),
              label: 'Export',
              icon: Icons.download_rounded,
              expand: true,
              onPressed: allDisabled && !_canChoose
                  ? null
                  : () => _finish(
                      _choose
                          ? const V2ExportScope.chooseChats()
                          : const V2ExportScope.all(),
                    ),
            ),
            secondary: OButton(
              label: 'Cancel',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: widget.onClose,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScopeOption extends StatelessWidget {
  const _ScopeOption({
    super.key,
    required this.title,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.subtitle,
    this.note,
  });

  final String title;
  final String? subtitle;
  final String? note;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fg = enabled ? c.text : c.textFaint;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      enabled: enabled,
      label: subtitle == null ? title : '$title, $subtitle',
      hint: note,
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: OSpace.xs),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: enabled ? onTap : null,
              borderRadius: BorderRadius.circular(ORadius.m),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: OSpace.listRow),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: OSpace.s),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: enabled ? c.text : c.textFaint,
                      ),
                      const SizedBox(width: OSpace.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: OType.body.copyWith(
                                color: fg,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: OSpace.xxs),
                              Text(
                                subtitle!,
                                style: OType.caption.copyWith(
                                  color: c.textMuted,
                                ),
                              ),
                            ],
                            if (note != null) ...[
                              const SizedBox(height: OSpace.xxs),
                              Text(
                                note!,
                                style: OType.caption.copyWith(color: c.danger),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the export scope sheet. Null means the person dismissed it.
Future<V2ExportScope?> showExportScopeSheet(
  BuildContext context, {
  required V2ExportScopeSheetData data,
}) {
  return showOSheet<V2ExportScope>(
    context,
    builder: (sheetContext) => ExportScopeSheet(
      data: data,
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

// ── Import preview ──────────────────────────────────────────────────────────

/// Shows exactly what a validated archive will add, before anything uploads.
class ImportPreviewSheet extends StatelessWidget {
  const ImportPreviewSheet({super.key, required this.data, this.onClose});

  final V2ImportPreviewData data;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final import = OButton(
      key: const ValueKey('import-preview-import'),
      label: 'Import',
      icon: Icons.upload_file_rounded,
      expand: true,
      onPressed: () => Navigator.of(context).pop(true),
    );
    final cancel = OButton(
      label: 'Cancel',
      variant: OButtonVariant.secondary,
      expand: true,
      onPressed: () => Navigator.of(context).pop(false),
    );
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                OSpace.xl,
                OSpace.s,
                OSpace.xl,
                OSpace.m,
              ),
              children: [
                OSheetHeader(
                  icon: Icons.inventory_2_outlined,
                  title: 'Import archive',
                  padding: EdgeInsets.zero,
                  onClose: onClose,
                ),
                const SizedBox(height: OSpace.m),
                Container(
                  padding: const EdgeInsets.all(OSpace.m),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(ORadius.m),
                    border: Border.all(color: c.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.body.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        data.summaryLabel,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                if (data.filesIncluded > 0) ...[
                  const SizedBox(height: OSpace.s),
                  _PreviewLine(
                    icon: Icons.attach_file_rounded,
                    label:
                        '${data.filesIncluded} '
                        '${data.filesIncluded == 1 ? 'file' : 'files'} included',
                  ),
                ],
                if (data.filesUnavailable > 0) ...[
                  const SizedBox(height: OSpace.xs),
                  _PreviewLine(
                    icon: Icons.error_outline_rounded,
                    label:
                        '${data.filesUnavailable} '
                        '${data.filesUnavailable == 1 ? 'file' : 'files'} '
                        'unavailable',
                    tone: c.warn,
                  ),
                ],
                const SizedBox(height: OSpace.m),
                Text(
                  'Adds new chats. Nothing is replaced.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          _SheetFooter(primary: import, secondary: cancel),
        ],
      ),
    );
  }
}

/// Primary and secondary action pinned under a sheet's scrollable body, so
/// the buttons stay reachable at 200 % text.
class _SheetFooter extends StatelessWidget {
  const _SheetFooter({required this.primary, required this.secondary});

  final Widget primary;
  final Widget secondary;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final stacked = _largeText(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.xl,
            OSpace.m,
            OSpace.xl,
            OSpace.m,
          ),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    primary,
                    const SizedBox(height: OSpace.s),
                    secondary,
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: primary),
                    const SizedBox(width: OSpace.s),
                    Expanded(child: secondary),
                  ],
                ),
        ),
      ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine({required this.icon, required this.label, this.tone});

  final IconData icon;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: tone ?? c.textMuted),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            label,
            style: OType.caption.copyWith(color: tone ?? c.textMuted),
          ),
        ),
      ],
    );
  }
}

/// The sheet's copy, already formatted by the caller.
@immutable
class V2ImportPreviewData {
  const V2ImportPreviewData({
    required this.fileName,
    required this.summaryLabel,
    this.filesIncluded = 0,
    this.filesUnavailable = 0,
  });

  final String fileName;

  /// For example "42 chats · 860 messages · 12 MB".
  final String summaryLabel;

  final int filesIncluded;
  final int filesUnavailable;
}

/// Opens the import preview. True only when the person confirmed the import.
Future<bool> showImportPreviewSheet(
  BuildContext context, {
  required V2ImportPreviewData data,
}) async {
  final confirmed = await showOSheet<bool>(
    context,
    builder: (sheetContext) => ImportPreviewSheet(
      data: data,
      onClose: () => Navigator.of(sheetContext).pop(false),
    ),
  );
  return confirmed ?? false;
}

// ── Shared ──────────────────────────────────────────────────────────────────

/// True when doubled text would squeeze the size column or the footer buttons.
bool _largeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) >= 14 * 1.5;

String _formatSize(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  const gb = 1024 * 1024 * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(bytes % gb == 0 ? 0 : 1)} GB';
  }
  if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(bytes % mb == 0 ? 0 : 1)} MB';
  }
  if (bytes >= kb) {
    return '${(bytes / kb).toStringAsFixed(bytes % kb == 0 ? 0 : 1)} KB';
  }
  return '$bytes B';
}

/// "20,000" without pulling in intl (the sheet must stay dependency-free).
String _formatCount(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return buffer.toString();
}

/// Opens [ExportPickerSheet] in the shared bottom-sheet container.
///
/// Returns the confirmed chat ids, or null when the sheet was dismissed.
Future<Set<String>?> showExportPickerSheet(
  BuildContext context, {
  required V2ExportPickerSheetData data,
  V2ExportPickerToggle? onToggleSession,
  V2ExportPickerSelectAll? onSelectAll,
  VoidCallback? onRetry,
}) {
  return showOSheet<Set<String>>(
    context,
    builder: (sheetContext) => ExportPickerSheet(
      data: data,
      onToggleSession: onToggleSession,
      onSelectAll: onSelectAll,
      onExportSelection: (ids) => Navigator.of(sheetContext).pop(ids),
      onRetry: onRetry,
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}
