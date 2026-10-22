import 'package:flutter/material.dart';

import '../../../core/collaboration/models.dart' show maxActiveMembers;
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'share_link_card.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

/// Load state for a share sheet. The link itself is data, not a route.
enum V2ShareStatus { loading, ready, error }

/// How a shared chat can be used by the people who open the link.
///
/// [collab] is a live room capped at [maxActiveMembers] people with a single
/// sender at a time, paid for by the creator. [readOnly] is a snapshot that
/// viewers can fork into their own account.
enum V2ShareMode { collab, readOnly }

/// Where a shared link can be sent from the share sheet.
///
/// The sheet no longer renders a target grid: the operating system's share
/// sheet owns that list. The enum stays so existing hosts keep compiling.
enum V2ShareTarget { whatsApp, gmail, slack, more }

/// Hard cap on people in a Collab room, including the creator.
const int v2ShareMemberLimit = maxActiveMembers;

/// Immutable share state for [ShareSheet].
@immutable
class V2ShareSheetData {
  const V2ShareSheetData({
    required this.link,
    required this.creatorName,
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
    this.status = V2ShareStatus.ready,
    this.errorMessage = 'We could not load the share link.',
  }) : assert(capacity > 0, 'A shared room always has a capacity');

  /// The read-only link shown in the sheet, for example `ovidsi.com/c/79f9b4c0e`.
  final String link;

  /// The sharing mode currently selected.
  final V2ShareMode mode;

  /// People in the Collab room, including the creator.
  final int memberCount;

  /// Hard room cap. Defaults to [v2ShareMemberLimit].
  final int capacity;

  /// Whether the creator's plan and storage pay for the room.
  final bool creatorPaysStorage;

  /// True when the person reading this sheet is a viewer of a read-only link
  /// rather than its creator, so they can fork it into their own account.
  final bool viewerCanFork;

  /// False when the current person cannot switch the mode (for example a
  /// member who joined someone else's room).
  final bool canChangeMode;

  /// Whether anyone with the link can open it. Kept for hosts that still own
  /// the value; the sheet does not render a toggle for it.
  final bool anyoneCanView;

  /// Whether the creator's name is shown on the shared page.
  final bool showName;

  /// Whether the link is currently live.
  final bool active;

  /// Whether the link was just copied. The owner of the state flips this for
  /// the short confirmation on the copy control.
  final bool copied;

  /// Name shown in the "Show my name" subtitle. Injected: the sheet never
  /// invents a person.
  final String creatorName;

  final V2ShareStatus status;
  final String errorMessage;

  bool get isCollab => mode == V2ShareMode.collab;

  /// True when the room has reached its member cap.
  bool get roomFull => capacity > 0 && memberCount >= capacity;

  /// Short label for the member count, for example `3 of 50 members`.
  String get memberLabel => '$memberCount of $capacity members';
}

/// Generic share sheet. Presentational: all state and actions are injected.
///
/// Minimal layout: a title row with close, two one-line mode cards, the link
/// row with copy, then the revoke action. Sharing to an app is the operating
/// system's job.
class ShareSheet extends StatelessWidget {
  const ShareSheet({
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
    this.title = 'Share this chat',
    this.subtitle,
    this.forkNote,
  });

  final V2ShareSheetData data;
  final VoidCallback? onCopyLink;
  final ValueChanged<V2ShareMode>? onModeChanged;

  /// Called when a read-only viewer forks the chat into their own account.
  final VoidCallback? onFork;
  final ValueChanged<bool>? onToggleAnyoneCanView;
  final ValueChanged<bool>? onToggleShowName;
  final ValueChanged<V2ShareTarget>? onShareTarget;
  final VoidCallback? onStopSharing;
  final VoidCallback? onCreateLink;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  final String title;

  /// Retained for hosts that used to pass a second header line. The minimal
  /// header is one line; the mode cards explain the two options instead.
  final String? subtitle;

