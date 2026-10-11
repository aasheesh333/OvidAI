import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'pty_service.dart';

/// Spawns a fresh shell process for a Studio terminal tab.
typedef PtySpawner = Future<Process> Function();

/// Owns one Studio terminal tab's persistent shell: streaming output into a
/// per-tab scrollback, dispatching commands via stdin, and surfacing shell
/// death so the next command can recreate the shell.
///
/// Deliberately widget-free so it can be unit-tested with an injected
/// [PtySpawner] — no sandbox required.
class StudioShellSession extends ChangeNotifier {
  StudioShellSession({required this.tabId});

  final String tabId;

  final List<String> history = <String>[];
  bool busy = false;
  bool dead = false;
  String? sessionId;
  PtyShell? shell;
  StreamSubscription<String>? sub;
  int _cmdSeq = 0;
  String? _pendingToken;
  String? _shellSid;
  String? _workspace;
  bool _disposed = false;
  Timer? _idleTimer;
  Timer? _interruptTimer;
  int? _shellPid;
  String? _pidToken;

  /// A command that produces no output for this long gets an honest
  /// "still running" notice (instead of being killed: a dev server or a long
  /// build is legitimately quiet). The user decides with Stop. Overridable for
  /// tests.
  @visibleForTesting
  static Duration idleNoticeAfterForTest = const Duration(seconds: 60);

  /// How long Stop waits for SIGINT to end the command before escalating to
  /// SIGKILL, and then to discarding the shell. Overridable for tests.
  @visibleForTesting
  static Duration interruptGraceForTest = const Duration(seconds: 2);

  /// Exported in every fresh shell: this terminal is a pipe, not a PTY, so
  /// anything that would open an editor/pager or ask y/N must not block.
  static const String nonInteractiveEnv =
      'export GIT_EDITOR=true PAGER=cat GIT_PAGER=cat '
      'DEBIAN_FRONTEND=noninteractive CI=1 NPM_CONFIG_YES=true';

  /// True while a command runs in the persistent shell, so input typed into
  /// the field is fed to that command's stdin (answers to y/N, `read`, …).
  bool get acceptsStdin => busy && _pendingToken != null && shell != null;

  /// Start a command in the UI (echo the prompt + mark busy).
  void begin(String display) {
    history.add('\$ $display');
    busy = true;
    _notify();
  }

  /// Append a line of output (used by the one-shot exec fallback).
  void addOutput(String line) {
    history.add(line);
    _notify();
  }

  /// Clear the busy state (used by the one-shot exec fallback).
  void finish() {
    busy = false;
    _notify();
  }

