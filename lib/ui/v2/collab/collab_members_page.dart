import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/collaboration/models.dart' show maxActiveMembers;
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2CollabMembersStatus { loading, empty, error, ready }

/// The three roles a shared live chat understands.
///
/// The wire model calls the middle role `participant`; this screen calls it
/// [canChat] and shows it as **Editor**. [editor] is a readable alias so callers
/// do not have to remember the historical name.
enum V2CollabRole {
  owner('Owner'),
  canChat('Editor'),
  viewOnly('Viewer');

  const V2CollabRole(this.label);

  /// The visible and spoken role name.
  final String label;

  /// Alias for callers that name the role by what it can do in the editor.
  static const V2CollabRole editor = canChat;
}

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

  bool get isOwner => role == V2CollabRole.owner;
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
    this.inviteErrorMessage = 'We could not create an invite link.',
    this.inviteCopyErrorMessage = 'We could not copy the link.',
    this.roleErrorMessage = 'We could not change this role.',
    this.leaveErrorMessage = 'We could not leave this chat.',
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
  final String inviteErrorMessage;

  /// Reported when the invite was created but the clipboard rejected it, so
  /// the page never blames creation for a copy failure.
  final String inviteCopyErrorMessage;
  final String roleErrorMessage;
  final String leaveErrorMessage;

  bool get roomFull => capacity > 0 && memberCount >= capacity;

  /// Seats left before the room is full.
  int get seatsLeft => capacity - memberCount < 0 ? 0 : capacity - memberCount;

  /// `n of 50`, the count the screen always shows.
  String get capacityLabel => '$memberCount of $capacity';

  /// The header's one subtitle. At the cap it becomes the exact reason the
  /// invite control is disabled, instead of leaving a dead icon unexplained.
  String get capacitySubtitle =>
      roomFull ? 'Room is full ($memberCount of $capacity).' : capacityLabel;

  /// The exact disabled reason, also used as the invite control's tooltip.
  String get fullReason => 'Room is full ($memberCount of $capacity).';

  /// True once the wiring has supplied storage numbers to show.
  bool get hasStorageInfo =>
      storageTotalLabel.isNotEmpty || storageUsedLabel.isNotEmpty;

  /// True when the signed-in member is the owner, so only they may change
  /// another member's role or remove them.
  bool get viewerIsOwner => members.any((m) => m.isYou && m.isOwner);

  /// True when there is nobody but the signed-in member to show.
  ///
  /// The true [memberCount] wins over the visible rows: a paginated roster
  /// that happens to contain only the signed-in member is not an empty room.
  bool get onlyYou =>
      memberCount <= 1 &&
      (members.isEmpty || (members.length == 1 && members.single.isYou));
}

/// Async work a member action may perform. A synchronous handler is accepted so
/// existing hosts and tests keep compiling.
typedef V2CollabAction = FutureOr<void> Function();

/// Creates an invite and returns the link the page should copy itself.
typedef V2CollabInviteLink = Future<String?> Function();

/// Changes one member's role. The future completes when the service confirms.
typedef V2CollabRoleChange =
    FutureOr<void> Function(V2CollabMember member, V2CollabRole role);

/// Removes one member. Resolves only after the service confirms the removal.
typedef V2CollabRemove = FutureOr<void> Function(V2CollabMember member);

/// Member roster for a shared live chat: one list with a role and a remove
/// action per row.
///
/// The page never invents an outcome. An invite link is reported as copied only
/// after the clipboard write resolves; a role change is shown optimistically
/// and rolled back when its handler fails; a removal is announced only after
/// its handler resolves.
///
/// Hosts may keep their existing action flows by passing [onInvite],
/// [onMemberMenu] and [onLeave] (those callbacks own their dialogs and copy).
/// Passing [onCreateInviteLink], [onRemove] or [onLeaveChat] transfers the
/// confirmation, in-flight and outcome reporting to this page instead.
class CollabMembersPage extends StatefulWidget {
  const CollabMembersPage({
    super.key,
    required this.data,
    this.onSearch,
    this.onInvite,
    this.onMemberMenu,
    this.onLeave,
    this.onRetry,
    this.onRoleChanged,
    this.onCreateInviteLink,
    this.onRemove,
    this.onLeaveChat,
  });

  final V2CollabMembersPageData data;

  /// Retained for hosts. The roster is short enough to scan without search.
  final ValueChanged<String>? onSearch;

  /// Host-owned invite action. It creates and copies the link; this page only
  /// waits for it and reports a thrown failure.
  final V2CollabAction? onInvite;