  /// Retained for the chat variant. Forking is explained by the card's action,
  /// so the sheet does not render a paragraph.
  final String? forkNote;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: switch (data.status) {
          V2ShareStatus.loading => const SizedBox(
            height: 320,
            child: OSkeletonList(rows: 4),
          ),
          V2ShareStatus.error => SizedBox(
            height: 320,
            child: OErrorState(message: data.errorMessage, onRetry: onRetry),
          ),
          V2ShareStatus.ready =>
            data.active ? _content(context) : _empty(context),
        },
      ),
    );
  }

  bool get _canPickMode =>
      data.canChangeMode && !data.viewerCanFork && onModeChanged != null;

  /// Revoking is irreversible for everyone holding the link, so the sheet owns
  /// the confirmation even when the host's callback is a bare service call.
  Future<void> _confirmRevoke(BuildContext context) async {
    final revoke = onStopSharing;
    if (revoke == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke this link?'),
        content: const Text(
          'Anyone with the link loses access immediately. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: OColors.of(dialogContext).danger,
              foregroundColor: OColors.of(dialogContext).onAccent,
            ),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) revoke();
  }

  Widget _empty(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          if (_canPickMode) ...[
            const SizedBox(height: OSpace.s),
            _modeCard(V2ShareMode.collab),
            const SizedBox(height: OSpace.s),
            _modeCard(V2ShareMode.readOnly),
          ],
          const SizedBox(height: OSpace.l),
          OCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Not shared yet',
                  style: OType.h3.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.l),
                if (onCreateLink != null)
                  OButton(
                    label: 'Create link',
                    icon: Icons.link_rounded,
                    expand: true,
                    onPressed: onCreateLink,
                  )
                else
                  Text(
                    'Sign in to create a link.',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final viewer = data.viewerCanFork;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          if (_canPickMode) ...[
            const SizedBox(height: OSpace.s),
            _modeCard(V2ShareMode.collab),
            const SizedBox(height: OSpace.s),
            _modeCard(V2ShareMode.readOnly),
          ],
          const SizedBox(height: OSpace.l),
          _linkBlock(context),
          if (!viewer && onStopSharing != null) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Revoke link',
              icon: Icons.link_off_rounded,
              variant: OButtonVariant.danger,
              expand: true,
              onPressed: () => _confirmRevoke(context),
            ),
          ],
        ],
      ),
    );
  }

  /// One header row, shared with every other sheet: title on the left, close
  /// on the right. The scroll view already supplies the outer gutter, so the
  /// header only adds the gap under itself.
  Widget _header() {
    return OSheetHeader(
      title: title,
      closeLabel: 'Close share sheet',
      onClose: onClose,
      padding: const EdgeInsets.only(bottom: OSpace.s),
    );
  }

  /// One line per mode. The selected card carries the check and the accent.
  Widget _modeCard(V2ShareMode mode) {
    final collab = mode == V2ShareMode.collab;
    final selected = data.isCollab == collab;
    final title = collab ? 'Collab' : 'Read only';
    final body = collab
        ? 'Up to ${data.capacity} people, one sender at a time.'
        : 'Anyone with the link can read and fork.';
    return _ModeCard(
      title: title,
      body: body,
      icon: collab ? Icons.groups_rounded : Icons.visibility_rounded,
      selected: selected,
      onTap: onModeChanged == null ? null : () => onModeChanged!(mode),
    );
  }

  /// The active-link block. [V2ShareLinkCard] owns the URL and its copy
  /// control; the sheet owns revoking, so the card never repeats it here.
  Widget _linkBlock(BuildContext context) {
    return V2ShareLinkCard(
      data: V2ShareLinkCardData(
        url: data.link,
        mode: data.mode,
        memberCount: data.memberCount,
        capacity: data.capacity,
        copied: data.copied,
        viewer: data.viewerCanFork,
      ),
      onCopy: data.link.trim().isEmpty ? null : onCopyLink,
      onFork: onFork,
    );
  }
}

/// Opens [ShareSheet] in the shared bottom-sheet container.
Future<void> showShareSheet(
  BuildContext context, {
  required V2ShareSheetData data,
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
    builder: (sheetContext) => ShareSheet(
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

/// One selectable share mode. The whole card is the 48 dp target and reports
/// its selected state to accessibility.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.body,
    required this.icon,
    required this.selected,
    this.onTap,
  });

  final String title;
  final String body;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel: '$title. $body',
      selected: selected,
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: OMotion.fast,
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : c.surface,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(
              color: selected
                  ? c.accentFill.withValues(alpha: 0.5)
                  : c.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? c.accent : c.textMuted,
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: OSpace.xxs),
                    Text(
                      body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: OSpace.s),
                Icon(Icons.check_rounded, size: 20, color: c.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
