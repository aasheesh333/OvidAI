import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_adapters.dart';
import 'plugin_manifest.dart';
import 'plugin_registry.dart';
import 'sandbox_service.dart';
import 'session_ledger.dart';
import 'state.dart';

/// Production plugin hook lifecycle (spec §8) — the runtime that fires
/// normalized [PluginHook]s at the 14 canonical agent-lifecycle points.
///
/// Event sources, in precedence order:
///   1. Registered normalized manifests (the contribution registry) —
///      ordered [PluginHook] lists, session-scoped by activation (§7).
///   2. Legacy installed [PluginItem] hook maps (`on_*` names) — migrated
///      on the fly through the frozen alias map (`canonicalHookEvent`).
///
/// Ordering (§8.2): install/registration order, then manifest order.
///
/// Blocking (§8.2): only `pre_tool` and `permission_request` may deny,
/// and only via exit code 2 or a valid JSON
/// `{"decision":"block","reason":"…"}`. Every other event is
/// fire-and-forget observe. Crash, timeout, missing interpreter,
/// malformed output, or any other nonzero exit is a visible fail-open
/// warning + ledger event — a broken hook script can never wedge the
/// agent run.
///
/// Environment per invocation: `PLUGIN_ROOT` (plugin content root),
/// `PLUGIN_STORAGE` (per-plugin private storage dir), `PLUGIN_WORKSPACE`
/// (session workspace), `PLUGIN_SESSION`, `PLUGIN_MODEL`, `PLUGIN_EVENT`
/// (canonical name), `PLUGIN_PAYLOAD` (capped JSON), plus the legacy
/// `OVID_HOOK_*` names for backward compatibility.
///
/// Recursion prevention (§8.2): a hook cannot re-fire its own event
/// while that event is executing, and nesting depth is capped.
///
/// Circuit breaker (§8.2): 3 consecutive failures of one plugin in one
/// session disable that plugin's hooks for the rest of the session.
class HookService extends ChangeNotifier {
  HookService._();
  static final HookService I = HookService._();

  /// Master kill-switch (Settings toggle, default ON).
  bool enabled = true;

  /// Invocations this boot (diagnostics surface).
  int fired = 0;
  int failed = 0;

  /// Default per-hook timeout when the hook declares none (§8.1).
  static const int defaultTimeoutS = 30;

  /// Hard cap on a declared per-hook timeout (§8.1).
  static const int maxTimeoutS = 120;

  /// Consecutive failures that trip the per-plugin per-session breaker.
  static const int breakerThreshold = 3;

  /// Max nested distinct-event hook executions (depth cap, §8.2).
  static const int maxDepth = 4;

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

  /// Test seam: replace the gate executor (no sandbox in unit tests).
  /// Signature: (command, env) → (exitCode, combinedOutput).
  @visibleForTesting
  Future<(int, String)> Function(String cmd, Map<String, String> env)?
      gateExecutorForTest;

  /// Test seam: capture the resolved per-hook timeout (seconds) without
  /// executing anything. Signature: (seconds) → stdout.
  @visibleForTesting
  Future<String> Function(int seconds)? execTimeoutForTest;

  // ── Session state (breaker + recursion guard) ─────────────────────────

  /// Consecutive-failure counts: `pluginId|sessionId` → count.
  final Map<String, int> _consecutiveFails = {};

  /// Settled breakers: `pluginId|sessionId` → true once tripped.
  final Set<String> _tripped = {};

  /// Events currently executing (recursion prevention — §8.2).
  final Set<String> _firingEvents = {};

  /// Current hook nesting depth (outer fire → nested fire).
  int _depth = 0;

  /// Whether [pluginId]'s hooks are disabled for [sessionId] (breaker).
  bool pluginTrippedForTest(String pluginId, String sessionId) =>
      _tripped.contains('$pluginId|$sessionId');

  /// Breaker state for diagnostics/UI.
  bool isPluginTripped(String pluginId, String sessionId) =>
      _tripped.contains('$pluginId|$sessionId');

