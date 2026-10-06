import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'diag.dart';

/// Linux/Android descendant cleanup without signalling a shared process group.
/// Freeze each verified ancestor before discovering children, so it cannot fork
/// behind the traversal. Birth times prevent stale registry entries targeting a
/// reused PID. Native pidfds/cgroups are still needed for adversarial escape or
/// descendants reparented before Stop; never guess ownership by UID/name.
class OwnedProcessTree {
  OwnedProcessTree(this.process) : _birth = _stat(process.pid)?.birth;
  final Process process;
  final String? _birth;
  bool _killed = false;

  static ({int parent, String birth})? _stat(int pid) {
    try {
      final text = File('/proc/$pid/stat').readAsStringSync();
      final fields = text.substring(text.lastIndexOf(')') + 2).split(' ');
      return (parent: int.parse(fields[1]), birth: fields[19]);
    } catch (_) {
      return null;
    }
  }

  void kill() {
    if (_killed) return;
    _killed = true;
    if (_birth == null) {
      process.kill(ProcessSignal.sigkill);
      return;
    }
    final owned = <int, String>{};
    void freeze(int id, String birth) {
      if (id == pid || _stat(id)?.birth != birth) return;
      if (Process.killPid(id, ProcessSignal.sigstop)) owned[id] = birth;
    }

    try {
      freeze(process.pid, _birth);
      var found = true;
      while (found && owned.isNotEmpty) {
        found = false;
        for (final entry in Directory('/proc').listSync()) {
          final id = int.tryParse(entry.path.split('/').last);
          if (id == null || owned.containsKey(id)) continue;
          final stat = _stat(id);
          if (stat != null &&
              owned.containsKey(stat.parent) &&
              _stat(stat.parent)?.birth == owned[stat.parent]) {
            freeze(id, stat.birth);
            found = found || owned.containsKey(id);
          }
        }
      }
    } catch (e) {
      Diag.swallow('process.tree', e);
    } finally {
      for (final entry in owned.entries.toList().reversed) {
        if (_stat(entry.key)?.birth == entry.value) {
          Process.killPid(entry.key, ProcessSignal.sigkill);
        }
      }
      if (_stat(process.pid)?.birth == _birth) {
        process.kill(ProcessSignal.sigkill);
      }
    }
  }
}

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
  PtyShell._(this._proc) : _tree = OwnedProcessTree(_proc) {
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
    // Surface process death: close the output sink so subscribers get
    // onDone, and fail any in-flight run instead of hanging it forever.
    unawaited(_proc.exitCode.whenComplete(_onExit));
    // A write to a shell that has already exited surfaces as an async broken
    // pipe on the sink; absorb it so it never becomes an unhandled zone error.
    unawaited(_proc.stdin.done.then((_) {}, onError: (Object _) {}));
  }

  final Process _proc;
  final OwnedProcessTree _tree;
  Future<void>? _closing;
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
  /// Closes (onDone) when the underlying process exits.
  Stream<String> get output => _outCtrl.stream;

  void _emit(String line) {
    if (!_outCtrl.isClosed) _outCtrl.add(line);
  }

  void _onExit() {
    _dead = true;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete('PTY process exited');
    }
    if (!_outCtrl.isClosed) {
      unawaited(_outCtrl.close());
    }
  }

  /// Send raw bytes to the shell's stdin — used by the Studio terminal so a
  /// command runs in the persistent shell without the run-marker protocol.
  ///
  /// Deliberately does not call `flush()`: `flush()` returns a Future that
  /// must be awaited, and an unawaited flush leaves the `IOSink` bound, so a
  /// second back-to-back `write()` throws
  /// `Bad state: StreamSink is bound to a stream`. `write()` already hands
  /// the bytes to the OS pipe, so back-to-back commands stay reliable.
  void writeStdin(String data) {
    if (_dead) return;
    try {
      _proc.stdin.write(data);
    } catch (_) {
      _dead = true;
      _onExit();
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
    if (_waiting != null) return 'PTY busy — command already running';
    final id = _nextId++;
    final marker = '__OVID_DONE_${id}__';
    _buffer.clear();
    final completer = Completer<String>();
    _waiting = completer;
    _marker = marker;
    try {
      _proc.stdin.writeln('$cmd; __rc=\$?; echo "$marker:\$__rc"');
      // write() is queued on IOSink; awaiting flush can stall indefinitely
      // on a shell whose stdin pipe is full while it is waiting on a child.
    } catch (_) {
      unawaited(close());
      return 'PTY died while writing command';
    }
    try {
      return await completer.future.timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      unawaited(close());
      return 'PTY command timed out (${timeoutSeconds}s)';
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _dead = true;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete('PTY closed');
    _tree.kill();
    try {
      await _sub.cancel();
      await _subErr.cancel();
      await _proc.exitCode;
    } catch (e) {
      Diag.swallow('pty_service', e);
    }
    if (!_outCtrl.isClosed) {
      try {
        // A paused UI subscriber must not hold process teardown hostage.
        unawaited(_outCtrl.close());
      } catch (e) {
        Diag.swallow('pty_service', e);
      }
    }
  }
}

/// A pool of persistent bash shells, namespaced by owner so the agent's
/// shells and the Studio terminal's shells never destroy each other.
///
/// - [agentOwner] shells back `run_shell(persistent: true)` and are killed by
///   agent Stop (`discardFor`/`discardAll`).
/// - [studioOwner] shells back Studio terminal tabs and are only dropped by
///   their own tab close (`discard`) or full teardown (`discardAllShells`).
class PtyPool {
  PtyPool._();
  static final PtyPool I = PtyPool._();

  static const String agentOwner = 'agent';
  static const String studioOwner = 'studio';

  final Map<String, PtyShell> _shells = {};
  final Map<String, Future<PtyShell?>> _pending = {};
  final Map<String, Object> _owners = {};

  /// NUL-delimited so `('a', 'b')` never collides with `('ab', '')`, and
  /// owner-prefixed so agent and studio namespaces never collide.
  static String _key(String owner, String sessionId, String tab) =>
      '$owner\u0000$sessionId\u0000$tab';

  Future<PtyShell?> getOrCreate(
    String sessionId,
    Future<Process> Function() spawner, {
    String tab = 'agent',
    String owner = agentOwner,
  }) async {
    final key = _key(owner, sessionId, tab);
    final existing = _shells[key];
    if (existing != null && !existing.isDead) return existing;
    final pending = _pending[key];
    if (pending != null) return pending;
    final generation = Object();
    _owners[key] = generation;
    final future = () async {
      try {
        final shell = await PtyShell.start(spawner);
        if (!identical(_owners[key], generation)) {
          await shell?.close();
          return null;
        }
        if (shell != null) _shells[key] = shell;
        return shell;
      } finally {
        if (identical(_owners[key], generation)) _pending.remove(key);
      }
    }();
    _pending[key] = future;
    return future;
  }

  /// Agent panic stop: kill every agent-owned shell (Studio tabs survive).
  Future<void> discardAll() async {
    await _discardWhere((k) => k.startsWith('$agentOwner\u0000'));
  }

  /// Full teardown (app exit/tests): kill every shell, Studio included.
  Future<void> discardAllShells() async {
    await _discardWhere((_) => true);
  }

  /// One tab is gone — drop only that tab's shell.
  Future<void> discard(
    String sessionId, {
    String tab = 'agent',
    String owner = agentOwner,
  }) async {
    final key = _key(owner, sessionId, tab);
    _owners.remove(key);
    _pending.remove(key);
    final s = _shells.remove(key);
    if (s != null) await s.close();
  }

  /// Agent Stop for one session — drops only agent-owned shells, leaving
  /// Studio terminal tabs alive.
  Future<void> discardFor(String sessionId) async {
    final prefix = '$agentOwner\u0000$sessionId\u0000';
    await _discardWhere((k) => k.startsWith(prefix));
  }

  Future<void> _discardWhere(bool Function(String key) match) async {
    final keys = {..._shells.keys, ..._pending.keys}.where(match).toList();
    for (final k in keys) {
      _owners.remove(k);
      _pending.remove(k);
    }
    for (final k in keys) {
      final s = _shells.remove(k);
      if (s != null) await s.close();
    }
  }
}