  /// Host-owned member actions. The page calls this only for a removable
  /// member; the host owns the menu, confirmation and outcome.
  final ValueChanged<V2CollabMember>? onMemberMenu;

  /// Host-owned leave action. The host owns the confirmation and outcome.
  final V2CollabAction? onLeave;

  final VoidCallback? onRetry;

  /// Called with the chosen role after the page's own role picker. The picker
  /// is only offered to the owner, and never for the owner's own row.
  final V2CollabRoleChange? onRoleChanged;

  /// Page-owned invite flow: create the invite, return its real link, and the
  /// page copies it. Nothing is reported as copied until this resolves.
  final V2CollabInviteLink? onCreateInviteLink;

  /// Page-owned removal flow. The page confirms, names the person, awaits the
  /// handler and reports the real outcome.
  final V2CollabRemove? onRemove;

  /// Page-owned leave flow. The page confirms first and tells the owner that
  /// the chat is archived before calling this handler.
  final V2CollabAction? onLeaveChat;

  @override
  State<CollabMembersPage> createState() => _CollabMembersPageState();
}

class _CollabMembersPageState extends State<CollabMembersPage> {
  bool _inviting = false;
  bool _leaving = false;
  final Set<String> _updatingRoles = <String>{};
  final Set<String> _removing = <String>{};
  final Map<String, V2CollabRole> _roleOverrides = <String, V2CollabRole>{};

  V2CollabMembersPageData get _data => widget.data;

  bool get _hasInviteAction =>
      widget.onCreateInviteLink != null || widget.onInvite != null;

  bool get _hasLeaveAction =>
      widget.onLeaveChat != null || widget.onLeave != null;

