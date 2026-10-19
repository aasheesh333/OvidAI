import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/cloud/cloud_rest.dart';
import '../core/diag.dart';
import '../l10n/l10n.dart';

/// Coarse cause of a failure, independent of wording. Screens with more
/// specific copy (e.g. "Key rejected by provider") switch on this instead of
/// parsing exception text themselves.
enum UserErrorKind {
  offline,
  timeout,
  unauthorized,
  forbidden,
  notFound,
  rateLimited,
  quotaExceeded,
  server,
  badResponse,
  device,
  file,
  notNow,
  unknown,
}

/// An HTTP response that was not a success, carrying the status so callers
/// can throw a typed failure instead of a `'HTTP 401 …'` string.
class HttpStatusException implements Exception {
  const HttpStatusException(this.statusCode, {this.body = ''});

  final int statusCode;
  final String body;

  @override
  String toString() => 'HTTP $statusCode';
}

/// User-facing interpretation of an exception.
///
/// The rule: [message] is what a person reads — one or two plain sentences,
/// never a Dart type name, `Bad state:`/`Exception:` prefix or stack frame.
/// [detail] is the cleaned first line of the original error; show it only
/// behind a "Details" disclosure (see `ErrorDetails`). The full error and
/// stack go to [Diag] when a `log` tag is supplied.
class UserError {
  const UserError(this.kind, this.message, {this.detail = '', this.statusCode});

  final UserErrorKind kind;
  final String message;
  final String detail;
  final int? statusCode;

  factory UserError.from(
    Object error, {
    AppLocalizations? l10n,
    StackTrace? stack,
    String? log,
  }) {
    if (log != null) Diag.swallow(log, error, stack);
    final status = statusOf(error);
    final kind = status != null ? kindForStatus(status) : kindOf(error);
    return UserError(
      kind,
      messageFor(kind, l10n ?? appLocalizationsFallback),
      detail: detailOf(error),
      statusCode: status,
    );
  }

  factory UserError.fromHttpStatus(int status, {AppLocalizations? l10n}) {
    final kind = kindForStatus(status);
    return UserError(
      kind,
      messageFor(kind, l10n ?? appLocalizationsFallback),
      detail: 'HTTP $status',
      statusCode: status,
    );
  }

  /// HTTP status carried by [error] — typed ([HttpStatusException],
  /// [CloudApiException]) or embedded as `HTTP nnn`.
  static int? statusOf(Object error) {
    if (error is CloudApiException) return error.status;
    if (error is HttpStatusException) return error.statusCode;
    final match = RegExp(r'\bHTTP (\d{3})\b').firstMatch('$error');
    return match == null ? null : int.parse(match.group(1)!);
  }

  static UserErrorKind kindForStatus(int status) {
    // 0 is not an HTTP status: CloudRestClient uses it for a request that
    // timed out before any answer arrived (`CloudApiException(0, 'timeout')`).
    if (status == 0) return UserErrorKind.timeout;
    if (status == 401) return UserErrorKind.unauthorized;
    if (status == 402) return UserErrorKind.quotaExceeded;
    if (status == 403) return UserErrorKind.forbidden;
    if (status == 404 || status == 410) return UserErrorKind.notFound;
    if (status == 408) return UserErrorKind.timeout;
    if (status == 429) return UserErrorKind.rateLimited;
    if (status >= 500 && status < 600) return UserErrorKind.server;
    return UserErrorKind.unknown;
  }

  static UserErrorKind kindOf(Object error) {
    if (error is TimeoutException) return UserErrorKind.timeout;
    if (error is SocketException ||
        error is HandshakeException ||
        error is http.ClientException) {
      return UserErrorKind.offline;
    }
    if (error is PlatformException || error is MissingPluginException) {
      return UserErrorKind.device;
    }
    if (error is FileSystemException) return UserErrorKind.file;
    if (error is FormatException ||
        error is TypeError ||
        error is HttpException) {
      return UserErrorKind.badResponse;
    }
    if (error is StateError || error is UnsupportedError) {
      return UserErrorKind.notNow;
    }
    final s = '$error'.toLowerCase();
    if (s.contains('timed out') || s.contains('timeout')) {
      return UserErrorKind.timeout;
    }
    if (s.contains('socketexception') ||
        s.contains('failed host lookup') ||
        s.contains('connection refused') ||
        s.contains('network is unreachable')) {
      return UserErrorKind.offline;
    }
    return UserErrorKind.unknown;
  }

  static String messageFor(UserErrorKind kind, AppLocalizations l) =>
      switch (kind) {
        UserErrorKind.offline => l.errorOffline,
        UserErrorKind.timeout => l.errorTimeout,
        UserErrorKind.unauthorized => l.errorUnauthorized,
        UserErrorKind.forbidden => l.errorForbidden,
        UserErrorKind.notFound => l.errorNotFound,
        UserErrorKind.rateLimited => l.errorRateLimited,
        UserErrorKind.quotaExceeded => l.errorQuotaExceeded,
        UserErrorKind.server => l.errorServer,
        UserErrorKind.badResponse => l.errorBadResponse,
        UserErrorKind.device => l.errorDevice,
        UserErrorKind.file => l.errorFile,
        UserErrorKind.notNow => l.errorNotNow,
        UserErrorKind.unknown => l.errorGeneric,
      };

  static final RegExp _typePrefix = RegExp(
    r'^(?:Bad state|Exception|FormatException|StateError|Unsupported operation|'
    r'Invalid argument\(s\)|PlatformException|ClientException|'
    r'SocketException|TimeoutException|FileSystemException|'
    r'[A-Z][A-Za-z]*(?:Exception|Error))\s*:?\s*',
  );

  /// First line of [error] without Dart type prefixes, capped for display.
  /// A [CloudApiException] contributes its server-written message — the
  /// error envelope's human sentence — not the `CloudApiException: 402 …`
  /// toString form.
  static String detailOf(Object error) {
    if (error is CloudApiException) return _capDetail(error.message);
    var line = '$error'
        .split('\n')
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    for (var i = 0; i < 3; i++) {
      final stripped = line.replaceFirst(_typePrefix, '');
      if (stripped == line) break;
      line = stripped;
    }
    return _capDetail(line);
  }

  static String _capDetail(String line) =>
      line.length > 300 ? '${line.substring(0, 300)}…' : line;
}

/// Shorthand for the common snackbar case: the friendly sentence only.
String friendlyError(
  Object error, {
  AppLocalizations? l10n,
  StackTrace? stack,
  String? log,
}) => UserError.from(error, l10n: l10n, stack: stack, log: log).message;
