import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';

/// What kind of account-level cloud problem the shell should explain.
/// Ordered by priority: a higher index outranks a lower one.
enum CloudIssueKind {
  /// Ovid Cloud cannot be reached (DNS, refused, TLS, timeout, gateway 5xx).
  /// Action: retry.
  unreachable,

  /// App Check is enabled for this build and attestation failed (or the
  /// server demanded it). Action: retry.
  unverified,

  /// The plan allowance is used up (HTTP 402). Action: open Plans.
  quota,

  /// The Firebase session is missing/expired (HTTP 401 after the forced
  /// token refresh, or no ID token at all). Action: sign in again.
  signedOut,
}

/// One shell-visible cloud problem, derived from a [CloudApiException].
@immutable
class CloudIssue {
  const CloudIssue({
    required this.kind,
    required this.status,
    required this.code,
    required this.message,
    this.resetsAt,
  });

  final CloudIssueKind kind;

  /// HTTP status (0 = no HTTP answer), as on [CloudApiException.status].
  final int status;

  /// Server envelope code, as on [CloudApiException.code].
  final String code;

  /// Server (or client-mapped) message.
  final String message;

  /// When a quota resets (`x-ovid-resets-at`), if the server said.
  final DateTime? resetsAt;

  /// Maps a typed cloud error to a shell issue, or null when the error
  /// belongs to the calling screen (400/403 forbidden/404/409/429...).
  static CloudIssue? classify(CloudApiException e) {
    final CloudIssueKind? kind;
    if (e.status == 401 || e.code == 'unauthenticated') {
      kind = CloudIssueKind.signedOut;
    } else if (e.status == 402) {
      kind = CloudIssueKind.quota;
    } else if (e.code == 'app_check_unavailable' ||
        (e.status == 403 && e.code.startsWith('app_check'))) {
      kind = CloudIssueKind.unverified;
    } else if (e.status == 0 ||
        e.status == 502 ||
        e.status == 503 ||
        e.status == 504) {
      kind = CloudIssueKind.unreachable;
    } else {
      kind = null;
    }
    if (kind == null) return null;
    return CloudIssue(
      kind: kind,
      status: e.status,
      code: e.code,
      message: e.message,
      resetsAt: e.resetsAt,
    );
  }

  @override
  String toString() => 'CloudIssue(${kind.name}, $status $code: $message)';
}

/// The cloud layer's account-level failure channel.
///
/// [CloudRestClient] reports every authenticated call here (the WS ticket
/// mint, session create-on-first-send and every REST route go through it),
/// so the shell banner sees signed-out, quota, attestation and
/// unreachable failures no matter which screen made the call. Per-message
/// errors are still recorded on the chat facade for the chat row.
///
/// Listen to [CloudIssues.I] (a [ValueListenable]) to render it.
class CloudIssues extends ValueNotifier<CloudIssue?> {
  CloudIssues() : super(null);

  /// The process-wide channel used by [CloudRestClient.I].
  static final CloudIssues I = CloudIssues();

  /// Records [e] if it is an account-level issue. A lower-priority issue
  /// never replaces a higher-priority one that is still showing (a timeout
  /// must not hide "sign in again").
  void reportFailure(CloudApiException e) {
    final issue = CloudIssue.classify(e);
    if (issue == null) return;
    final current = value;
    if (current != null && current.kind.index > issue.kind.index) return;
    value = issue;
  }

  /// A call succeeded. Clears session, attestation and transport issues; a
  /// quota issue clears only when a [billable] call (a POST) succeeds, since
  /// a successful read says nothing about the allowance.
  void reportSuccess({bool billable = false}) {
    final current = value;
    if (current == null) return;
    if (current.kind == CloudIssueKind.quota && !billable) return;
    value = null;
  }

  /// The user acted on (or closed) the banner.
  void dismiss() => value = null;
}
