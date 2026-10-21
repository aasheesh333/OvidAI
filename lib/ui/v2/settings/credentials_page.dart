import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

enum V2CredentialKind { google, github, token }

/// One connected credential.
@immutable
class V2Credential {
  const V2Credential({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.connected = true,
  });

  final String id;
  final V2CredentialKind kind;
  final String title;
  final String subtitle;
  final bool connected;
}

/// A site login the agent can use in the browser.
///
/// The password is write-only from the UI's point of view: the screen only
/// ever renders it masked, and the agent receives it through the credential
/// helper at run time, never through the transcript.
@immutable
class V2BrowserCredential {
  const V2BrowserCredential({
    required this.id,
    required this.site,
    required this.username,
    required this.password,
  });

  final String id;
  final String site;
  final String username;
  final String password;

  V2BrowserCredential copyWith({
    String? id,
    String? site,
    String? username,
    String? password,
  }) {
    return V2BrowserCredential(
      id: id ?? this.id,
      site: site ?? this.site,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }
}

/// Injected state for the Credentials screen.
@immutable
class V2CredentialsPageData {
  const V2CredentialsPageData({
    this.google,
    this.github,
    this.token,
    this.browserCredentials = const [],
    this.githubOAuthConnected,
    this.githubPatAdded = false,
    this.cloudKeyStatusLabel = 'Cloud key active',
    this.cloudKeyStatusDetail =
        'Encrypted on this device. The full key is never shown.',
    this.cloudKeyActive = true,
    this.loading = false,
    this.errorMessage,
    this.onConnectGoogle,
    this.onConnectGithub,
    this.onAddToken,
    this.onAddBrowserCredential,
    this.onEditBrowserCredential,
    this.onDeleteBrowserCredential,
    this.onConnectGithubOAuth,
    this.onDisconnectGithubOAuth,
    this.onAddGithubPat,
    this.onRemoveGithubPat,
    this.onRevokeAll,
    this.onManageCloudKey,
    this.onCredentialTap,
    this.onRetry,
  });

  final V2Credential? google;
  final V2Credential? github;
  final V2Credential? token;

  /// Site logins used by the browser. Passwords are only rendered masked.
  final List<V2BrowserCredential> browserCredentials;

  /// OAuth state. When null it is derived from [github].
  final bool? githubOAuthConnected;

  /// Whether a GitHub personal access token is stored.
  final bool githubPatAdded;
  final String cloudKeyStatusLabel;
  final String cloudKeyStatusDetail;
  final bool cloudKeyActive;
  final bool loading;
  final String? errorMessage;

  final VoidCallback? onConnectGoogle;
  final VoidCallback? onConnectGithub;
  final VoidCallback? onAddToken;
  final ValueChanged<V2BrowserCredential>? onAddBrowserCredential;
  final ValueChanged<V2BrowserCredential>? onEditBrowserCredential;
  final ValueChanged<V2BrowserCredential>? onDeleteBrowserCredential;
  final VoidCallback? onConnectGithubOAuth;
  final VoidCallback? onDisconnectGithubOAuth;
  final VoidCallback? onAddGithubPat;
  final VoidCallback? onRemoveGithubPat;
  final VoidCallback? onRevokeAll;
  final VoidCallback? onManageCloudKey;
  final ValueChanged<String>? onCredentialTap;
  final VoidCallback? onRetry;

  List<V2Credential> get credentials => <V2Credential>[
    ?google,
    ?github,
    ?token,
  ];

  bool get isEmpty =>
      credentials.isEmpty && browserCredentials.isEmpty && !githubPatAdded;

  bool get githubOAuthActive =>
      githubOAuthConnected ?? (github?.connected ?? false);
}

/// Connected accounts and personal keys used by Ovid.
class CredentialsPage extends StatelessWidget {
  const CredentialsPage({super.key, required this.data});

