import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';
import 'share_sheet.dart' show V2ShareMode, v2ShareMemberLimit;

// TODO(l10n): extract this card's English copy during the ARB pass.

/// Immutable state for [V2ShareLinkCard].
///
/// The card is presentational: the host owns copying, revoking and forking.
/// Dates are formatted locally so the card never asks for a clock beyond the
/// optional [V2ShareLinkCard.now] used to detect an expired link.
@immutable
class V2ShareLinkCardData {
  const V2ShareLinkCardData({
    required this.url,
    this.mode = V2ShareMode.readOnly,
    this.createdAt,
    this.expiresAt,
    this.memberCount = 1,
    this.capacity = v2ShareMemberLimit,
    this.copied = false,
    this.viewer = false,
    this.revoked = false,
  }) : assert(capacity > 0, 'A shared link always has a capacity');

  /// The link people open, for example `ovidsi.com/c/79f9b4c0e`.
  final String url;

  /// Collab rooms are live and capped; read-only links can be forked.
  final V2ShareMode mode;

  /// When the link was created, shown as a quiet meta row.
  final DateTime? createdAt;

  /// When the link stops working. Null means it does not expire.
  final DateTime? expiresAt;

  /// People in a Collab room, including the creator. Ignored in read-only.
  final int memberCount;

  /// Hard room cap. Defaults to [v2ShareMemberLimit].
  final int capacity;

  /// Whether the link was just copied, for the short "Copied" confirmation.
  final bool copied;

  /// True when the current person opened someone else's link.
  final bool viewer;

  /// True when the creator has revoked the link. Nothing is actionable then.
  final bool revoked;

  bool get isCollab => mode == V2ShareMode.collab;

  /// True when the room has reached its member cap.
  bool get roomFull => isCollab && memberCount >= capacity;

  /// Short label for the member count, for example `3 of 50 members`.
  String get memberLabel => '$memberCount of $capacity members';

  /// Only a read-only viewer can fork; Collab rooms are joined, not cloned.
  bool get canFork => viewer && !isCollab && !revoked;

  /// Whether [now] is at or past [expiresAt].
  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now);
}

/// `12 Oct 2026`, using the same month vocabulary as the artifact list.
String formatShareLinkDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

/// A share-link preview card: URL, copy, mode, member count, dates and the one
/// action that matters to the person reading it.
///
/// Deliberately QR-less: the product explicitly does not render a QR code, so
/// this card stays a readable link with one copy target. All state and
/// callbacks are injected.
class V2ShareLinkCard extends StatelessWidget {
  const V2ShareLinkCard({
    super.key,
    required this.data,
    this.onCopy,
    this.onRevoke,
    this.onFork,
    this.now,
  });

  final V2ShareLinkCardData data;

  /// Copy the URL. Disabled when the link is expired or revoked.
  final VoidCallback? onCopy;

  /// Revoke the link for its creator. Hidden for viewers.
  final VoidCallback? onRevoke;

  /// Fork a read-only link into the viewer's account.
  final VoidCallback? onFork;

