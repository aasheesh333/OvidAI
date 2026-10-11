import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/github_http_error.dart';
import '../core/github_service.dart';
import '../core/repo_cache.dart';

/// Human-readable failure copy for Studio.
///
/// Studio used to interpolate raw exceptions straight into user-facing
/// toasts and banners ("Repo sync failed: Exception: tree fetch 404"), which
/// leaks HTTP status codes, Dart type names and git stderr at people who
/// cannot act on any of it (2026-09-30 audit).
///
/// The rule this enforces: the [message] is what a person reads, the [detail]
/// is the original first line, shown only in a visually secondary line (and
/// available to logs/support). Never put [detail] in a headline.
class StudioFailure {
  const StudioFailure(this.message, this.detail);

  /// One sentence, no infra vocabulary, always ends in a period.
  final String message;

  /// The raw error's first line — stack frames and continuation lines are
  /// dropped so a banner cannot grow past the screen.
  final String detail;

  factory StudioFailure.of(Object error) {
    final raw = error.toString();
    return StudioFailure(
      _typedMessage(error) ?? _messageFor(raw),
      _firstLine(raw),
    );
  }

  /// Convenience for the many places that only have a snackbar to work with.
  static String messageOf(Object error) => StudioFailure.of(error).message;

  static String _firstLine(String raw) {
    final line = raw.split('\n').first.trim();
    return redact(line.isEmpty ? raw.trim() : line);
  }

  static final RegExp _tokenPattern = RegExp(
    r'\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)',
  );
  static final RegExp _userinfoPattern = RegExp(r'//[^/\s:@]+:[^/\s@]+@');

  /// Strips GitHub tokens and `user:secret@` URL credentials: the detail line
  /// is shown in banners/toasts and is what users screenshot for support.
  static String redact(String text) => text
      .replaceAll(_tokenPattern, '[redacted]')
      .replaceAll(_userinfoPattern, '//[redacted]@');

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String rateLimitMessage(DateTime? reset) {
    if (reset == null) {
      return "GitHub's request limit is reached. Try again in a few minutes.";
    }
    final local = reset.toLocal();
    return "GitHub's request limit is reached. Try again after "
        '${_two(local.hour)}:${_two(local.minute)}.';
  }

  /// Typed errors first: their class says what failed, so no guessing from
  /// digits in a message (a SHA like `a403f1c` is not an HTTP 403).
  static String? _typedMessage(Object error) {
    if (error is CommitFailure) return commitMessage(error);
    if (error is GitHubHttpException) return _httpMessage(error);
    if (error is GitHubAuthException) {
      return switch (error.code) {
        'invalid_token' || 'not_authenticated' =>
          'GitHub rejected your sign-in. Please sign in to GitHub again.',
        _ => error.message.endsWith('.') ? error.message : '${error.message}.',
      };
    }
    if (error is FetchFailure) return _fetchMessage(error);
    if (error is FileSystemException) return _fsMessage(error);
    if (error is ProcessException) {
      return 'A command in the Linux sandbox could not start. Reinstall the '
          'sandbox from Settings if this keeps happening.';
    }
    if (error is SocketException ||
        error is http.ClientException ||
        error is HandshakeException) {
      return 'Ovid could not connect. Check your connection and try again.';
    }
    if (error is TimeoutException) {
      return 'That took too long. Check your connection and try again.';
    }
    return null;
  }

  /// Copy for a failed commit, by [CommitFailure.kind].
  static String commitMessage(CommitFailure f) => switch (f.kind) {
    CommitFailureKind.staleApproval =>
      'Your files changed after you reviewed them. Review the changes again '
          'before committing.',
    CommitFailureKind.upstreamConflict =>
      'The branch moved on GitHub while you were committing. Sync to get the '
          'latest changes, then review and commit again.',
    CommitFailureKind.unknown =>
      'GitHub did not confirm the commit. Check the branch on GitHub before '
          'retrying — your edits are kept.',
    CommitFailureKind.persistence =>
      'Ovid could not save the commit state on this device. Free some storage '
          'and try again.',
    CommitFailureKind.busy =>
      'A commit for this branch is already in progress. Wait for it to '
          'finish.',
    CommitFailureKind.unsupported =>
      'Studio cannot commit one of these files (unsupported file type or '
          'mode).',
  };

  static String _httpMessage(GitHubHttpException e) {
    if (e.rateLimited) return rateLimitMessage(e.rateLimitReset);
    final ghMessage = (e.githubMessage ?? '').toLowerCase();
    if (ghMessage.contains('saml')) {
      return 'Your organization requires single sign-on for this repository. '
          'Authorize Ovid for the organization on GitHub, then retry.';
    }
    if (e.unauthorized) {
      return 'GitHub rejected your sign-in. Please sign in to GitHub again.';
    }
    if (e.forbidden) {
      return 'GitHub refused access to this repository. Check that your '
          'account has permission, or sign in again.';
    }
    if (e.notFound) {
      return 'GitHub could not find that repository, branch or file.';
    }
    if (e.conflict) {
      return 'GitHub rejected the change because the branch changed. Sync '
          'and try again.';
    }
    if (e.server) {
      return 'GitHub is having trouble right now. Try again in a moment.';
    }
    return 'GitHub could not complete the request. Try again.';
  }

