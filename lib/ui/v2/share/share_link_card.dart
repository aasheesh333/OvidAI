import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'share_sheet.dart' show V2ShareMode, v2ShareMemberLimit;

// TODO(l10n): extract this card's English copy during the ARB pass.

/// Immutable state for [V2ShareLinkCard].
///
/// The card is presentational: the host owns copying, revoking and forking.
/// Dates and member counts stay on the data object for hosts that need them;
/// the minimal card shows only the link and its one action.
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
    this.busy = false,
  }) : assert(capacity > 0, 'A shared link always has a capacity');

  /// The link people open, for example `ovidsi.com/c/79f9b4c0e`.
  final String url;

  /// Collab rooms are live and capped; read-only links can be forked.
  final V2ShareMode mode;

  /// When the link was created. Retained for hosts; not rendered.
  final DateTime? createdAt;

  /// When the link stops working. Null means it does not expire.
  final DateTime? expiresAt;

  /// People in a Collab room, including the creator.
  final int memberCount;

  /// Hard room cap. Defaults to [v2ShareMemberLimit].
  final int capacity;

  /// Whether the link was just copied, for the short "Copied" confirmation.
  final bool copied;

  /// True when the current person opened someone else's link.
  final bool viewer;

  /// True when the creator has revoked the link. Nothing is actionable then.
  final bool revoked;

  /// True while the host is revoking the link. Copy and fork are disabled so
  /// the surface cannot claim the link is still usable while it is going away.
  final bool busy;

  bool get isCollab => mode == V2ShareMode.collab;

  /// True when the room has reached its member cap.
  bool get roomFull => isCollab && memberCount >= capacity;

  /// Short label for the member count, for example `3 of 50 members`.
  String get memberLabel => '$memberCount of $capacity members';

  /// Only a read-only viewer can fork; Collab rooms are joined, not cloned.
  bool get canFork => viewer && !isCollab && !revoked && !busy;

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

/// The link row: the URL, one copy control, and the one action the person
/// reading it can take (fork for a viewer, revoke for a creator).
///
/// Deliberately QR-less and meta-less: the sheet already states the mode and
/// the room size, so repeating them here would be a second copy of the same
/// fact.
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

  /// Copy the URL. Disabled when the link is empty, expired, revoked or busy.
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
    final hasLink = data.url.trim().isNotEmpty;
    final copied = data.copied && hasLink && !data.revoked && !expired;
    final canCopy =
        hasLink && !expired && !data.revoked && !data.busy && onCopy != null;

    final fork = data.canFork && onFork != null && !expired
        ? OButton(
            label: 'Fork',
            icon: Icons.account_tree_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: onFork,
          )
        : null;
    final revoke =
        !data.viewer &&
            onRevoke != null &&
            !data.revoked &&
            !expired &&
            !data.busy
        ? OTextAction(
            label: 'Revoke',
            icon: Icons.link_off_rounded,
            onPressed: onRevoke,
          )
        : null;

    final status = data.revoked
        ? 'Link revoked.'
        : expired
        ? 'Link expired.'
        : data.busy
        ? 'Revoking link…'
        : null;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          padding: const EdgeInsets.all(OSpace.s),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.link_rounded, size: 20, color: c.accent),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Semantics(
                      container: true,
                      label: hasLink
                          ? 'Share link, ${data.url}'
                          : 'No link yet',
                      child: ExcludeSemantics(
                        child: Text(
                          hasLink ? data.url : 'No link yet',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.mono.copyWith(
                            color: hasLink ? c.text : c.textFaint,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: OSpace.xs),
                  // The label carries the full URL after copying so the
                  // announcement says exactly what landed on the clipboard.
                  Semantics(
                    container: true,
                    button: true,
                    enabled: canCopy,
                    liveRegion: copied,
                    label: copied ? 'Link copied, ${data.url}' : 'Copy link',
                    onTap: canCopy ? onCopy : null,
                    excludeSemantics: true,
                    child: OIconButton(
                      icon: copied ? Icons.check_rounded : Icons.copy_rounded,
                      semanticLabel: copied ? 'Copied' : 'Copy link',
                      tooltip: copied ? 'Copied' : 'Copy link',
                      active: copied,
                      onPressed: canCopy ? onCopy : null,
                    ),
                  ),
                ],
              ),
              if (status != null) ...[
                const SizedBox(height: OSpace.xs),
                Text(
                  status,
                  style: OType.caption.copyWith(
                    color: data.revoked ? c.danger : c.textMuted,
                  ),
                ),
              ],
              if (fork != null) ...[const SizedBox(height: OSpace.s), fork],
              if (revoke != null)
                Align(alignment: Alignment.centerLeft, child: revoke),
            ],
          ),
        ),
      ),
    );
  }
}
