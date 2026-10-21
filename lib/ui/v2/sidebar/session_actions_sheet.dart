import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
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

  String get meta {
    final parts = <String>[
      if (timeLabel.isNotEmpty) timeLabel,
      if (messageCount > 0)
        messageCount == 1 ? '1 message' : '$messageCount messages',
      if (modelLabel.isNotEmpty) '$modelLabel model',
    ];
    return parts.join(' · ');
  }
}

/// The chat actions sheet: pin, rename, move, share, duplicate, export and
/// delete, followed by the consequence footnote.
///
/// The pin switch is optimistic: it flips as soon as the user taps and then
/// reports through [onTogglePin], so the control reflects the change instead of
/// snapping back to the injected snapshot while the write lands.
class SessionActionsSheet extends StatefulWidget {
  const SessionActionsSheet({
    super.key,
    required this.data,
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
  final VoidCallback? onClose;
  final ValueChanged<bool>? onTogglePin;
  final VoidCallback? onRename;
  final VoidCallback? onMoveToProject;
  final VoidCallback? onShare;
  final VoidCallback? onDuplicate;
  final VoidCallback? onExportMarkdown;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  @override
  State<SessionActionsSheet> createState() => _SessionActionsSheetState();
}

class _SessionActionsSheetState extends State<SessionActionsSheet> {
  late bool _pinned = widget.data.pinned;

  @override
  void didUpdateWidget(SessionActionsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the caller when it hands over fresh data (for example after a
    // retry), but leave an optimistic flip alone while the write is in flight.
    if (widget.data.pinned != oldWidget.data.pinned) {
      _pinned = widget.data.pinned;
    }
  }

  void _setPinned(bool value) {
    if (_pinned != value) setState(() => _pinned = value);
    widget.onTogglePin?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final onClose = widget.onClose;
    switch (data.status) {
      case V2SessionActionsStatus.loading:
        return const SizedBox(height: 320, child: OSkeletonList(rows: 5));
      case V2SessionActionsStatus.error:
        return SizedBox(
          height: 320,
          child: OErrorState(
            title: 'Chat actions did not load',
            message:
                data.errorMessage ?? 'Check your connection and try again.',
            onRetry: widget.onRetry,
          ),
        );
      case V2SessionActionsStatus.empty:
        return SizedBox(
          height: 340,
          child: OEmptyState(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Chat not found',
            message:
                'This chat may have been deleted. Close this sheet and pick another chat.',
            action: OButton(label: 'Close', onPressed: onClose),
          ),
        );
      case V2SessionActionsStatus.content:
        return Container(
          color: c.surface,
          child: OFadeSlide(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.l,
                OSpace.l,
                OSpace.l,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(data: data, onClose: onClose),
                  const SizedBox(height: OSpace.m),
                  Divider(color: c.hairline, height: 1),
                  const SizedBox(height: OSpace.xs),
                  OStagger(
                    children: [
                      OListRow(
                        title: 'Pin to top of drawer',
                        subtitle: 'Keep this chat handy',
                        icon: _pinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        trailing: Switch.adaptive(
                          value: _pinned,
                          onChanged: widget.onTogglePin == null
                              ? null
                              : _setPinned,
                        ),
                        onTap: widget.onTogglePin == null
                            ? null
                            : () => _setPinned(!_pinned),
                        showChevron: false,
                      ),
                      OListRow(
                        title: 'Rename chat',
                        icon: Icons.edit_outlined,
                        onTap: widget.onRename,
                      ),
                      OListRow(
                        title: 'Move to project',
                        icon: Icons.folder_outlined,
                        // Flexible keeps the project chip from squeezing the
                        // title on narrow screens or at large text sizes.
                        trailing: Flexible(
                          child: _MoveTrailing(projectName: data.projectName),
                        ),
                        onTap: widget.onMoveToProject,
                        showChevron: false,
                      ),
                      OListRow(
                        title: 'Share chat',
                        subtitle: 'Send a link or invite people',
                        icon: Icons.share_outlined,
                        trailing: Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                          color: c.textFaint,
                        ),
                        onTap: widget.onShare,
                        showChevron: false,
                      ),
                      OListRow(
                        title: 'Duplicate chat',
                        icon: Icons.content_copy_rounded,
                        trailing: const Flexible(
                          child: _TrailingPill(label: 'Branch'),
                        ),
                        onTap: widget.onDuplicate,
                        showChevron: false,
                      ),
                      OListRow(
                        title: 'Export as Markdown',
                        subtitle: '.md file with code blocks',
                        icon: Icons.download_outlined,
                        trailing: Icon(
                          Icons.arrow_downward_rounded,
                          size: 18,
                          color: c.textFaint,
                        ),
                        onTap: widget.onExportMarkdown,
                        showChevron: false,
                      ),
                    ],
                  ),
                  Divider(color: c.hairline, height: 1),
                  OListRow(
                    title: 'Delete chat',
                    subtitle: 'Irreversible action',
                    icon: Icons.delete_outline_rounded,
                    danger: true,
                    trailing: Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: c.danger,
                    ),
                    onTap: widget.onDelete,
                    showChevron: false,
                  ),
                  const SizedBox(height: OSpace.m),
                  Container(
                    padding: const EdgeInsets.all(OSpace.m),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(ORadius.m),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: c.surfaceRaised,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.security_rounded,
                            size: 15,
                            color: c.textMuted,
                          ),
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Text(
                            "Deleting removes this chat's files, artifacts, and learned memory from your cloud account. This cannot be undone.",
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.data, this.onClose});

  final V2SessionActionsData data;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Semantics(
                      container: true,
                      header: true,
                      child: Text(
                        data.title.isEmpty ? 'Chat' : data.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.h2.copyWith(color: c.text),
                      ),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              if (data.meta.isNotEmpty) ...[
                const SizedBox(height: OSpace.xs),
                Text(
                  data.meta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: OSpace.s),
        OIconButton(
          icon: Icons.close_rounded,
          semanticLabel: 'Close chat actions',
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _MoveTrailing extends StatelessWidget {
  const _MoveTrailing({this.projectName});

  final String? projectName;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    if (projectName == null || projectName!.isEmpty) {
      return Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: c.surfaceRaised,
                borderRadius: BorderRadius.circular(ORadius.pill),
              ),
              child: Text(
                projectName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ),
        ),
        const SizedBox(width: OSpace.xs),
        Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
      ],
    );
  }
}

/// Compact pill for row trailing content.
///
/// Mirrors [OPill]'s neutral look but grows with the text scale instead of
/// being pinned to 24 dp, so large text is never clipped.
class _TrailingPill extends StatelessWidget {
  const _TrailingPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(
          color: c.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Opens [SessionActionsSheet] in the shared bottom-sheet container.
Future<void> showSessionActionsSheet(
  BuildContext context, {
  required V2SessionActionsData data,
  VoidCallback? onClose,
  ValueChanged<bool>? onTogglePin,
  VoidCallback? onRename,
  VoidCallback? onMoveToProject,
  VoidCallback? onShare,
  VoidCallback? onDuplicate,
  VoidCallback? onExportMarkdown,
  VoidCallback? onDelete,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => SessionActionsSheet(
      data: data,
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
