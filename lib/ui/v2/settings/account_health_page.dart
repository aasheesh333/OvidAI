import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'settings_rows.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// Where the account stands with the service.
enum V2AccountStatus {
  /// In good standing.
  active,

  /// A deletion request is scheduled but can still be cancelled.
  deletionPending,

  /// Blocked for abuse; data is kept and support can review it.
  suspendedForAbuse,
}

/// Injected state for the Account health screen.
///
/// The page only carries what a service can actually report: the account's
/// standing, the deletion state and the sign-in method. Device management and
/// two-step sign-in have no endpoint behind them, so they are not modelled and
/// not rendered.
@immutable
class V2AccountHealthPageData {
  const V2AccountHealthPageData({
    this.emailVerified = true,
    this.emailLabel = '',
    this.accountStatus,
    this.deletionScheduledLabel = '',
    this.hasData = true,
    this.loading = false,
    this.errorMessage,
    this.onContactSupport,
    this.onCancelDeletion,
    this.onRetry,
  });

  final bool emailVerified;

  /// The address the person signs in with. Empty when the account has none.
  final String emailLabel;

  /// Where the account stands right now, or null when no status has been
  /// reported. A missing status is never rendered as the green "Active" pill.
  final V2AccountStatus? accountStatus;

  /// The date the data goes, e.g. `20 Nov 2026`.
  final String deletionScheduledLabel;

  final bool hasData;
  final bool loading;
  final String? errorMessage;

  final VoidCallback? onContactSupport;

  /// Cancels a scheduled deletion. The page confirms first.
  final VoidCallback? onCancelDeletion;
  final VoidCallback? onRetry;

  bool get deletionPending => accountStatus == V2AccountStatus.deletionPending;

  String get accountStatusLabel => switch (accountStatus) {
    V2AccountStatus.active => 'Active',
    V2AccountStatus.deletionPending => 'Deletion pending',
    V2AccountStatus.suspendedForAbuse => 'Suspended',
    null => 'Not checked',
  };

  String get accountStatusDetail => switch (accountStatus) {
    V2AccountStatus.active => 'Your account is in good standing.',
    V2AccountStatus.deletionPending =>
      'Your account is scheduled for deletion.',
    V2AccountStatus.suspendedForAbuse =>
      'Suspended for abuse. Contact support to appeal.',
    null => 'No account status has been reported yet.',
  };

  /// `Deletes on 20 Nov 2026`, or an empty string when no date is known.
  String get deletionSummary => deletionScheduledLabel.isEmpty
      ? ''
      : 'Deletes on $deletionScheduledLabel';
}

/// Account health: standing, deletion state and the sign-in method.
class AccountHealthPage extends StatelessWidget {
  const AccountHealthPage({super.key, required this.data});

  final V2AccountHealthPageData data;

  @override
  Widget build(BuildContext context) {
    return OScreen(title: 'Account health', child: _body(context));
  }

