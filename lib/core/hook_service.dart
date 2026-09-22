import 'dart:async';
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

/// Evaluates a prompt-type hook with the agent's model. The AgentService
/// worker wires this: `HookService.I.promptHookEvaluator = (prompt, ctx) =>
/// AgentService.I.completeQuietly(prompt, ...)` (or equivalent). The
/// returned string is parsed by [HookService.parsePromptHookDecision]
/// (JSON `{"decision":"block"|"approve","reason":"…"}` or plain-text
/// "block"/"approve" heuristics). Null/empty or a throw fails OPEN.
typedef PromptHookEvaluator =
    Future<String?> Function(String prompt, Map<String, dynamic> context);

/// Gate outcome of [HookService.fireGate].
enum HookDecision {
  /// The action proceeds.
  allow,

  /// The action is denied outright (exit 2 / JSON `block`).
  deny,

  /// The hook defers to the user: route into the permission prompt
  /// (`hookSpecificOutput.permissionDecision: "ask"`).
  ask,
}

/// Outcome of [HookService.fireGate] — pre_tool/permission_request gates
/// (and [HookService.fireStop]) produce deny/ask; observe events never do.
class HookGateResult {
  final HookDecision decision;

  /// Plugin that produced the deny/ask (display name, no `legacy:` prefix).
  final String? decidedByPlugin;

  final String? reason;

  /// Rewritten tool args from `hookSpecificOutput.updatedInput` — the
  /// caller applies these pre-execution (pre_tool only). Present on allow
  /// results too: a hook may rewrite args without blocking.
  final Map<String, dynamic>? updatedInput;

  /// Backward-compat: true only for [HookDecision.allow].
  bool get allowed => decision == HookDecision.allow;

  /// Backward-compat: the plugin behind a deny (or ask).
  String? get deniedByPlugin =>
      decision == HookDecision.allow ? null : decidedByPlugin;

  const HookGateResult.allow({this.updatedInput})
    : decision = HookDecision.allow,
      decidedByPlugin = null,
      reason = null;

  const HookGateResult.deny(this.decidedByPlugin, this.reason, {this.updatedInput})
    : decision = HookDecision.deny;

  const HookGateResult.ask(this.decidedByPlugin, this.reason, {this.updatedInput})
    : decision = HookDecision.ask;
}

/// Outcome of [HookService.fireStop] — a Stop hook may veto the stop
/// (JSON `{"decision":"block"}` or exit code 2), in which case the model
/// loop continues. A USER-initiated stop always wins ([userInitiated]).
class HookStopResult {
  /// True = the stop proceeds; false = vetoed, the model loop continues.
  final bool stopAllowed;

  /// True when a user-initiated stop bypassed the hooks entirely.
  final bool userInitiated;

  final String? vetoedByPlugin;
  final String? vetoReason;

  const HookStopResult.allow({this.userInitiated = false})
    : stopAllowed = true,
      vetoedByPlugin = null,
      vetoReason = null;

  const HookStopResult.veto(this.vetoedByPlugin, this.vetoReason)
    : stopAllowed = false,
      userInitiated = false;
}

/// Detailed outcome of [HookService.fireDetailed] — [HookService.fire]
/// returns just [output].
class HookFireResult {
  /// Combined hook stdout after the output contract was applied
  /// (`suppressOutput` entries removed, `continue:false` honored).
  final String output;

  /// `systemMessage` values surfaced by hooks, in firing order.
  final List<String> systemMessages;

  /// True when a hook returned `continue:false` and later hooks were skipped.
  final bool halted;

  /// Reason when an evaluated prompt-type hook returned "block" on an
  /// observe event (null when no prompt hook blocked). The AgentService
  /// worker decides what a prompt-block means for the run.
  final String? promptBlockReason;

  const HookFireResult({
    required this.output,
    this.systemMessages = const [],
    this.halted = false,
    this.promptBlockReason,
  });
}

/// The JSON output contract a hook's stdout may carry (Claude Code shape).
/// Top level: `continue`, `suppressOutput`, `systemMessage`, `decision`,
/// `reason`. Nested `hookSpecificOutput`: `additionalContext`,
/// `permissionDecision` (`allow`|`ask`|`deny`), `permissionDecisionReason`,
/// `updatedInput`, `envFileAppend`/`env` (session_start only).
class HookOutputContract {
  final bool continueHooks;
  final bool suppressOutput;
  final String? systemMessage;
  final String? decision;
  final String? reason;
  final String? additionalContext;
  final String? permissionDecision;
  final String? permissionDecisionReason;
  final Map<String, dynamic>? updatedInput;

  const HookOutputContract({
    this.continueHooks = true,
    this.suppressOutput = false,
    this.systemMessage,
    this.decision,
    this.reason,
    this.additionalContext,
    this.permissionDecision,
    this.permissionDecisionReason,
    this.updatedInput,
  });

  static const empty = HookOutputContract();

  /// Parse a hook's stdout for the contract. Non-JSON output yields
  /// [empty] (plain text is context, never a decision).
  static HookOutputContract parse(String stdout) {
    final t = stdout.trim();
    if (t.isEmpty || !t.startsWith('{') || !t.endsWith('}')) return empty;
    dynamic j;
    try {
      j = jsonDecode(t);
    } catch (_) {
      return empty;
    }
    if (j is! Map) return empty;
    final m = j.cast<String, dynamic>();
    Map<String, dynamic>? hso;
    final rawHso = m['hookSpecificOutput'];
    if (rawHso is Map) hso = rawHso.cast<String, dynamic>();
    String? str(Object? v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;
    Map<String, dynamic>? updated;
    final rawUpdated = hso?['updatedInput'];
    if (rawUpdated is Map) updated = rawUpdated.cast<String, dynamic>();
    return HookOutputContract(
      continueHooks: m['continue'] is bool ? m['continue'] as bool : true,
      suppressOutput: m['suppressOutput'] == true,
      systemMessage: str(m['systemMessage']),
      decision: str(m['decision'])?.toLowerCase(),
      reason: str(m['reason']),
      additionalContext: str(hso?['additionalContext']),
      permissionDecision: str(hso?['permissionDecision'])?.toLowerCase(),
      permissionDecisionReason: str(hso?['permissionDecisionReason']),
      updatedInput: updated,
    );
  }
}

/// Parsed verdict of a prompt-type hook evaluation.
class PromptHookVerdict {
  /// 'block' or 'approve'.
  final String decision;
  final String? reason;

  const PromptHookVerdict(this.decision, [this.reason]);
}
/// normalized [PluginHook]s at the 14 canonical agent-lifecycle points.
///
/// Production plugin hook lifecycle (spec §8) — the runtime that fires
/// normalized [PluginHook]s at the 14 canonical agent-lifecycle points.
/// Event sources, in precedence order:
///   1. Registered normalized manifests (the contribution registry) —
///      ordered [PluginHook] lists, session-scoped by activation (§7).
///   2. Legacy installed [PluginItem] hook maps (`on_*` names) — migrated
///      on the fly through the frozen alias map (`canonicalHookEvent`).
///
/// Ordering (§8.2): install/registration order, then manifest order.
///
/// Blocking (§8.2): `pre_tool`, `permission_request` (via [fireGate])
/// and `stop` (via [fireStop]) may deny, and only via exit code 2 or a
/// valid JSON `{"decision":"block","reason":"…"}`. A USER-initiated stop
/// ([userStopChecker]) always wins over Stop-hook vetoes. Every other
/// event is fire-and-forget observe. Crash, timeout, missing interpreter,
/// malformed output, or any other nonzero exit is a visible fail-open
/// warning + ledger event — a broken hook script can never wedge the
/// agent run.
///
/// Hook child processes receive the FULL JSON payload on stdin (Claude
/// Code contract — real hooks do `json.load(sys.stdin)`), in addition to
/// the env vars below.
///
/// Environment per invocation: `PLUGIN_ROOT` (plugin content root),
/// `PLUGIN_STORAGE` (per-plugin private storage dir), `PLUGIN_WORKSPACE`
/// (session workspace), `PLUGIN_SESSION`, `PLUGIN_MODEL`, `PLUGIN_EVENT`
/// (canonical name), `PLUGIN_PAYLOAD` (capped JSON), `CLAUDE_PROJECT_DIR`,
/// `CLAUDE_ENV_FILE` (per-session env file a SessionStart hook can append
/// to via `hookSpecificOutput.envFileAppend`), `CLAUDE_CODE_REMOTE`,
/// plus the legacy `OVID_HOOK_*` names for backward compatibility.
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

