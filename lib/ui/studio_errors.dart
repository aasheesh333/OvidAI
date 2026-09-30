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
    return StudioFailure(_messageFor(raw), _firstLine(raw));
  }

  /// Convenience for the many places that only have a snackbar to work with.
  static String messageOf(Object error) => StudioFailure.of(error).message;

  static String _firstLine(String raw) {
    final line = raw.split('\n').first.trim();
    return line.isEmpty ? raw.trim() : line;
  }

  static String _messageFor(String raw) {
    final s = raw.toLowerCase();
    bool has(String needle) => s.contains(needle);

    // Order matters: the more specific root cause wins. A clone that died on
    // DNS should read as a connection problem, not a generic clone failure.
    if (has('repo not bound') || has('no repository')) {
      return 'Connect a repository in Studio first.';
    }
    if (has('repository binding changed')) {
      return 'Studio switched repository while that was running. Try again.';
    }
    if (has('401') || has('403') || has('bad credentials') ||
        has('requires authentication')) {
      return 'GitHub rejected your sign-in. Please sign in to GitHub again.';
    }
    if (has('socketexception') ||
        has('failed host lookup') ||
        has('network is unreachable') ||
        has('connection refused') ||
        has('connection reset') ||
        has('no address associated') ||
        has('clientexception') ||
        has('network')) {
      return 'Ovid could not reach GitHub. Check your connection and try '
          'again.';
    }
    if (has('timeoutexception') || has('timed out') || has('timeout')) {
      return 'GitHub took too long to respond. Try again in a moment.';
    }
    if (has('404') || has('not found') || has('no such')) {
      return 'GitHub could not find that repository, branch or file.';
    }
    if (has('git clone') || has('clone')) {
      return 'The working copy could not be cloned. Check the repository and '
          'try again.';
    }
    if (has('permission denied') || has('read-only') || has('readonly')) {
      return 'Ovid is not allowed to write there. Grant All Files Access or '
          'pick another folder.';
    }
    if (has('sandbox not installed') || has('linux sandbox')) {
      return 'The Linux sandbox is not installed. Open Studio once to install '
          'it, then try again.';
    }
    return 'Something went wrong. The details are below.';
  }
}
