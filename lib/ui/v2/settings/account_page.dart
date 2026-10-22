// TODO(l10n): move the English copy in this screen to the ARB files.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/account_service.dart';
import '../../../core/format.dart';
import '../../../core/play_billing.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'confirm_typed_sheet.dart';
import 'settings_rows.dart';

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
    this.onDataControl,
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
  ///
  /// Retained for hosts that still pass it; the minimal Account page does not
  /// render a Credentials row.
  final VoidCallback? onOpenCredentials;

  /// Opens Data control (export, import, cache, deletion).
  final VoidCallback? onDataControl;

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

    return OScreen(
      title: 'Account',
      child: OFadeSlide(child: body),
    );
  }

  Widget _emptyState(BuildContext context) {
    return OEmptyState(
      icon: Icons.person_off_outlined,
      title: 'No account found',
      message: 'Sign in to see your account.',
      action: OButton(
        label: 'Sign in',
        icon: Icons.login_rounded,
        onPressed: data.onSignIn ?? data.onRetry,
      ),
    );
  }

  Widget _content(BuildContext context, V2AccountProfile profile) {
    final rows = _rows(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProfileHeader(
            profile: profile,
            onChangePhoto: data.onChangePhoto,
          ),
          const SizedBox(height: OSpace.xl),
          if (rows.isNotEmpty) V2SettingsRowList(rows: rows),
          if (_deletionError != null) ...[
            const SizedBox(height: OSpace.l),
            _DeletionError(message: _deletionError!),
          ],
          if (_deletionPending) ...[
            const SizedBox(height: OSpace.xl),
            _DeletionBanner(
              deadline: _deletionDeadline,
              loading: _deletionLoading,
              onRestore:
                  data.onRestoreAccount == null && data.restoreDeletion == null
                  ? null
                  : _restoreAccount,
            ),
          ],
        ],
      ),
    );
  }

  /// Four destinations at most: the profile editor, the sign-in sheet, data
  /// control and the destructive delete. Profile details, credentials and
  /// support live behind those rows, not on the page.
  List<Widget> _rows(BuildContext context) {
    final rows = <Widget>[];
    final edit = _editProfileAction();
    if (edit != null) {
      rows.add(
        V2SettingsRow(
          icon: Icons.edit_outlined,
          title: 'Edit profile',
          onTap: edit,
        ),
      );
    }
    final canManageSignIn =
        data.onLinkAccount != null || data.onAccountTap != null;
    // Only a row that either shows real linked accounts or opens the sheet.
    // A dead "None linked" row is noise.
    if (canManageSignIn || data.connectedAccounts.isNotEmpty) {
      rows.add(
        V2SettingsRow(
          icon: Icons.login_rounded,
          title: 'Sign-in methods',
          subtitle: _linkedLabel(),
          showChevron: canManageSignIn,
          onTap: canManageSignIn ? () => _openSignInSheet(context) : null,
        ),
      );
    }
    if (data.onDataControl != null) {
      rows.add(
        V2SettingsRow(
          key: const ValueKey<String>('account-data-control-row'),
          icon: Icons.shield_outlined,
          title: 'Data control',
          onTap: data.onDataControl,
        ),
      );
    }
    if (_canDelete && !_deletionPending) {
      rows.add(
        V2SettingsRow(
          key: const ValueKey<String>('account-delete-row'),
          icon: Icons.warning_amber_rounded,
          title: 'Delete account',
          danger: true,
          showChevron: false,
          onTap: _deleting ? null : () => _confirmDelete(context),
        ),
      );
    }
    return rows;
  }

  VoidCallback? _editProfileAction() {
    final edit = data.onEditProfile;
    if (edit != null) return edit;
    final tap = data.onFieldTap;
    if (tap == null) return null;
    for (final field in data.fields) {
      if (field.editable) return () => tap(field);
    }
    return null;
  }

  String _linkedLabel() {
    final linked = <String>[
      for (final account in data.connectedAccounts)
        if (account.connected) account.name,
    ];
    return linked.isEmpty ? 'None linked' : linked.join(', ');
  }

  Future<void> _openSignInSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SafeArea(
          child: OContent(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: OSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const OSectionTitle(title: 'Sign-in methods'),
                  Column(
                    children: [
                      for (
                        var index = 0;
                        index < data.connectedAccounts.length;
                        index++
                      ) ...[
                        if (index > 0)
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: c.hairline,
                          ),
                        _signInRow(
                          sheetContext,
                          data.connectedAccounts[index],
                        ),
                      ],
                      if (data.onLinkAccount != null) ...[
                        if (data.connectedAccounts.isNotEmpty)
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: c.hairline,
                          ),
                        OListRow(
                          icon: Icons.add_link_rounded,
                          title: 'Link account',
                          padding: const EdgeInsets.symmetric(
                            vertical: OSpace.m,
                          ),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            data.onLinkAccount?.call();
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _signInRow(BuildContext context, V2ConnectedAccount account) {
    final tap = data.onAccountTap;
    return OListRow(
      leading: OAvatar(
        initials: account.name,
        size: 36,
        semanticLabel: account.name,
      ),
      title: account.name,
      subtitle: account.detail,
      trailing: OPill(
        label: account.connected ? 'Connected' : 'Not linked',
        tone: account.connected ? OPillTone.success : OPillTone.neutral,
      ),
      showChevron: false,
      padding: const EdgeInsets.symmetric(vertical: OSpace.m),
      onTap: tap == null ? null : () => tap(account),
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
      data: V2ConfirmTypedSheetData(contact: _confirmationContact),
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

/// Avatar, name and plan pill. Everything else about the profile lives behind
/// the one "Edit profile" action.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.onChangePhoto});

  final V2AccountProfile profile;
  final VoidCallback? onChangePhoto;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final plan = _planLabel(profile);
    return Center(
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              OAvatar(
                initials: profile.initials ?? profile.name,
                image: profile.image,
                size: 80,
                semanticLabel: '${profile.name} profile photo',
              ),
              if (onChangePhoto != null)
                Positioned(
                  right: -OSpace.s,
                  bottom: -OSpace.s,
                  child: OIconButton(
                    icon: Icons.photo_camera_rounded,
                    semanticLabel: 'Change photo',
                    tooltip: 'Change photo',
                    onPressed: onChangePhoto,
                  ),
                ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          Text(
            profile.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: OType.h2.copyWith(color: c.text),
          ),
          if (plan.isNotEmpty) ...[
            const SizedBox(height: OSpace.s),
            OPill(label: plan, tone: OPillTone.accent),
          ],
        ],
      ),
    );
  }
}
