import '../state.dart';

/// Where a compaction may cut the transcript.
///
/// In Ovid's transcript a tool call and its result live on ONE tool-card
/// message, and the request replay flattens cards into assistant notes, so a
/// replayed request can never hold an orphaned `tool` result. What still
/// matters is not cutting INSIDE a turn's tool run:
///   * the retained tail must not start with a tool card whose issuing turn
///     was folded away
///   * a still-running tool card must never be folded
/// The preferred cut is a user-turn boundary: the tail then starts with the
/// user message that opened the turn, as in Claude Code.
abstract final class CompactionPolicy {
  /// Checkpoint size budget (tokens) for a model window: ~12% of the window,
  /// clamped. It is small enough that the checkpoint itself never re-triggers
  /// compaction, and large enough to hold the user's instructions verbatim.
  static int checkpointBudgetTokens(int window) =>
      (window * 0.12).round().clamp(2500, 24000);

  static bool _isTurnStart(Message m) =>
      m.role == 'user' && m.kind != MsgKind.tool && m.kind != MsgKind.compact;

  static bool _safeAt(List<Message> msgs, int c) {
    if (c <= 0 || c >= msgs.length) return true;
    final m = msgs[c];
    final prev = msgs[c - 1];
    if (m.kind == MsgKind.tool) return false;
    if (prev.kind == MsgKind.tool && prev.toolState == 'running') return false;
    return true;
  }

  /// True when cutting at [cutoff] (folding `[.., cutoff)`) would separate a
  /// tool card from its turn, or fold a running tool.
  static bool splitsToolRun(List<Message> msgs, int cutoff) =>
      !_safeAt(msgs, cutoff);

  /// Move a proposed [cutoff] to a safe boundary in `(from, msgs.length]`.
  /// It prefers a user-turn start that keeps at least half of the intended
  /// fold, then any non-tool boundary at or before [cutoff], then the
  /// nearest safe boundary after it. It returns [from] (fold nothing) when
  /// there is no safe cut.
  static int snapCutoff(
    List<Message> msgs,
    int from,
    int cutoff, {
    int minFold = 1,
  }) {
    if (cutoff >= msgs.length) return msgs.length;
    if (cutoff - from < minFold) return cutoff;
    final intended = cutoff - from;
    final floor = from + (intended / 2).ceil().clamp(minFold, intended);
    for (var c = cutoff; c >= floor; c--) {
      if (_isTurnStart(msgs[c]) && _safeAt(msgs, c)) return c;
    }
    for (var c = cutoff; c >= from + minFold; c--) {
      if (_safeAt(msgs, c)) return c;
    }
    for (var c = cutoff + 1; c < msgs.length; c++) {
      if (_safeAt(msgs, c)) return c;
    }
    return from;
  }
}
