import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// One device signed in to the account.
@immutable
class V2SignInDevice {
  const V2SignInDevice({
    required this.id,
    required this.name,
    required this.detail,
    this.current = false,
  });

  final String id;
  final String name;
  final String detail;
  final bool current;
}

/// Where the account stands with the service.
enum V2AccountStatus {
  /// In good standing.
  active,

  /// A deletion request is scheduled but can still be cancelled.
  deletionPending,

  /// Blocked for abuse; data is kept and support can review it.
  suspendedForAbuse,
}

/// One usage or storage line in the account summary.
@immutable
class V2AccountUsageMetric {
  const V2AccountUsageMetric({
    required this.id,
    required this.title,
    this.value = '',
    this.detail = '',
  });

  final String id;
  final String title;

  /// The headline, e.g. `2.1 GB` or `38M tokens`. Empty until measured.
  final String value;

  /// The qualifier, e.g. `of 3 GB` or `Resets in 6h 12m`.
  final String detail;
}

/// One service shown in the status list.
@immutable
class V2ServiceStatus {
  const V2ServiceStatus({
    required this.name,
    required this.statusLabel,
    this.healthy = true,
  });

  final String name;
  final String statusLabel;
  final bool healthy;
}

/// One recent sign-in event.
@immutable
class V2SignInEvent {
  const V2SignInEvent({
    required this.id,
    required this.device,
    required this.location,
    required this.timeLabel,
    this.current = false,
  });

  final String id;
  final String device;
  final String location;
  final String timeLabel;
  final bool current;
}

/// Injected state for the Account health screen.
@immutable
class V2AccountHealthPageData {
  const V2AccountHealthPageData({
    this.statusTitle = 'Health check not run yet',
    this.statusMessage =
        'Run a check to verify your account, devices and sign-ins.',
    this.healthy,
    this.score,
    this.lastCheckLabel = '',
    this.lastCheckDetail = '',
    this.twoFactorEnabled,
    this.emailVerified = true,
    this.emailLabel = '',
    this.regionLabel = '',
    this.accountStatus,
    this.usage = const <V2AccountUsageMetric>[
      V2AccountUsageMetric(id: 'storage', title: 'Storage left'),
      V2AccountUsageMetric(id: 'daily_usage', title: 'Daily usage left'),
      V2AccountUsageMetric(id: 'monthly_usage', title: 'Monthly usage left'),
    ],
    this.deletionRequestedLabel = '',
    this.deletionScheduledLabel = '',
    this.services = const <V2ServiceStatus>[],
    this.devices = const <V2SignInDevice>[],
    this.recentSignIns = const <V2SignInEvent>[],
    this.hasData = true,
    this.loading = false,
    this.errorMessage,
    this.onReviewDevices,
    this.onDeviceTap,
    this.onRevokeDevice,
    this.onEnableTwoFactor,
    this.onVerifyEmail,
    this.onContactSupport,
    this.onRunCheck,
    this.onCancelDeletion,
    this.onRetry,
  });

  final String statusTitle;
  final String statusMessage;

  /// Whether the account currently passes every check. Null means "not
  /// measured"; the page never turns that into a healthy claim. The hero only
  /// shows a healthy state when a check has actually run
  /// ([hasCheckResult]) and this is true.
  final bool? healthy;

  /// Security score out of 100, or null when it has not been measured yet. The
  /// score block is hidden rather than showing a made-up number.
  final int? score;
  final String lastCheckLabel;
  final String lastCheckDetail;

  /// Null when the account has no second factor or the state is unknown. A
  /// missing value is never rendered as "On".
  final bool? twoFactorEnabled;
  final bool emailVerified;
  final String emailLabel;
  final String regionLabel;

  /// Where the account stands right now, or null when no status has been
  /// reported. A missing status is never rendered as the green "Active" pill.
  final V2AccountStatus? accountStatus;

  /// Storage and allowance lines. The page never invents a number: a metric
  /// with an empty [V2AccountUsageMetric.value] reads "Not measured yet".
  final List<V2AccountUsageMetric> usage;

  /// When deletion was asked for, e.g. `21 Oct 2026`.
  final String deletionRequestedLabel;

