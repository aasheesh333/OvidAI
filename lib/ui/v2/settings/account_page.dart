// TODO(l10n): move the English copy in this screen to the ARB files.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/account_service.dart';
import '../../../core/format.dart';
import '../../../core/play_billing.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'confirm_typed_sheet.dart';

enum V2AccountStatus { loading, ready, empty, error }

@immutable
class V2AccountProfile {
  const V2AccountProfile({
    required this.name,
    required this.email,
    this.role = '',
    this.planName = '',
    this.initials,
    this.image,
  });

  final String name;
  final String email;

  /// Secondary label under the name (for example a job title).
  final String role;

  /// Current plan, rendered as a pill next to the name. Falls back to [role]
  /// so existing adapters that put the plan in `role` keep working.
  final String planName;
  final String? initials;
  final ImageProvider? image;
}

@immutable
class V2AccountField {
  const V2AccountField({
    required this.id,
    required this.label,
    required this.value,
    this.editable = false,
    this.verified = false,
  });

  final String id;
  final String label;
  final String value;
  final bool editable;
  final bool verified;
}

@immutable
class V2ConnectedAccount {
  const V2ConnectedAccount({
    required this.id,
    required this.name,
    required this.detail,
    this.connected = true,
  });

  final String id;
  final String name;
  final String detail;
  final bool connected;
}

@immutable
class V2AccountData {
  const V2AccountData({
    this.status = V2AccountStatus.ready,
    this.profile,
    this.fields = const [],
    this.connectedAccounts = const [],
    this.onChangePhoto,
    this.onEditProfile,
    this.onFieldTap,
    this.onAccountTap,
    this.onLinkAccount,
    this.onOpenCredentials,
    this.onTeamSupport,
    this.onSignOut,
    this.onDeleteAccount,
    this.onManageSubscription,
    this.onRestoreAccount,
    this.onSignIn,
    this.onRetry,
    this.requestDeletion,
    this.restoreDeletion,
    this.signOutLoading = false,
    this.deletionPending = false,
    this.deletionDeadline,
    this.deletionLoading = false,
    this.errorMessage = 'We could not load your account.',
    this.syncLabel = 'All synced',
    this.syncOk = true,
  });

  final V2AccountStatus status;
  final V2AccountProfile? profile;
  final List<V2AccountField> fields;
  final List<V2ConnectedAccount> connectedAccounts;
  final VoidCallback? onChangePhoto;
  final VoidCallback? onEditProfile;
  final ValueChanged<V2AccountField>? onFieldTap;
  final ValueChanged<V2ConnectedAccount>? onAccountTap;
  final VoidCallback? onLinkAccount;

  /// Opens the Credentials screen (browser logins, GitHub, tokens).
  final VoidCallback? onOpenCredentials;

  /// Opens team/shared-session and support destinations.
  final VoidCallback? onTeamSupport;
  final VoidCallback? onSignOut;
  final VoidCallback? onDeleteAccount;

  /// Opens the Google Play subscription centre. When null the screen opens
  /// the Play subscriptions page itself.
  final VoidCallback? onManageSubscription;

  /// Cancels a pending deletion inside the grace period.
  final VoidCallback? onRestoreAccount;

  /// Submits the deletion request to the account service. When supplied the
  /// screen shows the server's receipt (state and deadline) instead of
  /// assuming the request succeeded. [onDeleteAccount] is the legacy hook used
  /// only when this is null.
  final Future<AccountDeletion> Function(String requestId)? requestDeletion;

  /// Cancels a pending deletion on the server (the account owner's restore).
  /// Falls back to [onRestoreAccount].
  final Future<AccountDeletion?> Function()? restoreDeletion;

  final VoidCallback? onSignIn;
  final VoidCallback? onRetry;
  final bool signOutLoading;

  /// True between the deletion request and the server deadline.
  final bool deletionPending;

  /// Server deadline for a pending deletion. The copy stays truthful even
  /// when the adapter cannot supply it yet.
  final DateTime? deletionDeadline;
  final bool deletionLoading;
  final String errorMessage;

  /// Sync status shown beside "Profile details". The adapter should pass the
  /// real state; pass an empty string to hide the label.
  final String syncLabel;