  final V2CredentialsPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Credentials'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 6));
    }
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (data.isEmpty) {
      return OEmptyState(
        icon: Icons.key_off_outlined,
        title: 'No credentials yet',
        message: 'Connect Google or GitHub so Ovid can work for you.',
        action: OButton(
          label: 'Connect Google',
          icon: Icons.mail_outline_rounded,
          onPressed: data.onConnectGoogle,
        ),
        secondaryAction: OButton(
          label: 'Connect GitHub',
          variant: OButtonVariant.secondary,
          onPressed: data.onConnectGithub,
        ),
      );
    }
    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.l,
          OSpace.screen,
          OSpace.xxl,
        ),
        child: OStagger(
          children: [
            _intro(context),
            _browserLogins(context),
            _credentialList(context),
            _githubAccess(context),
            _cloudKey(context),
            _revoke(context),
          ],
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(
                Icons.verified_user_outlined,
                size: 24,
                color: c.accent,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Protected & Encrypted',
                        style: OType.h2.copyWith(color: c.text),
                      ),
                      const SizedBox(height: OSpace.xs),
                      const OPill(
                        label: 'Healthy',
                        tone: OPillTone.success,
                        dot: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    'Your keys and browser logins are encrypted on this '
                    'device. Passwords are never shown to the agent in plain '
                    'text.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Site logins the browser can use. Passwords are write-only: the screen
  /// shows a fixed mask and never the stored value.
  Widget _browserLogins(BuildContext context) {
    final c = OColors.of(context);
    final count = data.browserCredentials.length;
    final canAdd = data.onAddBrowserCredential != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Browser logins',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: canAdd
                ? OButton(
                    label: 'Add login',
                    variant: OButtonVariant.ghost,
                    size: OButtonSize.compact,
                    onPressed: () => _editBrowserCredential(context),
                  )
                : null,
          ),
          if (data.browserCredentials.isEmpty)
            OCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No browser logins yet',
                    style: OType.body.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Add a site so Ovid can sign in for you during a task.',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                  if (canAdd) ...[
                    const SizedBox(height: OSpace.m),
                    OButton(
                      label: 'Add login',
                      icon: Icons.add_rounded,
                      variant: OButtonVariant.secondary,
                      onPressed: () => _editBrowserCredential(context),
                    ),
                  ],
                ],
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked = _stacksAt(
                  context,
                  constraints.maxWidth - 2 * OSpace.l,
                );
                return OCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (
                        var i = 0;
                        i < data.browserCredentials.length;
                        i++
                      ) ...[
                        if (i > 0) Divider(color: c.hairline, height: 1),
                        _browserRow(
                          context,
                          data.browserCredentials[i],
                          stacked: stacked,
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: OSpace.s),
          Text(
            '$count saved · Passwords are stored encrypted on this device and '
            'never shown to the agent in plain text.',
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }

  Widget _browserRow(
    BuildContext context,
    V2BrowserCredential credential, {
    required bool stacked,
  }) {
    final c = OColors.of(context);
    final edit = data.onEditBrowserCredential == null
        ? null
        : () => _editBrowserCredential(context, existing: credential);
    final delete = data.onDeleteBrowserCredential == null
        ? null
        : () => _deleteBrowserCredential(context, credential);
    final leading = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(Icons.language_rounded, size: 19, color: c.textMuted),
    );
    final subtitle =
        '${credential.username} · ${_maskedPassword(credential.password)}';
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OIconButton(
          icon: Icons.edit_rounded,
          semanticLabel: 'Edit ${credential.site}',
          tooltip: 'Edit ${credential.site}',
          onPressed: edit,
        ),
        OIconButton(
          icon: Icons.delete_outline_rounded,
          semanticLabel: 'Delete ${credential.site}',
          tooltip: 'Delete ${credential.site}',
          onPressed: delete,
        ),
      ],
    );
    if (!stacked) {
      return OListRow(
        leading: leading,
        title: credential.site,
        subtitle: subtitle,
        showChevron: false,
        trailing: actions,
        onTap: edit,
      );
    }
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  credential.site,
                  style: OType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.xs),
                actions,
              ],
            ),
          ),
        ],
      ),
    );
    final label = '${credential.site}, $subtitle';
    if (edit == null) {
      return Semantics(label: label, child: content);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: edit,
        child: Semantics(label: label, button: true, child: content),
      ),
    );
  }

  Future<void> _editBrowserCredential(
    BuildContext context, {
    V2BrowserCredential? existing,
  }) async {
    final saved = await showOSheet<V2BrowserCredential>(
      context,
      title: existing == null ? 'Add browser login' : 'Edit browser login',
      builder: (_) => _BrowserCredentialForm(existing: existing),
    );
    if (saved == null) return;
    if (existing == null) {
      data.onAddBrowserCredential?.call(saved);
    } else {
      data.onEditBrowserCredential?.call(saved);
    }
  }

  Future<void> _deleteBrowserCredential(
    BuildContext context,
    V2BrowserCredential credential,
  ) async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Delete login?',
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ovid will no longer be able to sign in to '
                '${credential.site}. The saved password is removed from this '
                'device.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep login',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'Delete login',
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true) data.onDeleteBrowserCredential?.call(credential);
  }

  /// GitHub can authenticate with OAuth (browser sign-in) or a personal
  /// access token. Both states are shown so the user knows what git will use.
  Widget _githubAccess(BuildContext context) {
    final c = OColors.of(context);
    final oauth = data.githubOAuthActive;
    final pat = data.githubPatAdded;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'GitHub access',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth <
                  380 * MediaQuery.textScalerOf(context).scale(1);
              return OCard(
                child: Column(
                  children: [
                    _accessRow(
                      context,
                      title: 'OAuth (browser sign-in)',
                      detail: oauth
                          ? 'Connected with your GitHub account'
                          : 'Connect GitHub to clone and push',
                      active: oauth,
                      activeLabel: 'Connected',
                      inactiveLabel: 'Not connected',
                      actionLabel: oauth ? 'Disconnect' : 'Connect',
                      onAction: oauth
                          ? data.onDisconnectGithubOAuth
                          : data.onConnectGithubOAuth,
                      stacked: stacked,
                    ),
                    Divider(color: c.hairline, height: 1),
                    _accessRow(
                      context,
                      title: 'GitHub personal access token',
                      detail: pat
                          ? 'Added · used for git clone and push'
                          : 'Not added',
                      active: pat,
                      activeLabel: 'Added',
                      inactiveLabel: 'Not added',
                      actionLabel: pat ? 'Replace token' : 'Add token',
                      onAction: data.onAddGithubPat,
                      secondaryLabel: pat ? 'Remove' : null,
                      onSecondary: pat ? data.onRemoveGithubPat : null,
                      stacked: stacked,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _accessRow(
    BuildContext context, {
    required String title,
    required String detail,
    required bool active,
    required String activeLabel,
    required String inactiveLabel,
    required String actionLabel,
    required VoidCallback? onAction,
    String? secondaryLabel,
    VoidCallback? onSecondary,
    required bool stacked,
  }) {
    final c = OColors.of(context);
    final pill = OPill(
      label: active ? activeLabel : inactiveLabel,
      tone: active ? OPillTone.success : OPillTone.neutral,
      dot: true,
    );
    final buttons = <Widget>[
      OButton(
        label: actionLabel,
        variant: OButtonVariant.ghost,
        size: OButtonSize.compact,
        onPressed: onAction,
      ),
      if (secondaryLabel != null)
        OButton(
          label: secondaryLabel,
          variant: OButtonVariant.ghost,
          size: OButtonSize.compact,
          onPressed: onSecondary,
        ),
    ];
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: OType.body.copyWith(
            color: c.text,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(detail, style: OType.caption.copyWith(color: c.textMuted)),
      ],
    );
    if (!stacked) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: text),
          const SizedBox(width: OSpace.s),
          pill,
          const SizedBox(width: OSpace.xs),
          ...buttons,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        text,
        const SizedBox(height: OSpace.xs),
        pill,
        const SizedBox(height: OSpace.xs),
        Wrap(spacing: OSpace.s, runSpacing: OSpace.xs, children: buttons),
      ],
    );
  }

  Widget _cloudKey(BuildContext context) {
    final c = OColors.of(context);
    final icon = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: data.cloudKeyActive
            ? c.success.withValues(alpha: 0.12)
            : c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(
        Icons.vpn_key_outlined,
        size: 19,
        color: data.cloudKeyActive ? c.success : c.textMuted,
      ),
    );
    final pill = OPill(
      label: data.cloudKeyActive ? 'Active' : 'Off',
      tone: data.cloudKeyActive ? OPillTone.success : OPillTone.neutral,
      dot: true,
    );
    final button = OButton(
      label: 'Manage',
      variant: OButtonVariant.ghost,
      onPressed: data.onManageCloudKey,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked = _stacksAt(context, constraints.maxWidth);
            final label = Text(
              data.cloudKeyStatusLabel,
              style: OType.body.copyWith(
                color: c.text,
                fontWeight: FontWeight.w500,
              ),
            );
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (stacked) ...[
                  label,
                  const SizedBox(height: OSpace.xs),
                  pill,
                ] else
                  Row(
                    children: [
                      Expanded(child: label),
                      pill,
                    ],
                  ),
                const SizedBox(height: OSpace.xs),
                Text(
                  data.cloudKeyStatusDetail,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            );
            if (!stacked) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  icon,
                  const SizedBox(width: OSpace.m),
                  Expanded(child: text),
                  const SizedBox(width: OSpace.s),
                  button,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    icon,
                    const SizedBox(width: OSpace.m),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: OSpace.s),
                Align(alignment: AlignmentDirectional.centerEnd, child: button),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _credentialList(BuildContext context) {
    final c = OColors.of(context);
    final count = data.credentials.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Sign-in methods',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              '$count stored',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              // The status pill and the "Add" button cannot share a line with
              // the account name at 320 dp / 200 % text, so the rows reflow.
              final stacked = _stacksAt(
                context,
                constraints.maxWidth - 2 * OSpace.l,
              );
              return OCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < data.credentials.length; i++) ...[
                      if (i > 0) Divider(color: c.hairline, height: 1),
                      _credentialRow(
                        context,
                        data.credentials[i],
                        stacked: stacked,
                      ),
                    ],
                    if (data.token == null) ...[
                      Divider(color: c.hairline, height: 1),
                      OListRow(
                        icon: Icons.key_rounded,
                        title: 'Personal access token',
                        subtitle: 'Not added yet',
                        showChevron: false,
                        trailing: OButton(
                          label: 'Add',
                          variant: OButtonVariant.ghost,
                          onPressed: data.onAddToken,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _credentialRow(
    BuildContext context,
    V2Credential credential, {
    required bool stacked,
  }) {
    final c = OColors.of(context);
    final isToken = credential.kind == V2CredentialKind.token;
    final subtitle = isToken
        ? _maskedToken(credential.subtitle)
        : credential.subtitle;
    final onTap = data.onCredentialTap == null
        ? null
        : () => data.onCredentialTap!(credential.id);
    final leading = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(_kindIcon(credential.kind), size: 19, color: c.textMuted),
    );
    final pill = OPill(
      label: credential.connected ? 'Active' : 'Off',
      tone: credential.connected ? OPillTone.success : OPillTone.neutral,
      dot: true,
    );
    if (!stacked) {
      return OListRow(
        leading: leading,
        title: credential.title,
        subtitle: subtitle,
        showChevron: false,
        onTap: onTap,
        trailing: isToken
            ? OButton(
                label: 'Add',
                variant: OButtonVariant.ghost,
                onPressed: data.onAddToken,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  pill,
                  if (onTap != null) ...[
                    const SizedBox(width: OSpace.xs),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: c.textFaint,
                    ),
                  ],
                ],
              ),
      );
    }
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  credential.title,
                  style: OType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.xs),
                if (isToken)
                  OButton(
                    label: 'Add',
                    variant: OButtonVariant.ghost,
                    onPressed: data.onAddToken,
                  )
                else
                  pill,
              ],
            ),
          ),
        ],
      ),
    );
    final label = '${credential.title}, $subtitle';
    if (onTap == null) {
      return Semantics(label: label, child: content);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Semantics(label: label, button: true, child: content),
      ),
    );
  }

  Widget _revoke(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OButton(
            label: 'Revoke all credentials',
            icon: Icons.warning_amber_rounded,
            variant: OButtonVariant.danger,
            expand: true,
            onPressed: data.credentials.isEmpty
                ? null
                : () => _confirmRevoke(context),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            'Revoking disconnects every account and token. You will need to sign in again.',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRevoke(BuildContext context) async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Revoke all credentials?',
      builder: (context) {
        final c = OColors.of(context);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'This disconnects Google, GitHub, and your personal token. Active tasks will stop.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep active',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'Revoke now',
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true) data.onRevokeAll?.call();
  }
}