  /// The date the data goes, e.g. `20 Nov 2026`.
  final String deletionScheduledLabel;

  final List<V2ServiceStatus> services;
  final List<V2SignInDevice> devices;
  final List<V2SignInEvent> recentSignIns;
  final bool hasData;
  final bool loading;
  final String? errorMessage;

  /// Legacy review action. The devices are listed inline with per-device
  /// actions, so the page no longer renders a separate "Review" button. Kept
  /// so existing call sites keep compiling.
  final VoidCallback? onReviewDevices;
  final ValueChanged<String>? onDeviceTap;
  final ValueChanged<String>? onRevokeDevice;
  final VoidCallback? onEnableTwoFactor;
  final VoidCallback? onVerifyEmail;
  final VoidCallback? onContactSupport;
  final VoidCallback? onRunCheck;

  /// Cancels a scheduled deletion. The page confirms first.
  final VoidCallback? onCancelDeletion;
  final VoidCallback? onRetry;

  int? get resolvedScore => score?.clamp(0, 100);

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

  /// `Requested 21 Oct 2026 · Deletes on 20 Nov 2026` with empty parts
  /// dropped, or an empty string when the caller has no dates yet.
  String get deletionSummary => [
    if (deletionRequestedLabel.isNotEmpty) 'Requested $deletionRequestedLabel',
    if (deletionScheduledLabel.isNotEmpty) 'Deletes on $deletionScheduledLabel',
  ].join(' · ');

  /// True once a security check has actually run and reported a time.
  bool get hasCheckResult =>
      lastCheckLabel.isNotEmpty || lastCheckDetail.isNotEmpty;

  /// `2 hours ago · Automated audit passed.` with empty parts dropped.
  String get lastCheckSummary => [
    lastCheckLabel,
    lastCheckDetail,
  ].where((part) => part.isNotEmpty).join(' · ');

  /// A green state is only honest once a check has run and passed.
  bool get effectiveHealthy => hasCheckResult && healthy == true;

  String get healthPillLabel {
    if (!hasCheckResult) return 'Not checked yet';
    return switch (healthy) {
      true => 'Healthy',
      false => 'Needs attention',
      null => 'Not verified',
    };
  }
}

/// Account health: status, last security check and signed-in devices.
class AccountHealthPage extends StatelessWidget {
  const AccountHealthPage({super.key, required this.data});