  /// False shows the status in the warning tone instead of success.
  final bool syncOk;
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.data});

  final V2AccountData data;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  V2AccountData get data => widget.data;

  /// The server's answer after a deletion request in this session. It wins
  /// over injected data so the banner reflects what the service returned.
  AccountDeletion? _receipt;
  bool _deleting = false;
  String? _deletionError;
  bool _restored = false;

  bool get _deletionPending =>
      !_restored && (data.deletionPending || _receipt?.isPending == true);

  DateTime? get _deletionDeadline =>
      _receipt?.deleteAfter ?? data.deletionDeadline;

  bool get _deletionLoading => data.deletionLoading || _deleting;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (data.status) {
      case V2AccountStatus.loading:
        body = const OSkeletonList(rows: 6);
      case V2AccountStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2AccountStatus.empty:
        body = _emptyState(context);
      case V2AccountStatus.ready:
        body = data.profile == null
            ? _emptyState(context)
            : _content(context, data.profile!);
    }

    return OScaffold(
      appBar: const OAppBar(title: 'Account'),
      body: OFadeSlide(child: body),
    );
  }

  Widget _emptyState(BuildContext context) {
    return OEmptyState(
      icon: Icons.person_off_outlined,
      title: 'No account found',
      message: 'Sign in to see your profile, plan and linked accounts.',
      action: OButton(
        label: 'Sign in',
        icon: Icons.login_rounded,
        onPressed: data.onSignIn ?? data.onRetry,
      ),
    );
  }

  Widget _content(BuildContext context, V2AccountProfile profile) {
    final c = OColors.of(context);
    final linked = data.connectedAccounts.where((a) => a.connected).length;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    OAvatar(
                      initials: profile.initials ?? profile.name,
                      image: profile.image,
                      size: 96,
                      semanticLabel: '${profile.name} profile photo',
                    ),
                    Positioned(
                      right: -8,
                      bottom: -8,
                      child: data.onChangePhoto == null
                          ? const SizedBox.shrink()
                          : OIconButton(
                              icon: Icons.photo_camera_rounded,
                              semanticLabel: 'Change photo',
                              tooltip: 'Change photo',
                              active: true,
                              onPressed: data.onChangePhoto,
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.m),
                Text(
                  profile.name,
                  textAlign: TextAlign.center,
                  style: OType.h2.copyWith(color: c.text),
                ),
                if (_planLabel(profile).isNotEmpty) ...[
                  const SizedBox(height: OSpace.s),
                  OPill(label: _planLabel(profile), tone: OPillTone.accent),
                ],
                if (profile.planName.isNotEmpty &&
                    profile.role.isNotEmpty &&
                    profile.role != profile.planName) ...[
                  const SizedBox(height: 2),
                  Text(
                    profile.role,
                    textAlign: TextAlign.center,
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
                const SizedBox(height: OSpace.m),
                if (data.onChangePhoto != null)
                  OButton(
                    label: 'Change photo',
                    icon: Icons.edit_rounded,
                    variant: OButtonVariant.secondary,
                    onPressed: data.onChangePhoto,
                  ),
              ],
            ),
          ),
          const SizedBox(height: OSpace.xl),
          OSectionHeader(
            label: 'Profile details',
            padding: const EdgeInsets.fromLTRB(
              OSpace.xs,
              OSpace.s,
              OSpace.xs,
              OSpace.s,
            ),
            trailing: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (data.syncLabel.isNotEmpty)
                    Flexible(
                      child: _SyncLabel(label: data.syncLabel, ok: data.syncOk),
                    ),
                  if (data.onEditProfile != null) ...[
                    const SizedBox(width: OSpace.xs),
                    OIconButton(
                      icon: Icons.edit_rounded,
                      semanticLabel: 'Edit profile',
                      tooltip: 'Edit profile',
                      onPressed: data.onEditProfile,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (data.fields.isEmpty)
            OEmptyState(
              compact: true,
              icon: Icons.badge_outlined,
              title: 'No profile details',
              message: 'Add your name, phone and region so Ovid can help you.',
              action: (data.onEditProfile ?? data.onRetry) == null
                  ? null
                  : OButton(
                      label: 'Add details',
                      icon: Icons.add_rounded,
                      onPressed: data.onEditProfile ?? data.onRetry,
                    ),
            )
          else
            _DetailsCard(data: data),
          const SizedBox(height: OSpace.xl),
          OSectionHeader(
            label: 'Sign-in methods',
            padding: const EdgeInsets.fromLTRB(
              OSpace.xs,
              OSpace.s,
              OSpace.xs,
              OSpace.s,
            ),
            trailing: Align(
              alignment: Alignment.centerRight,
              child: Text(
                linked == 0
                    ? 'None linked'
                    : '$linked of ${data.connectedAccounts.length} linked',
                textAlign: TextAlign.right,
                style: OType.caption.copyWith(color: c.accent),
              ),
            ),
          ),
          if (data.connectedAccounts.isEmpty)
            OEmptyState(
              compact: true,
              icon: Icons.link_off_rounded,
              title: 'No linked accounts',
              message:
                  'Link Google or Apple to sign in faster and keep your account safe.',
              action: data.onLinkAccount == null
                  ? null
                  : OButton(
                      label: 'Link account',
                      icon: Icons.add_link_rounded,
                      onPressed: data.onLinkAccount,
                    ),
            )
          else
            _ConnectedCard(data: data),
          const SizedBox(height: OSpace.xl),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                OListRow(
                  icon: Icons.password_rounded,
                  title: 'Credentials',
                  subtitle: 'Browser logins, GitHub and personal tokens',
                  enabled: data.onOpenCredentials != null,
                  showChevron: data.onOpenCredentials != null,
                  onTap: data.onOpenCredentials,
                ),
                Divider(height: 1, thickness: 1, color: c.hairline),
                OListRow(
                  icon: Icons.groups_outlined,
                  title: 'Team & support',
                  subtitle: 'Shared sessions, help and contact',
                  enabled: data.onTeamSupport != null,
                  showChevron: data.onTeamSupport != null,
                  onTap: data.onTeamSupport,
                ),
              ],
            ),
          ),
          if (_deletionError != null) ...[
            const SizedBox(height: OSpace.l),
            _DeletionError(message: _deletionError!),
          ],
          if (_deletionPending) ...[
            const SizedBox(height: OSpace.xl),
            _DeletionBanner(
              deadline: _deletionDeadline,
              loading: _deletionLoading,
              onRestore: data.onRestoreAccount == null && data.restoreDeletion == null
                  ? null
                  : _restoreAccount,
            ),
          ],
          const SizedBox(height: OSpace.xl),
          OButton(
            label: 'Sign out',
            icon: Icons.logout_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            loading: data.signOutLoading,
            onPressed: data.onSignOut,
          ),
          if (!_deletionPending) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Delete account',
              icon: Icons.warning_amber_rounded,
              variant: OButtonVariant.danger,
              expand: true,
              loading: _deleting,
              onPressed: _canDelete ? () => _confirmDelete(context) : null,
            ),
            const SizedBox(height: OSpace.s),
            Text(
              'Deletion starts a 24-hour grace period. Sign in again and choose '
              'Restore account before the deadline to keep your account.',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  bool get _canDelete =>
      data.requestDeletion != null || data.onDeleteAccount != null;

  /// The value the person must type. Only a real email or phone is offered;
  /// a placeholder like "Signed in" falls back to the `DELETE` target so the
  /// confirmation never asks for a string that is not theirs.
  String get _confirmationContact {
    final value = data.profile?.email.trim() ?? '';
    if (value.isEmpty) return '';
    if (value.contains('@')) return value;
    if (RegExp(r'^\+?[0-9][0-9 ()\-]{4,}$').hasMatch(value)) return value;
    return '';
  }

  /// Stable for one confirmation: the server deduplicates retries of the same
  /// request instead of creating a second deletion.
  String _newRequestId() => List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  /// Typed confirmation first, then the real deletion service. The copy never
  /// promises immediate deletion: the server keeps a 24-hour grace period and
  /// reports the deadline back in the receipt.
  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showConfirmTypedSheet(
      context,
      data: V2ConfirmTypedSheetData(
        contact: _confirmationContact,
        graceNote:
            'Signing in during the 24-hour grace period lets you choose '
            'Restore account. Nothing is deleted before the deadline.',
      ),
      onManageSubscription: data.onManageSubscription ?? _openPlaySubscriptions,
    );
    if (!confirmed || !mounted) return;

    final request = data.requestDeletion;
    if (request == null) {
      // Legacy adapter: its action owns the confirmation and the request.
      data.onDeleteAccount?.call();
      return;
    }

    setState(() {
      _deleting = true;
      _deletionError = null;
    });
    try {
      final receipt = await request(_newRequestId());
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _receipt = receipt.isPending ? receipt : null;
        _deletionError = receipt.isPending
            ? null
            : 'The server did not schedule a deletion. Your account is still '
                  'active.';
      });
      if (receipt.isPending) {
        final deadline = receipt.deleteAfter;
        _snack(
          deadline == null
              ? 'Deletion scheduled. You can restore your account during the '
                    '24-hour grace period.'
              : 'Deletion scheduled for ${formatDeadline(deadline)}. You can '
                    'restore your account until then.',
        );
      }
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _deletionError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _deletionError =
            'We could not request deletion. Check your connection and try '
            'again.';
      });
    }
  }

  Future<void> _restoreAccount() async {
    final restore = data.restoreDeletion;
    if (restore == null) {
      data.onRestoreAccount?.call();
      return;
    }
    setState(() {
      _deleting = true;
      _deletionError = null;
    });
    try {
      final receipt = await restore();
      if (!mounted) return;
      final stillPending = receipt != null && receipt.isPending;
      setState(() {
        _deleting = false;
        _receipt = stillPending ? receipt : null;
        if (!stillPending) _restored = true;
      });
      _snack('Your account was restored.');
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _deletionError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _deletionError =
            'We could not restore your account. Check your connection and try '
            'again.';
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Current plan, or the legacy `role` value used as a plan by older adapters.
String _planLabel(V2AccountProfile profile) =>
    profile.planName.isNotEmpty ? profile.planName : profile.role;

Future<void> _openPlaySubscriptions() async {
  try {
    await launchUrl(
      playSubscriptionCenterUri(),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // The user can still manage the subscription from the Play Store app.
  }
}

/// Warn-tinted card shown while the server holds a pending deletion request.
class _DeletionBanner extends StatelessWidget {
  const _DeletionBanner({
    required this.deadline,
    required this.loading,
    required this.onRestore,
  });

  final DateTime? deadline;
  final bool loading;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.warn.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hourglass_bottom_rounded, size: 20, color: c.warn),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'Deletion scheduled',
                  style: OType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Text(
            deadline == null
                ? 'Your account will be deleted after the 24-hour grace '
                      'period.'
                : 'Your account will be deleted on '
                      '${formatDeadline(deadline!)}.',
            style: OType.bodySm.copyWith(color: c.text),
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            'Signing in lets you choose Restore account until the deadline. '
            'Nothing is deleted before then.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.m),
          if (onRestore != null)
            OButton(
              label: 'Restore account',
              icon: Icons.restore_rounded,
              variant: OButtonVariant.secondary,
              loading: loading,
              onPressed: onRestore,
            ),
        ],
      ),
    );
  }
}

