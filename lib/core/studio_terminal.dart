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
  bool _disposed = false;

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

  /// Dispatch [cmd] to this tab's persistent shell. Returns false when no
  /// shell is available and the caller must use the one-shot fallback.
  Future<bool> runPersistent(
    String cmd, {
    required String sid,
    required PtySpawner spawner,
  }) async {
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
      dead = false;
      sub = s.output.listen(
        (line) => _onOutput(s!, line),
        onDone: () => _onShellDone(s!),
        onError: (_) => _onShellDone(s!),
      );
    }

    final token = '__OVID_STUDIO_DONE_${tabId}_${_cmdSeq++}__';
    _pendingToken = token;
    s.writeStdin('$cmd\n');
    s.writeStdin('echo "$token"\n');
    return true;
  }

  void _onOutput(PtyShell s, String line) {
    if (!identical(shell, s)) return;
    if (_pendingToken != null && line.trim() == _pendingToken) {
      _pendingToken = null;
      busy = false;
      _notify();
      return;
    }
    history.add(line);
    _notify();
  }

  void _onShellDone(PtyShell s) {
    if (!identical(shell, s)) return;
    // The shell died mid-command (exit, crash, or killed): stop the spinner
    // and tell the user, then let the next command recreate a fresh shell.
    shell = null;
    _pendingToken = null;
    dead = true;
    busy = false;
    history.add('⚠ shell exited — next command starts a fresh shell');
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final sid = _shellSid ?? sessionId;
    sub?.cancel();
    sub = null;
    shell = null;
    if (sid != null) {
      unawaited(
        PtyPool.I.discard(sid, tab: tabId, owner: PtyPool.studioOwner),
      );
    }
    super.dispose();
  }
}
