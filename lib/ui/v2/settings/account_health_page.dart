import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
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
    this.statusTitle = 'All systems normal',
    this.statusMessage = 'No suspicious activity detected.',
    this.healthy = true,
    this.score,
    this.lastCheckLabel = '',
    this.lastCheckDetail = '',
    this.twoFactorEnabled = true,
    this.emailVerified = true,
    this.emailLabel = '',
    this.regionLabel = '',
    this.accountStatus = V2AccountStatus.active,
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

  /// Whether the account currently passes every check. Drives the hero pill and
  /// the scan dot; the wiring pass must feed the real result.
  final bool healthy;

  /// Security score out of 100, or null when it has not been measured yet. The
  /// score block is hidden rather than showing a made-up number.
  final int? score;
  final String lastCheckLabel;
  final String lastCheckDetail;
  final bool twoFactorEnabled;
  final bool emailVerified;
  final String emailLabel;
  final String regionLabel;

  /// Where the account stands right now. Suspended and deletion-pending
  /// accounts keep their data but change what the page can promise.
  final V2AccountStatus accountStatus;

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
  };

  String get accountStatusDetail => switch (accountStatus) {
    V2AccountStatus.active => 'Your account is in good standing.',
    V2AccountStatus.deletionPending =>
      'Your account is scheduled for deletion.',
    V2AccountStatus.suspendedForAbuse =>
      'Suspended for abuse. Contact support to appeal.',
  };

  /// `Requested 21 Oct 2026 · Deletes on 20 Nov 2026` with empty parts
  /// dropped, or an empty string when the caller has no dates yet.
  String get deletionSummary => [
    if (deletionRequestedLabel.isNotEmpty) 'Requested $deletionRequestedLabel',
    if (deletionScheduledLabel.isNotEmpty)
      'Deletes on $deletionScheduledLabel',
  ].join(' · ');

  /// True once a security check has actually run and reported a time.
  bool get hasCheckResult =>
      lastCheckLabel.isNotEmpty || lastCheckDetail.isNotEmpty;

  /// `2 hours ago · Automated audit passed.` with empty parts dropped.
  String get lastCheckSummary => [
    lastCheckLabel,
    lastCheckDetail,
  ].where((part) => part.isNotEmpty).join(' · ');
}

/// Account health: status, last security check and signed-in devices.
class AccountHealthPage extends StatelessWidget {
  const AccountHealthPage({super.key, required this.data});

