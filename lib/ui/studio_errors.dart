import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/cloud/cloud_rest.dart';
import '../core/github_service.dart';

/// Human-readable failure copy for Studio.
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

  /// Typed errors first: their class says what failed, so no guessing from
  /// digits in a message (a SHA like `a403f1c` is not an HTTP 403).
  static String? _typedMessage(Object error) {
    if (error is CloudApiException) return _cloudMessage(error);
    if (error is GitHubAuthException) {
      return switch (error.code) {
        'invalid_token' || 'not_authenticated' =>
          'GitHub rejected your sign-in. Please sign in to GitHub again.',
        'device_request_failed' =>
          'GitHub sign-in could not start. Try again in a moment.',
        'token_request_failed' =>
          'GitHub sign-in could not be completed. Try again.',
        _ => error.message.endsWith('.') ? error.message : '${error.message}.',
      };
    }
    if (error is FileSystemException) {
      return 'Ovid could not read or write that file.';
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

  /// Copy for the gateway's error envelope (P7 workspace routes).
  static String _cloudMessage(CloudApiException e) {
    switch (e.code) {
      case 'baseline_mismatch':
        return 'This file changed on the server. Your draft has been kept — '
            'resolve the conflict to continue.';
      case 'hydrating':
        return 'The cloud workspace is still warming up. Try again shortly.';
      case 'file_too_large':
        return 'That file is too large to edit in Studio.';
      case 'not_found':
        return 'That file no longer exists in the workspace.';
      case 'unavailable':
      case 'file_service_not_configured':
        return 'The cloud workspace is temporarily unavailable. Try again.';
      case 'timeout':
        return 'That took too long. Check your connection and try again.';
      case 'unauthenticated':
        return 'Sign in to use Ovid Cloud.';
    }
    if (e.status == 401) {
      return 'Your Ovid Cloud session expired. Sign in again.';
    }
    if (e.status == 404) {
      return 'That file no longer exists in the workspace.';
    }
    if (e.status >= 500) {
      return 'Ovid Cloud is having trouble right now. Try again in a moment.';
    }
    return 'Something went wrong. The details are below.';
  }

  static String _messageFor(String raw) {
    final s = raw.toLowerCase();
    bool has(String needle) => s.contains(needle);

    if (has('no space left') || has('errno = 28') || has('enospc')) {
      return 'This device is out of storage. Free some space and try again.';
    }
    if (has('permission denied') || has('read-only') || has('readonly')) {
      return 'Ovid is not allowed to write there.';
    }
    if (has('socketexception') ||
        has('failed host lookup') ||
        has('network is unreachable') ||
        has('connection refused') ||
        has('connection reset') ||
        has('clientexception')) {
      return 'Ovid could not connect. Check your connection and try again.';
    }
    if (has('timeoutexception') || has('timed out')) {
      return 'That took too long. Check your connection and try again.';
    }
    return 'Something went wrong. The details are below.';
  }
}
