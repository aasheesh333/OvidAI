import 'package:flutter/material.dart';

import '../../../core/collaboration/models.dart' show maxActiveMembers;
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2CollabMembersStatus { loading, empty, error, ready }

enum V2CollabRole { owner, canChat, viewOnly }

/// One member of a shared live chat.
@immutable
class V2CollabMember {
  const V2CollabMember({
    required this.id,
    required this.name,
    this.subtitle = '',
    this.role = V2CollabRole.canChat,
    this.isYou = false,
    this.isCreator = false,
    this.canRemove = false,
    this.online = false,
    this.initials,
  });

  final String id;
  final String name;

  /// Retained for hosts that carry a secondary line. The minimal roster shows
  /// the name and the role only.
  final String subtitle;
  final V2CollabRole role;
  final bool isYou;

  /// True for the person whose account and storage own this room. The creator
  /// badge is shown even when the owner has transferred the Owner role.
  final bool isCreator;

  /// True only when this device may remove the member (the owner, looking at
  /// somebody else). The remove control is hidden otherwise.
  final bool canRemove;

  /// Retained for hosts; the roster does not render presence.
  final bool online;
  final String? initials;
}

/// Immutable state for [CollabMembersPage].
@immutable
class V2CollabMembersPageData {
  const V2CollabMembersPageData({
    this.title = 'Members',
    this.chatName = '',
    this.members = const [],
    required this.memberCount,
    this.capacity = maxActiveMembers,
    this.creatorName = '',
    this.storageUsedLabel = '',
    this.storageTotalLabel = '',
    this.storageFreeLabel = '',
    this.storagePercent = 0,
    this.status = V2CollabMembersStatus.ready,
    this.errorMessage = 'We could not load the member list.',
  }) : assert(capacity > 0, 'A room always has a capacity');

  final String title;

  /// Retained for hosts. The roster's one subtitle is the member count.
  final String chatName;

  /// The rows visible in the roster.
  final List<V2CollabMember> members;

  /// The true member count, which can be larger than [members].
  final int memberCount;

  /// Hard room cap, [maxActiveMembers] by default.
  final int capacity;
  final String creatorName;
  final String storageUsedLabel;
  final String storageTotalLabel;
  final String storageFreeLabel;
  final double storagePercent;
  final V2CollabMembersStatus status;
  final String errorMessage;

  bool get roomFull => capacity > 0 && memberCount >= capacity;

  /// Seats left before the room is full.
  int get seatsLeft => capacity - memberCount < 0 ? 0 : capacity - memberCount;

  String get capacityLabel => '$memberCount of $capacity members';

  /// True once the wiring has supplied storage numbers to show.
  bool get hasStorageInfo =>
      storageTotalLabel.isNotEmpty || storageUsedLabel.isNotEmpty;
}

/// Member roster for a shared live chat: one list with a role and a remove
/// action per row.
class CollabMembersPage extends StatelessWidget {
  const CollabMembersPage({
    super.key,
    required this.data,
    this.onSearch,
    this.onInvite,
    this.onMemberMenu,
    this.onLeave,
    this.onRetry,
  });

  final V2CollabMembersPageData data;

  /// Retained for hosts. The roster is short enough to scan without search.
  final ValueChanged<String>? onSearch;
  final VoidCallback? onInvite;

  /// Opens the member's actions. The page offers it as the remove control.
  final ValueChanged<V2CollabMember>? onMemberMenu;
  final VoidCallback? onLeave;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: data.title,
      subtitle: data.capacityLabel,
      maxWidth: 640,
      padding: false,
      actions: [
        if (onInvite != null)
          OIconButton(
            icon: Icons.person_add_alt_1_rounded,
            semanticLabel: 'Invite someone',
            onPressed: onInvite,
          ),
      ],
      child: switch (data.status) {
        V2CollabMembersStatus.loading => const OSkeletonList(rows: 6),
        V2CollabMembersStatus.error => OErrorState(
          message: data.errorMessage,
          onRetry: onRetry,
        ),
        V2CollabMembersStatus.empty => _empty(),
        V2CollabMembersStatus.ready =>
          data.members.isEmpty ? _empty() : _list(),
      },
    );
  }

  Widget _empty() {
    return OEmptyState(
      icon: Icons.group_outlined,
      title: 'No members yet',
      message: 'Invite someone to this chat.',
      action: onInvite == null
          ? null
          : OButton(
              label: 'Invite someone',
              icon: Icons.person_add_alt_1_rounded,
              onPressed: onInvite,
            ),
    );
  }

  Widget _list() {
    final members = data.members;
    final footerCount = onLeave == null ? 0 : 1;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      itemCount: members.length + footerCount,
      itemBuilder: (context, index) {
        if (index == members.length) {
          return Padding(
            padding: const EdgeInsets.only(top: OSpace.l),
            child: OButton(
              label: 'Leave chat',
              icon: Icons.logout_rounded,
              variant: OButtonVariant.danger,
              expand: true,
              onPressed: onLeave,
            ),
          );
        }
        final member = members[index];
        return Column(
          children: [
            _MemberRow(
              member: member,
              onRemove: onMemberMenu == null || !member.canRemove
                  ? null
                  : () => onMemberMenu!(member),
            ),
            if (index < members.length - 1)
              Divider(height: 1, color: OColors.of(context).hairline),
          ],
        );
      },
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, this.onRemove});

  final V2CollabMember member;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (roleLabel, roleTone) = switch (member.role) {
      V2CollabRole.owner => ('Owner', OPillTone.accent),
      V2CollabRole.canChat => ('Can chat', OPillTone.neutral),
      V2CollabRole.viewOnly => ('View only', OPillTone.neutral),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Row(
          children: [
            OAvatar(
              initials: member.initials ?? member.name,
              size: 40,
              semanticLabel: member.name,
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: OSpace.xs,
                    runSpacing: OSpace.xxs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        member.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (member.isYou)
                        Text(
                          '(you)',
                          style: OType.caption.copyWith(color: c.accent),
                        ),
                      if (member.isCreator)
                        const OPill(
                          label: 'Creator',
                          tone: OPillTone.accent,
                        ),
                    ],
                  ),
                  const SizedBox(height: OSpace.xs),
                  OPill(label: roleLabel, tone: roleTone),
                ],
              ),
            ),
            if (onRemove != null) ...[
              const SizedBox(width: OSpace.s),
              OIconButton(
                icon: Icons.person_remove_rounded,
                semanticLabel: 'Remove ${member.name}',
                onPressed: onRemove,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
