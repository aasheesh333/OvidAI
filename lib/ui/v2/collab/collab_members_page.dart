import 'package:flutter/material.dart';

import '../../../core/collaboration/models.dart' show maxActiveMembers;
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
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
    this.online = false,
    this.initials,
  });

  final String id;
  final String name;
  final String subtitle;
  final V2CollabRole role;
  final bool isYou;

  /// True for the person whose account and storage own this room. The creator
  /// badge is shown even when the owner has transferred the Owner role.
  final bool isCreator;

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

/// Member roster for a shared live chat.
class CollabMembersPage extends StatefulWidget {
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
  final ValueChanged<String>? onSearch;
  final VoidCallback? onInvite;
  final ValueChanged<V2CollabMember>? onMemberMenu;
  final VoidCallback? onLeave;
  final VoidCallback? onRetry;

  @override
  State<CollabMembersPage> createState() => _CollabMembersPageState();
}

class _CollabMembersPageState extends State<CollabMembersPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value.trim());
    widget.onSearch?.call(value.trim());
  }

  void _clearSearch() {
    _controller.clear();
    _onQueryChanged('');
  }

  List<V2CollabMember> get _visibleMembers {
    if (_query.isEmpty) return widget.data.members;
    final needle = _query.toLowerCase();
    return widget.data.members
        .where(
          (member) =>
              member.name.toLowerCase().contains(needle) ||
              member.subtitle.toLowerCase().contains(needle),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(
        title: widget.data.title,
        subtitle: widget.data.chatName.isEmpty ? null : widget.data.chatName,
        actions: [
          OIconButton(
            icon: Icons.person_add_alt_1_rounded,
            semanticLabel: 'Invite someone',
            onPressed: widget.onInvite,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: switch (widget.data.status) {
            V2CollabMembersStatus.loading => const OSkeletonList(rows: 6),
            V2CollabMembersStatus.error => OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2CollabMembersStatus.empty => _emptyRoster(compact: false),
            V2CollabMembersStatus.ready => _content(context),
          },
        ),
      ),
    );
  }

  Widget _emptyRoster({required bool compact}) {
    return OEmptyState(
      compact: compact,
      icon: Icons.group_outlined,
      title: 'No members yet',
      message: 'Invite someone to this chat. They can watch or take a turn.',
      action: OButton(
        label: 'Invite someone',
        icon: Icons.person_add_alt_1_rounded,
        onPressed: widget.onInvite,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final visible = _visibleMembers;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      children: [
        OFadeSlide(
          child: OStagger(
            children: [
              _SummaryCard(data: widget.data, c: c),
              const SizedBox(height: OSpace.m),
              OSearchField(
                controller: _controller,
                hint: 'Search members',
                onChanged: _onQueryChanged,
              ),
              const SizedBox(height: OSpace.m),
              OSectionHeader(
                label: 'Members',
                padding: const EdgeInsets.fromLTRB(0, OSpace.s, 0, OSpace.s),
                trailing: Text(
                  '${visible.length} shown',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: OSpace.l),
                  child: _query.isEmpty
                      ? _emptyRoster(compact: true)
                      : OEmptyState(
                          compact: true,
                          icon: Icons.search_off_rounded,
                          title: 'No members found',
                          message: 'Try another name.',
                          action: OButton(
                            label: 'Clear search',
                            icon: Icons.close_rounded,
                            onPressed: _clearSearch,
                          ),
                        ),
                )
              else
                for (final member in visible) ...[
                  _MemberRow(
                    member: member,
                    onMenu: widget.onMemberMenu == null
                        ? null
                        : () => widget.onMemberMenu!(member),
                  ),
                  const SizedBox(height: OSpace.s),
                ],
              const SizedBox(height: OSpace.m),
              _StorageCard(data: widget.data, c: c),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Leave chat',
                icon: Icons.logout_rounded,
                variant: OButtonVariant.danger,
                expand: true,
                onPressed: widget.onLeave,
              ),
              const SizedBox(height: OSpace.s),
              Text(
                'Leaving removes this shared chat from your list. The creator keeps the storage.',
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.data, required this.c});

  final V2CollabMembersPageData data;
  final OColors c;

  @override
  Widget build(BuildContext context) {
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                data.capacityLabel,
                style: OType.h2.copyWith(color: c.text),
              ),
              _Tag(
                label: data.roomFull
                    ? 'Room full'
                    : '${data.seatsLeft} seats left',
                tone: data.roomFull ? _TagTone.warn : _TagTone.success,
                dot: true,
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OProgressBar(
            value: data.capacity == 0 ? 0 : data.memberCount / data.capacity,
          ),
          const SizedBox(height: OSpace.m),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.group_rounded, size: 16, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'Up to ${data.capacity} people can join, including the '
                  'creator.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'Only one person can send at a time.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, this.onMenu});

  final V2CollabMember member;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (roleLabel, roleTone) = switch (member.role) {
      V2CollabRole.owner => ('Owner', _TagTone.accent),
      V2CollabRole.canChat => ('Can chat', _TagTone.neutral),
      V2CollabRole.viewOnly => ('View only', _TagTone.neutral),
    };
    final tag = _Tag(label: roleLabel, tone: roleTone);
    return OCard(
      accent: member.isYou,
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.m,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // With large text, or on a narrow card, the name and the role pill
          // cannot share one line without squeezing the name to a sliver.
          // The pill moves under the avatar instead.
          final stacked =
              constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: _identity(context, c)),
                  if (!stacked) ...[const SizedBox(width: OSpace.s), tag],
                  OIconButton(
                    icon: Icons.more_vert_rounded,
                    semanticLabel: 'Member options for ${member.name}',
                    onPressed: onMenu,
                  ),
                ],
              ),
              if (stacked) ...[
                const SizedBox(height: OSpace.s),
                Padding(padding: const EdgeInsets.only(left: 56), child: tag),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _identity(BuildContext context, OColors c) {
    return Row(
      children: [
        OAvatar(
          initials: member.initials ?? member.name,
          size: 44,
          semanticLabel: member.name,
        ),
        const SizedBox(width: OSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: OSpace.xs,
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
                    const _Tag(label: 'Creator', tone: _TagTone.accent),
                ],
              ),
              if (member.subtitle.isNotEmpty) ...[
                const SizedBox(height: OSpace.xs),
                Row(
                  children: [
                    if (member.online) ...[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: c.success,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: OSpace.xs),
                    ],
                    Expanded(
                      child: Text(
                        member.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

enum _TagTone { neutral, accent, success, warn }

/// Small status tag. Mirrors the shared `OPill` look but grows with the text
/// scale instead of clipping its label inside a fixed 24 dp box.
class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    this.tone = _TagTone.neutral,
    this.dot = false,
  });

  final String label;
  final _TagTone tone;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (bg, fg) = switch (tone) {
      _TagTone.neutral => (c.surfaceAlt, c.textMuted),
      _TagTone.accent => (c.accentSoft, c.accent),
      _TagTone.success => (c.success.withValues(alpha: 0.12), c.success),
      _TagTone.warn => (c.warn.withValues(alpha: 0.12), c.warn),
    };
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              style: OType.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.data, required this.c});

  final V2CollabMembersPageData data;
  final OColors c;

  @override
  Widget build(BuildContext context) {
    final hasInfo = data.hasStorageInfo;
    final percent = hasInfo
        ? Text(
            '${(data.storagePercent * 100).round()}%',
            style: OType.caption.copyWith(
              color: c.accent,
              fontWeight: FontWeight.w600,
            ),
          )
        : null;
    return OCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      borderRadius: BorderRadius.circular(ORadius.m),
                    ),
                    child: Icon(
                      Icons.workspace_premium_rounded,
                      size: 19,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'The creator pays for storage',
                          style: OType.bodySm.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (data.creatorName.isNotEmpty) ...[
                          const SizedBox(height: OSpace.xs),
                          Text(
                            '${data.creatorName} pays for this chat. Storage '
                            'is billed to the creator\'s plan.',
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ],
                        if (stacked && percent != null) ...[
                          const SizedBox(height: OSpace.xs),
                          percent,
                        ],
                      ],
                    ),
                  ),
                  if (!stacked && percent != null) ...[
                    const SizedBox(width: OSpace.s),
                    percent,
                  ],
                ],
              ),
              if (hasInfo) ...[
                const SizedBox(height: OSpace.m),
                OProgressBar(value: data.storagePercent, height: 8),
                const SizedBox(height: OSpace.s),
                Wrap(
                  spacing: OSpace.m,
                  runSpacing: OSpace.xs,
                  children: [
                    Text(
                      '${data.storageUsedLabel} of ${data.storageTotalLabel} used',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                    Text(
                      '${data.storageFreeLabel} free',
                      style: OType.caption.copyWith(color: c.textFaint),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