  Widget _body(BuildContext context) {
    if (data.loading) return const OSkeletonList(rows: 4);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (!data.hasData) {
      return const OEmptyState(
        icon: Icons.health_and_safety_outlined,
        title: 'No account data',
        message: 'Sign in to see your account status.',
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusLine(context),
          const SizedBox(height: OSpace.l),
          V2SettingsRowList(
            rows: [
              _HealthRow(
                key: const ValueKey<String>('health-account-status'),
                icon: Icons.verified_user_outlined,
                title: 'Account status',
                showChevron: false,
                trailing: OPill(
                  label: data.accountStatusLabel,
                  tone: switch (data.accountStatus) {
                    V2AccountStatus.active => OPillTone.success,
                    V2AccountStatus.deletionPending => OPillTone.warn,
                    V2AccountStatus.suspendedForAbuse => OPillTone.danger,
                    null => OPillTone.neutral,
                  },
                  dot: true,
                ),
              ),
              _HealthRow(
                icon: Icons.alternate_email_rounded,
                title: 'Email',
                subtitle: data.emailLabel.isEmpty ? null : data.emailLabel,
                showChevron: false,
                trailing: data.emailVerified
                    ? const OPill(
                        label: 'Verified',
                        tone: OPillTone.success,
                        dot: true,
                      )
                    : const OPill(
                        label: 'Not verified',
                        tone: OPillTone.warn,
                        dot: true,
                      ),
              ),
              if (data.deletionPending && data.deletionSummary.isNotEmpty)
                _HealthRow(
                  key: const ValueKey<String>('health-deletion'),
                  icon: Icons.event_busy_outlined,
                  title: 'Deletion',
                  subtitle: data.deletionSummary,
                  showChevron: false,
                ),
              if (data.onContactSupport != null)
                _HealthRow(
                  icon: Icons.support_agent_rounded,
                  title: 'Contact support',
                  onTap: data.onContactSupport,
                ),
            ],
          ),
          if (_bottomAction() != null) ...[
            const SizedBox(height: OSpace.l),
            _bottomAction()!,
          ],
        ],
      ),
    );
  }

  /// One status line: the pill plus what that standing means.
  Widget _statusLine(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OPill(
          label: data.accountStatusLabel,
          tone: switch (data.accountStatus) {
            V2AccountStatus.active => OPillTone.success,
            V2AccountStatus.deletionPending => OPillTone.warn,
            V2AccountStatus.suspendedForAbuse => OPillTone.danger,
            null => OPillTone.neutral,
          },
          dot: true,
        ),
        const SizedBox(height: OSpace.xs),
        Text(
          data.accountStatusDetail,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: OType.bodySm.copyWith(color: c.textMuted),
        ),
      ],
    );
  }

  Widget? _bottomAction() {
    if (data.deletionPending && data.onCancelDeletion != null) {
      return _CancelDeletionButton(onPressed: data.onCancelDeletion!);
    }
    return null;
  }
}

/// Confirms with the real deletion service before anything is cancelled.
class _CancelDeletionButton extends StatelessWidget {
  const _CancelDeletionButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OButton(
      key: const ValueKey<String>('account-health-cancel-deletion'),
      label: 'Cancel deletion',
      variant: OButtonVariant.danger,
      expand: true,
      onPressed: () => _confirm(context),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Cancel account deletion?',
      builder: (context) {
        final c = OColors.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your account and its data will be kept.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep deletion',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                key: const ValueKey<String>(
                  'account-health-confirm-cancel-deletion',
                ),
                label: 'Cancel deletion',
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true) onPressed();
  }
}

/// Settings row that keeps its trailing pill inside the card.
///
/// `OListRow` hands its trailing child an unbounded width, so a status pill
/// paints past the card edge once the caption is scaled up. At normal text this
/// is exactly `OListRow`; above 140 % the trailing control moves under the
/// title instead of squeezing it into a sliver.
class _HealthRow extends StatelessWidget {
  const _HealthRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.showChevron = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  /// Above this scale the trailing control drops below the title.
  static const _stackAbove = 1.4;

  @override
  Widget build(BuildContext context) {
    final trailingWidget = trailing;
    final stacked =
        trailingWidget != null &&
        MediaQuery.textScalerOf(context).scale(1) > _stackAbove;
    if (!stacked) {
      return OListRow(
        title: title,
        subtitle: subtitle,
        leading: icon == null ? null : V2SettingsTile(icon: icon!),
        showChevron: showChevron,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        trailing: trailingWidget == null
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 168),
                child: trailingWidget,
              ),
      );
    }

    final c = OColors.of(context);
    final leadingWidget =
        icon == null ? null : V2SettingsTile(icon: icon!);
    final label = subtitle == null ? title : '$title, $subtitle';
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leadingWidget != null) ...[
            leadingWidget,
            const SizedBox(width: OSpace.m),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The row label already carries the title and subtitle; the
                // visible copies are decoration and would be read twice.
                ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: OType.body.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: OSpace.s),
                trailingWidget,
              ],
            ),
          ),
        ],
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: onTap == null
          ? Semantics(label: label, child: content)
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(ORadius.m),
                child: Semantics(label: label, button: true, child: content),
              ),
            ),
    );
  }
}
