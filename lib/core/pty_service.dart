import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// F1 (the reference persistent-PTY parity): one long-lived bash process per session
/// inside the sandbox. `run_shell` with `persistent: true` goes through
/// this, so `cd`, exported vars and exported functions PERSIST between the
/// agent's commands — exactly the Unix shell semantics the reference
/// `ovid-tool-bash-persistent` exposes on desktop.
///
/// Commands are executed by writing to the shell's stdin and watching
/// stdout for a unique per-command marker. Output between markers is
/// the command's real stdout (+ stderr text lifted to stdout).
class PtyShell {
  PtyShell._(this._proc) {
    _sub = _proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (_) {});
    // Drain stderr — otherwise stderr output back-pressures the pipe
    // (32K) and a noisy command deadlocks mid-run. Merged into the same
    // buffer with an `err:` prefix so the model still sees it.
    _subErr = _proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) {
      final waiting = _waiting;
      if (waiting == null || waiting.isCompleted) return;
      _buffer.writeln('[stderr] $l');
    }, onError: (_) {});
  }

  final Process _proc;
  late final StreamSubscription<String> _sub;
  late final StreamSubscription<String> _subErr;
  final StringBuffer _buffer = StringBuffer();
  int _nextId = 0;
  bool _dead = false;

  Completer<String>? _waiting;
  String? _marker;

  static Future<PtyShell?> start(Future<Process> Function() spawner) async {
    try {
      final proc = await spawner();
      return PtyShell._(proc);
    } catch (_) {
      return null;
    }
  }

  bool get isDead => _dead;

  void _onLine(String line) {
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) return;
    // Marker line that ends this command's output span.
    if (_marker != null && line.startsWith(_marker!)) {
      // Extract trailing exit code: `__OVID_DONE_<id>:<rc>`
      final tail = line.substring(_marker!.length);
      final rc = int.tryParse(tail.replaceAll(RegExp(r'\D'), '')) ?? -1;
      _waiting = null;
      if (!waiting.isCompleted) {
        var out = _buffer.toString();
        if (out.endsWith('\n')) out = out.substring(0, out.length - 1);
        waiting.complete('rc=$rc\n$out');
      }
      return;
    }
    _buffer.writeln(line);
  }

  /// Run [cmd] in this persistent shell; returns "rc=N\n<output>".
  Future<String> run(String cmd, {int timeoutSeconds = 60}) async {
    if (_dead) return 'PTY dead — start a fresh persistent shell';
    final id = _nextId++;
    final marker = '__OVID_DONE_${id}__';
    _buffer.clear();
    final completer = Completer<String>();
    _waiting = completer;
    _marker = marker;
    try {
      _proc.stdin.writeln(
        '$cmd; __rc=\$?; echo "$marker:\$__rc"',
      );
      _proc.stdin.flush();
    } catch (_) {
      _dead = true;
      return 'PTY died while writing command';
    }
    try {
      return await completer.future
          .timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      _dead = true;
      try {
        _proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      return 'PTY command timed out (${timeoutSeconds}s)';
    }
  }

  Future<void> close() async {
    _dead = true;
    try {
      await _sub.cancel();
      await _subErr.cancel();
      _proc.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }
}

/// A pool of per-session bash shells. Kill-all comes free via the registry.
class PtyPool {
  PtyPool._();
  static final PtyPool I = PtyPool._();
  final Map<String, PtyShell> _shells = {};

  Future<PtyShell?> getOrCreate(
    String sessionId,
    Future<Process> Function() spawner,
  ) async {
    final existing = _shells[sessionId];
    if (existing != null && !existing.isDead) return existing;
    final shell = await PtyShell.start(spawner);
    if (shell == null) return null;
    _shells[sessionId] = shell;
    return shell;
  }

  /// Kill everything (agent panic stop).
  Future<void> discardAll() async {
    for (final s in _shells.values) {
      await s.close();
    }
    _shells.clear();
  }

  /// One session is gone — drop only its shell.
  Future<void> discardFor(String sessionId) async {
    final s = _shells.remove(sessionId);
    if (s != null) await s.close();
  }
}