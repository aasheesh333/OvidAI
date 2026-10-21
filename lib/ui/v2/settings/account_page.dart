// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

enum V2AccountStatus { loading, ready, empty, error }

@immutable
class V2AccountProfile {
  const V2AccountProfile({
    required this.name,
    required this.email,
    this.role = '',
    this.initials,
    this.image,
  });

  final String name;
  final String email;
  final String role;
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
    this.onSignOut,
    this.onDeleteAccount,
    this.onSignIn,
    this.onRetry,
    this.signOutLoading = false,
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
  final VoidCallback? onSignOut;
  final VoidCallback? onDeleteAccount;
  final VoidCallback? onSignIn;
  final VoidCallback? onRetry;
  final bool signOutLoading;
  final String errorMessage;

  /// Sync status shown beside "Profile details". The adapter should pass the
  /// real state; pass an empty string to hide the label.
  final String syncLabel;

  /// False shows the status in the warning tone instead of success.
  final bool syncOk;
}

class AccountPage extends StatelessWidget {
  const AccountPage({super.key, required this.data});

  final V2AccountData data;

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
                      child: OIconButton(
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
                if (profile.role.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    profile.role,
                    textAlign: TextAlign.center,
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
                const SizedBox(height: OSpace.m),
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
              action: OButton(
                label: 'Add details',
                icon: Icons.add_rounded,
                onPressed: data.onEditProfile ?? data.onRetry,
              ),
            )
          else
            _DetailsCard(data: data),
          const SizedBox(height: OSpace.xl),
          OSectionHeader(
            label: 'Connected accounts',
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
              action: OButton(
                label: 'Link account',
                icon: Icons.add_link_rounded,
                onPressed: data.onLinkAccount,
              ),
            )
          else
            _ConnectedCard(data: data),
          const SizedBox(height: OSpace.xl),
          OButton(
            label: 'Sign out',
            icon: Icons.logout_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            loading: data.signOutLoading,
            onPressed: data.onSignOut,
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            label: 'Delete account',
            icon: Icons.warning_amber_rounded,
            variant: OButtonVariant.danger,
            expand: true,
            onPressed: data.onDeleteAccount,
          ),
          const SizedBox(height: OSpace.s),
          Text(
            'Permanently remove your data and cloud files. This cannot be undone.',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textMuted),
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
            else if (onTap != null)
              Icon(
                field.editable
                    ? Icons.edit_rounded
                    : Icons.chevron_right_rounded,
                size: field.editable ? 18 : 20,
                color: field.editable ? c.textMuted : c.textFaint,
              ),
          ],
        ),
      ),
    );
    if (onTap == null) {
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
