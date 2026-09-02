import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_service.dart';
import 'sandbox_service.dart';
import 'session_ledger.dart';
import 'state.dart';

/// PR24: plugin hooks — the mobile analogue of DSH's in-process JS hook
/// listeners. A plugin declares `hooks: {event: "<shell command>"}` in its
/// marketplace manifest; HookService fires the command inside the sandbox
/// at the matching agent-lifecycle point, with:
///   • OVID_HOOK_EVENT  — the event name
///   • OVID_HOOK_PLUGIN — the declaring plugin's name
///   • OVID_HOOK_SESSION — the session id
///   • OVID_HOOK_PAYLOAD — a compact JSON payload (capped)
///   • cwd = the session workspace
/// A `on_pre_request` hook's stdout (first 2 KB) is returned so the run
/// can inject it as model context; every invocation + outcome is written
/// to the session ledger (`hook/invoked` / `hook/result`, DSH session-event
/// parity). Failures NEVER break the agent run — they surface in the
/// ledger + status line only.
class HookService extends ChangeNotifier {
  HookService._();
  static final HookService I = HookService._();

  /// Master kill-switch (Settings toggle, default ON).
  bool enabled = true;

  /// Invocations this boot (diagnostics surface).
  int fired = 0;
  int failed = 0;

  /// Restore the persisted kill-switch (call once at boot).
  Future<void> loadEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool('ovid_hooks_enabled') ?? true;
    } catch (_) {}
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ovid_hooks_enabled', v);
    } catch (_) {}
  }

  /// Test seam: replace the executor (no sandbox in unit tests).
  /// Signature: (command, env) → stdout.
  @visibleForTesting
  Future<String> Function(String cmd, Map<String, String> env)?
      executorForTest;

  /// Whether ANY installed+enabled plugin listens to [event].
  /// (Renamed from hasListeners — ChangeNotifier owns that name.)
  bool hasHookListeners(String event) {
    if (!enabled) return false;
    return AppState.I.plugins
        .any((p) => p.installed && p.enabled && p.hooks.containsKey(event));
  }

  /// Fire [event] for [sessionId]. Returns the combined stdout of all
  /// listener commands (≤2 KB, `on_pre_request` context injection) —
  /// empty when no listener or hooks are disabled.
  Future<String> fire(
    String event,
    String sessionId, {
    Map<String, dynamic> payload = const {},
  }) async {
    if (!enabled) return '';
    final listeners = AppState.I.plugins
        .where((p) => p.installed && p.enabled && p.hooks.containsKey(event))
        .toList();
    if (listeners.isEmpty) return '';

    final payloadJson = jsonEncode({
      'event': event,
      'session': sessionId,
      ...payload,
    });
    final cwd = await AgentService.I.sessionWorkDirForTest();
    final collected = <String>[];

    for (final p in listeners) {
      final cmd = p.hooks[event]!;
      final env = <String, String>{
        'OVID_HOOK_EVENT': event,
        'OVID_HOOK_PLUGIN': p.name,
        'OVID_HOOK_SESSION': sessionId,
        'OVID_HOOK_PAYLOAD': cleanHookJson(payloadJson),
      };
      final record = <String, dynamic>{
        'plugin': p.name,
        'event': event,
        'command': cmd,
      };
      fired++;
      try {
        await SessionLedger.I.append(
          sessionId,
          'hook/invoked',
          Map<String, dynamic>.from(record),
        );
      } catch (_) {}
      String out;
      try {
        final custom = executorForTest;
        if (custom != null) {
          out = await custom(cmd, env);
        } else if (SandboxService.I.isInstalled) {
          final (code, o) = await SandboxService.I
              .execChecked(['bash', '-c', cmd], hostWorkDir: cwd)
              .timeout(const Duration(seconds: 30));
          if (code != 0) {
            failed++;
            try {
              await SessionLedger.I.append(sessionId, 'hook/result', {
                ...record,
                'ok': false,
                'exit': code,
                'stderr': cleanHookJson(o),
              });
            } catch (_) {}
            continue;
          }
          out = o;
        } else {
          // Sandbox not installed — a hook cannot run; record and move on.
          try {
            await SessionLedger.I.append(sessionId, 'hook/result', {
              ...record,
              'ok': false,
              'reason': 'sandbox not installed',
            });
          } catch (_) {}
          continue;
        }
      } catch (e) {
        failed++;
        try {
          await SessionLedger.I.append(sessionId, 'hook/result', {
            ...record,
            'ok': false,
            'error': e.toString(),
          });
        } catch (_) {}
        continue;
      }
      if (out.trim().isNotEmpty) {
        collected.add(out.trim());
        try {
          await SessionLedger.I.append(sessionId, 'hook/result', {
            ...record,
            'ok': true,
            'stdout': cleanHookJson(out),
          });
        } catch (_) {}
      }
    }
    final joined = collected.join('\n');
    if (joined.length > 2048) {
      return '${joined.substring(0, 2048)}\n[hook output truncated]';
    }
    return joined;
  }

  /// Compact + strip newlines so env vars stay one-line.
  static String cleanHookJson(String s) {
    final compact = s.replaceAll('\n', ' ').replaceAll('\r', '');
    if (compact.length > 4096) {
      return '${compact.substring(0, 4096)}…';
    }
    return compact;
  }
}