  final V2AccountHealthPageData data;

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Account health',
      actions: [
        if (data.onRunCheck != null)
          OIconButton(
            key: const ValueKey<String>('account-health-run-check'),
            icon: Icons.refresh_rounded,
            semanticLabel: data.hasCheckResult
                ? 'Run check again'
                : 'Run check',
            tooltip: data.hasCheckResult ? 'Run again' : 'Run check',
            onPressed: data.onRunCheck,
          ),
      ],
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) return const OSkeletonList(rows: 6);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (!data.hasData) {
      return OEmptyState(
        icon: Icons.health_and_safety_outlined,
        title: 'No health data yet',
        message: 'Run a check to see account status.',
        action: data.onRunCheck == null
            ? null
            : OButton(
                label: 'Run a check',
                icon: Icons.refresh_rounded,
                onPressed: data.onRunCheck,
              ),
      );
    }

    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusLine(context),
          const SizedBox(height: OSpace.l),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
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
                Divider(color: c.hairline, height: 1),
                _HealthRow(
                  icon: Icons.alternate_email_rounded,
                  title: 'Email',
                  showChevron: false,
                  onTap: data.emailVerified ? null : data.onVerifyEmail,
                  trailing: data.emailVerified
                      ? const OPill(
                          label: 'Verified',
                          tone: OPillTone.success,
                          dot: true,
                        )
                      : data.onVerifyEmail != null
                      ? OButton(
                          label: 'Verify',
                          variant: OButtonVariant.ghost,
                          onPressed: data.onVerifyEmail,
                        )
                      : const OPill(
                          label: 'Not verified',
                          tone: OPillTone.warn,
                          dot: true,
                        ),
                ),
                if (data.twoFactorEnabled != null) ...[
                  Divider(color: c.hairline, height: 1),
                  _HealthRow(
                    icon: Icons.password_rounded,
                    title: 'Two-step sign-in',
                    showChevron: false,
                    onTap: data.twoFactorEnabled!
                        ? null
                        : data.onEnableTwoFactor,
                    trailing: data.twoFactorEnabled!
                        ? const OPill(
                            label: 'On',
                            tone: OPillTone.success,
                            dot: true,
                          )
                        : data.onEnableTwoFactor != null
                        ? OButton(
                            label: 'Turn on',
                            variant: OButtonVariant.ghost,
                            onPressed: data.onEnableTwoFactor,
                          )
                        : const OPill(
                            label: 'Off',
                            tone: OPillTone.warn,
                            dot: true,
                          ),
                  ),
                ],
                for (final device in data.devices) ...[
                  Divider(color: c.hairline, height: 1),
                  _HealthRow(
                    icon: Icons.devices_rounded,
                    title: device.name,
                    subtitle: device.detail,
                    showChevron: false,
                    onTap: data.onDeviceTap == null
                        ? null
                        : () => data.onDeviceTap!(device.id),
                    trailing: device.current
                        ? const OPill(
                            label: 'This device',
                            tone: OPillTone.accent,
                          )
                        : data.onRevokeDevice == null
                        ? null
                        : OButton(
                            label: 'Revoke',
                            variant: OButtonVariant.danger,
                            onPressed: () =>
                                _confirmRevokeDevice(context, device),
                          ),
                  ),
                ],
                if (data.onContactSupport != null) ...[
                  Divider(color: c.hairline, height: 1),
                  _HealthRow(
                    icon: Icons.support_agent_rounded,
                    title: 'Contact support',
                    onTap: data.onContactSupport,
                  ),
                ],
              ],
            ),
          ),
          if (_bottomAction(context) != null) ...[
            const SizedBox(height: OSpace.l),
            _bottomAction(context)!,
          ],
        ],
      ),
    );
  }

  /// One status line: the pill plus the last real check. No green tick unless a
  /// check actually ran.
  Widget _statusLine(BuildContext context) {
    final c = OColors.of(context);
    final checked = data.hasCheckResult;
    final healthy = data.effectiveHealthy;
    final unknown = !checked || data.healthy == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OPill(
          label: data.healthPillLabel,
          tone: unknown
              ? OPillTone.neutral
              : healthy
              ? OPillTone.success
              : OPillTone.warn,
          dot: true,
        ),
        const SizedBox(height: OSpace.xs),
        Text(
          checked ? data.lastCheckSummary : 'No check has run yet.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: OType.bodySm.copyWith(color: c.textMuted),
        ),
      ],
    );
  }

  Widget? _bottomAction(BuildContext context) {
    if (data.deletionPending && data.onCancelDeletion != null) {
      return OButton(
        key: const ValueKey<String>('account-health-cancel-deletion'),
        label: 'Cancel deletion',
        variant: OButtonVariant.danger,
        expand: true,
        onPressed: () => _confirmCancelDeletion(context),
      );
    }
    return null;
  }

  Future<void> _confirmCancelDeletion(BuildContext context) async {
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
    if (confirmed == true) data.onCancelDeletion?.call();
  }

  Future<void> _confirmRevokeDevice(
    BuildContext context,
    V2SignInDevice device,
  ) async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Revoke this device?',
      builder: (context) {
        final c = OColors.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${device.name} will be signed out. You can sign in again later.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep signed in',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'Revoke device',
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true) data.onRevokeDevice?.call(device.id);
  }
}

/// Settings row that keeps its trailing pill or button inside the card.
///
/// `OListRow` hands its trailing child an unbounded width, so a status pill or
/// a small button paints past the card edge once the caption is scaled up. At
/// normal text this is exactly `OListRow`; above 140 % the trailing control
/// moves under the title instead of squeezing it into a sliver.
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
        icon: icon,
        showChevron: showChevron,
        onTap: onTap,
        trailing: trailingWidget == null
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 168),
                child: trailingWidget,
              ),
      );
    }

    final c = OColors.of(context);
    final leadingWidget = icon == null
        ? null
        : Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(icon, size: 19, color: c.textMuted),
          );
    final label = subtitle == null ? title : '$title, $subtitle';
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
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
