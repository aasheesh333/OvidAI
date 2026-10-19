import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cloud/cloud_issues.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/cloud_ws.dart';
import '../core/connection_service.dart';
import '../core/firebase_service.dart';
import '../core/ovid_cloud_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'billing_screen.dart';

/// Maps the Ovid Cloud mint/connection state onto the same issue kinds the
/// REST layer reports, so a failed login mint (SH-009) shows the same banner
/// as a failed chat call.
CloudIssue? issueFromConnection(CloudConnectionState state) {
  if (state.status != CloudConnectionStatus.failed) return null;
  final kind = switch (state.mintStatus) {
    MintStatus.freeLimitReached => CloudIssueKind.quota,
    MintStatus.sessionExpired || MintStatus.notSignedIn =>
      CloudIssueKind.signedOut,
    MintStatus.deviceUnverified => CloudIssueKind.unverified,
    MintStatus.unavailable => CloudIssueKind.unreachable,
    _ => null,
  };
  if (kind == null) return null;
  return CloudIssue(
    kind: kind,
    status: 0,
    code: 'mint_${state.mintStatus!.name}',
    message: state.error ?? '',
  );
}

/// Persistent, actionable shell-level strip for account-level cloud
/// failures: signed out / expired session (Sign in again), plan allowance
/// used up (View plans), Ovid Cloud unreachable (Retry) and attestation
/// failure (Retry). Driven by [CloudIssues.I] (every REST call, including
/// the WS ticket mint and create-on-first-send) plus the mint state of
/// [OvidCloudService]. It stays until the condition clears or the user acts.
class CloudIssueBanner extends StatelessWidget {
  const CloudIssueBanner({
    super.key,
    this.issues,
    this.mintIssue,
    this.mintSource,
    this.isOffline,
    this.onSignInAgain,
    this.onOpenPlans,
    this.onRetry,
  });

  /// Test seams; production defaults bind the app singletons.
  final CloudIssues? issues;
  final CloudIssue? Function()? mintIssue;
  final Listenable? mintSource;
  final bool Function()? isOffline;
  final Future<void> Function()? onSignInAgain;
  final Future<void> Function(BuildContext context)? onOpenPlans;
  final Future<void> Function()? onRetry;

  static CloudIssue? _defaultMintIssue() =>
      issueFromConnection(OvidCloudService.I.connectionFor(AppState.I));

  static Future<void> _defaultSignInAgain() async {
    // Signing out returns to the LoginGate's sign-in screen.
    await FirebaseService.I.signOut();
  }

  static Future<void> _defaultOpenPlans(BuildContext context) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const BillingScreen()),
      );

  static Future<void> _defaultRetry() async {
    unawaited(ConnectionService.I.probe());
    unawaited(WsMultiplexer.I.connectIfNeeded());
    unawaited(OvidCloudService.I.ensureConnected(force: true));
    // An authenticated read: success clears the issue, failure re-raises it.
    try {
      await CloudSessionStore.I.refreshSessions();
    } catch (_) {
      // Already reported to CloudIssues by the REST layer.
    }
    unawaited(CloudSessionStore.I.flushOutbox());
  }

  @override
  Widget build(BuildContext context) {
    final channel = issues ?? CloudIssues.I;
    final mint = mintIssue ?? _defaultMintIssue;
    final offline = isOffline ?? () => ConnectionService.I.offline;
    final sources = <Listenable>[
      channel,
      if (mintIssue == null) (mintSource ?? OvidCloudService.I),
      if (isOffline == null) ConnectionService.I,
    ];
    return AnimatedBuilder(
      animation: Listenable.merge(sources),
      builder: (context, _) {
        final fromRest = channel.value;
        final fromMint = mint();
        final CloudIssue? issue;
        if (fromRest == null) {
          issue = fromMint;
        } else if (fromMint == null) {
          issue = fromRest;
        } else {
          issue = fromMint.kind.index > fromRest.kind.index
              ? fromMint
              : fromRest;
        }
        if (issue == null) return const SizedBox.shrink();
        // The offline strip already explains "no network".
        if (issue.kind == CloudIssueKind.unreachable && offline()) {
          return const SizedBox.shrink();
        }
        return _IssueStrip(
          issue: issue,
          onAction: () async {
            channel.dismiss();
            switch (issue!.kind) {
              case CloudIssueKind.signedOut:
                await (onSignInAgain ?? _defaultSignInAgain)();
              case CloudIssueKind.quota:
                await (onOpenPlans ?? _defaultOpenPlans)(context);
              case CloudIssueKind.unreachable:
              case CloudIssueKind.unverified:
                await (onRetry ?? _defaultRetry)();
            }
          },
          onDismiss: issue.kind == CloudIssueKind.quota &&
                  identical(issue, fromRest)
              ? channel.dismiss
              : null,
        );
      },
    );
  }
}

class _IssueStrip extends StatelessWidget {
  const _IssueStrip({
    required this.issue,
    required this.onAction,
    this.onDismiss,
  });

  final CloudIssue issue;
  final Future<void> Function() onAction;
  final VoidCallback? onDismiss;

  static String _resets(DateTime? at) {
    if (at == null) return '';
    final local = at.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return ' It resets at $hh:$mm.';
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, text, action) = switch (issue.kind) {
      CloudIssueKind.signedOut => (
          Icons.lock_clock_outlined,
          Aether.danger,
          'Your session has expired. Sign in again to keep using Ovid.',
          'Sign in again',
        ),
      CloudIssueKind.quota => (
          Icons.hourglass_bottom_rounded,
          Aether.warn,
          "You've used your plan's allowance.${_resets(issue.resetsAt)}",
          'View plans',
        ),
      CloudIssueKind.unreachable => (
          Icons.cloud_off_outlined,
          Aether.warn,
          "Can't reach Ovid Cloud. Messages can't be sent right now.",
          'Retry',
        ),
      CloudIssueKind.unverified => (
          Icons.gpp_maybe_outlined,
          Aether.danger,
          "Ovid couldn't verify this copy of the app. Retry, or reinstall "
              'the latest version.',
          'Retry',
        ),
    };
    return SafeArea(
      bottom: false,
      child: Semantics(
        liveRegion: true,
        child: Material(
          key: const ValueKey('cloud-issue-banner'),
          color: color.withValues(alpha: 0.16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 12, height: 1.3),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(onAction()),
                  child: Text(action),
                ),
                if (onDismiss != null)
                  IconButton(
                    tooltip: 'Dismiss',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