  /// Wiring point for prompt-type hooks (item 3). The AgentService worker
  /// sets this to route prompt-hook evaluation through the agent's model:
  ///   HookService.I.promptHookEvaluator = (prompt, ctx) =>
  ///       AgentService.I.evaluatePromptHook(prompt, context: ctx);
  /// Null (default) = prompt hooks are skipped fail-open with a ledger note.
  PromptHookEvaluator? promptHookEvaluator;

  /// Wiring point for user-initiated stops (item 4). The AgentService worker
  /// sets this to report whether the stop for [sessionId] was USER-initiated
  /// (Stop button / cancel), e.g.:
  ///   HookService.I.userStopChecker = (sid) =>
  ///       AgentService.I.userStopRequestedFor(sid);
  /// A user stop ALWAYS wins over Stop-hook vetoes: [fireStop] returns
  /// allow without running any hook. Null (default) = no user signal, hooks
  /// may veto.
  bool Function(String sessionId)? userStopChecker;

  /// Invocations this boot (diagnostics surface).
  int fired = 0;
  int failed = 0;

  /// Default per-hook timeout when the hook declares none (§8.1).
  static const int defaultTimeoutS = 30;

  /// Hard cap on a declared per-hook timeout (§8.1). Best-effort parity:
  /// long-running hooks (compilers, test suites) may legitimately need
  /// the full five minutes.
  static const int maxTimeoutS = 300;

  /// Consecutive failures that trip the per-plugin per-session breaker.
  static const int breakerThreshold = 3;

  /// Max nested distinct-event hook executions (depth cap, §8.2).
  static const int maxDepth = 4;

  /// Per-session context injected by a `session_start` hook, keyed by session
  /// id. A [CC] plugin's SessionStart hook returns the text that becomes the
  /// session's standing context (e.g. `superpowers` injects its intro skill);
  /// the run loop reads this to prepend it. Bounded so a hostile hook cannot
  /// blow up the prompt.
  static const int maxSessionContextChars = 8192;
  final Map<String, String> _sessionContexts = {};

  /// The `session_start` context a hook produced for [sessionId], or ''.
  String sessionContextFor(String sessionId) =>
      _sessionContexts[sessionId] ?? '';