  void _recordSuccess(String pluginId, String sessionId) {
    _consecutiveFails.remove('$pluginId|$sessionId');
  }

  void _recordFailure(String pluginId, String sessionId) {
    final key = '$pluginId|$sessionId';
    final n = (_consecutiveFails[key] ?? 0) + 1;
    if (n >= breakerThreshold) {
      _tripped.add(key);
      _consecutiveFails.remove(key);
    } else {
      _consecutiveFails[key] = n;
    }
  }

  // ── Hook resolution ──────────────────────────────────────────────────

  /// One resolved hook invocation target.
  static bool _matcherApplies(String? matcher, Map<String, dynamic> payload) {
    if (matcher == null || matcher.isEmpty) return true;
    final tool = payload['tool']?.toString() ?? '';
    try {
      return RegExp(matcher).hasMatch(tool);
    } catch (_) {
      return false; // malformed matcher → skip (fail-open)
    }
  }

  /// All hooks listening for [eventRaw] (canonical or legacy alias),
  /// visible to [sessionId], in install order then manifest order.
  /// Legacy `PluginItem` map hooks are appended (mapped through the
  /// frozen alias map) after registered normalized hooks, keyed by
  /// `legacy:<plugin-name>` so install order across sources stays
  /// deterministic (registry registrations first, then plugin-list
  /// order).
  List<(String pluginId, PluginHook hook)> _resolveHooks(
    String eventRaw,
    String sessionId,
  ) {
    final canonical = canonicalHookEvent(eventRaw) ?? eventRaw;
    final out = <(String, PluginHook)>[];
    for (final pid in PluginContributionRegistry.I.registeredPluginIds) {
      final m = PluginContributionRegistry.I.manifestFor(pid);
      if (m == null) continue;
      if (!PluginContributionRegistry.I.isPluginActiveForSession(
        pid,
        sessionId,
      )) {
        continue;
      }
      for (final h in m.hooks) {
        if (h.event != canonical) continue;
        out.add((pid, h));
      }
    }
    for (final p in AppState.I.plugins) {
      if (!p.installed || !p.enabled) continue;
      // Legacy map form — one command per (event, plugin).
      final cmd = p.hooks[eventRaw] ?? p.hooks[canonical];
      if (cmd == null || cmd.trim().isEmpty) continue;
      if (p.runtimeId != null &&
          PluginContributionRegistry.I.isRegistered(p.runtimeId!)) {
        // A REGISTERED plugin fires its ordered manifest hooks above —
        // never the legacy map too (double-fire).
        continue;
      }
      out.add((
        'legacy:${p.name}',
        PluginHook(
          pluginId: 'legacy:${p.name}',
          event: canonical,
          ordinal: 0,
          type: 'command',
          payload: cmd,
          matcher: p.hookMatchers[eventRaw] ?? p.hookMatchers[canonical],
          timeoutS: defaultTimeoutS,
        ),
      ));
    }
    return out;
  }

  /// Whether ANY installed+enabled or registered-active plugin listens to
  /// [event] (canonical or legacy alias).
  bool hasHookListeners(String event) {
    if (!enabled) return false;
    // Any session id works for the "is there a listener at all" question:
    // globalActive listeners match every session. (Callers that need
    // session-scoped firing pass the session id to fire/fireGate, which
    // re-resolves per session.)
    return _resolveHooks(event, '').isNotEmpty;
  }

  /// Whether any LEGACY `PluginItem` map hook listens for [event] — the
  /// per-turn `on_turn_start` firing site uses this so a plugin that
  /// declared the legacy name does not get a second canonical
  /// user_prompt_submit firing per turn (canonical fires once at runTask
  /// entry instead).
  bool hasLegacyMapHookListeners(String event) {
    if (!enabled) return false;
    return AppState.I.plugins.any(
      (p) =>
          p.installed &&
          p.enabled &&
          (p.hooks.containsKey(event) ||
              p.hooks.containsKey(canonicalHookEvent(event) ?? '')),
    );
  }

  // ── Execution core ───────────────────────────────────────────────────