  static String _fetchMessage(FetchFailure f) => switch (f) {
    FetchFailure.notBound => 'Connect a repository in Studio first.',
    FetchFailure.noToken => 'Sign in to GitHub first.',
    FetchFailure.unauthorized =>
      'GitHub rejected your sign-in. Please sign in to GitHub again.',
    FetchFailure.forbidden =>
      'GitHub refused access to this repository. Check that your account has '
          'permission, or sign in again.',
    FetchFailure.notFound =>
      'GitHub could not find that repository, branch or file.',
    FetchFailure.server =>
      'GitHub is having trouble right now. Try again in a moment.',
    FetchFailure.timeout =>
      'GitHub took too long to respond. Try again in a moment.',
    FetchFailure.network =>
      'Ovid could not reach GitHub. Check your connection and try again.',
    FetchFailure.none ||
    FetchFailure.unknown => 'Something went wrong. The details are below.',
  };

  static String _fsMessage(FileSystemException e) {
    final code = e.osError?.errorCode;
    final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (code == 28 || text.contains('no space left')) {
      return 'This device is out of storage. Free some space and try again.';
    }
    if (code == 2 || text.contains('no such file')) {
      return 'That file or folder no longer exists on this device.';
    }
    if (code == 13 ||
        code == 1 ||
        code == 30 ||
        text.contains('permission denied') ||
        text.contains('read-only')) {
      return 'Ovid is not allowed to write there. Grant All Files Access or '
          'pick another folder.';
    }
    return 'Ovid could not read or write a file on this device.';
  }

  /// An HTTP status only counts when it is labelled as one ("HTTP 403",
  /// "status 404", "failed: 401", "(403)", "fetch 404") — never bare digits
  /// inside a SHA, path, port or line number.
  static final RegExp _statusPattern = RegExp(
    r'(?:\b(?:http|status|code|fetch|failed|error)\b[:\s]*\(?|\()([1-5]\d\d)\b',
  );

  static String _messageFor(String raw) {
    final s = raw.toLowerCase();
    bool has(String needle) => s.contains(needle);
    final statusMatch = _statusPattern.firstMatch(s);
    final status = statusMatch == null
        ? null
        : int.tryParse(statusMatch.group(1)!);

    // Order matters: the more specific root cause wins, and local
    // (file-system / sandbox) causes are checked before anything is blamed
    // on GitHub.
    if (has('repo not bound') || has('no repository')) {
      return 'Connect a repository in Studio first.';
    }
    if (has('repository binding changed')) {
      return 'Studio switched repository while that was running. Try again.';
    }
    if (has('no space left') || has('errno = 28') || has('enospc')) {
      return 'This device is out of storage. Free some space and try again.';
    }
    if (has('sandbox not installed') || has('linux sandbox')) {
      return 'The Linux sandbox is not installed. Open Studio once to install '
          'it, then try again.';
    }
    if (has('no such file or directory') || has('errno = 2,')) {
      return 'That file or folder no longer exists on this device.';
    }
    if (has('permission denied') || has('read-only') || has('readonly')) {
      return 'Ovid is not allowed to write there. Grant All Files Access or '
          'pick another folder.';
    }
    if (has('pty command timed out') || has('command timed out')) {
      return 'The command took too long and was stopped.';
    }
    if (has('rate limit')) return rateLimitMessage(null);
    if (has('saml')) {
      return 'Your organization requires single sign-on for this repository. '
          'Authorize Ovid for the organization on GitHub, then retry.';
    }
    if (status == 401 ||
        has('bad credentials') ||
        has('requires authentication')) {
      return 'GitHub rejected your sign-in. Please sign in to GitHub again.';
    }
    if (status == 403) {
      return 'GitHub refused access to this repository. Check that your '
          'account has permission, or sign in again.';
    }
    if (has('socketexception') ||
        has('failed host lookup') ||
        has('network is unreachable') ||
        has('connection refused') ||
        has('connection reset') ||
        has('no address associated') ||
        has('clientexception')) {
      return 'Ovid could not connect. Check your connection and try again.';
    }
    if (has('timeoutexception') || has('timed out')) {
      return 'That took too long. Check your connection and try again.';
    }
    if (status == 404) {
      return 'GitHub could not find that repository, branch or file.';
    }
    if (status != null && status >= 500) {
      return 'GitHub is having trouble right now. Try again in a moment.';
    }
    if (has('git clone') || RegExp(r'\bclone\b').hasMatch(s)) {
      return 'The working copy could not be cloned. Check the repository and '
          'try again.';
    }
    return 'Something went wrong. The details are below.';
  }
}