  final V2AccountHealthPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Account health'),
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
    if (!data.hasData) {
      return OEmptyState(
        icon: Icons.health_and_safety_outlined,
        title: 'No health data yet',
        message: 'Run a check to see how your account and devices are doing.',
        action: OButton(
          label: 'Run a check',
          icon: Icons.refresh_rounded,
          onPressed: data.onRunCheck,
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
            _hero(context),
            _summary(context),
            if (data.accountStatus == V2AccountStatus.suspendedForAbuse)
              _suspendedNotice(context),
            if (data.deletionPending) _deletionRequest(context),
            _healthCard(context),
            _devices(context),
            _recentSignIns(context),
            _serviceStatus(context),
            _regionSupport(context),
            _isolationNote(context),
          ],
        ),
      ),
    );
  }

  Widget _hero(BuildContext context) {
    final c = OColors.of(context);
    final score = data.resolvedScore;
    final tone = data.healthy ? c.success : c.warn;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(
                    data.healthy
                        ? Icons.health_and_safety_outlined
                        : Icons.gpp_maybe_outlined,
                    size: 24,
                    color: tone,
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.statusTitle,
                        style: OType.h2.copyWith(color: c.text),
                      ),
                      const SizedBox(height: OSpace.xs),
                      OPill(
                        label: data.healthy ? 'Healthy' : 'Needs attention',
                        tone: data.healthy ? OPillTone.success : OPillTone.warn,
                        dot: true,
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        data.statusMessage,
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (score != null) ...[
              const SizedBox(height: OSpace.m),
              Container(
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (MediaQuery.textScalerOf(context).scale(1) > 1.4) ...[
                      Text(
                        'Security score',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        '$score/100',
                        style: OType.bodyStrong.copyWith(color: c.text),
                      ),
                    ] else
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Security score',
                              style: OType.caption.copyWith(color: c.textMuted),
                            ),
                          ),
                          Text(
                            '$score/100',
                            style: OType.bodyStrong.copyWith(color: c.text),
                          ),
                        ],
                      ),
                    const SizedBox(height: OSpace.s),
                    OProgressBar(value: score / 100),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One card answers "how much is left, and where does my account stand".
  /// The page shows `Not measured yet` rather than a made-up number.
  Widget _summary(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Account summary',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _HealthRow(
                  key: const ValueKey<String>('health-account-status'),
                  icon: Icons.verified_user_outlined,
                  title: 'Account status',
                  subtitle: data.accountStatusDetail,
                  showChevron: false,
                  trailing: OPill(
                    label: data.accountStatusLabel,
                    tone: switch (data.accountStatus) {
                      V2AccountStatus.active => OPillTone.success,
                      V2AccountStatus.deletionPending => OPillTone.warn,
                      V2AccountStatus.suspendedForAbuse => OPillTone.danger,
                    },
                    dot: true,
                  ),
                ),
                for (final metric in data.usage) ...[
                  Divider(color: c.hairline, height: 1),
                  _HealthRow(
                    key: ValueKey<String>('health-usage-${metric.id}'),
                    icon: _usageIcon(metric.id),
                    title: metric.title,
                    subtitle: _usageDetail(metric),
                    showChevron: false,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _usageIcon(String id) => switch (id) {
    'storage' => Icons.cloud_outlined,
    'daily_usage' => Icons.today_outlined,
    'monthly_usage' => Icons.calendar_month_outlined,
    _ => Icons.bar_chart_rounded,
  };

  String _usageDetail(V2AccountUsageMetric metric) {
    if (metric.value.trim().isEmpty) return 'Not measured yet';
    if (metric.detail.trim().isEmpty) return metric.value;
    return '${metric.value} · ${metric.detail}';
  }

  Widget _suspendedNotice(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Container(
        key: const ValueKey<String>('account-health-suspended-notice'),
        padding: const EdgeInsets.all(OSpace.l),
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(ORadius.l),
          border: Border.all(color: c.danger.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.gpp_bad_outlined, size: 20, color: c.danger),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    'Suspended for abuse',
                    style: OType.h3.copyWith(color: c.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.s),
            Text(
              'Your data is kept. Contact support to appeal this decision.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            OButton(
              key: const ValueKey<String>('account-health-suspended-support'),
              label: 'Contact support',
              icon: Icons.support_agent_rounded,
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: data.onContactSupport,
            ),
          ],
        ),
      ),
    );
  }

  Widget _deletionRequest(BuildContext context) {
    final c = OColors.of(context);
    final summary = data.deletionSummary;
    final when = data.deletionScheduledLabel.isEmpty
        ? ''
        : ' on ${data.deletionScheduledLabel}';
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Deletion request',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            key: const ValueKey<String>('account-health-deletion-card'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: c.warn,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        'Deletion requested',
                        style: OType.h3.copyWith(color: c.text),
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    const OPill(
                      label: 'Pending',
                      tone: OPillTone.warn,
                      dot: true,
                    ),
                  ],
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: OSpace.s),
                  Text(
                    summary,
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
                const SizedBox(height: OSpace.s),
                Text(
                  'Your chats, files, memory and artifacts will be deleted'
                  '$when. Until then, you can cancel.',
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.m),
                OButton(
                  key: const ValueKey<String>('account-health-cancel-deletion'),
                  label: 'Cancel deletion',
                  variant: OButtonVariant.secondary,
                  expand: true,
                  onPressed: data.onCancelDeletion == null
                      ? null
                      : () => _confirmCancelDeletion(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
                'Your account and all its data will be kept. You can request '
                'deletion again at any time.',
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

  Widget _healthCard(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Account health',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              'Continuous scan',
              style: OType.caption.copyWith(
                color: data.healthy ? c.success : c.textMuted,
              ),
            ),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _HealthRow(
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: (data.healthy ? c.success : c.warn).withValues(
                        alpha: 0.12,
                      ),
                      borderRadius: BorderRadius.circular(ORadius.m),
                    ),
                    child: Icon(
                      data.healthy
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 19,
                      color: data.healthy ? c.success : c.warn,
                    ),
                  ),
                  title: 'Security scan',
                  subtitle: data.statusMessage,
                  showChevron: false,
                  stackTrailing: false,
                  trailing: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: data.healthy ? c.success : c.warn,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Divider(color: c.hairline, height: 1),
                _HealthRow(
                  icon: Icons.password_rounded,
                  title: 'Two-step sign-in',
                  subtitle: data.twoFactorEnabled
                      ? 'On. A code is required when you sign in.'
                      : 'Off. Add a second step to protect your account.',
                  showChevron: false,
                  onTap: data.twoFactorEnabled ? null : data.onEnableTwoFactor,
                  trailing: data.twoFactorEnabled
                      ? const OPill(
                          label: 'On',
                          tone: OPillTone.success,
                          dot: true,
                        )
                      : OButton(
                          label: 'Turn on',
                          variant: OButtonVariant.ghost,
                          onPressed: data.onEnableTwoFactor,
                        ),
                ),
                Divider(color: c.hairline, height: 1),
                _HealthRow(
                  icon: Icons.alternate_email_rounded,
                  title: 'Email verification',
                  subtitle: data.emailLabel.isEmpty ? null : data.emailLabel,
                  showChevron: false,
                  onTap: data.emailVerified ? null : data.onVerifyEmail,
                  trailing: data.emailVerified
                      ? const OPill(
                          label: 'Verified',
                          tone: OPillTone.success,
                          dot: true,
                        )
                      : OButton(
                          label: 'Verify',
                          variant: OButtonVariant.ghost,
                          onPressed: data.onVerifyEmail,
                        ),
                ),
                Divider(color: c.hairline, height: 1),
                _HealthRow(
                  icon: Icons.schedule_rounded,
                  title: 'Last security check',
                  subtitle: data.hasCheckResult
                      ? data.lastCheckSummary
                      : 'No check has run yet.',
                  showChevron: false,
                  stackTrailing: false,
                  trailing: data.hasCheckResult
                      ? Icon(
                          Icons.verified_outlined,
                          size: 20,
                          color: data.healthy ? c.success : c.textFaint,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _devices(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Active sign-ins',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: OButton(
              label: 'Review',
              variant: OButtonVariant.ghost,
              onPressed: data.onReviewDevices,
            ),
          ),
          if (data.devices.isEmpty)
            OCard(
              child: Text(
                'No other devices are signed in.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < data.devices.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    _HealthRow(
                      icon: Icons.devices_rounded,
                      title: data.devices[i].name,
                      subtitle: data.devices[i].detail,
                      trailing: data.devices[i].current
                          ? const OPill(
                              label: 'This device',
                              tone: OPillTone.accent,
                            )
                          : OButton(
                              label: 'Revoke',
                              variant: OButtonVariant.danger,
                              onPressed: data.onRevokeDevice == null
                                  ? null
                                  : () => _confirmRevokeDevice(
                                      context,
                                      data.devices[i],
                                    ),
                            ),
                      onTap: data.onDeviceTap == null
                          ? null
                          : () => data.onDeviceTap!(data.devices[i].id),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _recentSignIns(BuildContext context) {
    final c = OColors.of(context);
    final count = data.recentSignIns.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Recent sign-ins',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              '$count ${count == 1 ? 'event' : 'events'}',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          if (data.recentSignIns.isEmpty)
            OCard(
              child: Text(
                'No recent sign-ins to review.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < data.recentSignIns.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    _HealthRow(
                      icon: Icons.login_rounded,
                      title: data.recentSignIns[i].device,
                      subtitle:
                          '${data.recentSignIns[i].location} · ${data.recentSignIns[i].timeLabel}',
                      showChevron: false,
                      trailing: data.recentSignIns[i].current
                          ? const OPill(
                              label: 'This device',
                              tone: OPillTone.accent,
                            )
                          : null,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _serviceStatus(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Service status',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: data.services.isEmpty
                ? null
                : Text('Live', style: OType.caption.copyWith(color: c.success)),
          ),
          if (data.services.isEmpty)
            OCard(
              child: Text(
                'Status is not available right now.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < data.services.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    _HealthRow(
                      icon: data.services[i].healthy
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                      title: data.services[i].name,
                      showChevron: false,
                      trailing: OPill(
                        label: data.services[i].statusLabel,
                        tone: data.services[i].healthy
                            ? OPillTone.success
                            : OPillTone.warn,
                        dot: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _regionSupport(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Region and support',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                if (data.regionLabel.isNotEmpty) ...[
                  _HealthRow(
                    icon: Icons.public_rounded,
                    title: 'Region',
                    subtitle: data.regionLabel,
                    showChevron: false,
                  ),
                  Divider(color: c.hairline, height: 1),
                ],
                _HealthRow(
                  icon: Icons.support_agent_rounded,
                  title: 'Contact support',
                  subtitle: 'Get help with your account or sign-in',
                  onTap: data.onContactSupport,
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

  Widget _isolationNote(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.textFaint),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              'Keys stay encrypted on this device. Ovid only uses them while a task is running.',
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ),
        ],
      ),
    );
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
    this.leading,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    this.stackTrailing = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  /// False for a tiny trailing marker (a dot or a 20 dp icon) that always fits
  /// next to the title, so it stays inline instead of stacking.
  final bool stackTrailing;

  /// Above this scale the trailing control drops below the title.
  static const _stackAbove = 1.4;

  @override
  Widget build(BuildContext context) {
    final trailingWidget = trailing;
    final stacked =
        stackTrailing &&
        trailingWidget != null &&
        MediaQuery.textScalerOf(context).scale(1) > _stackAbove;
    if (!stacked) {
      return OListRow(
        title: title,
        subtitle: subtitle,
        icon: icon,
        leading: leading,
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
    final leadingWidget =
        leading ??
        (icon == null
            ? null
            : Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(icon, size: 19, color: c.textMuted),
              ));
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
