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

/// Injected state for the Credentials screen.
@immutable
class V2CredentialsPageData {
  const V2CredentialsPageData({
    this.google,
    this.github,
    this.token,
    this.cloudKeyStatusLabel = 'Cloud key active',
    this.cloudKeyStatusDetail =
        'Encrypted on this device. The full key is never shown.',
    this.cloudKeyActive = true,
    this.loading = false,
    this.errorMessage,
    this.onConnectGoogle,
    this.onConnectGithub,
    this.onAddToken,
    this.onRevokeAll,
    this.onManageCloudKey,
    this.onCredentialTap,
    this.onRetry,
  });

  final V2Credential? google;
  final V2Credential? github;
  final V2Credential? token;
  final String cloudKeyStatusLabel;
  final String cloudKeyStatusDetail;
  final bool cloudKeyActive;
  final bool loading;
  final String? errorMessage;

  final VoidCallback? onConnectGoogle;
  final VoidCallback? onConnectGithub;
  final VoidCallback? onAddToken;
  final VoidCallback? onRevokeAll;
  final VoidCallback? onManageCloudKey;
  final ValueChanged<String>? onCredentialTap;
  final VoidCallback? onRetry;

  List<V2Credential> get credentials => <V2Credential>[
    ?google,
    ?github,
    ?token,
  ];

  bool get isEmpty => credentials.isEmpty;
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
            _cloudKey(context),
            _credentialList(context),
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
                    'Your keys are encrypted on this device and never shown again.',
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
            label: 'Credentials',
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

IconData _kindIcon(V2CredentialKind kind) {
  return switch (kind) {
    V2CredentialKind.google => Icons.mail_outline_rounded,
    V2CredentialKind.github => Icons.terminal_rounded,
    V2CredentialKind.token => Icons.key_rounded,
  };
}
