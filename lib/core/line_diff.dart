/// Line-based unified diff (Myers' O(ND) algorithm) for commit review.
///
/// The commit review used to print every old line as `-` and every new line
/// as `+`, so a one-line change in a 2 000-line file showed 4 000 lines and
/// the reviewer could not see what actually changed. This produces real
/// unified hunks with [defaultContext] lines of context.
library;

/// Default number of unchanged context lines around each change.
const int defaultContext = 3;

/// Beyond this edit distance the minimal diff is not worth its cost (Myers'
/// trace is O(D²) memory); the file is shown as one whole-file hunk, which
/// is still a correct — just not minimal — diff.
const int maxEditDistance = 4000;

/// One line of a hunk: ' ' context, '-' removed, '+' added, or '\' for the
/// "No newline at end of file" marker that follows the line it describes.
typedef DiffLine = ({String kind, String text});

/// A unified-diff hunk.
class DiffHunk {
  const DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final int oldStart, oldCount, newStart, newCount;
  final List<DiffLine> lines;

  String get header => '@@ -$oldStart,$oldCount +$newStart,$newCount @@';
}

const String _noEol = '\u0000<no-eol>';

/// Splits [text] into lines; the last line of a text without a trailing
/// newline carries an internal marker so "x" and "x\n" compare different.
List<String> diffLinesOf(String? text) {
  if (text == null || text.isEmpty) return const [];
  final parts = text.split('\n');
  if (parts.last.isEmpty) {
    parts.removeLast();
  } else {
    parts[parts.length - 1] = '${parts.last}$_noEol';
  }
  return parts;
}

/// Unified hunks turning [before] into [after].
List<DiffHunk> unifiedHunks(
  String? before,
  String? after, {
  int context = defaultContext,
}) {
  final a = diffLinesOf(before), b = diffLinesOf(after);
  final ops = _diffOps(a, b);
  return _group(ops, a, b, context);
}

/// Renders hunks as unified-diff text lines (header + body).
Iterable<String> renderHunks(List<DiffHunk> hunks) sync* {
  for (final h in hunks) {
    yield h.header;
    for (final l in h.lines) {
      yield l.kind == r'\' ? l.text : '${l.kind}${l.text}';
    }
  }
}

// Edit script entries: 0 = equal, -1 = delete (from a), 1 = insert (from b).
typedef _Op = ({int kind, int ai, int bi});

List<_Op> _diffOps(List<String> a, List<String> b) {
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final ops = <_Op>[for (var i = 0; i < prefix; i++) (kind: 0, ai: i, bi: i)];
  final aMid = a.sublist(prefix, a.length - suffix);
  final bMid = b.sublist(prefix, b.length - suffix);
  final mid = _myers(aMid, bMid);
  if (mid == null) {
    for (var i = 0; i < aMid.length; i++) {
      ops.add((kind: -1, ai: prefix + i, bi: prefix));
    }
    for (var j = 0; j < bMid.length; j++) {
      ops.add((kind: 1, ai: prefix + aMid.length, bi: prefix + j));
    }
  } else {
    for (final op in mid) {
      ops.add((kind: op.kind, ai: op.ai + prefix, bi: op.bi + prefix));
    }
  }
  for (var k = suffix; k > 0; k--) {
    ops.add((kind: 0, ai: a.length - k, bi: b.length - k));
  }
  return ops;
}

/// Myers' greedy algorithm with a stored trace for backtracking. Returns
/// null when the edit distance exceeds [maxEditDistance].
List<_Op>? _myers(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  if (n == 0 && m == 0) return const [];
  final max = n + m;
  final limit = max < maxEditDistance ? max : maxEditDistance;
  final offset = limit + 1;
  final v = List<int>.filled(2 * limit + 3, 0);
  final trace = <List<int>>[];
  for (var d = 0; d <= limit; d++) {
    trace.add(List<int>.of(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1];
      } else {
        x = v[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        return _backtrack(trace, d, n, m, offset);
      }
    }
  }
  return null;
}

List<_Op> _backtrack(
  List<List<int>> trace,
  int dEnd,
  int n,
  int m,
  int offset,
) {
  final ops = <_Op>[];
  var x = n, y = m;
  for (var d = dEnd; d > 0; d--) {
    final v = trace[d];
    final k = x - y;
    final prevK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]))
        ? k + 1
        : k - 1;
    final prevX = v[offset + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x--;
      y--;
      ops.add((kind: 0, ai: x, bi: y));
    }
    if (x == prevX) {
      y--;
      ops.add((kind: 1, ai: x, bi: y));
    } else {
      x--;
      ops.add((kind: -1, ai: x, bi: y));
    }
  }
  while (x > 0 && y > 0) {
    x--;
    y--;
    ops.add((kind: 0, ai: x, bi: y));
  }
  return ops.reversed.toList();
}

List<DiffHunk> _group(
  List<_Op> ops,
  List<String> a,
  List<String> b,
  int context,
) {
  final hunks = <DiffHunk>[];
  var i = 0;
  while (i < ops.length) {
    // Find the next change.
    while (i < ops.length && ops[i].kind == 0) {
      i++;
    }
    if (i >= ops.length) break;
    var start = i - context;
    if (start < 0) start = 0;
    // Extend while changes are within 2*context of each other.
    var end = i;
    var lastChange = i;
    while (end < ops.length) {
      if (ops[end].kind != 0) {
        lastChange = end;
      } else if (end - lastChange > 2 * context) {
        break;
      }
      end++;
    }
    var stop = lastChange + context + 1;
    if (stop > ops.length) stop = ops.length;
    final lines = <DiffLine>[];
    var oldCount = 0, newCount = 0;
    for (var j = start; j < stop; j++) {
      final op = ops[j];
      final raw = op.kind == 1 ? b[op.bi] : a[op.ai];
      final noEol = raw.endsWith(_noEol);
      final text = noEol ? raw.substring(0, raw.length - _noEol.length) : raw;
      final kind = op.kind == 0 ? ' ' : (op.kind < 0 ? '-' : '+');
      if (op.kind <= 0) oldCount++;
      if (op.kind >= 0) newCount++;
      lines.add((kind: kind, text: text));
      if (noEol) lines.add((kind: r'\', text: r'\ No newline at end of file'));
    }
    final first = ops[start];
    final oldStart = oldCount == 0 ? first.ai : first.ai + 1;
    final newStart = newCount == 0 ? first.bi : first.bi + 1;
    hunks.add(
      DiffHunk(
        oldStart: oldStart,
        oldCount: oldCount,
        newStart: newStart,
        newCount: newCount,
        lines: List.unmodifiable(lines),
      ),
    );
    i = stop;
  }
  return hunks;
}