/// Plain-language failure from the deletion service, shown next to the
/// destructive actions instead of a raw exception.
class _DeletionError extends StatelessWidget {
  const _DeletionError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.danger.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.danger),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              message,
              style: OType.bodySm.copyWith(color: c.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncLabel extends StatelessWidget {
  const _SyncLabel({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final colour = ok ? c.success : c.warn;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: OType.caption.copyWith(color: colour),
          ),
        ),
      ],
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.data});

  final V2AccountData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final rows = <Widget>[];
    for (var index = 0; index < data.fields.length; index++) {
      final field = data.fields[index];
      rows.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DetailRow(field: field, onTap: data.onFieldTap),
            if (index != data.fields.length - 1)
              Divider(height: 1, thickness: 1, color: c.hairline),
          ],
        ),
      );
    }
    return OCard(
      padding: EdgeInsets.zero,
      child: OStagger(children: rows),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.field, required this.onTap});

  final V2AccountField field;
  final ValueChanged<V2AccountField>? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final canTap = field.editable && onTap != null;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
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
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    field.label,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    field.value,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            if (field.verified)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: const OPill(label: 'Verified', tone: OPillTone.success),
              )
            else if (canTap)
              Icon(Icons.edit_rounded, size: 18, color: c.textMuted),
          ],
        ),
      ),
    );
    if (!canTap) {
      return Semantics(label: '${field.label}, ${field.value}', child: row);
    }
    return OPressable(
      onTap: () => onTap!(field),
      semanticLabel: '${field.label}, ${field.value}',
      child: row,
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({required this.data});

  final V2AccountData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final rows = <Widget>[];
    for (var index = 0; index < data.connectedAccounts.length; index++) {
      final account = data.connectedAccounts[index];
      rows.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ConnectedRow(account: account, onTap: data.onAccountTap),
            if (index != data.connectedAccounts.length - 1)
              Divider(height: 1, thickness: 1, indent: 64, color: c.hairline),
          ],
        ),
      );
    }
    return OCard(
      padding: EdgeInsets.zero,
      child: OStagger(children: rows),
    );
  }
}

