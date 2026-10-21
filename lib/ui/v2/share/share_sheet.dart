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

  /// Whether anyone with the link can open it.
  final bool anyoneCanView;

  /// Whether the creator's name is shown on the shared page.
  final bool showName;

  /// Whether the link is currently live.
  final bool active;

  /// Whether the link was just copied. The owner of the state flips this for
  /// the short "Copied" confirmation.
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
  final String? subtitle;

  /// Extra explanation shown above the share targets. The chat variant uses
  /// this for the fork-into-your-own-account note.
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
            height: 420,
            child: OSkeletonList(rows: 4),
          ),
          V2ShareStatus.error => SizedBox(
            height: 380,
            child: OErrorState(message: data.errorMessage, onRetry: onRetry),
          ),
          V2ShareStatus.ready =>
            data.active ? _content(context) : _empty(context),
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final c = OColors.of(context);
    final message = data.isCollab
        ? 'Create a live room for up to ${data.capacity} people. One person '
              'sends at a time and you pay for storage.'
        : 'Create a link anyone can view. Your files and connectors stay '
              'private.';
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
          _header(context, c),
          if (data.canChangeMode && !data.viewerCanFork) ...[
            const SizedBox(height: OSpace.l),
            _modeSelector(context, c, showCurrent: false),
          ],
          const SizedBox(height: OSpace.l),
          OCard(
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.link_off_rounded,
                    size: 32,
                    color: c.accent,
                  ),
                ),
                const SizedBox(height: OSpace.l),
                Text(
                  'This chat is not shared yet',
                  textAlign: TextAlign.center,
                  style: OType.h2.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.s),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ),
                const SizedBox(height: OSpace.l),
                OButton(
                  label: 'Create link',
                  icon: Icons.link_rounded,
                  expand: true,
                  onPressed: onCreateLink,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      child: OFadeSlide(
        child: OStagger(
          children: [
            _header(context, c),
            const SizedBox(height: OSpace.l),
            _linkBlock(context),
            if (data.canChangeMode && !data.viewerCanFork) ...[
              const SizedBox(height: OSpace.m),
              _modeSelector(context, c, showCurrent: true),
            ],
            if (!data.viewerCanFork) ...[
              const SizedBox(height: OSpace.m),
              _permissions(context, c),
            ],
            if (forkNote != null) ...[
              const SizedBox(height: OSpace.m),
              _forkNoteCard(c),
            ],
            const SizedBox(height: OSpace.l),
            OSectionHeader(
              label: 'Share directly',
              padding: const EdgeInsets.only(bottom: OSpace.s),
            ),
            _targets(context, c),
            if (!data.viewerCanFork) ...[
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Stop sharing',
                icon: Icons.link_off_rounded,
                variant: OButtonVariant.danger,
                expand: true,
                onPressed: onStopSharing,
              ),
            ],
            const SizedBox(height: OSpace.l),
            _privacyNote(c),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, OColors c) {
    final explanation = _subtitleFor(data);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: OType.h2.copyWith(color: c.text)),
              if (explanation != null) ...[
                const SizedBox(height: OSpace.xs),
                Text(
                  explanation,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ],
            ],
          ),
        ),
        if (onClose != null)
          OIconButton(
            icon: Icons.close_rounded,
            semanticLabel: 'Close share sheet',
            onPressed: onClose,
          ),
      ],
    );
  }

  /// Collab and read-only links explain themselves differently. An explicit
  /// [subtitle] only refines the read-only copy; Collab always states its own
  /// rules so the cap and the storage owner are never hidden.
  String? _subtitleFor(V2ShareSheetData data) {
    if (data.isCollab) {
      final people = data.capacity == 1 ? '1 person' : '${data.capacity} people';
      return 'Up to $people can join. One person sends at a time, and you pay '
          'for storage.';
    }
    return subtitle;
  }

  Widget _modeSelector(
    BuildContext context,
    OColors c, {
    required bool showCurrent,
  }) {
    if (showCurrent) return _modeSwitch(context, c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OSectionHeader(
          label: 'Share mode',
          padding: const EdgeInsets.only(bottom: OSpace.s),
          trailing: Text(
            data.isCollab ? 'Live room' : 'Snapshot',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
        _modeOption(V2ShareMode.collab),
        const SizedBox(height: OSpace.s),
        _modeOption(V2ShareMode.readOnly),
      ],
    );
  }

  /// Compact mode switch shown under the active link.
  ///
  /// [V2ShareLinkCard] already states the current mode as a badge, so repeating
  /// both mode cards here would announce the same mode twice. The switch offers
  /// only the other mode, which is the one action left to take.
  Widget _modeSwitch(BuildContext context, OColors c) {
    final target = data.isCollab ? V2ShareMode.readOnly : V2ShareMode.collab;
    final title = data.isCollab ? 'Read only' : 'Collab';
    final body = data.isCollab
        ? 'A read-only snapshot people can fork into their own account.'
        : 'A live room for up to ${data.capacity} people, one sender at a '
              'time.';
    final icon = data.isCollab
        ? Icons.visibility_rounded
        : Icons.groups_rounded;
    return OPressable(
      onTap: onModeChanged == null ? null : () => onModeChanged!(target),
      semanticLabel: 'Share mode. Switch to $title. $body',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(ORadius.s),
                ),
                child: Icon(icon, size: 19, color: c.accent),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'SHARE MODE',
                      style: OType.overline.copyWith(color: c.textMuted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.s),
              Text(
                'Switch',
                style: OType.caption.copyWith(
                  color: c.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(Icons.swap_horiz_rounded, size: 16, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeOption(V2ShareMode mode) {
    final collab = mode == V2ShareMode.collab;
    return _ModeOption(
      title: collab ? 'Collab' : 'Read only',
      icon: collab ? Icons.groups_rounded : Icons.visibility_rounded,
      body: collab
          ? 'Up to ${data.capacity} people join one live chat. One person '
                'sends at a time, and you pay for storage.'
          : 'Anyone with the link can read this chat and fork a copy into '
                'their own account.',
      selected: data.isCollab == collab,
      onTap: onModeChanged == null ? null : () => onModeChanged!(mode),
    );
  }

  /// The active-link block. [V2ShareLinkCard] owns the URL, the mode badge, the
  /// member count, copying, revoking and forking, so the sheet only maps its
  /// state onto the card.
  Widget _linkBlock(BuildContext context) {
    // The card names its copy control "Copy share link". The sheet's copy
    // action has always been announced as "Copy link", so the block keeps that
    // name for assistive tech (and for callers that look the control up by it).
    return Semantics(
      label: 'Copy link',
      child: V2ShareLinkCard(
        data: V2ShareLinkCardData(
          url: data.link,
          mode: data.mode,
          memberCount: data.memberCount,
          capacity: data.capacity,
          copied: data.copied,
          viewer: data.viewerCanFork,
        ),
        onCopy: onCopyLink,
        // A viewer can never revoke someone else's link; the card shows the
        // fork action for them instead.
        onRevoke: data.viewerCanFork ? null : onStopSharing,
        onFork: onFork,
      ),
    );
  }

  Widget _permissions(BuildContext context, OColors c) {
    if (data.isCollab) return _collabRules(context, c);
    return OCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _ToggleRow(
            title: 'Anyone with the link can view',
            subtitle: 'Read-only. They can fork it into their own account.',
            value: data.anyoneCanView,
            onChanged: onToggleAnyoneCanView,
          ),
          Divider(
            height: 1,
            color: c.hairline,
            indent: OSpace.l,
            endIndent: OSpace.l,
          ),
          _ToggleRow(
            title: 'Show my name',
            subtitle: 'Displays ${data.creatorName} as creator',
            value: data.showName,
            onChanged: onToggleShowName,
          ),
        ],
      ),
    );
  }

  /// Collab rules replace the read-only visibility switch: the room is live,
  /// cap and occupancy are shown on the link card above, and this block keeps
  /// the turn and storage rules plus the name switch.
  Widget _collabRules(BuildContext context, OColors c) {
    return OCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(OSpace.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoRow(
                  icon: Icons.pan_tool_alt_rounded,
                  title: 'One person sends at a time',
                  body:
                      'Everyone else waits for the turn. Drafts are never '
                      'dropped.',
                ),
                const SizedBox(height: OSpace.s),
                _InfoRow(
                  icon: Icons.workspace_premium_rounded,
                  title: data.creatorPaysStorage
                      ? 'You pay for storage'
                      : 'Storage is shared',
                  body: data.creatorPaysStorage
                      ? 'Members use your plan and storage, not their own.'
                      : 'Members use their own plan and storage.',
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: c.hairline,
            indent: OSpace.l,
            endIndent: OSpace.l,
          ),
          _ToggleRow(
            title: 'Show my name',
            subtitle: 'Displays ${data.creatorName} as creator',
            value: data.showName,
            onChanged: onToggleShowName,
          ),
        ],
      ),
    );
  }

  Widget _forkNoteCard(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.account_tree_rounded, size: 20, color: c.accent),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              forkNote!,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _targets(BuildContext context, OColors c) {
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        alignment: WrapAlignment.spaceEvenly,
        spacing: OSpace.s,
        runSpacing: OSpace.m,
        children: [
          for (final target in V2ShareTarget.values)
            ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: 72,
                maxWidth: constraints.maxWidth,
              ),
              child: _ShareTargetButton(
                target: target,
                onTap: onShareTarget == null
                    ? null
                    : () => onShareTarget!(target),
              ),
            ),
        ],
      ),
    );
  }

  Widget _privacyNote(OColors c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: OSpace.xs),
          child: Icon(Icons.lock_outline_rounded, size: 14, color: c.textFaint),
        ),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: Text(
            'Shared chats never include your files or connectors.',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
      ],
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
class _ModeOption extends StatelessWidget {
  const _ModeOption({
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
          curve: OMotion.standard,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: selected ? c.accentFill : c.surfaceRaised,
                  borderRadius: BorderRadius.circular(ORadius.s),
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: selected ? c.onAccent : c.textMuted,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      body,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.s),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? c.accent : c.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: c.accent),
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
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    subtitle,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.m),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: c.accentFill,
              activeThumbColor: c.onAccent,
              inactiveTrackColor: c.surfaceRaised,
              inactiveThumbColor: c.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareTargetButton extends StatelessWidget {
  const _ShareTargetButton({required this.target, this.onTap});

  final V2ShareTarget target;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (label, icon, tint) = switch (target) {
      V2ShareTarget.whatsApp => ('WhatsApp', Icons.chat_rounded, c.success),
      V2ShareTarget.gmail => ('Gmail', Icons.mail_rounded, c.danger),
      V2ShareTarget.slack => ('Slack', Icons.forum_rounded, c.accent),
      V2ShareTarget.more => ('More', Icons.more_horiz_rounded, c.textMuted),
    };
    return Semantics(
      label: 'Share on $label',
      button: true,
      enabled: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      child: OPressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.xs,
            vertical: OSpace.s,
          ),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(ORadius.l),
                ),
                child: Icon(icon, size: 26, color: tint),
              ),
              const SizedBox(height: OSpace.s),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