  Future<Directory?> _sessionWorkDir(String sessionId) async {
    try {
      final s = sessionId.isEmpty
          ? null
          : AppState.I.sessions
                .where((x) => x.id == sessionId)
                .firstOrNull;
      final pinned = s?.workspaceFolder;
      if (pinned != null && pinned.trim().isNotEmpty) {
        final d = Directory(pinned);
        if (d.existsSync()) return d;
      }
      final sid = s?.sandboxId ?? s?.id ?? sessionId;
      if (sid.isEmpty) return null;
      return SandboxService.I.workDirFor(sid);
    } catch (_) {
      return null;
    }
  }

  Future<String> _pluginStorageDir(String pluginId) async {
    final safe = pluginId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    try {
      final docs = await getApplicationDocumentsDirectory();
      final d = Directory('${docs.path}/plugin-storage/$safe');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d.path;
    } catch (_) {
      // No platform channel (tests) — an honest per-plugin temp dir.
      try {
        final d = Directory(
          '${Directory.systemTemp.path}/plugin-storage/$safe',
        );
        if (!d.existsSync()) d.createSync(recursive: true);
        return d.path;
      } catch (_) {
        return '';
      }
    }
  }

  Map<String, String> _envFor({
    required String pluginId,
    required PluginHook hook,
    required String canonical,
    required String sessionId,
    required String payloadJson,
    required String workspace,
    required String storage,
    String? model,
  }) {
    final pluginName = pluginId.startsWith('legacy:')
        ? pluginId.substring(7)
        : pluginId;
    return {
      'OVID_HOOK_EVENT': canonical,
      'OVID_HOOK_PLUGIN': pluginName,
      'OVID_HOOK_SESSION': sessionId,
      'OVID_HOOK_PAYLOAD': cleanHookJson(payloadJson),
      'PLUGIN_ID': pluginId,
      'PLUGIN_EVENT': canonical,
      'PLUGIN_SESSION': sessionId,
      'PLUGIN_MODEL': model ?? '',
      'PLUGIN_PAYLOAD': cleanHookJson(payloadJson),
      'PLUGIN_ROOT': _rootPathFor(pluginId, hook),
      'PLUGIN_STORAGE': storage,
      'PLUGIN_WORKSPACE': workspace,
    };
  }

  String _rootPathFor(String pluginId, PluginHook hook) {
    if (pluginId.startsWith('legacy:')) {
      return '';
    }
    final m = PluginContributionRegistry.I.manifestFor(pluginId);
    return m?.rootPath ?? '';
  }

  /// Execute one hook. Returns (exitCode, stdout) — throws on
  /// exec error/timeout. Failures bubble to the caller's fail-open
  /// handling. [gate] selects the test seam matching the calling context
  /// (gate vs observe) so a test executor for one never intercepts the
  /// other.
  Future<(int, String)> _exec(
    PluginHook hook,
    Map<String, String> env,
    Directory? cwd, {
    bool gate = false,
  }) async {
    final timeout = Duration(
      seconds: hook.timeoutS <= 0
          ? defaultTimeoutS
          : (hook.timeoutS > maxTimeoutS ? maxTimeoutS : hook.timeoutS),
    );
    if (gate) {
      final g = gateExecutorForTest;
      if (g != null) return g(hook.payload, env);
    }
    final custom = executorForTest;
    if (custom != null) return (0, await custom(hook.payload, env));
    final t = execTimeoutForTest;
    if (t != null) return (0, await t(timeout.inSeconds));
    if (!SandboxService.I.isInstalled) {
      throw StateError('sandbox not installed');
    }
    final (code, out) = await SandboxService.I
        .execChecked(['bash', '-c', hook.payload], hostWorkDir: cwd)
        .timeout(timeout);
    return (code, out);
  }

  Future<void> _ledger(String sessionId, String kind, Map<String, dynamic> d) {
    return SessionLedger.I.append(sessionId, kind, d);
  }

  // ── fire: observe events (fire-and-forget semantics at call sites) ──

