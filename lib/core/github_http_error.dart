import 'package:http/http.dart' as http;

/// A GitHub REST call answered with a non-success HTTP status.
///
/// Typed so user-facing copy can classify by [status] instead of hunting for
/// "401"/"403"/"404" substrings in a message (which matched commit SHAs, line
/// numbers and paths, and sent rate-limited users to sign in again).
class GitHubHttpException implements Exception {
  const GitHubHttpException(
    this.operation,
    this.status, {
    this.rateLimited = false,
    this.rateLimitReset,
    this.githubMessage,
    this.note,
  });

  /// Builds the exception from a response, detecting GitHub's rate limits:
  /// HTTP 429, or 403 with `X-RateLimit-Remaining: 0`, `Retry-After` or a
  /// "rate limit" message in the body.
  factory GitHubHttpException.fromResponse(
    String operation,
    http.Response res, {
    String? note,
  }) {
    final headers = res.headers;
    String? message;
    try {
      final m = RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(res.body);
      message = m?.group(1);
    } catch (_) {
      message = null;
    }
    final body = res.body.toLowerCase();
    final rateLimited =
        res.statusCode == 429 ||
        (res.statusCode == 403 &&
            (headers['x-ratelimit-remaining']?.trim() == '0' ||
                headers.containsKey('retry-after') ||
                body.contains('rate limit')));
    DateTime? reset;
    final resetEpoch = int.tryParse(headers['x-ratelimit-reset']?.trim() ?? '');
    if (resetEpoch != null) {
      reset = DateTime.fromMillisecondsSinceEpoch(resetEpoch * 1000);
    } else {
      final after = int.tryParse(headers['retry-after']?.trim() ?? '');
      if (after != null) reset = DateTime.now().add(Duration(seconds: after));
    }
    return GitHubHttpException(
      operation,
      res.statusCode,
      rateLimited: rateLimited,
      rateLimitReset: rateLimited ? reset : null,
      githubMessage: message,
      note: note,
    );
  }

  /// What was being attempted, e.g. "repos fetch".
  final String operation;
  final int status;

  /// GitHub's primary or secondary rate limit (not a permission problem).
  final bool rateLimited;

  /// When the rate limit resets, if GitHub said.
  final DateTime? rateLimitReset;

  /// GitHub's own `message` field, when the body carried one.
  final String? githubMessage;

  /// Extra developer context appended to [toString] (never user copy).
  final String? note;

  bool get unauthorized => status == 401;
  bool get forbidden => status == 403 && !rateLimited;
  bool get notFound => status == 404;
  bool get conflict => status == 409 || status == 422;
  bool get server => status >= 500;

  @override
  String toString() =>
      '$operation failed: HTTP $status'
      '${githubMessage == null || githubMessage!.isEmpty ? '' : ' ($githubMessage)'}'
      '${note == null ? '' : ' — $note'}';
}