/// Add/edit form for a browser login. Owns its controllers so they outlive the
/// sheet's dismissal animation.
class _BrowserCredentialForm extends StatefulWidget {
  const _BrowserCredentialForm({this.existing});

  final V2BrowserCredential? existing;

  @override
  State<_BrowserCredentialForm> createState() => _BrowserCredentialFormState();
}

class _BrowserCredentialFormState extends State<_BrowserCredentialForm> {
  late final TextEditingController _site = TextEditingController(
    text: widget.existing?.site ?? '',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  final _password = TextEditingController();

  @override
  void dispose() {
    _site.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _save() {
    final existing = widget.existing;
    Navigator.of(context).pop(
      V2BrowserCredential(
        id: existing?.id ?? 'browser-${DateTime.now().microsecondsSinceEpoch}',
        site: _site.text.trim(),
        username: _username.text.trim(),
        password: _password.text.isEmpty && existing != null
            ? existing.password
            : _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final existing = widget.existing;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('browser-site-field'),
            controller: _site,
            autofocus: existing == null,
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Site',
              hintText: 'example.com',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: OSpace.m),
          TextField(
            key: const ValueKey('browser-username-field'),
            controller: _username,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Username',
              hintText: 'you@example.com',
            ),
          ),
          const SizedBox(height: OSpace.m),
          TextField(
            key: const ValueKey('browser-password-field'),
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Password',
              hintText: existing == null
                  ? 'Stored encrypted on this device'
                  : 'Leave blank to keep the saved password',
            ),
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            'Ovid fills this login for you. The password is never shown to '
            'the agent in plain text.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            label: existing == null ? 'Save login' : 'Save changes',
            expand: true,
            onPressed: _site.text.trim().isEmpty ? null : _save,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: 'Cancel',
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// At 320 dp with 200 % text a pill or a button no longer fits beside the
/// label it belongs to. Cards and rows fall back to a stacked layout instead of
/// squeezing the text to nothing.
bool _stacksAt(BuildContext context, double width) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return width < 190 * scale;
}

/// Tokens are only ever rendered in a masked form. If a caller passes a raw
/// value by mistake, everything except the last four characters is hidden.
String _maskedToken(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '••••';
  if (trimmed.contains('•') || trimmed.contains('*')) return trimmed;
  if (trimmed.length <= 4) return '••••';
  return '••••••${trimmed.substring(trimmed.length - 4)}';
}

/// Browser passwords are stricter than tokens: no characters of the stored
/// value are rendered, so a screenshot or shoulder-surfer learns nothing.
String _maskedPassword(String value) =>
    value.trim().isEmpty ? 'No password saved' : '••••••••';

IconData _kindIcon(V2CredentialKind kind) {
  return switch (kind) {
    V2CredentialKind.google => Icons.mail_outline_rounded,
    V2CredentialKind.github => Icons.terminal_rounded,
    V2CredentialKind.token => Icons.key_rounded,
  };
}