  /// Fire [event] for [sessionId]. Returns the combined stdout of all
  /// listener commands (≤2 KB — `pre_request` context injection) — empty
  /// when no listener or hooks are disabled. Observe events NEVER block
  /// the run: failures are ledgered and skipped.
  Future<String> fire(
    String event,
    String sessionId, {
    Map<String, dynamic> payload = const {},
    String? model,
  }) async {
    if (!enabled) return '';
    final canonical = canonicalHookEvent(event) ?? event;
    // Recursion prevention: never re-fire an event already executing.
    if (_firingEvents.contains(canonical)) return '';
    if (_depth >= maxDepth) return '';
    final hooks = _resolveHooks(event, sessionId);
    if (hooks.isEmpty) return '';

    _firingEvents.add(canonical);
    _depth++;
    final payloadJson = jsonEncode({
      'event': canonical,
      'session': sessionId,
      ...payload,
    });
    final cwd = await _sessionWorkDir(sessionId);
    final collected = <String>[];
    try {
      for (final (pluginId, hook) in hooks) {
        if (!_matcherApplies(hook.matcher, payload)) continue;
        if (_tripped.contains('$pluginId|$sessionId')) continue;
        if (hook.type != 'command') {
          // Prompt hooks have no shell runtime ("where implementable",
          // §8.1) — skipped with a visible ledger note, never executed.
          fired++;
          try {
            await _ledger(sessionId, 'hook/result', {
              'plugin': pluginId,
              'event': canonical,
              'type': hook.type,
              'ok': false,
              'reason': 'prompt-type hook has no shell runtime — skipped',
            });
          } catch (_) {}
          continue;
        }
        final storage = await _pluginStorageDir(pluginId);
        final env = _envFor(
          pluginId: pluginId,
          hook: hook,
          canonical: canonical,
          sessionId: sessionId,
          payloadJson: payloadJson,
          workspace: cwd?.path ?? '',
          storage: storage,
          model: model,
        );
        final record = {
          'plugin': pluginId,
          'event': canonical,
          'command': hook.payload,
        };
        fired++;
        try {
          await _ledger(
            sessionId,
            'hook/invoked',
            Map<String, dynamic>.from(record),
          );
        } catch (_) {}
        try {
          final (code, out) = await _exec(hook, env, cwd);
          if (code != 0) {
            failed++;
            _recordFailure(pluginId, sessionId);
            try {
              await _ledger(sessionId, 'hook/result', {
                ...record,
                'ok': false,
                'exit': code,
                'warning': 'hook failed (fail-open) — output ignored',
                'stdout': cleanHookJson(out),
              });
            } catch (_) {}
            continue;
          }
          _recordSuccess(pluginId, sessionId);
          if (out.trim().isNotEmpty) {
            collected.add(out.trim());
            try {
              await _ledger(sessionId, 'hook/result', {
                ...record,
                'ok': true,
                'stdout': cleanHookJson(out),
              });
            } catch (_) {}
          }
        } catch (e) {
          failed++;
          _recordFailure(pluginId, sessionId);
          try {
            await _ledger(sessionId, 'hook/result', {
              ...record,
              'ok': false,
              'error': e.toString(),
              'warning': 'hook failed (fail-open) — run continues',
            });
          } catch (_) {}
        }
      }
    } finally {
      _firingEvents.remove(canonical);
      _depth--;
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

  /// Parse a hook's stdout for a JSON block decision
  /// (`{"decision":"block","reason":"…"}`). Returns the reason string when
  /// stdout is such a block, null otherwise.
  static String? jsonBlockReason(String out) {
    final t = out.trim();
    if (!t.startsWith('{') || !t.endsWith('}')) return null;
    dynamic j;
    try {
      j = jsonDecode(t);
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    if (j['decision'] != 'block') return null;
    final reason = j['reason'];
    return (reason is String && reason.trim().isNotEmpty)
        ? reason.trim()
        : null;
  }

  // ── fireGate: blocking events (pre_tool, permission_request) ────────

  /// Fire the GATING event [event] for [sessionId] and return whether the
  /// action is allowed. Only `pre_tool` and `permission_request` are
  /// blocking (§8.2); a block requires exit code 2 or a valid JSON block
  /// decision. Everything else — crash, timeout, missing interpreter,
  /// malformed output, any other nonzero exit — fails OPEN with a ledger
  /// warning (a broken hook must never brick the run).
  Future<HookGateResult> fireGate(
    String event,
    String sessionId, {
    Map<String, dynamic> payload = const {},
    String? model,
  }) async {
    if (!enabled) return const HookGateResult.allow();
    final canonical = canonicalHookEvent(event) ?? event;
    if (!PluginHook.blockingEvents.contains(canonical)) {
      // A non-blocking event routed through the gate is a caller bug —
      // fail open, never deny from an observe event.
      return const HookGateResult.allow();
    }
    if (_firingEvents.contains(canonical)) {
      return const HookGateResult.allow();
    }
    if (_depth >= maxDepth) return const HookGateResult.allow();
    final hooks = _resolveHooks(event, sessionId);
    if (hooks.isEmpty) return const HookGateResult.allow();

    _firingEvents.add(canonical);
    _depth++;
    final payloadJson = jsonEncode({
      'event': canonical,
      'session': sessionId,
      ...payload,
    });
    final cwd = await _sessionWorkDir(sessionId);
    try {
      for (final (pluginId, hook) in hooks) {
        if (!_matcherApplies(hook.matcher, payload)) continue;
        if (_tripped.contains('$pluginId|$sessionId')) continue;
        if (hook.type != 'command') continue;
        final storage = await _pluginStorageDir(pluginId);
        final env = _envFor(
          pluginId: pluginId,
          hook: hook,
          canonical: canonical,
          sessionId: sessionId,
          payloadJson: payloadJson,
          workspace: cwd?.path ?? '',
          storage: storage,
          model: model,
        );
        final record = {
          'plugin': pluginId,
          'event': canonical,
          'command': hook.payload,
        };
        fired++;
        try {
          await _ledger(
            sessionId,
            'hook/invoked',
            Map<String, dynamic>.from(record),
          );
        } catch (_) {}
        try {
          final (code, out) = await _exec(hook, env, cwd, gate: true);
          final blockReason = jsonBlockReason(out);
          if (code == 2 || blockReason != null) {
            failed++;
            final reason = blockReason ??
                (out.trim().isEmpty
                    ? '$pluginId denied this action'
                    : cleanHookJson(out.trim()));
            try {
              await _ledger(sessionId, 'hook/result', {
                ...record,
                'ok': false,
                'exit': code,
                'decision': 'deny',
                'blockReason': ?blockReason,
                'reason': reason,
              });
            } catch (_) {}
            return HookGateResult.deny(pluginId, reason);
          }
          _recordSuccess(pluginId, sessionId);
          try {
            await _ledger(sessionId, 'hook/result', {
              ...record,
              'ok': true,
              'decision': 'allow',
              if (out.trim().isNotEmpty) 'stdout': cleanHookJson(out),
            });
          } catch (_) {}
        } catch (e) {
          // Exec error/timeout/missing sandbox — fail-open, but count
          // toward the breaker and record the visible warning.
          failed++;
          _recordFailure(pluginId, sessionId);
          try {
            await _ledger(sessionId, 'hook/result', {
              ...record,
              'ok': false,
              'error': e.toString(),
              'reason': 'gate fails open on error',
            });
          } catch (_) {}
        }
      }
    } finally {
      _firingEvents.remove(canonical);
      _depth--;
    }
    return const HookGateResult.allow();
  }
}

/// Outcome of [HookService.fireGate] — only pre_tool/permission_request
/// gates produce a deny.
@immutable
class HookGateResult {
  final bool allowed;
  final String? deniedByPlugin;
  final String? reason;

  const HookGateResult.allow()
      : allowed = true,
        deniedByPlugin = null,
        reason = null;

  const HookGateResult.deny(this.deniedByPlugin, this.reason)
      : allowed = false;
}
