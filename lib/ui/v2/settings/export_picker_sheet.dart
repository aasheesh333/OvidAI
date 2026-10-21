import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// Archive limits for a single export.
///
/// The same limits are shown on Data control: one backup may hold up to 64 MB,
/// 1,000 chats and 20,000 messages. When the account is larger than any one of
/// them, Data control opens this picker so the person chooses a subset.
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
}

/// Called with a chat id and its new selected state.
typedef V2ExportPickerToggle = void Function(String id, bool selected);

/// Called with the complete set of chat ids that should be selected.
///
/// Select-all passes the ids that fit; an empty list clears the selection. The
/// adapter applies the ids to its source list and rebuilds this sheet.
typedef V2ExportPickerSelectAll = void Function(List<String> ids);

/// Injected state for [ExportPickerSheet].
///
/// The sheet never mutates [sessions]. Every checkbox, select-all and export
/// action goes back to the caller through a callback.
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

  /// Why the archive picker was opened. Explains every limit the whole account
  /// breaks, not just the 64 MB one.
  String get intro {
    final reasons = <String>[];
    if (totalBytes > limitBytes) {
      reasons.add(
        'Your chats are ${_formatSize(totalBytes)}, over the '
        '$limitSizeLabel archive limit.',
      );
    }
    if (totalMessages > limitMessages) {
      reasons.add(
        'Your chats hold ${_formatCount(totalMessages)} messages, over the '
        '${_formatCount(limitMessages)} message limit.',
      );
    }
    if (sessions.length > limitChats) {
      reasons.add(
        'You have ${_formatCount(sessions.length)} chats, over the '
        '${_formatCount(limitChats)} chat limit.',
      );
    }
    if (reasons.isEmpty) {
      return 'Select the chats to include in this backup.';
    }
    return '${reasons.join(' ')} Select the chats to include in this backup.';
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
}

enum _BlockedLimit { bytes, messages, chats }

/// Bottom sheet for choosing which chats go into an archive that is larger
/// than the 64 MB / 1,000 chat / 20,000 message limits.
///
/// The list is presentational: [data] is immutable and every change is reported
/// through [onToggleSession], [onSelectAll], [onExport] or [onClose]. The live
/// wiring in `lib/ui/v2/app/` owns the actual selection and rebuilds the sheet.
class ExportPickerSheet extends StatelessWidget {
  const ExportPickerSheet({
    super.key,
    required this.data,
    this.onToggleSession,
    this.onSelectAll,
    this.onExport,
    this.onRetry,
    this.onClose,
  });

  final V2ExportPickerSheetData data;
  final V2ExportPickerToggle? onToggleSession;
  final V2ExportPickerSelectAll? onSelectAll;
  final VoidCallback? onExport;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final body = switch (data.status) {
      V2ExportPickerStatus.loading => _loading(context),
      V2ExportPickerStatus.error => _error(context),
      V2ExportPickerStatus.ready =>
        data.sessions.isEmpty ? _empty(context) : _content(context),
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
              _Header(intro: data.intro),
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
          message: data.errorMessage,
          onRetry: onRetry,
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
          message: 'Start a chat first. Then come back to back it up.',
          action: OButton(label: data.emptyActionLabel, onPressed: onClose),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    // Header, summary, select-all, one row per chat, then the heavy-artifacts
    // note. The builder keeps long 1,000-chat lists lazy.
    final leading = <Widget>[
      _Header(intro: data.intro),
      const SizedBox(height: OSpace.m),
      _Summary(data: data),
      const SizedBox(height: OSpace.s),
      _SelectAllRow(
        data: data,
        onSelectAll: data.canSelectAll && onSelectAll != null
            ? () => onSelectAll!(
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
            itemCount: leading.length + sessionCount + 1,
            itemBuilder: (context, index) {
              if (index < leading.length) return leading[index];
              final sessionIndex = index - leading.length;
              if (sessionIndex < sessionCount) {
                final session = data.sessions[sessionIndex];
                return _SessionRow(
                  data: data,
                  session: session,
                  onToggle: onToggleSession,
                );
              }
              return Padding(
                padding: const EdgeInsets.only(top: OSpace.m),
                child: const _HeavyArtifactsNote(),
              );
            },
          ),
        ),
        _Footer(data: data, onExport: onExport, onClose: onClose),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.intro});

  final String intro;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(
                Icons.inventory_2_outlined,
                size: 21,
                color: c.accent,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Text(
                'Choose chats to export',
                style: OType.h2.copyWith(color: c.text),
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.s),
        Text(intro, style: OType.bodySm.copyWith(color: c.textMuted)),
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
            if (someCannotFit)
              Padding(
                padding: const EdgeInsets.only(left: OSpace.touch),
                child: Text(
                  'Some chats are too large to add to this archive.',
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.data, required this.session, this.onToggle});

  final V2ExportPickerSheetData data;
  final V2ExportPickerSession session;
  final V2ExportPickerToggle? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final blocked = data._blockedLimit(session);
    final enabled = blocked == null && onToggle != null;
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
      onTap: enabled ? () => onToggle!(session.id, !session.selected) : null,
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
                        ? (value) => onToggle!(session.id, value ?? false)
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
                      ? () => onToggle!(session.id, !session.selected)
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

class _HeavyArtifactsNote extends StatelessWidget {
  const _HeavyArtifactsNote();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const ValueKey('export-picker-heavy-note'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.upload_file_rounded, size: 18, color: c.warn),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              'Heavy artifacts are not included in a backup. Large files, '
              'videos and generated assets must be re-uploaded after importing.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

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
      onPressed: data.canExport ? onExport : null,
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
Future<void> showExportPickerSheet(
  BuildContext context, {
  required V2ExportPickerSheetData data,
  V2ExportPickerToggle? onToggleSession,
  V2ExportPickerSelectAll? onSelectAll,
  VoidCallback? onExport,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => ExportPickerSheet(
      data: data,
      onToggleSession: onToggleSession,
      onSelectAll: onSelectAll,
      onExport: onExport,
      onRetry: onRetry,
      onClose: () => Navigator.maybePop(sheetContext),
    ),
  );
}
