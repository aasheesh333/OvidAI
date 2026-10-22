// TODO(l10n): move the English copy in this screen to the ARB files.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/account_service.dart';
import '../../../core/format.dart';
import '../../../core/ovid_cloud_service.dart';
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

  /// Legacy slot that older adapters use for the plan label (for example a
  /// job title before plans existed). [planName] wins when both are set.
  final String role;

  /// Current plan, rendered as a pill next to the name. A raw tier id
  /// (`free`, `3x`, `7x`, `15x`) is resolved to its real plan name.
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
    this.onDataControl,
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

  /// Opens Data control (export, import, cache, deletion).
  final VoidCallback? onDataControl;

  /// Ends the session. Signing out is not deletion: the account stays.
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
  /// over injected data so the row reflects what the service returned.
  AccountDeletion? _receipt;
  bool _deleting = false;
  String? _deletionError;
  bool _restored = false;

  bool get _deletionPending =>
      !_restored && (data.deletionPending || _receipt?.isPending == true);

  DateTime? get _deletionDeadline =>
      _receipt?.deleteAfter ?? data.deletionDeadline;

  bool get _deletionLoading => data.deletionLoading || _deleting;

  bool get _hasCancel =>
      data.restoreDeletion != null || data.onRestoreAccount != null;

  bool get _canCancel => _hasCancel && !_deletionLoading;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (data.status) {
      case V2AccountStatus.loading:
        body = const OSkeletonList(rows: 5);
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
    final sessionRows = _sessionRows();
    final dangerRows = _deleteRows(context);
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
          if (sessionRows.isNotEmpty) ...[
            const SizedBox(height: OSpace.xl),
            V2SettingsRowList(rows: sessionRows),
          ],
          if (dangerRows.isNotEmpty) ...[
            const SizedBox(height: OSpace.xl),
            V2SettingsRowList(rows: dangerRows),
          ],
          if (_deletionPending) ...[
            const SizedBox(height: OSpace.s),
            _GraceNote(canCancel: _hasCancel),
          ],
          if (_deletionError != null) ...[
            const SizedBox(height: OSpace.l),
            _DeletionError(message: _deletionError!),
          ],
        ],
      ),
    );
  }

  /// Profile destinations: the editor, the sign-in sheet and data control.
  /// A row is only rendered when it has a real destination.
  List<Widget> _rows(BuildContext context) {
    final rows = <Widget>[];
    final edit = _editProfileAction();
    if (edit != null) {
      rows.add(
        V2SettingsRow(
          key: const ValueKey<String>('account-edit-row'),
          icon: Icons.edit_outlined,
          title: 'Edit profile',
          onTap: edit,
        ),
      );
    }
    final canManageSignIn =
        data.onLinkAccount != null || data.onAccountTap != null;
    final hasSheetContent =
        data.connectedAccounts.isNotEmpty || data.onLinkAccount != null;
    if (canManageSignIn && hasSheetContent) {
      rows.add(
        V2SettingsRow(
          key: const ValueKey<String>('account-sign-in-row'),
          icon: Icons.login_rounded,
          title: 'Sign-in methods',
          subtitle: _linkedLabel(),
          onTap: () => _openSignInSheet(context),
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
    return rows;
  }

  /// Sign out sits on its own, above the destructive row: ending a session
  /// keeps the account, deleting it does not.
  List<Widget> _sessionRows() {
    final signOut = data.onSignOut;
    if (signOut == null) return const <Widget>[];
    return <Widget>[
      V2SettingsRow(
        key: const ValueKey<String>('account-sign-out-row'),
        icon: Icons.logout_rounded,
        title: 'Sign out',
        enabled: !data.signOutLoading,
        showChevron: false,
        trailing: data.signOutLoading
            ? const _Busy(semanticLabel: 'Signing out')
            : null,
        onTap: data.signOutLoading ? null : signOut,
      ),
    ];
  }

  /// The destructive row: one state at a time — idle, deleting, pending.
  List<Widget> _deleteRows(BuildContext context) {
    if (_deletionPending) {
      final deadline = _deletionDeadline;
      return <Widget>[
        V2SettingsRow(
          key: const ValueKey<String>('account-delete-row'),
          icon: Icons.hourglass_bottom_rounded,
          title: 'Deletion pending',
          subtitle: deadline == null
              ? 'Deletes after 24 hours'
              : 'Deletes ${formatLocalDateTime(deadline)}',
          showChevron: false,
          stacksTrailing: true,
          trailing: _hasCancel
              ? OButton(
                  key: const ValueKey<String>('account-cancel-deletion'),
                  label: 'Cancel deletion',
                  variant: OButtonVariant.ghost,
                  size: OButtonSize.compact,
                  loading: _deletionLoading,
                  onPressed: _canCancel ? _restoreAccount : null,
                )
              : null,
        ),
      ];
    }

    if (!_canDelete) return const <Widget>[];
    final label = _deletionLoading ? 'Requesting deletion' : null;
    return <Widget>[
      Semantics(
        container: true,
        button: true,
        enabled: !_deletionLoading,
        label: 'Delete account',
        hint: label ?? 'Destructive action. Deletes your account after 24 hours.',
        onTap: _deletionLoading ? null : () => _confirmDelete(context),
        child: ExcludeSemantics(
          child: V2SettingsRow(
            key: const ValueKey<String>('account-delete-row'),
            icon: Icons.warning_amber_rounded,
            title: 'Delete account',
            subtitle: _deletionLoading ? 'Requesting deletion' : null,
            danger: true,
            enabled: !_deletionLoading,
            showChevron: false,
            trailing: _deletionLoading
                ? const _Busy(semanticLabel: 'Requesting deletion')
                : null,
            onTap: _deletionLoading ? null : () => _confirmDelete(context),
          ),
        ),
      ),
    ];
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
    return showOSheet<void>(
      context,
      title: 'Sign-in methods',
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: OSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < data.connectedAccounts.length; index++)
                ...[
                  if (index > 0)
                    Divider(height: 1, thickness: 1, color: c.hairline),
                  _signInRow(sheetContext, data.connectedAccounts[index]),
                ],
              if (data.onLinkAccount != null) ...[
                if (data.connectedAccounts.isNotEmpty)
                  Divider(height: 1, thickness: 1, color: c.hairline),
                OListRow(
                  key: const ValueKey<String>('account-link-row'),
                  icon: Icons.add_link_rounded,
                  title: 'Link account',
                  padding: const EdgeInsets.symmetric(
                    vertical: OSpace.m,
                    horizontal: OSpace.l,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    data.onLinkAccount?.call();
                  },
                ),
              ],
            ],
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
      padding: const EdgeInsets.symmetric(
        vertical: OSpace.m,
        horizontal: OSpace.l,
      ),
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
            : 'Deletion was not scheduled. Try again.';
      });
      if (receipt.isPending) _snack('Deletion scheduled.');
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
        _deletionError = 'Could not request deletion. Try again.';
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
      if (!stillPending) _snack('Deletion cancelled.');
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
        _deletionError = 'Could not cancel deletion. Try again.';
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

/// Names a host may pass when it has no real identity to show. They are not
/// people's names, so the header falls back to the account's own identifier.
const Set<String> _placeholderNames = <String>{
  'ovid user',
  'user',
  'account',
  'signed in',
  'you',
};

/// Tier ids an adapter may hand over instead of a plan name.
const Set<String> _tierIds = <String>{'free', '3x', '7x', '15x'};

/// The real name, or the account's own identifier when the host only supplied
/// a placeholder. Never a made-up name.
String _displayName(V2AccountProfile profile) {
  final raw = profile.name.trim();
  if (raw.isNotEmpty && !_placeholderNames.contains(raw.toLowerCase())) {
    return raw;
  }
  final identifier = profile.email.trim();
  if (identifier.contains('@')) {
    final local = identifier.substring(0, identifier.indexOf('@')).trim();
    if (local.isNotEmpty) return local;
  }
  if (identifier.isNotEmpty) return identifier;
  return 'Your account';
}

/// The string the avatar turns into initials: the supplied initials for a real
/// name, otherwise the resolved identity.
String _avatarSeed(V2AccountProfile profile, String name) {
  final raw = profile.name.trim();
  final realName =
      raw.isNotEmpty && !_placeholderNames.contains(raw.toLowerCase());
  final initials = profile.initials?.trim();
  if (realName && initials != null && initials.isNotEmpty) return initials;
  return name;
}

/// Current plan. A raw tier id is resolved through the same catalog the rest
/// of the app uses; the legacy `role` slot is read only when it holds the plan.
String _planLabel(V2AccountProfile profile) {
  for (final value in <String>[profile.planName, profile.role]) {
    final label = value.trim();
    if (label.isEmpty) continue;
    if (_tierIds.contains(label.toLowerCase())) {
      return label.toLowerCase() == 'free' ? 'Free plan' : ovidPlanName(label);
    }
    return label;
  }
  return '';
}

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

/// One line of fact under a pending deletion row: the grace window and the
/// way out. The deadline itself lives in the row.
class _GraceNote extends StatelessWidget {
  const _GraceNote({required this.canCancel});

  final bool canCancel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: v2SettingsRowDividerIndent,
        top: OSpace.xs,
      ),
      child: Text(
        canCancel
            ? '24-hour grace · cancel anytime'
            : 'Deletion happens after 24 hours.',
        style: OType.caption.copyWith(color: c.textMuted),
      ),
    );
  }
}

/// A 20 dp progress glyph for a row that is doing work.
class _Busy extends StatelessWidget {
  const _Busy({required this.semanticLabel});

  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: c.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Plain-language failure from the deletion service, shown next to the
/// destructive row instead of a raw exception.
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
/// the one "Edit profile" action, and the identity is announced once.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.onChangePhoto});

  final V2AccountProfile profile;
  final VoidCallback? onChangePhoto;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final name = _displayName(profile);
    final plan = _planLabel(profile);
    return Semantics(
      container: true,
      label: plan.isEmpty ? name : '$name, $plan',
      child: Center(
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                ExcludeSemantics(
                  child: OAvatar(
                    initials: _avatarSeed(profile, name),
                    image: profile.image,
                    size: 80,
                  ),
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
            ExcludeSemantics(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: OType.h2.copyWith(color: c.text),
              ),
            ),
            if (plan.isNotEmpty) ...[
              const SizedBox(height: OSpace.s),
              ExcludeSemantics(
                child: OPill(label: plan, tone: OPillTone.accent),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