/// One linked account. Mirrors `OListRow`, but at large text the status badge
/// moves under the address instead of squeezing the name into a narrow column.
class _ConnectedRow extends StatelessWidget {
  const _ConnectedRow({required this.account, required this.onTap});

  final V2ConnectedAccount account;
  final ValueChanged<V2ConnectedAccount>? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final pill = OPill(
      label: account.connected ? 'Connected' : 'Not linked',
      tone: account.connected ? OPillTone.success : OPillTone.neutral,
      dot: account.connected,
    );
    final avatar = OAvatar(
      initials: account.name,
      size: 40,
      semanticLabel: account.name,
    );
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.4;
    if (!stacked) {
      return OListRow(
        leading: avatar,
        title: account.name,
        subtitle: account.detail,
        showChevron: false,
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: pill,
        ),
        onTap: onTap == null ? null : () => onTap!(account),
      );
    }

    final label = [
      account.name,
      account.detail,
      account.connected ? 'Connected' : 'Not linked',
    ].join(', ');
    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.name,
                  style: OType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  account.detail,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.s),
                pill,
              ],
            ),
          ),
        ],
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: onTap == null
          ? Semantics(label: label, child: row)
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => onTap!(account),
                borderRadius: BorderRadius.circular(ORadius.m),
                child: Semantics(label: label, button: true, child: row),
              ),
            ),
    );
  }
}