  /// Returns a user-facing reason when [cmd] cannot be dispatched as one
  /// complete command (an unclosed quote or trailing backslash would make
  /// bash read the following protocol line as part of the command and wedge
  /// the tab), otherwise null.
  static String? incompleteReason(String cmd) {
    String? open;
    var escaped = false;
    for (var i = 0; i < cmd.length; i++) {
      final ch = cmd[i];
      if (open == "'") {
        if (ch == "'") open = null;
        continue;
      }
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        continue;
      }
      if (open != null) {
        if (ch == open) open = null;
        continue;
      }
      if (ch == '"' || ch == "'" || ch == '`') open = ch;
    }
    if (open != null) {
      final name = open == '`' ? 'backtick' : 'quote ($open)';
      return 'Unclosed $name — command not run.';
    }
    if (escaped) return 'Trailing backslash — command not run.';
    return null;
  }

  /// Feed one line to the running command's stdin. Returns false (and
  /// writes nothing) when no command is running in the persistent shell.
  bool sendStdin(String line) {
    final s = shell;
    if (!acceptsStdin || s == null) return false;
    history.add(line);
    s.writeStdin('$line\n');
    _armIdleNotice(_pendingToken!);
    _notify();
    return true;
  }

  /// Dispatch [cmd] to this tab's persistent shell. Returns false when no
  /// shell is available and the caller must use the one-shot fallback.
  Future<bool> runPersistent(
    String cmd, {
    required String sid,
    required PtySpawner spawner,
    String? workspace,
  }) async {
    if (_workspace != workspace && _shellSid != null) {
      await sub?.cancel();
      sub = null;
      shell = null;
      await PtyPool.I.discard(
        _shellSid!,
        tab: tabId,
        owner: PtyPool.studioOwner,
      );
    }
    _workspace = workspace;
    sessionId = sid;
    PtyShell? s;
    try {
      s = await PtyPool.I.getOrCreate(
        sid,
        spawner,
        tab: tabId,
        owner: PtyPool.studioOwner,
      );
    } catch (_) {
      s = null;
    }
    if (s == null) return false;

    if (!identical(shell, s)) {
      final oldSid = _shellSid;
      await sub?.cancel();
      // The active session changed: drop the old pool entry so it cannot
      // leak a live shell under a different session key. A dead shell on the
      // same session was already replaced by `getOrCreate`.
      if (oldSid != null && oldSid != sid) {
        unawaited(
          PtyPool.I.discard(oldSid, tab: tabId, owner: PtyPool.studioOwner),
        );
      }
      shell = s;
      _shellSid = sid;
      _shellPid = null;
      dead = false;
      sub = s.output.listen(
        (line) => _onOutput(s!, line),
        onDone: () => _onShellDone(s!),
        onError: (_) => _onShellDone(s!),
      );
      // Fresh shell: make it non-interactive-safe and learn its pid so Stop
      // can interrupt the running command without killing the shell.
      final pidToken = '__OVID_STUDIO_PID_${tabId}__';
      _pidToken = pidToken;
      s.writeStdin('$nonInteractiveEnv; echo "$pidToken \$\$"\n');
    }

    final token = '__OVID_STUDIO_DONE_${tabId}_${_cmdSeq++}__';
    _pendingToken = token;
    // The command and the completion sentinel are ONE bash list (a brace
    // group spanning lines, then `; echo`), so bash has parsed the sentinel
    // before the command starts. A command that reads stdin (`read`, a y/N
    // prompt, `python`) therefore can never swallow the sentinel as input;
    // it reads only what the user sends via [sendStdin].
    s.writeStdin('{\n$cmd\n}; echo "$token \$?"\n');
    _armIdleNotice(token);
    return true;
  }

  void _armIdleNotice(String token) {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleNoticeAfterForTest, () {
      if (_disposed || !busy || _pendingToken != token) return;
      history.add(
        '⚠ no output for ${_idle(idleNoticeAfterForTest)} — still running. '
        'Type input below, or tap Stop to interrupt.',
      );
      _notify();
    });
  }

  static String _idle(Duration d) =>
      d.inSeconds >= 1 ? '${d.inSeconds}s' : '${d.inMilliseconds}ms';

  /// Ctrl-C: interrupt the running command but keep the shell (and its `cd`
  /// and exports). Sends SIGINT to the shell's child processes; escalates to
  /// SIGKILL and finally to [cancel] if the command does not end within
  /// [interruptGraceForTest]. When the shell's processes cannot be signalled
  /// (no `/proc`, unknown pid, or a builtin with no child process) it falls
  /// back to [cancel] straight away. Safe to call when nothing is running.
  void interrupt() {
    if (!busy) return;
    final token = _pendingToken;
    final pid = _shellPid;
    if (token == null || pid == null || shell == null) {
      cancel();
      return;
    }
    final sent = OwnedProcessTree.signalDescendants(pid, ProcessSignal.sigint);
    if (sent <= 0) {
      cancel();
      return;
    }
    history.add('^C');
    _notify();
    _interruptTimer?.cancel();
    _interruptTimer = Timer(interruptGraceForTest, () {
      if (_disposed || _pendingToken != token) return;
      OwnedProcessTree.signalDescendants(pid, ProcessSignal.sigkill);
      _interruptTimer = Timer(interruptGraceForTest, () {
        if (_disposed || _pendingToken != token) return;
        cancel();
      });
    });
  }

  /// Hard abort: stop the spinner and drop the shell so the next command
  /// starts fresh (loses `cd`/exports). Safe to call when nothing is running.
  void cancel() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _interruptTimer?.cancel();
    _interruptTimer = null;
    final wasBusy = busy;
    _pendingToken = null;
    busy = false;
    final sid = _shellSid ?? sessionId;
    if (sid != null) {
      unawaited(PtyPool.I.discard(sid, tab: tabId, owner: PtyPool.studioOwner));
    }
    shell = null;
    _shellPid = null;
    if (wasBusy) {
      history.add('⚠ stopped — next command starts a fresh shell');
    }
    _notify();
  }

  void _onOutput(PtyShell s, String line) {
    if (!identical(shell, s)) return;
    final trimmed = line.trim();
    final pidToken = _pidToken;
    if (pidToken != null && trimmed.startsWith(pidToken)) {
      _shellPid = int.tryParse(trimmed.substring(pidToken.length).trim());
      _pidToken = null;
      return;
    }
    final token = _pendingToken;
    if (token != null && trimmed.startsWith(token)) {
      _idleTimer?.cancel();
      _idleTimer = null;
      _interruptTimer?.cancel();
      _interruptTimer = null;
      _pendingToken = null;
      busy = false;
      final rc = int.tryParse(trimmed.substring(token.length).trim());
      if (rc != null && rc != 0) history.add('⚠ exit $rc');
      _notify();
      return;
    }
    // A stale sentinel (e.g. from a command interrupted by a hard reset)
    // is protocol, never output.
    if (trimmed.startsWith('__OVID_STUDIO_DONE_')) return;
    history.add(line);
    _notify();
  }

  void _onShellDone(PtyShell s) {
    if (!identical(shell, s)) return;
    // The shell died mid-command (exit, crash, or killed): stop the spinner
    // and tell the user, then let the next command recreate a fresh shell.
    _idleTimer?.cancel();
    _idleTimer = null;
    _interruptTimer?.cancel();
    _interruptTimer = null;
    shell = null;
    _shellPid = null;
    _pendingToken = null;
    dead = true;
    busy = false;
    history.add('⚠ shell exited — next command starts a fresh shell');
    _notify();
  }

  /// Maximum retained terminal lines.
  ///
  /// PERF (2026-09-24): `history` grew without bound, so a long-lived Studio tab
  /// running builds (apt, npm, gradle) accumulated tens of thousands of strings —
  /// steadily rising memory per tab, and an increasingly expensive rebuild of the
  /// terminal pane on every new line. Trimming here covers all five append sites
  /// at once, since every one of them notifies. Oldest lines go first; `clear`
  /// still empties the buffer entirely.
  static const int maxHistoryLines = 5000;

  void _notify() {
    if (_disposed) return;
    if (history.length > maxHistoryLines) {
      history.removeRange(0, history.length - maxHistoryLines);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _interruptTimer?.cancel();
    _interruptTimer = null;
    final sid = _shellSid ?? sessionId;
    sub?.cancel();
    sub = null;
    shell = null;
    if (sid != null) {
      unawaited(PtyPool.I.discard(sid, tab: tabId, owner: PtyPool.studioOwner));
    }
    super.dispose();
  }
}
