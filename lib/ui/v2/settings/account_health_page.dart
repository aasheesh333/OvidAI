import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'settings_rows.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// Where the account stands with the service.
///
/// The gateway's `/account/health` answers the ban flag and the deletion row,
/// so both are modelled. A missing status is still unknown: it is never
/// rendered as "Healthy".
enum V2AccountStatus {
  /// In good standing.
  active,

  /// A deletion request is scheduled but can still be cancelled.
  deletionPending,

  /// The account is banned. The ban reason is not shown on this screen, but
  /// the status line must never call a banned account healthy.
  banned,
}

/// The four states of the Account Health screen.
enum V2AccountHealthStatus { loading, ready, empty, error }

/// Injected state for the Account health screen.
///
/// The page carries only the four facts the app can read: the plan, today's
/// usage, storage and the deletion state. Every label is supplied by the
/// caller; an empty label renders the honest [unknown] mark instead of a zero
/// that looks like real usage. Nothing else is modelled or rendered, so no
/// row can promise a fact the app cannot read.
@immutable
class V2AccountHealthPageData {
  const V2AccountHealthPageData({
    this.planLabel = '',
    this.accountStatus,
    this.todayUsageLabel = '',
    this.todayUsageFraction,
    this.storageUsedLabel = '',
    this.storageFraction,
    this.deletionScheduledLabel = '',
    this.deletionKnown = false,
    this.loading = false,
    this.status = V2AccountHealthStatus.ready,
    this.errorMessage,
    this.onOpenPlans,
    this.onOpenStorage,
    this.onCancelDeletion,
    this.onRetry,
  });

  /// The mark for a fact the app has not read. It is deliberately not `0`: a
  /// zero looks like real usage and hides a failed read.
  static const unknown = '—';

  /// Empty-state copy lives here so the page and its tests share one string.
  static const emptyTitle = 'Not signed in';
  static const emptyMessage = 'Sign in.';

  /// The fallback for an explicit error that carries no server message.
  static const loadFailed = 'Could not load.';

  /// The current plan's display name (`Free`, `Go`, …), or empty when unknown.
  final String planLabel;

  /// Where the account stands right now, or null when no status has been
  /// reported. A missing status is never rendered as "Healthy".
  final V2AccountStatus? accountStatus;

  /// Today's usage, already formatted (`8.2K tokens`). Empty when unknown.
  final String todayUsageLabel;

  /// Share (0..1) of today's allowance already used, or null when unknown.
  /// Drives the attention line; it is never shown as a number.
  final double? todayUsageFraction;

  /// Used storage, already formatted (`1.2 GB of 3 GB`). Empty when unknown.
  final String storageUsedLabel;

  /// Share (0..1) of the storage quota already used, or null when unknown.
  final double? storageFraction;

  /// The date the data goes, e.g. `20 Nov 2026`.
  final String deletionScheduledLabel;

  /// True when the server answered the deletion question, even if the answer
  /// was "none". Without this, a banned account would show a dash on the
  /// deletion row although the server said there is no deletion.
  final bool deletionKnown;

  final bool loading;

  /// The explicit screen state. The legacy [loading]/[errorMessage] flags are
  /// still honoured when this is [V2AccountHealthStatus.ready].
  final V2AccountHealthStatus status;
  final String? errorMessage;

  /// Opens the plan list. Null when the host has no route: the row is static.
  final VoidCallback? onOpenPlans;

  /// Opens the storage screen. Null when the host has no route: the row is
  /// static.
  final VoidCallback? onOpenStorage;

  /// Cancels a scheduled deletion. The page confirms first.
  final VoidCallback? onCancelDeletion;
  final VoidCallback? onRetry;

  bool get deletionPending => accountStatus == V2AccountStatus.deletionPending;

  bool get canCancelDeletion => deletionPending && onCancelDeletion != null;

  /// The state the page renders. An explicit status wins; the legacy flags
  /// keep older callers (and the preview data) working unchanged.
  V2AccountHealthStatus get effectiveStatus {
    if (status != V2AccountHealthStatus.ready) return status;
    if (loading) return V2AccountHealthStatus.loading;
    if (errorMessage != null) return V2AccountHealthStatus.error;
    return V2AccountHealthStatus.ready;
  }

  /// The one status line, derived from the facts above. It is never hardcoded:
  /// a missing status or a fact that needs attention changes it.
  String get statusLabel {
    if (accountStatus == V2AccountStatus.banned) return 'Banned';
    if (deletionPending) return 'Attention needed · Deletion scheduled';
    if (accountStatus == null) return 'Attention needed · Status unknown';
    if ((storageFraction ?? 0) >= 0.9) {
      return 'Attention needed · Storage almost full';
    }
    if ((todayUsageFraction ?? 0) >= 1) {
      return 'Attention needed · Daily limit reached';
    }
    return 'Healthy';
  }

