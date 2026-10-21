import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import 'share_sheet.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

/// Immutable state for [ShareChatSheet].
///
/// A chat link is read-only for the people who open it. They may fork the chat
/// into their own account, which makes a private copy for them.
@immutable
class V2ShareChatSheetData {
  const V2ShareChatSheetData({
    required this.link,
    this.mode = V2ShareMode.readOnly,
    this.memberCount = 1,
    this.capacity = v2ShareMemberLimit,
    this.creatorPaysStorage = true,
    this.viewerCanFork = false,
    this.canChangeMode = true,
    this.anyoneCanView = true,
    this.showName = true,
    this.active = true,
    this.copied = false,
    this.creatorName = '',
    this.status = V2ShareStatus.ready,
    this.errorMessage = 'We could not load the share link.',
  }) : assert(capacity > 0, 'A shared room always has a capacity');

  final String link;

  /// Collab (live, capped, one sender) or Read only (forkable snapshot).
  final V2ShareMode mode;
  final int memberCount;
  final int capacity;
  final bool creatorPaysStorage;
  final bool viewerCanFork;
  final bool canChangeMode;
  final bool anyoneCanView;
  final bool showName;
  final bool active;
  final bool copied;

  /// Name shown on the shared page. Empty means the signed-in person, which
  /// the sheet reads as "you". There is no placeholder person: the wiring pass
  /// injects the real account name.
  final String creatorName;

  final V2ShareStatus status;
  final String errorMessage;

  V2ShareSheetData toSheetData() => V2ShareSheetData(
    link: link,
    mode: mode,
    memberCount: memberCount,
    capacity: capacity,
    creatorPaysStorage: creatorPaysStorage,
    viewerCanFork: viewerCanFork,
    canChangeMode: canChangeMode,
    anyoneCanView: anyoneCanView,
    showName: showName,
    active: active,
    copied: copied,
    creatorName: creatorName.isEmpty ? 'you' : creatorName,
    status: status,
    errorMessage: errorMessage,
  );
}

/// Chat-specific share sheet. It wraps the generic [ShareSheet] and adds the
/// fork-into-your-own-account note that only chat links need.
class ShareChatSheet extends StatelessWidget {
  const ShareChatSheet({
    super.key,
    required this.data,
    this.onCopyLink,
    this.onModeChanged,
    this.onFork,
    this.onToggleAnyoneCanView,
    this.onToggleShowName,
    this.onShareTarget,
    this.onStopSharing,
    this.onCreateLink,
    this.onRetry,
    this.onClose,
  });

  final V2ShareChatSheetData data;
  final VoidCallback? onCopyLink;
  final ValueChanged<V2ShareMode>? onModeChanged;
  final VoidCallback? onFork;
  final ValueChanged<bool>? onToggleAnyoneCanView;
  final ValueChanged<bool>? onToggleShowName;
  final ValueChanged<V2ShareTarget>? onShareTarget;
  final VoidCallback? onStopSharing;
  final VoidCallback? onCreateLink;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ShareSheet(
      data: data.toSheetData(),
      onCopyLink: onCopyLink,
      onModeChanged: onModeChanged,
      onFork: onFork,
      onToggleAnyoneCanView: onToggleAnyoneCanView,
      onToggleShowName: onToggleShowName,
      onShareTarget: onShareTarget,
      onStopSharing: onStopSharing,
      onCreateLink: onCreateLink,
      onRetry: onRetry,
      onClose: onClose,
      title: 'Share this chat',
      subtitle: 'Anyone with the link can view or fork it.',
      forkNote:
          'Forking makes a copy in their own account. Your original stays private.',
    );
  }
}

/// Opens [ShareChatSheet] in the shared bottom-sheet container.
Future<void> showShareChatSheet(
  BuildContext context, {
  required V2ShareChatSheetData data,
  VoidCallback? onCopyLink,
  ValueChanged<V2ShareMode>? onModeChanged,
  VoidCallback? onFork,
  ValueChanged<bool>? onToggleAnyoneCanView,
  ValueChanged<bool>? onToggleShowName,
  ValueChanged<V2ShareTarget>? onShareTarget,
  VoidCallback? onStopSharing,
  VoidCallback? onCreateLink,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => ShareChatSheet(
      data: data,
      onCopyLink: onCopyLink,
      onModeChanged: onModeChanged,
      onFork: onFork,
      onToggleAnyoneCanView: onToggleAnyoneCanView,
      onToggleShowName: onToggleShowName,
      onShareTarget: onShareTarget,
      onStopSharing: onStopSharing,
      onCreateLink: onCreateLink,
      onRetry: onRetry,
      onClose: () => Navigator.maybePop(sheetContext),
    ),
  );
}
