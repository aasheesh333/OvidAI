import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// F1 (the sandbox persistent-PTY parity): one long-lived bash process per session
/// inside the sandbox. `run_shell` with `persistent: true` goes through
/// this, so `cd`, exported vars and exported functions PERSIST between the
/// agent's commands — exactly the Unix shell semantics the persistent shell
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
    // (32K) and a noisy command deadlocks mid-run. Streamed to the UI sink
    // (and merged into the run buffer) with an `[stderr]` prefix so both
    // the user and the model still see it.
    _subErr = _proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) {
      _emit('[stderr] $l');
      final waiting = _waiting;
      if (waiting == null || waiting.isCompleted) return;
      _buffer.writeln('[stderr] $l');
    }, onError: (_) {});
  }

  final Process _proc;
  late final StreamSubscription<String> _sub;
  late final StreamSubscription<String> _subErr;
  final StringBuffer _buffer = StringBuffer();
  final StreamController<String> _outCtrl =
      StreamController<String>.broadcast();
  int _nextId = 0;
  bool _dead = false;

  Completer<String>? _waiting;
  String? _marker;

  /// Live stdout/stderr lines as they arrive (markers filtered). Broadcast:
  /// every Studio tab (and any other observer) can subscribe independently.
  Stream<String> get output => _outCtrl.stream;

  void _emit(String line) {
    if (!_outCtrl.isClosed) _outCtrl.add(line);
  }

  /// Send raw bytes to the shell's stdin — used by the Studio terminal so a
  /// command runs in the persistent shell without the run-marker protocol.
  ///
  /// No `flush()` here: a pending flush binds the IOSink and a second write
  /// throws `Bad state: StreamSink is bound to a stream`. `write()` already
  /// hands the bytes to the OS pipe, so back-to-back commands stay reliable.
  void writeStdin(String data) {
    if (_dead) return;
    try {
      _proc.stdin.write(data);
    } catch (_) {
      _dead = true;
    }
  }

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
    // Marker line that ends this command's output span. Never surfaced to
    // the UI sink — it is internal protocol.
    if (_marker != null && line.startsWith(_marker!)) {
      // Extract trailing exit code: `__OVID_DONE_<id>:<rc>`
      final tail = line.substring(_marker!.length);
      final rc = int.tryParse(tail.replaceAll(RegExp(r'\D'), '')) ?? -1;
      final waiting = _waiting;
      if (waiting != null && !waiting.isCompleted) {
        _waiting = null;
        var out = _buffer.toString();
        if (out.endsWith('\n')) out = out.substring(0, out.length - 1);
        waiting.complete('rc=$rc\n$out');
      }
      return;
    }
    // A stale/foreign marker from a previous command must not leak either.
    if (line.startsWith('__OVID_DONE_')) return;
    _emit(line);
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) return;
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
    try {
      await _outCtrl.close();
    } catch (_) {}
  }
}

/// A pool of per-(session, tab) bash shells. Kill-all comes free via the
/// registry.
class PtyPool {
  PtyPool._();
  static final PtyPool I = PtyPool._();
  final Map<String, PtyShell> _shells = {};

  /// NUL-delimited so `('a', 'b')` never collides with `('ab', '')`.
  static String _key(String sessionId, String tab) => '$sessionId\u0000$tab';

  Future<PtyShell?> getOrCreate(
    String sessionId,
    Future<Process> Function() spawner, {
    String tab = 'agent',
  }) async {
    final key = _key(sessionId, tab);
    final existing = _shells[key];
    if (existing != null && !existing.isDead) return existing;
    final shell = await PtyShell.start(spawner);
    if (shell == null) return null;
    _shells[key] = shell;
    return shell;
  }

  /// Kill everything (agent panic stop).
  Future<void> discardAll() async {
    for (final s in _shells.values) {
      await s.close();
    }
    _shells.clear();
  }

  /// One tab is gone — drop only that tab's shell.
  Future<void> discard(String sessionId, {String tab = 'agent'}) async {
    final s = _shells.remove(_key(sessionId, tab));
    if (s != null) await s.close();
  }

  /// One session is gone — drop every tab shell belonging to it.
  Future<void> discardFor(String sessionId) async {
    final prefix = '$sessionId\u0000';
    final keys = _shells.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in keys) {
      final s = _shells.remove(k);
      if (s != null) await s.close();
    }
  }
}