  bool get isHealthy => statusLabel == 'Healthy';

  /// The same line, punctuated for a screen reader instead of a middle dot.
  String get statusAnnouncement =>
      isHealthy ? 'Healthy' : statusLabel.replaceFirst(' · ', '. ');

  String get planText => planLabel.trim().isEmpty ? unknown : planLabel.trim();

  String get todayText =>
      todayUsageLabel.trim().isEmpty ? unknown : todayUsageLabel.trim();

  String get storageText =>
      storageUsedLabel.trim().isEmpty ? unknown : storageUsedLabel.trim();

  String get deletionText {
    if (deletionPending) {
      final date = deletionScheduledLabel.trim();
      return date.isEmpty ? 'Scheduled' : 'Scheduled · $date';
    }
    if (deletionKnown || accountStatus == V2AccountStatus.active) {
      return 'None';
    }
    return unknown;
  }
}

/// Account health: one derived status line and four facts the app can read.
class AccountHealthPage extends StatelessWidget {
  const AccountHealthPage({super.key, required this.data});

  final V2AccountHealthPageData data;

  @override
  Widget build(BuildContext context) {
    // The shell's band cap (640 dp on a tablet, 720 dp on a wide window) is the
    // single source of truth; a wider window adds margin, not line length.
    return OScreen(title: 'Account health', child: _body(context));
  }

  Widget _body(BuildContext context) {
    switch (data.effectiveStatus) {
      case V2AccountHealthStatus.loading:
        return const OSkeletonList(rows: 4);
      case V2AccountHealthStatus.error:
        return OErrorState(
          message: data.errorMessage ?? V2AccountHealthPageData.loadFailed,
          onRetry: data.onRetry,
        );
      case V2AccountHealthStatus.empty:
        return _emptyState();
      case V2AccountHealthStatus.ready:
        return _content(context);
    }
  }

  Widget _emptyState() {
    return const OEmptyState(
      icon: Icons.account_circle_outlined,
      title: V2AccountHealthPageData.emptyTitle,
      message: V2AccountHealthPageData.emptyMessage,
    );
  }

  Widget _content(BuildContext context) {
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
                key: const ValueKey<String>('health-plan'),
                icon: Icons.workspace_premium_outlined,
                title: 'Plan',
                value: data.planText,
                onTap: data.onOpenPlans,
              ),
              _HealthRow(
                key: const ValueKey<String>('health-usage'),
                icon: Icons.insights_outlined,
                title: 'Today',
                value: data.todayText,
              ),
              _HealthRow(
                key: const ValueKey<String>('health-storage'),
                icon: Icons.cloud_outlined,
                title: 'Storage',
                value: data.storageText,
                onTap: data.onOpenStorage,
              ),
              _HealthRow(
                key: const ValueKey<String>('health-deletion'),
                icon: Icons.event_busy_outlined,
                title: 'Deletion',
                value: data.deletionText,
                onTap: data.canCancelDeletion
                    ? () => _confirmCancelDeletion(context)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One status line. The icon and the words carry the state; the whole line
  /// is a single semantics node so TalkBack announces it once.
  Widget _statusLine(BuildContext context) {
    final c = OColors.of(context);
    final healthy = data.isHealthy;
    return Semantics(
      container: true,
      label: 'Status: ${data.statusAnnouncement}',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: OSpace.xxs),
              child: Icon(
                healthy
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                size: 18,
                color: healthy ? c.success : c.warn,
              ),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                data.statusLabel,
                style: OType.bodySm.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirms with the real deletion service before anything is cancelled.
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
}

/// One fact: a 40 dp tile, a short label and its value on the same line.
///
/// The value is ellipsized rather than wrapped so a long size or date cannot
/// turn the row into a paragraph. An actionable row is a real button
/// (chevron, tap target, `button: true`); a row without a handler is static
/// and never announces an enabled state.
class _HealthRow extends StatelessWidget {
  const _HealthRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final actionable = onTap != null;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Row(
          children: [
            V2SettingsTile(icon: icon),
            const SizedBox(width: OSpace.m),
            Expanded(
              flex: 2,
              child: ExcludeSemantics(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Flexible(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: ExcludeSemantics(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ),
            ),
            if (actionable) ...[
              const SizedBox(width: OSpace.xs),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
            ],
          ],
        ),
      ),
    );

    // A dash is visual shorthand; spoken, the row says the value is unknown.
    final spokenValue = value == V2AccountHealthPageData.unknown
        ? 'unknown'
        : value;
    final label = '$title, $spokenValue';
    if (!actionable) return Semantics(label: label, child: content);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ORadius.m),
        child: Semantics(
          label: label,
          button: true,
          enabled: true,
          child: content,
        ),
      ),
    );
  }
}