  @override
  void didUpdateWidget(covariant CollabMembersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.data.members, widget.data.members)) return;
    final members = <String, V2CollabMember>{
      for (final member in widget.data.members) member.id: member,
    };
    _roleOverrides.removeWhere((id, role) {
      final member = members[id];
      // The host caught up with the optimistic value, or the member left the
      // roster; either way the override has done its job.
      return member == null || member.role == role;
    });
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: _data.title,
      subtitle: _data.capacitySubtitle,
      maxWidth: 640,
      padding: false,
      actions: _hasInviteAction ? [_inviteAction()] : const [],
      child: switch (_data.status) {
        V2CollabMembersStatus.loading => const OSkeletonList(rows: 6),
        V2CollabMembersStatus.error => OErrorState(
          message: _data.errorMessage,
          onRetry: widget.onRetry,
        ),
        V2CollabMembersStatus.empty => _empty(),
        V2CollabMembersStatus.ready =>
          _data.onlyYou ? _empty() : _list(),
      },
    );
  }

  Widget _inviteAction() {
    if (_inviting) {
      return Semantics(
        label: 'Creating invite link',
        liveRegion: true,
        child: const SizedBox(
          width: OSpace.touch,
          height: OSpace.touch,
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    final blocked = _data.roomFull;
    return OIconButton(
      icon: Icons.person_add_alt_1_rounded,
      semanticLabel: blocked
          ? 'Invite someone, ${_data.fullReason}'
          : 'Invite someone',
      tooltip: blocked ? _data.fullReason : null,
      onPressed: blocked ? null : _invite,
    );
  }

  Future<void> _invite() async {
    if (_inviting || _data.roomFull) return;
    final pageOwned = widget.onCreateInviteLink;
    final hostOwned = widget.onInvite;
    if (pageOwned == null && hostOwned == null) return;

    setState(() => _inviting = true);
    try {
      if (pageOwned != null) {
        final link = await pageOwned();
        if (link == null || link.trim().isEmpty) {
          _notify(_data.inviteErrorMessage);
          return;
        }
        try {
          await Clipboard.setData(ClipboardData(text: link));
        } catch (_) {
          // The link exists but never reached the clipboard. Say that, not
          // "could not create", which would blame the wrong step.
          _notify(_data.inviteCopyErrorMessage);
          return;
        }
        // Only now is there a real link in the clipboard.
        _notify('Invite link copied.');
      } else {
        await Future<void>.sync(hostOwned!);
      }
    } catch (_) {
      _notify(_data.inviteErrorMessage);
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Widget _empty() {
    final onlyYou = _data.members.any((member) => member.isYou);
    final invite = _hasInviteAction
        ? OButton(
            label: 'Invite someone',
            icon: Icons.person_add_alt_1_rounded,
            loading: _inviting,
            onPressed: _data.roomFull || _inviting ? null : _invite,
          )
        : null;
    final leave = _hasLeaveAction
        ? OButton(
            label: 'Leave chat',
            icon: Icons.logout_rounded,
            variant: OButtonVariant.danger,
            loading: _leaving,
            semanticLabel: 'Leave chat, destructive',
            onPressed: _leaving ? null : _leave,
          )
        : null;
    return OEmptyState(
      icon: Icons.group_outlined,
      title: onlyYou ? 'Only you' : 'No members yet',
      message: _data.roomFull
          ? _data.fullReason
          : 'Invite someone to this chat.',
      action: invite,
      secondaryAction: leave,
    );
  }

  Widget _list() {
    final members = _data.members;
    final footerCount = _hasLeaveAction ? 1 : 0;
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
              loading: _leaving,
              semanticLabel: 'Leave chat, destructive',
              onPressed: _leaving ? null : _leave,
            ),
          );
        }
        final member = members[index];
        final roleUpdating = _updatingRoles.contains(member.id);
        final removing = _removing.contains(member.id);
        // The owner can never be removed or demoted, even if a host marks the
        // row removable by mistake. A row with a mutation in flight does not
        // accept a second, conflicting one.
        final canRemove =
            !roleUpdating &&
            !removing &&
            !member.isOwner &&
            !member.isYou &&
            member.canRemove &&
            (widget.onRemove != null || widget.onMemberMenu != null);
        final role = _roleOverrides[member.id] ?? member.role;
        final canChangeRole =
            widget.onRoleChanged != null &&
            !removing &&
            _data.viewerIsOwner &&
            !member.isOwner &&
            !member.isYou;
        return Column(
          key: ValueKey<String>('collab-member-${member.id}'),
          children: [
            _MemberRow(
              member: member,
              role: role,
              roleUpdating: roleUpdating,
              removing: removing,
              onRoleTap: canChangeRole
                  ? () => _pickRole(member, role)
                  : null,
              onRemove: canRemove ? () => _requestRemove(member) : null,
            ),
            if (index < members.length - 1)
              Divider(height: 1, color: OColors.of(context).hairline),
          ],
        );
      },
    );
  }

  Future<void> _pickRole(V2CollabMember member, V2CollabRole current) async {
    final chosen = await showOSheet<V2CollabRole>(
      context,
      title: 'Change role',
      builder: (sheetContext) => _roleSheet(sheetContext, member, current),
    );
    if (chosen == null || chosen == current) return;
    await _changeRole(member, chosen);
  }

  Widget _roleSheet(
    BuildContext context,
    V2CollabMember member,
    V2CollabRole current,
  ) {
    final c = OColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: OSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                0,
                OSpace.l,
                OSpace.s,
              ),
              child: Text(
                member.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.bodyStrong.copyWith(color: c.text),
              ),
            ),
            for (final role in const [
              V2CollabRole.canChat,
              V2CollabRole.viewOnly,
            ])
              MergeSemantics(
                child: Semantics(
                  selected: role == current,
                  child: OListRow(
                    title: role.label,
                    subtitle: role == V2CollabRole.canChat
                        ? 'Can send messages'
                        : 'Can read only',
                    showChevron: false,
                    trailing: role == current
                        ? Icon(Icons.check_rounded, size: 20, color: c.accent)
                        : null,
                    onTap: () => Navigator.pop(context, role),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeRole(V2CollabMember member, V2CollabRole role) async {
    final change = widget.onRoleChanged;
    if (change == null ||
        _updatingRoles.contains(member.id) ||
        _removing.contains(member.id)) {
      return;
    }
    final previous = _roleOverrides[member.id] ?? member.role;

    // Optimistic: the row switches immediately, then rolls back if the service
    // rejects the change.
    setState(() {
      _roleOverrides[member.id] = role;
      _updatingRoles.add(member.id);
    });
    try {
      await Future<void>.sync(() => change(member, role));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (previous == member.role) {
          _roleOverrides.remove(member.id);
        } else {
          _roleOverrides[member.id] = previous;
        }
      });
      _notify(_data.roleErrorMessage);
    } finally {
      if (mounted) setState(() => _updatingRoles.remove(member.id));
    }
  }

  Future<void> _requestRemove(V2CollabMember member) async {
    final remove = widget.onRemove;
    if (remove == null) {
      // Host-owned flow: it owns the menu, confirmation and outcome.
      widget.onMemberMenu?.call(member);
      return;
    }
    final confirmed = await _confirm(
      title: 'Remove ${member.name}?',
      message: 'They lose access to this chat.',
      actionLabel: 'Remove',
      destructiveLabel: 'Remove ${member.name}, destructive',
    );
    if (!confirmed || !mounted) return;
    await _remove(member, remove);
  }

  Future<void> _remove(V2CollabMember member, V2CollabRemove remove) async {
    if (_removing.contains(member.id)) return;
    setState(() => _removing.add(member.id));
    try {
      await Future<void>.sync(() => remove(member));
      _notify('${member.name} was removed.');
    } catch (_) {
      _notify('We could not remove ${member.name}.');
    } finally {
      if (mounted) setState(() => _removing.remove(member.id));
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    final pageOwned = widget.onLeaveChat;
    final hostOwned = widget.onLeave;
    if (pageOwned == null && hostOwned == null) return;

    if (pageOwned != null) {
      final owner = _data.viewerIsOwner;
      final confirmed = await _confirm(
        title: owner ? 'End this chat?' : 'Leave this chat?',
        message: owner
            ? 'The chat is archived. The link stops working.'
            : 'You can rejoin with a valid link.',
        actionLabel: owner ? 'End chat' : 'Leave',
        destructiveLabel: owner
            ? 'End chat, destructive'
            : 'Leave chat, destructive',
      );
      if (!confirmed || !mounted) return;
    }

    setState(() => _leaving = true);
    try {
      await Future<void>.sync(() => (pageOwned ?? hostOwned!)());
    } catch (_) {
      _notify(_data.leaveErrorMessage);
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String actionLabel,
    required String destructiveLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          OButton(
            label: actionLabel,
            semanticLabel: destructiveLabel,
            variant: OButtonVariant.dangerFill,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.role,
    required this.roleUpdating,
    required this.removing,
    this.onRoleTap,
    this.onRemove,
  });

  final V2CollabMember member;
  final V2CollabRole role;
  final bool roleUpdating;
  final bool removing;
  final VoidCallback? onRoleTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = <String>[
      member.name,
      role.label,
      if (member.isYou) 'you',
      if (member.isCreator) 'creator',
      if (roleUpdating) 'updating role',
      if (removing) 'removing',
    ].join(', ');

    return Semantics(
      container: true,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.listRow),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: OSpace.m),
          child: Row(
            children: [
              ExcludeSemantics(
                child: OAvatar(
                  initials: member.initials ?? member.name,
                  size: 40,
                  semanticLabel: member.name,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              member.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.bodySm.copyWith(
                                color: c.text,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (member.isYou) ...[
                            const SizedBox(width: OSpace.xs),
                            Text(
                              '(you)',
                              maxLines: 1,
                              style: OType.caption.copyWith(color: c.accent),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: OSpace.xs),
                    Wrap(
                      spacing: OSpace.s,
                      runSpacing: OSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (onRoleTap == null)
                          ExcludeSemantics(
                            child: OPill(
                              label: role.label,
                              tone: role == V2CollabRole.owner
                                  ? OPillTone.accent
                                  : OPillTone.neutral,
                            ),
                          )
                        else
                          _RoleControl(
                            memberName: member.name,
                            role: role,
                            busy: roleUpdating,
                            onTap: onRoleTap,
                          ),
                        if (member.isCreator)
                          const ExcludeSemantics(
                            child: OPill(
                              label: 'Creator',
                              tone: OPillTone.accent,
                            ),
                          ),
                        if (roleUpdating)
                          ExcludeSemantics(
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (removing)
                Semantics(
                  container: true,
                  label: 'Removing ${member.name}',
                  liveRegion: true,
                  child: const SizedBox(
                    width: OSpace.touch,
                    height: OSpace.touch,
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                )
              else if (onRemove != null) ...[
                const SizedBox(width: OSpace.s),
                OIconButton(
                  icon: Icons.person_remove_rounded,
                  semanticLabel: 'Remove ${member.name}, destructive',
                  onPressed: onRemove,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A 48 dp tap target around the current-role pill. It is only built for the
/// owner looking at somebody else, and announces the role it will change.
class _RoleControl extends StatelessWidget {
  const _RoleControl({
    required this.memberName,
    required this.role,
    required this.busy,
    this.onTap,
  });

  final String memberName;
  final V2CollabRole role;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final label = busy
        ? 'Updating role for $memberName, currently ${role.label}'
        : 'Change role for $memberName, currently ${role.label}';
    final pill = OPill(
      label: role.label,
      tone: role == V2CollabRole.owner
          ? OPillTone.accent
          : OPillTone.neutral,
      icon: busy
          ? Icons.hourglass_top_rounded
          : Icons.unfold_more_rounded,
    );
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: pill,
          ),
        ),
      ),
    );
  }
}
