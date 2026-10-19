import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/studio_files.dart';

/// Human-readable failure copy for Studio.
///
/// The rule this enforces: [message] is what a person reads. [detail] is the
/// original first line, redacted, for logs and support only — Studio never
/// renders it (ST-009: raw `CloudApiException: 404 not_found: …` text used to
/// reach users through toasts and banners).
class StudioFailure {
  const StudioFailure(this.message, this.detail);

  /// One sentence, no infra vocabulary, always ends in a period.
  final String message;

  /// The raw error's first line — stack frames and continuation lines are
  /// dropped. Diagnostics only; not user copy.
  final String detail;

  factory StudioFailure.of(Object error) {
    final raw = error.toString();
    return StudioFailure(
      _typedMessage(error) ?? _messageFor(raw),
      _firstLine(raw),
    );
  }

  /// Copy for a failed workspace TREE load (ST-009). The subject is the
  /// workspace, never "that file".
  factory StudioFailure.forTree(Object error) {
    final raw = error.toString();
    return StudioFailure(_treeMessage(error), _firstLine(raw));
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

  /// Strips GitHub tokens and `user:secret@` URL credentials from diagnostics.
  static String redact(String text) => text
      .replaceAll(_tokenPattern, '[redacted]')
      .replaceAll(_userinfoPattern, '//[redacted]@');

  static bool _offline(Object error) =>
      error is SocketException ||
      error is http.ClientException ||
      error is HandshakeException ||
      (error is CloudApiException && error.status == 0 && error.code != 'timeout');

  static String _treeMessage(Object error) {
    if (error is StudioNoWorkspaceException) {
      return 'Your cloud workspace is created the first time Ovid works on '
          'something for you. Send a message in any chat, then come back.';
    }
    if (_offline(error)) {
      return 'You are offline. Check your connection and try again.';
    }
    if (error is TimeoutException ||
        (error is CloudApiException && error.code == 'timeout')) {
      return 'Ovid Cloud did not answer in time. Try again.';
    }
    if (error is CloudApiException) {
      if (error.code == 'unauthenticated' || error.status == 401) {
        return 'Sign in to use Studio.';
      }
      if (error.code == 'app_check_unavailable') {
        return 'Ovid could not verify this app with the cloud. Update Ovid '
            'or try again later.';
      }
      if (error.status == 404) {
        return 'This chat has no cloud workspace yet.';
      }
      if (error.status >= 500 || error.code == 'unavailable') {
        return 'Your cloud workspace is temporarily unavailable. Try again '
            'in a moment.';
      }
    }
    return 'Studio could not load your files. Try again.';
  }

  /// Typed errors first: their class says what failed, so no guessing from
  /// digits in a message (a SHA like `a403f1c` is not an HTTP 403).
  static String? _typedMessage(Object error) {
    if (error is CloudApiException) return _cloudMessage(error);
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
        return 'This file changed in the workspace. Your draft has been '
            'kept — choose which version to keep.';
      case 'already_exists':
        return 'Something with that name already exists in the workspace.';
      case 'not_empty':
        return 'That folder is not empty.';
      case 'hydrating':
        return 'Your workspace is waking up. Studio will save automatically '
            'when it is ready.';
      case 'not_warm':
        return 'Your workspace is waking up. Try again in a moment.';
      case 'no_workspace':
        return 'Your cloud workspace does not exist yet. Send a message in '
            'any chat first.';
      case 'file_too_large':
        return 'That file is too large to edit in Studio.';
      case 'bad_request':
        return 'That name cannot be used in the workspace.';
      case 'not_found':
        return 'That file is no longer in the workspace.';
      case 'unavailable':
      case 'file_service_not_configured':
        return 'Your cloud workspace is temporarily unavailable. Try again.';
      case 'timeout':
        return 'That took too long. Check your connection and try again.';
      case 'unauthenticated':
        return 'Sign in to use Studio.';
    }
    if (e.status == 0) {
      return 'Ovid could not connect. Check your connection and try again.';
    }
    if (e.status == 401) {
      return 'Your Ovid session expired. Sign in again.';
    }
    if (e.status == 404) {
      return 'That file is no longer in the workspace.';
    }
    if (e.status >= 500) {
      return 'Ovid Cloud is having trouble right now. Try again in a moment.';
    }
    return 'Something went wrong. Try again.';
  }

  static String _messageFor(String raw) {
    final s = raw.toLowerCase();
    bool has(String needle) => s.contains(needle);

    if (has('no space left') || has('errno = 28') || has('enospc')) {
      return 'This device is out of storage. Free some space and try again.';
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
    return 'Something went wrong. Try again.';
  }
}