  /// Injectable clock used to decide whether the link is expired. Defaults to
  /// [DateTime.now] so tests can pin the answer.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final expired = data.isExpiredAt(now ?? DateTime.now());

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(ORadius.l),
            border: Border.all(color: c.hairline),
          ),
          padding: const EdgeInsets.all(OSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(c),
              const SizedBox(height: OSpace.m),
              if (data.revoked) ...[
                _revokedNotice(c),
                const SizedBox(height: OSpace.m),
              ],
              _linkRow(context, c, expired: expired),
              const SizedBox(height: OSpace.m),
              _meta(c, expired: expired),
              if (data.isCollab) ...[
                const SizedBox(height: OSpace.m),
                _members(c),
              ],
              _actions(c, expired: expired),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(OColors c) {
    final badge = data.isCollab
        ? const OPill(label: 'Collab', tone: OPillTone.accent, dot: true)
        : const OPill(label: 'Read only', tone: OPillTone.neutral);
    return LayoutBuilder(
      builder: (context, constraints) {
        // At 200 % text the badge is wide enough to starve the title, so it
        // drops under the subtitle instead of sitting in the corner.
        final tight =
            constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.3;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.s),
              ),
              child: Icon(Icons.link_rounded, size: 20, color: c.accent),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.viewer ? 'Shared with you' : 'Share link',
                    style: OType.h3.copyWith(color: c.text),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    data.isCollab
                        ? 'Anyone with the link can join the room.'
                        : 'Anyone with the link can read this chat.',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                  if (tight) ...[const SizedBox(height: OSpace.s), badge],
                ],
              ),
            ),
            if (!tight) ...[const SizedBox(width: OSpace.s), badge],
          ],
        );
      },
    );
  }

  Widget _linkRow(BuildContext context, OColors c, {required bool expired}) {
    final label = data.copied ? 'Copied' : 'Copy link';
    final enabled = !expired && !data.revoked && onCopy != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inline = constraints.maxWidth >= _inlineLinkWidth(context, label);
        final link = Semantics(
          label: 'Share link, ${data.url}',
          child: ExcludeSemantics(
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.surfaceRaised,
                    borderRadius: BorderRadius.circular(ORadius.s),
                  ),
                  child: Icon(
                    Icons.alternate_email_rounded,
                    size: 17,
                    color: c.textMuted,
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    data.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.mono.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            ),
          ),
        );
        final button = OButton(
          label: label,
          icon: data.copied ? Icons.check_rounded : Icons.copy_rounded,
          variant: data.copied
              ? OButtonVariant.secondary
              : OButtonVariant.primary,
          expand: !inline,
          onPressed: enabled ? onCopy : null,
          semanticLabel: data.copied ? 'Share link copied' : 'Copy share link',
        );
        return Container(
          padding: const EdgeInsets.all(OSpace.s),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.hairline),
          ),
          child: inline
              ? Row(
                  children: [
                    Expanded(child: link),
                    const SizedBox(width: OSpace.s),
                    button,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    link,
                    const SizedBox(height: OSpace.s),
                    button,
                  ],
                ),
        );
      },
    );
  }

  /// Width the inline link row needs before the copy button can sit beside the
  /// URL without squeezing it. Mirrors the share sheet's measurement so both
  /// cards behave the same at 200 % text.
  double _inlineLinkWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: OType.label),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final buttonWidth = painter.width + 19 + OSpace.s + 40;
    painter.dispose();
    // 32 icon + gap + a readable URL minimum + gap + button.
    return 32 + OSpace.s + 96 + OSpace.s + buttonWidth;
  }

  Widget _meta(OColors c, {required bool expired}) {
    final items = <Widget>[
      if (data.createdAt != null)
        _MetaItem(
          icon: Icons.calendar_today_rounded,
          label: 'Created ${formatShareLinkDate(data.createdAt!)}',
        ),
      if (data.expiresAt != null)
        _MetaItem(
          icon: expired ? Icons.event_busy_rounded : Icons.schedule_rounded,
          label:
              '${expired ? 'Expired' : 'Expires'} '
              '${formatShareLinkDate(data.expiresAt!)}',
          color: expired ? c.danger : null,
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: OSpace.l, runSpacing: OSpace.s, children: items);
  }

  Widget _members(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.s),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.groups_rounded, size: 18, color: c.textMuted),
          ),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.memberLabel,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  data.roomFull
                      ? 'The room is full. New people need a free seat.'
                      : 'One person sends at a time.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                if (data.roomFull) ...[
                  const SizedBox(height: OSpace.xs),
                  const OPill(
                    label: 'Room full',
                    tone: OPillTone.warn,
                    dot: true,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _revokedNotice(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link_off_rounded, size: 18, color: c.danger),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              'This link was revoked. Nobody can open it now.',
              style: OType.caption.copyWith(color: c.danger),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(OColors c, {required bool expired}) {
    final Widget? action;
    if (data.revoked || (data.viewer && !data.canFork)) {
      action = null;
    } else if (data.viewer) {
      action = OButton(
        label: 'Fork into my account',
        icon: Icons.account_tree_rounded,
        variant: OButtonVariant.secondary,
        expand: true,
        onPressed: expired ? null : onFork,
      );
    } else {
      action = OButton(
        label: 'Revoke link',
        icon: Icons.link_off_rounded,
        variant: OButtonVariant.danger,
        expand: true,
        onPressed: onRevoke,
      );
    }
    if (action == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: OSpace.l),
        Divider(height: 1, color: c.hairline),
        const SizedBox(height: OSpace.m),
        if (data.viewer)
          Padding(
            padding: const EdgeInsets.only(bottom: OSpace.s),
            child: Text(
              'Forking makes a copy in your account. The original stays with '
              'its creator.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        action,
      ],
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final tint = color ?? c.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: tint),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: Text(label, style: OType.caption.copyWith(color: tint)),
        ),
      ],
    );
  }
}