  /// Extract the injectable context from a hook's stdout, honoring the three
  /// output shapes real plugins use:
  ///   • [CC]:     `{"hookSpecificOutput":{"additionalContext":"…"}}`
  ///   • Cursor:  `{"additional_context":"…"}`
  ///   • SDK:     `{"additionalContext":"…"}`
  /// Non-JSON output is treated as plain context; a JSON object without a
  /// context field yields ''.
  static String extractHookContext(String stdout) {
    final t = stdout.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('{') && t.endsWith('}')) {
      try {
        final j = jsonDecode(t);
        if (j is Map) {
          final nested = j['hookSpecificOutput'];
          if (nested is Map && nested['additionalContext'] is String) {
            return (nested['additionalContext'] as String).trim();
          }
          for (final key in const [
            'additional_context',
            'additionalContext',
            'context',
          ]) {
            final v = j[key];
            if (v is String && v.trim().isNotEmpty) return v.trim();
          }
          return '';
        }
      } catch (_) {
        // Not JSON after all — fall through to raw text.
      }
    }
    return t;
  }

  /// Reset the per-session context map + test seams (isolated tests).
  @visibleForTesting
  void resetForTest() {
    _sessionContexts.clear();
    executorForTest = null;
    gateExecutorForTest = null;
    stdinExecutorForTest = null;
    execTimeoutForTest = null;
    promptHookEvaluator = null;
    userStopChecker = null;
    _consecutiveFails.clear();
    _tripped.clear();
    _firingEvents.clear();
    fired = 0;
    failed = 0;
  }

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
  Future<String> Function(String cmd, Map<String, String> env)? executorForTest;

  /// Test seam: replace the gate executor (no sandbox in unit tests).
  /// Signature: (command, env) → (exitCode, combinedOutput).
  @visibleForTesting
  Future<(int, String)> Function(String cmd, Map<String, String> env)?
  gateExecutorForTest;

  /// Test seam: stdin-aware executor (no sandbox in unit tests).
  /// Signature: (command, env, stdinJson) → (exitCode, combinedOutput).
  /// Consulted BEFORE [executorForTest] so tests can assert the exact JSON
  /// payload the hook child receives on stdin (item 1).
  @visibleForTesting
  Future<(int, String)> Function(
    String cmd,
    Map<String, String> env,
    String stdinJson,
  )?
  stdinExecutorForTest;

  /// Test seam: capture the resolved per-hook timeout (seconds) without
  /// executing anything. Signature: (seconds) → stdout.
  @visibleForTesting
  Future<String> Function(int seconds)? execTimeoutForTest;

  // ── Session state (breaker + recursion guard) ─────────────────────────

  /// Consecutive-failure counts: `pluginId|sessionId` → count.
  final Map<String, int> _consecutiveFails = {};

  /// Settled breakers: `pluginId|sessionId` → true once tripped.
  final Set<String> _tripped = {};

  /// Events currently executing (recursion prevention — §8.2), keyed by
  /// `sessionId|canonicalEvent`. Distinct concurrent sessions are independent;
  /// a session cannot re-fire its own in-flight event.
  final Set<String> _firingEvents = {};

  /// Per-invocation-chain hook nesting depth (Zone value). Concurrent sibling
  /// fires each own their chain budget instead of sharing one global cap.
  static final Object _depthKey = Object();

  static int _chainDepth() => Zone.current[_depthKey] as int? ?? 0;

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

  /// Upper bound on a declared matcher. Real matchers are short (`*`, a tool
  /// name, a `|`-alternation); anything longer is treated as hostile and the
  /// hook is skipped rather than compiled.
  static const int maxMatcherLength = 256;

  /// Whether [matcher] is safe to compile. Rejects oversized patterns and
  /// nested quantifiers (`(a+)+`, `(.*)*`) — the classic catastrophic-
  /// backtracking shapes that can hang the isolate (ReDoS). Empty and `*`
  /// are safe (they mean "match all").
  static bool isSafeMatcher(String matcher) {
    if (matcher.isEmpty || matcher == '*') return true;
    if (matcher.length > maxMatcherLength) return false;
    // A quantifier applied to a group that itself contains a quantifier.
    if (RegExp(r'\([^)]*[*+?][^)]*\)[*+?]').hasMatch(matcher)) return false;
    return true;
  }

  /// Redact secret-looking values from a hook payload before it reaches a
  /// plugin. A `pre_tool` payload carries the raw tool args — including
  /// provider API keys from `catalog_set_provider_key` — and any plugin with
  /// the observe capability could otherwise exfiltrate them.
  static Map<String, dynamic> redactHookPayload(Map<String, dynamic> payload) {
    return _redactValue(payload) as Map<String, dynamic>;
  }

  static const Set<String> _secretKeyMarkers = {
    'apikey',
    'api_key',
    'key',
    'token',
    'secret',
    'password',
    'passwd',
    'authorization',
    'auth',
    'credential',
    'private_key',
    'access_key',
  };

  static bool _isSecretKey(String key) {
    final k = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
    for (final m in _secretKeyMarkers) {
      if (k == m || k.endsWith('_$m') || k.contains(m)) return true;
    }
    return false;
  }

  static Object? _redactValue(Object? value, {String? key}) {
    if (key != null && _isSecretKey(key)) return '[redacted]';
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key.toString(): _redactValue(e.value, key: e.key.toString()),
      };
    }
    if (value is List) {
      return [for (final v in value) _redactValue(v)];
    }
    return value;
  }

  /// One resolved hook invocation target.
  ///
  /// [CC] matchers are event-specific: tool events match the tool name, but
  /// `SessionStart` matches the session SOURCE (`startup`/`resume`/`clear`/
  /// `compact`). Matching every event against `payload['tool']` silently
  /// dropped every SessionStart hook (e.g. `superpowers` declares
  /// `startup|clear|compact`). `*` and empty mean "all".
  static bool _matcherApplies(
    String canonicalEvent,
    String? matcher,
    Map<String, dynamic> payload,
  ) {
    if (matcher == null || matcher.isEmpty || matcher == '*') return true;
    if (!isSafeMatcher(matcher)) return false;
    final subject = _matcherSubject(canonicalEvent, payload);
    // Anchor the whole-string alternatives so `startup` does not match
    // `startupx`, but still allow a plain substring for tool names.
    try {
      return RegExp(matcher).hasMatch(subject);
    } catch (_) {
      return false; // malformed matcher → skip (fail-open)
    }
  }

  /// The string a matcher runs against for [canonicalEvent].
  static String _matcherSubject(
    String canonicalEvent,
    Map<String, dynamic> payload,
  ) {
    if (canonicalEvent == 'session_start' || canonicalEvent == 'session_end') {
      final reason = payload['reason']?.toString() ?? '';
      return _ccSessionSource(reason);
    }
    return payload['tool']?.toString() ?? '';
  }

  /// Map Ovid's session-start reason onto the [CC] source token a plugin's
  /// matcher expects. Ovid has no `clear`/`compact` start reasons yet, so
  /// those alternatives simply never match here.
  static String _ccSessionSource(String reason) {
    switch (reason) {
      case 'created':
      case 'implicit':
      case 'subagent':
        return 'startup';
      case 'restored':
        return 'resume';
      default:
        return reason;
    }
  }

  /// Legacy/CC-native alias keys per canonical event — the reverse of the
  /// frozen `canonicalHookEvent` map (plugin_adapters.dart). A legacy
  /// `PluginItem` hook map keyed by any of these still fires when the
  /// canonical event is requested (migration ruling: old installs keep
  /// firing). `on_turn_start` is deliberately NOT an alias of
  /// `user_prompt_submit` here: legacy on_turn_start keeps its historical
  /// per-turn firing site, while canonical user_prompt_submit fires once
  /// per prompt at run entry (double-fire otherwise).
  static const Map<String, List<String>> _legacyEventAliases = {
    'session_start': ['on_session_start', 'SessionStart'],
    'session_end': ['SessionEnd'],
    'pre_request': ['on_pre_request'],
    'post_request': [],
    'pre_tool': ['on_pre_tool', 'PreToolUse'],
    'post_tool': ['on_post_tool', 'PostToolUse', 'PostToolUseFailure'],
    'user_prompt_submit': ['UserPromptSubmit'],
    'stop': ['on_turn_end', 'Stop'],
    'notification': ['Notification'],
    'pre_compact': ['PreCompact'],
    'post_compact': ['PostCompact'],
    'permission_request': ['PermissionRequest'],
    'subagent_start': ['SubagentStart'],
    'subagent_end': ['SubagentStop'],
  };

  /// Candidate legacy-map keys for [eventRaw]/[canonical], in priority
  /// order (canonical declaration wins over aliases).
  static List<String> _eventKeyCandidates(String eventRaw, String canonical) {
    final out = <String>[canonical];
    if (eventRaw != canonical) out.add(eventRaw);
    for (final a in _legacyEventAliases[canonical] ?? const <String>[]) {
      if (!out.contains(a)) out.add(a);
    }
    return out;
  }

  /// Display name for a plugin id — strips the internal `legacy:` prefix
  /// so deny reasons and env vars never leak it.
  static String _displayName(String pluginId) =>
      pluginId.startsWith('legacy:') ? pluginId.substring(7) : pluginId;

  /// All hooks listening for [eventRaw] (canonical or legacy alias),
  /// visible to [sessionId], in install order then manifest order.
  /// Legacy `PluginItem` map hooks are appended (mapped through the
  /// frozen alias map) after registered normalized hooks, keyed by
  /// `legacy:<plugin-name>` so install order across sources stays
  /// deterministic (registry registrations first, then plugin-list
  /// order). Each entry carries the event name the hook was DECLARED
  /// with (legacy hooks keep their legacy name in `OVID_HOOK_EVENT`).
  List<(String pluginId, PluginHook hook, String declaredEvent)> _resolveHooks(
    String eventRaw,
    String sessionId, {
    String? onlyPluginId,
  }) {
    final canonical = canonicalHookEvent(eventRaw) ?? eventRaw;
    final out = <(String, PluginHook, String)>[];
    for (final pid in PluginContributionRegistry.I.registeredPluginIds) {
      if (onlyPluginId != null && pid != onlyPluginId) continue;
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
        out.add((pid, h, canonical));
      }
    }
    if (!AppState.I.legacyPluginExecutionAllowed) return out;
    for (final p in AppState.I.plugins) {
      if (p.runtimeId != null ||
          !p.installed ||
          !p.enabled ||
          p.migrationRequired) {
        continue;
      }
      // Legacy map form — one command per (event, plugin). The map may be
      // keyed by the canonical name, the fired name, or any legacy/CC
      // alias of the canonical event; first key present wins.
      String? cmd;
      String? matcher;
      var declared = canonical;
      for (final key in _eventKeyCandidates(eventRaw, canonical)) {
        final c = p.hooks[key];
        if (c == null || c.trim().isEmpty) continue;
        cmd = c;
        matcher = p.hookMatchers[key] ?? p.hookMatchers[canonical];
        declared = key;
        break;
      }
      if (cmd == null) continue;
      out.add((
        'legacy:${p.name}',
        PluginHook(
          pluginId: 'legacy:${p.name}',
          event: canonical,
          ordinal: 0,
          type: 'command',
          payload: cmd,
          matcher: matcher,
          timeoutS: defaultTimeoutS,
        ),
        declared,
      ));
    }
    return out;
  }

  /// Whether ANY installed+enabled or registered-active plugin listens to
  /// [event] (canonical or legacy alias). Pass the REAL [sessionId] the
  /// subsequent fire/fireGate will use — dispatch guards must consult the
  /// running session so a `sessionActive` registration counts in its
  /// owning session (empty/absent stays fail-closed: global/legacy
  /// listeners only).
  bool hasHookListeners(String event, {String sessionId = ''}) {
    if (!enabled) return false;
    return _resolveHooks(event, sessionId).isNotEmpty;
  }

  /// Side-effect-free health probe: whether [pluginId] has a live normalized
  /// hook registration. Never executes a hook — only consults the registry.
  bool hasRegisteredHooks(String pluginId) {
    if (!PluginContributionRegistry.I.isRegistered(pluginId)) return false;
    final manifest = PluginContributionRegistry.I.manifestFor(pluginId);
    return manifest != null && manifest.hooks.isNotEmpty;
  }

  /// Whether any LEGACY `PluginItem` map hook listens for [event] — the
  /// per-turn `on_turn_start` firing site uses this so a plugin that
  /// declared the legacy name does not get a second canonical
  /// user_prompt_submit firing per turn (canonical fires once at runTask
  /// entry instead).
  bool hasLegacyMapHookListeners(String event) {
    if (!enabled || !AppState.I.legacyPluginExecutionAllowed) return false;
    return AppState.I.plugins.any(
      (p) =>
          p.installed &&
          p.enabled &&
          p.runtimeId == null &&
          !p.migrationRequired &&
          (p.hooks.containsKey(event) ||
              p.hooks.containsKey(canonicalHookEvent(event) ?? '')),
    );
  }

  // ── Execution core ───────────────────────────────────────────────────

  Future<Directory?> _sessionWorkDir(String sessionId) async {
    try {
      final s = sessionId.isEmpty
          ? null
          : AppState.I.sessions.where((x) => x.id == sessionId).firstOrNull;
      final pinned = s?.workspaceFolder;
      if (pinned != null && pinned.trim().isNotEmpty) {
        final d = Directory(pinned);
        if (d.existsSync()) return d;
      }
      final sid = s?.sandboxId ?? s?.id ?? sessionId;
      if (sid.isEmpty) return null;
      return await SandboxService.I.workDirFor(sid);
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

  /// Directory holding per-session hook env files (item 8).
  Future<Directory?> _hookEnvDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final d = Directory('${docs.path}/hook-env');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (_) {
      try {
        final d = Directory('${Directory.systemTemp.path}/hook-env');
        if (!d.existsSync()) d.createSync(recursive: true);
        return d;
      } catch (_) {
        return null;
      }
    }
  }

  /// Path of the per-session env file exposed as `CLAUDE_ENV_FILE`. A
  /// SessionStart hook appends `KEY=VALUE` lines to it (via
  /// `hookSpecificOutput.envFileAppend`); subsequent hooks in the same
  /// session inherit those vars. Empty when no dir is available.
  Future<String> _sessionEnvFilePath(String sessionId) async {
    if (sessionId.isEmpty) return '';
    final dir = await _hookEnvDir();
    if (dir == null) return '';
    final safe = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return '${dir.path}/$safe.env';
  }

  /// Load the session env file into a map (item 8). Malformed lines are
  /// skipped; the file is capped at 64 KB so a hostile hook cannot blow up
  /// every subsequent invocation's environment.
  Map<String, String> _loadSessionEnv(String path) {
    if (path.isEmpty) return const {};
    try {
      final f = File(path);
      if (!f.existsSync()) return const {};
      final text = f.readAsStringSync();
      final capped = text.length > 65536
          ? text.substring(0, 65536)
          : text;
      final out = <String, String>{};
      for (final rawLine in capped.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final eq = line.indexOf('=');
        if (eq <= 0) continue;
        final name = line.substring(0, eq).trim();
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) continue;
        out[name] = line.substring(eq + 1);
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Append validated `KEY=VALUE` lines to the session env file (called
  /// for SessionStart hook output). Best-effort — never throws.
  Future<void> _appendSessionEnv(String sessionId, List<String> lines) async {
    if (lines.isEmpty) return;
    try {
      final path = await _sessionEnvFilePath(sessionId);
      if (path.isEmpty) return;
      final f = File(path);
      if (f.existsSync() && f.lengthSync() > 65536) return;
      final sink = f.openWrite(mode: FileMode.append);
      try {
        for (final line in lines) {
          sink.writeln(line);
        }
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Delete the session env file (session_end cleanup).
  Future<void> _deleteSessionEnv(String sessionId) async {
    try {
      final path = await _sessionEnvFilePath(sessionId);
      if (path.isEmpty) return;
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<Map<String, String>> _envFor({
    required String pluginId,
    required PluginHook hook,
    required String canonical,
    required String declaredEvent,
    required String sessionId,
    required String payloadJson,
    required String workspace,
    required String storage,
    String? model,
  }) async {
    final pluginName = _displayName(pluginId);
    final root = _rootPathFor(pluginId, hook);
    // Per-session env vars a SessionStart hook persisted via
    // `hookSpecificOutput.envFileAppend` (item 8). Spread FIRST so the
    // built-in contract below always wins on collision.
    final envFilePath = await _sessionEnvFilePath(sessionId);
    final sessionEnv = _loadSessionEnv(envFilePath);
    return {
      ...sessionEnv,
      // Legacy env contract: the DECLARED name (a hook that registered
      // on_turn_start sees "on_turn_start"), never the internal prefix.
      'OVID_HOOK_EVENT': declaredEvent,
      'OVID_HOOK_PLUGIN': pluginName,
      'OVID_HOOK_SESSION': sessionId,
      'OVID_HOOK_PAYLOAD': cleanHookJson(payloadJson),
      'PLUGIN_ID': pluginName,
      // New canonical env contract (§8.1) — always the canonical name.
      'PLUGIN_EVENT': canonical,
      'PLUGIN_SESSION': sessionId,
      'PLUGIN_MODEL': model ?? '',
      'PLUGIN_PAYLOAD': cleanHookJson(payloadJson),
      'PLUGIN_ROOT': root,
      'PLUGIN_STORAGE': storage,
      'PLUGIN_WORKSPACE': workspace,
      // Host-harness aliases. Real [CC] plugins interpolate
      // `${CLAUDE_PLUGIN_ROOT}` into their hook commands (e.g.
      // `obra/superpowers` runs `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd"`);
      // without this the command expands to `/hooks/...` and fails. Setting
      // the CC name also steers polyglot hooks to their CC output shape.
      'CLAUDE_PLUGIN_ROOT': root,
      'OVID_PLUGIN_ROOT': root,
      // Missing-env parity (item 8): real [CC] hooks read these.
      'CLAUDE_PROJECT_DIR': workspace,
      'CLAUDE_ENV_FILE': envFilePath,
      // We run hooks locally, not on a remote host — the empty value
      // steers polyglot hooks to their local code path.
      'CLAUDE_CODE_REMOTE': '',
    };
  }

  String _rootPathFor(String pluginId, PluginHook hook) {
    if (pluginId.startsWith('legacy:')) {
      return '';
    }
    final m = PluginContributionRegistry.I.manifestFor(pluginId);
    return m?.rootPath ?? '';
  }

  /// Rewrite a Windows-style hook entrypoint to its runnable sibling.
  ///
  /// Real [CC] plugins ship e.g. `hooks/run-hook.cmd` (a Windows batch /
  /// polyglot wrapper) which cannot exec on Android. When the payload's
  /// first `.cmd` reference has an extensionless sibling that exists, use
  /// the sibling; otherwise leave the payload untouched (fail-open
  /// downstream). Known root variables are expanded against this plugin's
  /// installed root for the existence check only.
  @visibleForTesting
  String resolveHookPayload(PluginHook hook) {
    final payload = hook.payload;
    final match = RegExp(
      r'"([^"]+\.cmd)"|'
      r"'([^']+\.cmd)'"
      r'|(\S+\.cmd)\b',
      caseSensitive: false,
    ).firstMatch(payload);
    if (match == null) return payload;
    final token = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
    if (token.isEmpty) return payload;
    final root = _rootPathFor(hook.pluginId, hook);
    if (root.isEmpty) return payload;
    final expanded = expandPluginRoot(token, root);
    if (expanded.contains(r'$')) return payload;
    final sibling = expanded.substring(0, expanded.length - 4);
    try {
      if (!File(sibling).existsSync()) return payload;
    } catch (_) {
      return payload;
    }
    return payload.replaceRange(match.start, match.end, '"$sibling"');
  }

  /// Execute one hook. Returns (exitCode, stdout) — throws on
  /// exec error/timeout. Failures bubble to the caller's fail-open
  /// handling. [gate] selects the test seam matching the calling context
  /// (gate vs observe) so a test executor for one never intercepts the
  /// other. [stdinPayload] is the full JSON payload written to the child's
  /// stdin (item 1 — the Claude Code contract: real hooks do
  /// `json.load(sys.stdin)`; without it they read EOF and die).
  /// Whether the hook declaration asked for fire-and-forget execution
  /// (`"async": true`, stashed in `unknownFields` by the adapters).
  static bool _hookDeclaresAsync(PluginHook hook) =>
      hook.unknownFields['async'] == true;

  /// Interpreters the sandbox guarantees for hook execution. A manifest
  /// `shell` naming anything else falls back to bash with an optional
  /// compatibility note at adapter time ([kKnownHookShells]).
  static String _hookShell(PluginHook hook) {
    final declared = hook.unknownFields['shell'];
    if (declared is String && kKnownHookShells.contains(declared.trim())) {
      return declared.trim();
    }
    return 'bash';
  }

  Future<(int, String)> _exec(
    PluginHook hook,
    Map<String, String> env,
    Directory? cwd, {
    bool gate = false,
    String stdinPayload = '',
  }) async {
    final timeout = Duration(
      seconds: hook.timeoutS <= 0
          ? defaultTimeoutS
          : (hook.timeoutS > maxTimeoutS ? maxTimeoutS : hook.timeoutS),
    );
    // Windows-style entrypoints never reach a shell verbatim: prefer the
    // runnable sibling when one exists (fail-open keeps the old string).
    var command = resolveHookPayload(hook);
    final root = _rootPathFor(hook.pluginId, hook);
    if (root.isNotEmpty) {
      command = expandPluginRoot(command, root);
    }
    if (gate) {
      final g = gateExecutorForTest;
      if (g != null) return g(command, env);
    }
    // Stdin-aware test seam (item 1) — consulted before the legacy seams.
    final se = stdinExecutorForTest;
    if (se != null) return se(command, env, stdinPayload);
    final custom = executorForTest;
    if (custom != null) return (0, await custom(command, env));
    final t = execTimeoutForTest;
    if (t != null) return (0, await t(timeout.inSeconds));
    // The sandbox exec boundary — the hook env contract (CLAUDE_PLUGIN_ROOT,
    // PLUGIN_ROOT, PLUGIN_SESSION, ...). When a test override stands in for
    // the installed sandbox, route through `execChecked`, which consults it:
    // the override observes the FULL env map exactly as the production spawn
    // would receive it. Stdin delivery is additive — the stdin-aware seam
    // above already serves stdin-capable tests, and production keeps the
    // spawn path below. Without this, the spawn path bypassed the boundary
    // the contract tests pin, so hooks never reached it.
    if (SandboxService.hasExecOverride) {
      return SandboxService.I
          .execChecked(
            [_hookShell(hook), '-c', command],
            hostWorkDir: cwd,
            env: env,
          )
          .timeout(timeout);
    }
    // `execChecked` throws its own (more helpful) error when no sandbox is
    // installed; this guard exists only to fail early with the historical
    // message. A test override stands in for the installed sandbox, so it
    // must not be pre-empted here -- that boundary is exactly where the hook
    // env bug slipped through.
    if (!SandboxService.sandboxReady) {
      throw StateError('sandbox not installed');
    }
    // Spawn (not execChecked): the hook child MUST receive the full JSON
    // payload on stdin — `SandboxService.spawn` (Process.start) is the only
    // sandbox API exposing the stdin pipe. The UTF-8 bytes are written and
    // the pipe closed before we wait for exit, exactly like Claude Code.
    // The env map is the hook's ENTIRE runtime contract: [CC]/Codex plugins
    // interpolate `${CLAUDE_PLUGIN_ROOT}` (and read `PLUGIN_PAYLOAD`,
    // `PLUGIN_SESSION`, `PLUGIN_MODEL`, ...) inside their commands. Dropping
    // it here left every variable unset, so `"${CLAUDE_PLUGIN_ROOT}/hooks/
    // run-hook.cmd" session-start` expanded to `/hooks/run-hook.cmd` and died
    // with exit 127 -- for EVERY plugin, not just one. `spawn` merges
    // this over the sandbox env, so pass it through.
    //
    // Note: `spawn` (unlike the old `execChecked` path) enforces the
    // sandbox policy (destructive-command denylist) — a denied hook fails
    // open through the callers' normal error handling, same as any exec
    // failure.
    final proc = await SandboxService.I.spawn(
      [_hookShell(hook), '-c', command],
      hostWorkDir: cwd,
      env: env,
    );
    // Subscribe to stdout/stderr BEFORE touching stdin so a chatty hook
    // can never deadlock on a full pipe while we write.
    final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
    final stderrFuture = proc.stderr.transform(utf8.decoder).join();
    try {
      if (stdinPayload.isNotEmpty) {
        proc.stdin.add(utf8.encode(stdinPayload));
      }
      await proc.stdin.close();
    } catch (_) {
      // A hook that exits before reading stdin (closed pipe) must not fail
      // the invocation — its exit code/output still decide.
    }
    int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      // The old execChecked path leaked the timed-out process; kill it so
      // a hung hook cannot outlive its timeout (Stop can also reach it via
      // the sandbox's live-process registry — spawn registers it).
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      rethrow;
    }
    final out = await stdoutFuture;
    final err = await stderrFuture;
    return (code, '$out$err');
  }

  Future<void> _ledger(String sessionId, String kind, Map<String, dynamic> d) {
    return SessionLedger.I.append(sessionId, kind, d);
  }

  // ── fire: observe events (fire-and-forget semantics at call sites) ──

  /// Fire [event] for [sessionId]. Returns the combined stdout of all
  /// listener commands (≤2 KB — `pre_request` context injection) — empty
  /// when no listener or hooks are disabled. Observe events NEVER block
  /// the run: failures are ledgered and skipped. See [fireDetailed] for
  /// the output contract (`continue:false`, `suppressOutput`,
  /// `systemMessage`) and prompt-hook verdicts.
  Future<String> fire(
    String event,
    String sessionId, {
    Map<String, dynamic> payload = const {},
    String? model,
    String? onlyPluginId,
  }) async => (await fireDetailed(
    event,
    sessionId,
    payload: payload,
    model: model,
    onlyPluginId: onlyPluginId,
  )).output;

  /// [fire] with the full output contract: `continue:false` halting,
  /// `suppressOutput` filtering, surfaced `systemMessage`s, and
  /// prompt-hook block verdicts. Blocking stop semantics live in
  /// [fireStop] — call exactly one of the two for the `stop` event.
  Future<HookFireResult> fireDetailed(
    String event,
    String sessionId, {
    Map<String, dynamic> payload = const {},
    String? model,
    String? onlyPluginId,
  }) async {
    if (!enabled) return const HookFireResult(output: '');
    final canonical = canonicalHookEvent(event) ?? event;
    // Recursion prevention: never re-fire the SAME event for the SAME session
    // while it is executing. Concurrent DISTINCT sessions are independent and
    // must both run (workflow child fan-out).
    final guardKey = '$sessionId|$canonical';
    if (_firingEvents.contains(guardKey)) {
      return const HookFireResult(output: '');
    }
    final chainDepth = _chainDepth();
    if (chainDepth >= maxDepth) return const HookFireResult(output: '');
    final hooks = _resolveHooks(event, sessionId, onlyPluginId: onlyPluginId);
    if (hooks.isEmpty) return const HookFireResult(output: '');

    _firingEvents.add(guardKey);
    try {
      final result = await runZoned(
        () => _runHooks(
          sessionId: sessionId,
          canonical: canonical,
          hooks: hooks,
          payload: payload,
          model: model,
        ),
        zoneValues: {_depthKey: chainDepth + 1},
      );
      // A SessionStart hook's output is the session's standing context
      // (real [CC] plugins inject a skill here). Extract it once and hold it
      // for the run loop, which prepends it to the request.
      if (canonical == 'session_start' && result.output.isNotEmpty) {
        final ctx = extractHookContext(result.output);
        if (ctx.isNotEmpty) _sessionContexts[sessionId] = ctx;
      }
      if (canonical == 'session_end') {
        // The per-session env file dies with the session (item 8), and so
        // does the cached session_start context — a new session re-fires
        // session_start and rebuilds it.
        _sessionContexts.remove(sessionId);
        await _deleteSessionEnv(sessionId);
      }
      return result;
    } finally {
      _firingEvents.remove(guardKey);
    }
  }

  /// Evaluate one prompt-type hook through the wired [promptHookEvaluator]
  /// (item 3). Returns the parsed verdict, or null when the hook was
  /// skipped (no evaluator wired / evaluation failed / unparseable
  /// response) — every skip is fail-open with a ledger note.
  Future<PromptHookVerdict?> _evalPromptHook({
    required String pluginId,
    required PluginHook hook,
    required String canonical,
    required String sessionId,
    required Map<String, dynamic> payload,
    required String? model,
    required String stdinJson,
  }) async {
    final record = {
      'plugin': pluginId,
      'event': canonical,
      'type': 'prompt',
    };
    final eval = promptHookEvaluator;
    if (eval == null) {
      fired++;
      try {
        await _ledger(sessionId, 'hook/result', {
          ...record,
          'ok': false,
          'reason':
              'prompt-type hook skipped: no PromptHookEvaluator wired '
              '(fail-open)',
        });
      } catch (_) {}
      return null;
    }
    fired++;
    try {
      await _ledger(sessionId, 'hook/invoked', {
        ...Map<String, dynamic>.from(record),
        'promptChars': hook.payload.length,
      });
    } catch (_) {}
    final prompt = _buildPromptHookPrompt(
      hook: hook,
      canonical: canonical,
      sessionId: sessionId,
      stdinJson: stdinJson,
    );
    String? response;
    try {
      response = await eval(prompt, {
        'event': canonical,
        'session': sessionId,
        'plugin': _displayName(pluginId),
        'hook': hook.canonicalId,
        'model': ?model,
      }).timeout(const Duration(seconds: 120));
    } catch (e) {
      failed++;
      _recordFailure(pluginId, sessionId);
      try {
        await _ledger(sessionId, 'hook/result', {
          ...record,
          'ok': false,
          'error': e.toString(),
          'warning': 'prompt-hook evaluation failed (fail-open)',
        });
      } catch (_) {}
      return null;
    }
    final verdict = parsePromptHookDecision(response ?? '');
    if (verdict == null) {
      _recordSuccess(pluginId, sessionId);
      try {
        await _ledger(sessionId, 'hook/result', {
          ...record,
          'ok': true,
          'decision': 'unparseable — fail-open',
        });
      } catch (_) {}
      return null;
    }
    _recordSuccess(pluginId, sessionId);
    try {
      await _ledger(sessionId, 'hook/result', {
        ...record,
        'ok': true,
        'decision': verdict.decision,
        if (verdict.reason != null) 'reason': verdict.reason,
      });
    } catch (_) {}
    return verdict;
  }

  /// Build the evaluation prompt for a prompt-type hook: the hook's rule
  /// text plus the same event context a command hook would see on stdin.
  static String _buildPromptHookPrompt({
    required PluginHook hook,
    required String canonical,
    required String sessionId,
    required String stdinJson,
  }) {
    final eventName = ccHookEventNames[canonical] ?? canonical;
    return 'You are evaluating a plugin hook rule for the "$eventName" '
        'event (session "$sessionId"). The plugin registered this rule:\n\n'
        '${hook.payload}\n\n'
        'The current event context (JSON):\n$stdinJson\n\n'
        'Decide whether this event violates the rule. Reply with exactly '
        'one word — "block" or "approve" — or with JSON '
        '{"decision": "block"|"approve", "reason": "..."}. '
        '"block" stops the event; "approve" lets it proceed.';
  }

  /// The `"if"` predicate declared on [hook] (`unknownFields` first, then
  /// `frontmatter`), or null when the hook declares none.
  static String? _hookIfPredicate(PluginHook hook) {
    final u = hook.unknownFields['if'];
    if (u is String && u.trim().isNotEmpty) return u;
    final f = hook.frontmatter['if'];
    if (f is String && f.trim().isNotEmpty) return f;
    return null;
  }

  Future<HookFireResult> _runHooks({
    required String sessionId,
    required String canonical,
    required List<(String, PluginHook, String)> hooks,
    required Map<String, dynamic> payload,
    required String? model,
  }) async {
    final payloadJson = jsonEncode({
      'event': canonical,
      'session': sessionId,
      ...redactHookPayload(payload),
    });
    final cwd = await _sessionWorkDir(sessionId);
    // The FULL JSON payload every hook child receives on stdin (item 1).
    final stdinJson = buildHookStdinJson(
      canonicalEvent: canonical,
      sessionId: sessionId,
      payload: payload,
      cwd: cwd?.path ?? '',
      transcriptPath: _transcriptPathFrom(payload),
    );
    final collected = <String>[];
    final systemMessages = <String>[];
    var halted = false;
    String? promptBlockReason;
    for (final (pluginId, hook, declaredEvent) in hooks) {
      if (!_matcherApplies(canonical, hook.matcher, payload)) continue;
      if (_tripped.contains('$pluginId|$sessionId')) continue;
      // `"if"` predicate (item 7): a non-matching hook is skipped — it is
      // a filter, not a failure, so no breaker/ledger noise.
      final ifPredicate = _hookIfPredicate(hook);
      if (ifPredicate != null && !ifPredicateMatches(ifPredicate, payload)) {
        continue;
      }
      if (hook.type == 'prompt') {
        // Prompt-type hooks are LLM-evaluated where the event supports it
        // (item 3); elsewhere they keep the historical skip-with-note.
        if (promptHookEvents.contains(canonical)) {
          final verdict = await _evalPromptHook(
            pluginId: pluginId,
            hook: hook,
            canonical: canonical,
            sessionId: sessionId,
            payload: payload,
            model: model,
            stdinJson: stdinJson,
          );
          if (verdict != null && verdict.decision == 'block') {
            promptBlockReason ??=
                verdict.reason ?? 'blocked by prompt hook ($pluginId)';
          }
          continue;
        }
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
      if (hook.type != 'command') continue;
      final storage = await _pluginStorageDir(pluginId);
      final env = await _envFor(
        pluginId: pluginId,
        hook: hook,
        canonical: canonical,
        declaredEvent: declaredEvent,
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
          _hookDeclaresAsync(hook)
              ? {...Map<String, dynamic>.from(record), 'async': true}
              : Map<String, dynamic>.from(record),
        );
      } catch (_) {}
      // `async: true` hooks are fire-and-forget per the Claude Code
      // contract: launch without awaiting so they never block the session.
      // Their output is NOT collected into session context (it may arrive
      // after the turn), and failures only touch the health ledger.
      if (_hookDeclaresAsync(hook)) {
        // `_exec` resolves normally on nonzero exit — check the code the
        // same way the sync path does, instead of recording every
        // completed process as a success.
        unawaited(
          _exec(hook, env, cwd, stdinPayload: stdinJson)
              .then((result) async {
                final (code, out) = result;
                if (code == 0) {
                  _recordSuccess(pluginId, sessionId);
                  return;
                }
                _recordFailure(pluginId, sessionId);
                try {
                  await _ledger(sessionId, 'hook/result', {
                    ...record,
                    'ok': false,
                    'exit': code,
                    'async': true,
                    'warning': 'async hook failed (fail-open) — output ignored',
                    'stdout': cleanHookJson(out),
                  });
                } catch (_) {}
              })
              .catchError((Object _) {
                _recordFailure(pluginId, sessionId);
              }),
        );
        continue;
      }
      try {
        final (code, out) = await _exec(hook, env, cwd, stdinPayload: stdinJson);
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
        // A SessionStart hook may persist vars for the session via
        // `hookSpecificOutput.envFileAppend` (item 8).
        if (canonical == 'session_start') {
          final appends = extractEnvFileAppend(out);
          if (appends.isNotEmpty) {
            await _appendSessionEnv(sessionId, appends);
          }
        }
        final contract = HookOutputContract.parse(out);
        final trimmed = out.trim();
        if (trimmed.isNotEmpty && !contract.suppressOutput) {
          collected.add(trimmed);
        }
        if (contract.systemMessage != null) {
          systemMessages.add(contract.systemMessage!);
        }
        try {
          await _ledger(sessionId, 'hook/result', {
            ...record,
            'ok': true,
            if (trimmed.isNotEmpty) 'stdout': cleanHookJson(out),
            if (!contract.continueHooks) 'halted': true,
            if (contract.suppressOutput) 'suppressOutput': true,
            if (contract.systemMessage != null)
              'systemMessage': contract.systemMessage,
          });
        } catch (_) {}
        // `continue:false` halts further hooks for this event (item 9).
        if (!contract.continueHooks) {
          halted = true;
          break;
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
    final joined = collected.join('\n');
    // session_start output becomes standing session context, so it gets the
    // larger context cap; other events are short injections (≤2 KB).
    final cap = canonical == 'session_start' ? maxSessionContextChars : 2048;
    final output = joined.length > cap
        ? '${joined.substring(0, cap)}\n[hook output truncated]'
        : joined;
    return HookFireResult(
      output: output,
      systemMessages: systemMessages,
      halted: halted,
      promptBlockReason: promptBlockReason,
    );
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

  /// Claude Code event name for a canonical event (the `hook_event_name`
  /// real hooks switch on). Events with no CC equivalent keep the
  /// canonical name.
  static const Map<String, String> ccHookEventNames = {
    'session_start': 'SessionStart',
    'session_end': 'SessionEnd',
    'user_prompt_submit': 'UserPromptSubmit',
    'pre_tool': 'PreToolUse',
    'post_tool': 'PostToolUse',
    'notification': 'Notification',
    'pre_compact': 'PreCompact',
    'post_compact': 'PostCompact',
    'stop': 'Stop',
    'subagent_start': 'SubagentStart',
    'subagent_end': 'SubagentStop',
    'permission_request': 'PermissionRequest',
  };

  /// Transcript path for hook stdin: the caller (AgentService) may
  /// supply `transcript_path` in the event payload; HookService has no
  /// other source for it. Empty when absent.
  static String _transcriptPathFrom(Map<String, dynamic> payload) {
    final v = payload['transcript_path'] ?? payload['transcriptPath'];
    return v is String ? v : '';
  }

  /// Build the FULL JSON payload a hook child receives on stdin (item 1 —
  /// the Claude Code contract: real hooks do `json.load(sys.stdin)`).
  /// Keys: `session_id`, `transcript_path`, `cwd`, `permission_mode`,
  /// `hook_event_name`, plus `tool_name`/`tool_input`/`tool_response`
  /// (tool events), `prompt` (user-prompt events), `reason` and
  /// event-specific extras when the caller supplied them. Values are
  /// redacted exactly like the env payload ([redactHookPayload]).
  @visibleForTesting
  static String buildHookStdinJson({
    required String canonicalEvent,
    required String sessionId,
    required Map<String, dynamic> payload,
    required String cwd,
    String transcriptPath = '',
  }) {
    final redacted = redactHookPayload(payload);
    final m = <String, dynamic>{
      'session_id': sessionId,
      // Explicit parameter wins; otherwise the caller may carry it in the
      // event payload (the two internal fire paths do this via
      // `_transcriptPathFrom`).
      'transcript_path': transcriptPath.isNotEmpty
          ? transcriptPath
          : _transcriptPathFrom(redacted),
      'cwd': cwd,
      'permission_mode': redacted['permission_mode']?.toString() ?? '',
      'hook_event_name': ccHookEventNames[canonicalEvent] ?? canonicalEvent,
    };
    final tool = redacted['tool'] ?? redacted['tool_name'];
    if (tool != null) m['tool_name'] = tool.toString();
    final toolInput =
        redacted['tool_input'] ?? redacted['args'] ?? redacted['input'];
    if (toolInput != null) m['tool_input'] = toolInput;
    final toolResult =
        redacted['tool_result'] ??
        redacted['tool_response'] ??
        redacted['result'];
    if (toolResult != null) m['tool_response'] = toolResult;
    final prompt = redacted['prompt'] ?? redacted['user_prompt'];
    if (prompt != null) m['prompt'] = prompt;
    final reason = redacted['reason'];
    if (reason != null) m['reason'] = reason.toString();
    // Event-specific extras real hooks read.
    if (canonicalEvent == 'notification' && redacted['message'] != null) {
      m['message'] = redacted['message'];
    }
    if (canonicalEvent == 'pre_compact' || canonicalEvent == 'post_compact') {
      if (redacted['trigger'] != null) m['trigger'] = redacted['trigger'];
    }
    return jsonEncode(m);
  }

  /// Evaluate a hook `"if"` predicate (item 7): `ToolName(arg-pattern)`,
  /// `ToolName(*)` or bare `ToolName`. The arg pattern wildcard-matches
  /// (`*` → `.*`, unanchored) against the JSON-encoded tool input; `:`
  /// matches a colon or whitespace so `Bash(git commit:*)` matches
  /// `{"command": "git commit -m …"}`. A malformed predicate never matches
  /// (the hook is skipped — fail-closed for the hook, fail-open for the
  /// run). `*` as the tool part matches any tool.
  @visibleForTesting
  static bool ifPredicateMatches(
    String predicate,
    Map<String, dynamic> payload,
  ) {
    final p = predicate.trim();
    if (p.isEmpty) return true;
    String toolPart;
    String? argPattern;
    final paren = p.indexOf('(');
    if (paren < 0) {
      toolPart = p;
    } else {
      if (!p.endsWith(')')) return false;
      toolPart = p.substring(0, paren).trim();
      argPattern = p.substring(paren + 1, p.length - 1).trim();
    }
    if (toolPart.isEmpty) return false;
    final tool = (payload['tool'] ?? payload['tool_name'])?.toString() ?? '';
    if (toolPart != '*' && toolPart != tool) return false;
    if (argPattern == null || argPattern.isEmpty || argPattern == '*') {
      return true;
    }
    final input = payload['tool_input'] ?? payload['args'] ?? payload['input'];
    final subject = input is String ? input : jsonEncode(input);
    // `*` → `.*`; `:` is a soft separator (colon or whitespace); everything
    // else is literal. Unanchored: the pattern may match anywhere in the
    // JSON-encoded input.
    final buf = StringBuffer();
    for (final ch in argPattern.split('')) {
      if (ch == '*') {
        buf.write('.*');
      } else if (ch == ':') {
        buf.write('[:\\s]');
      } else {
        buf.write(RegExp.escape(ch));
      }
    }
    try {
      return RegExp(buf.toString(), dotAll: true).hasMatch(subject);
    } catch (_) {
      return false;
    }
  }

  /// Parse an LLM's verdict on a prompt-type hook (item 3). Accepts JSON
  /// `{"decision":"block"|"approve","reason":"…"}` or plain text:
  /// leading "block"/"approve" wins, else the first whole-word occurrence
  /// (a negated "do not block" does NOT count as block). Anything else
  /// yields null → the caller fails open.
  @visibleForTesting
  static PromptHookVerdict? parsePromptHookDecision(String response) {
    final t = response.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('{') && t.endsWith('}')) {
      try {
        final j = jsonDecode(t);
        if (j is Map) {
          final d = j['decision']?.toString().toLowerCase().trim();
          if (d == 'block' || d == 'approve') {
            final r = j['reason'];
            return PromptHookVerdict(
              d!,
              r is String && r.trim().isNotEmpty ? r.trim() : null,
            );
          }
        }
      } catch (_) {
        // Fall through to the text heuristics.
      }
    }
    final lower = t.toLowerCase();
    final capped = t.length > 500 ? '${t.substring(0, 500)}…' : t;
    if (lower.startsWith('block')) return PromptHookVerdict('block', capped);
    if (lower.startsWith('approve')) {
      return PromptHookVerdict('approve', capped);
    }
    final negatedBlock = RegExp(
      r"\b(do not|don't|dont|never|no)\s+block\b",
    ).hasMatch(lower);
    if (!negatedBlock && RegExp(r'\bblock\b').hasMatch(lower)) {
      return PromptHookVerdict('block', capped);
    }
    if (RegExp(r'\bapprove\b').hasMatch(lower)) {
      return PromptHookVerdict('approve', capped);
    }
    return null;
  }

  /// Events on which prompt-type hooks are evaluated (item 3). Other
  /// events skip prompt hooks with a ledger note (no shell runtime).
  static const Set<String> promptHookEvents = {
    'stop',
    'subagent_end',
    'user_prompt_submit',
    'pre_tool',
    'permission_request',
  };

  /// Extract `KEY=VALUE` lines a SessionStart hook appends to the
  /// per-session env file (item 8): `hookSpecificOutput.envFileAppend`
  /// (list of strings or map) or `hookSpecificOutput.env` (map). Only
  /// well-formed `NAME=value` lines survive; anything else is dropped.
  @visibleForTesting
  static List<String> extractEnvFileAppend(String stdout) {
    final t = stdout.trim();
    if (t.isEmpty || !t.startsWith('{') || !t.endsWith('}')) {
      return const [];
    }
    dynamic j;
    try {
      j = jsonDecode(t);
    } catch (_) {
      return const [];
    }
    if (j is! Map) return const [];
    final hso = j['hookSpecificOutput'];
    if (hso is! Map) return const [];
    final hm = hso.cast<String, dynamic>();
    final append = hm['envFileAppend'] ?? hm['env_file_append'];
    List<String> raw;
    if (append is List) {
      raw = [for (final e in append) e.toString()];
    } else if (append is Map) {
      raw = [
        for (final e in append.entries) '${e.key}=${e.value}',
      ];
    } else {
      final envMap = hm['env'];
      if (envMap is! Map) return const [];
      raw = [
        for (final e in envMap.entries) '${e.key}=${e.value}',
      ];
    }
    final nameRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');
    return [
      for (final line in raw)
        if (nameRe.hasMatch(line.trim())) line.trim(),
    ];
  }

  // ── fireGate: blocking events (pre_tool, permission_request) ────────

  /// Fire the GATING event [event] for [sessionId] and return the gate
  /// outcome. Only `pre_tool` and `permission_request` are blocking
  /// (§8.2); a block requires exit code 2 or a valid JSON block decision.
  /// `hookSpecificOutput.updatedInput` rewrites the tool args (returned on
  /// [HookGateResult.updatedInput] even when allowed) and
  /// `hookSpecificOutput.permissionDecision: "ask"` surfaces as
  /// [HookDecision.ask] for routing into the permission prompt. Everything
  /// else — crash, timeout, missing interpreter, malformed output, any
  /// other nonzero exit — fails OPEN with a ledger warning (a broken hook
  /// must never brick the run).
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
    final guardKey = '$sessionId|$canonical';
    if (_firingEvents.contains(guardKey)) {
      return const HookGateResult.allow();
    }
    final chainDepth = _chainDepth();
    if (chainDepth >= maxDepth) return const HookGateResult.allow();
    final hooks = _resolveHooks(event, sessionId);
    if (hooks.isEmpty) return const HookGateResult.allow();

    _firingEvents.add(guardKey);
    try {
      return await runZoned(
        () => _runGateHooks(
          sessionId: sessionId,
          canonical: canonical,
          hooks: hooks,
          payload: payload,
          model: model,
        ),
        zoneValues: {_depthKey: chainDepth + 1},
      );
    } finally {
      _firingEvents.remove(guardKey);
    }
  }

  // ── fireStop: the stop event as a blocking gate (item 4) ────────────

  /// Fire the `stop` hooks as a BLOCKING gate and return whether the stop
  /// may proceed. A Stop hook vetoes the stop (model loop continues) via
  /// exit code 2 or a JSON `{"decision":"block","reason":"…"}` — command
  /// or prompt-type hooks alike.
  ///
  /// A USER-initiated stop ALWAYS wins over hooks: pass
  /// [userStopRequested]: true (or wire [userStopChecker]) and the result
  /// is allow without running any hook. Call exactly one of [fireStop] /
  /// [fire] for the `stop` event — never both (each executes the hooks).
  ///
  /// AGENTSERVICE WIRING (for the AgentService worker): at the natural
  /// stop point, replace the fire-and-forget `fire('stop', …)` with:
  /// ```dart
  /// final stopRes = await HookService.I.fireStop(
  ///   sessionId,
  ///   payload: {...},
  ///   model: model,
  ///   userStopRequested: true, // when the user hit Stop/cancel
  /// );
  /// if (!stopRes.stopAllowed) {
  ///   // vetoed — continue the model loop instead of stopping
  /// }
  /// ```
  /// and set `HookService.I.userStopChecker = (sid) =>`
  /// `[passive per-session "user asked to stop" flag]` once at startup so
  /// [fireStop] can honor user stops without a per-call argument. The
  /// passive signal must NOT be `stopRequested()` itself (that method
  /// performs the stop); use the run's cancel flag.
  Future<HookStopResult> fireStop(
    String sessionId, {
    Map<String, dynamic> payload = const {},
    String? model,
    bool? userStopRequested,
  }) async {
    final userStop =
        userStopRequested ?? userStopChecker?.call(sessionId) ?? false;
    if (userStop) {
      return const HookStopResult.allow(userInitiated: true);
    }
    if (!enabled) return const HookStopResult.allow();
    const canonical = 'stop';
    final guardKey = '$sessionId|$canonical';
    if (_firingEvents.contains(guardKey)) {
      return const HookStopResult.allow();
    }
    final chainDepth = _chainDepth();
    if (chainDepth >= maxDepth) return const HookStopResult.allow();
    final hooks = _resolveHooks(canonical, sessionId);
    if (hooks.isEmpty) return const HookStopResult.allow();

    _firingEvents.add(guardKey);
    try {
      final gate = await runZoned(
        () => _runGateHooks(
          sessionId: sessionId,
          canonical: canonical,
          hooks: hooks,
          payload: payload,
          model: model,
        ),
        zoneValues: {_depthKey: chainDepth + 1},
      );
      if (gate.decision == HookDecision.deny) {
        return HookStopResult.veto(
          gate.decidedByPlugin,
          gate.reason ?? 'stopped by hook',
        );
      }
      // "ask" is meaningless at stop time — fail open (allow).
      return const HookStopResult.allow();
    } finally {
      _firingEvents.remove(guardKey);
    }
  }

  /// Runs the resolved gating hooks; always returns a [HookGateResult]
  /// (allow carrying any [HookGateResult.updatedInput] collected along the
  /// way). Callers own the recursion guard/zone wrapping.
  Future<HookGateResult> _runGateHooks({
    required String sessionId,
    required String canonical,
    required List<(String, PluginHook, String)> hooks,
    required Map<String, dynamic> payload,
    required String? model,
  }) async {
    final payloadJson = jsonEncode({
      'event': canonical,
      'session': sessionId,
      ...redactHookPayload(payload),
    });
    final cwd = await _sessionWorkDir(sessionId);
    final stdinJson = buildHookStdinJson(
      canonicalEvent: canonical,
      sessionId: sessionId,
      payload: payload,
      cwd: cwd?.path ?? '',
      transcriptPath: _transcriptPathFrom(payload),
    );
    Map<String, dynamic>? updatedInput;
    for (final (pluginId, hook, declaredEvent) in hooks) {
      if (!_matcherApplies(canonical, hook.matcher, payload)) continue;
      if (_tripped.contains('$pluginId|$sessionId')) continue;
      final ifPredicate = _hookIfPredicate(hook);
      if (ifPredicate != null && !ifPredicateMatches(ifPredicate, payload)) {
        continue;
      }
      final displayName = _displayName(pluginId);
      if (hook.type == 'prompt') {
        // Prompt-type hooks on gate events are LLM-evaluated (item 3); a
        // "block" verdict denies like exit code 2.
        if (!promptHookEvents.contains(canonical)) continue;
        final verdict = await _evalPromptHook(
          pluginId: pluginId,
          hook: hook,
          canonical: canonical,
          sessionId: sessionId,
          payload: payload,
          model: model,
          stdinJson: stdinJson,
        );
        if (verdict != null && verdict.decision == 'block') {
          failed++;
          final reason =
              verdict.reason ?? '$displayName denied this action';
          try {
            await _ledger(sessionId, 'hook/result', {
              'plugin': pluginId,
              'event': canonical,
              'type': 'prompt',
              'ok': false,
              'decision': 'deny',
              'reason': reason,
            });
          } catch (_) {}
          return HookGateResult.deny(
            displayName,
            reason,
            updatedInput: updatedInput,
          );
        }
        continue;
      }
      if (hook.type != 'command') continue;
      final storage = await _pluginStorageDir(pluginId);
      final env = await _envFor(
        pluginId: pluginId,
        hook: hook,
        canonical: canonical,
        declaredEvent: declaredEvent,
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
        final (code, out) = await _exec(
          hook,
          env,
          cwd,
          gate: true,
          stdinPayload: stdinJson,
        );
        final contract = HookOutputContract.parse(out);
        // Rewritten tool args (item 5) — collected even from hooks that
        // allow, so the caller can apply them pre-execution.
        if (contract.updatedInput != null) {
          updatedInput = contract.updatedInput;
        }
        final blockReason = jsonBlockReason(out);
        final decision = contract.decision;
        final permDecision = contract.permissionDecision;
        final denies =
            code == 2 ||
            blockReason != null ||
            decision == 'block' ||
            decision == 'deny' ||
            permDecision == 'deny';
        final asks = !denies &&
            (decision == 'ask' || permDecision == 'ask');
        if (denies || asks) {
          failed++;
          final reason =
              blockReason ??
              contract.reason ??
              contract.permissionDecisionReason ??
              (out.trim().isEmpty
                  ? '$displayName denied this action'
                  : cleanHookJson(out.trim()));
          try {
            await _ledger(sessionId, 'hook/result', {
              ...record,
              'ok': false,
              'exit': code,
              'decision': asks ? 'ask' : 'deny',
              'blockReason': ?blockReason,
              'reason': reason,
              if (contract.updatedInput != null)
                'updatedInput': contract.updatedInput,
            });
          } catch (_) {}
          return asks
              ? HookGateResult.ask(
                  displayName,
                  reason,
                  updatedInput: updatedInput,
                )
              : HookGateResult.deny(
                  displayName,
                  reason,
                  updatedInput: updatedInput,
                );
        }
        _recordSuccess(pluginId, sessionId);
        try {
          await _ledger(sessionId, 'hook/result', {
            ...record,
            'ok': true,
            'decision': 'allow',
            if (out.trim().isNotEmpty) 'stdout': cleanHookJson(out),
            if (contract.updatedInput != null)
              'updatedInput': contract.updatedInput,
            if (!contract.continueHooks) 'halted': true,
          });
        } catch (_) {}
        if (!contract.continueHooks) break;
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
    return HookGateResult.allow(updatedInput: updatedInput);
  }
}
