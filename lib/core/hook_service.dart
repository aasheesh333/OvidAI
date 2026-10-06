import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_adapters.dart';
import 'hook_execution_scope.dart';
import 'hook_context_store.dart';
import 'plugin_manifest.dart';
import 'plugin_registry.dart';
import 'sandbox_service.dart';
import 'session_ledger.dart';
import 'state.dart';
import 'diag.dart';

/// Evaluates a prompt-type hook with the agent's model. The AgentService
/// worker wires this: `HookService.I.promptHookEvaluator = (prompt, ctx) =>
/// AgentService.I.completeQuietly(prompt, ...)` (or equivalent). The
/// returned string is parsed by [HookService.parsePromptHookDecision]
/// (JSON `{"decision":"block"|"approve","reason":"…"}` or plain-text
/// "block"/"approve" heuristics). Null/empty or a throw fails OPEN.
typedef PromptHookEvaluator =
    Future<String?> Function(String prompt, Map<String, dynamic> context);

/// Tool-capable agent-hook evaluation request (plugin hooks with
/// `type: "agent"`). Unlike prompt hooks, agent hooks may call tools —
/// the wired evaluator owns tool execution and must enforce
/// [AgentHookEvaluation.approvedTools] plus its own permission policy.
/// Bounds are part of the contract: [AgentHookEvaluation.budget] is the
/// hard wall-clock limit (HookService drops any late result), and
/// [AgentHookEvaluation.cancelled] completes when the evaluation is
/// fenced — plugin removed/re-registered, session generation ended,
/// hooks disabled, or the budget expired — so a well-behaved evaluator
/// can stop its work promptly.
class AgentHookEvaluation {
  const AgentHookEvaluation({
    required this.prompt,
    required this.context,
    required this.approvedTools,
    required this.budget,
    required this.cancelled,
  });

  /// Hook rule text. The redacted event stdin JSON is in [context]['stdin'].
  final String prompt;

  /// Redacted event/session/plugin/hook/model context.
  final Map<String, dynamic> context;

  /// Complete tool allowlist for THIS evaluation: the hook's own bounded
  /// `tools` declaration, never broader. Empty means no tools. HookService
  /// executes nothing itself.
  final Set<String> approvedTools;

  /// Hard evaluation budget; results after it is exceeded are dropped.
  final Duration budget;

  /// Completes when this evaluation is fenced (or once it settles).
  final Future<void> cancelled;
}

/// Parsed decision of an agent-type hook evaluation. [decision] is
/// operational data ('block' stops/vetoes; 'approve' proceeds); [reason]
/// is publication text and is secret-scrubbed before ledger/result use.
class AgentHookVerdict {
  final String decision;
  final String? reason;

  const AgentHookVerdict(this.decision, [this.reason]);

  const AgentHookVerdict.block([this.reason]) : decision = 'block';

  const AgentHookVerdict.approve([this.reason]) : decision = 'approve';

  bool get isBlock => decision == 'block';
}

/// Evaluates an agent-type hook. Production integration must wire this to a
/// bounded tool-capable agent loop (approved tool scope + cancellation);
/// it is NEVER routed through [PromptHookEvaluator] — reusing the
/// prompt-only evaluator would misrepresent agent semantics. Null
/// verdict, timeout, throw or any fence fails OPEN with a ledger note.
typedef AgentHookEvaluator =
    Future<AgentHookVerdict?> Function(AgentHookEvaluation evaluation);

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

  /// True when a hook returned `hookSpecificOutput.permissionDecision:
  /// "allow"`. In Claude Code that BYPASSES the user permission prompt for
  /// this tool call — before this flag existed Ovid treated `allow` as merely
  /// "not deny / not ask" and still prompted the user, so a plugin that had
  /// already decided could never actually decide (audit 2026-09-25).
  ///
  /// Scoped narrowly on purpose: it skips the ordinary approval prompt only.
  /// Destructive commands still confirm, plan mode still asks nothing, and a
  /// `permission_request` hook deny still wins — the bypass cannot widen those.
  final bool bypassPermission;

  /// Backward-compat: true only for [HookDecision.allow].
  bool get allowed => decision == HookDecision.allow;

  /// Backward-compat: the plugin behind a deny (or ask).
  String? get deniedByPlugin =>
      decision == HookDecision.allow ? null : decidedByPlugin;

  const HookGateResult.allow({this.updatedInput, this.bypassPermission = false})
    : decision = HookDecision.allow,
      decidedByPlugin = null,
      reason = null;

  const HookGateResult.deny(
    this.decidedByPlugin,
    this.reason, {
    this.updatedInput,
  }) : decision = HookDecision.deny,
       bypassPermission = false;

  const HookGateResult.ask(
    this.decidedByPlugin,
    this.reason, {
    this.updatedInput,
  }) : decision = HookDecision.ask,
       bypassPermission = false;
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
  /// For pre_request/user_prompt_submit, independently extracted and bounded
  /// context. Other events retain stdout after suppressOutput/continue handling;
  /// session_start injection uses [HookService.sessionContextFor], not this JSON.
  final String output;

  /// `systemMessage` values surfaced by hooks, in firing order.
  final List<String> systemMessages;

  /// True when a hook returned `continue:false` and later hooks were skipped.
  final bool halted;

  /// Reason when an evaluated prompt-type hook returned "block" on an
  /// observe event (null when no prompt hook blocked). The AgentService
  /// worker decides what a prompt-block means for the run.
  final String? promptBlockReason;

  /// Set when a COMMAND hook exited 2 on an event Claude Code lets block
  /// (`user_prompt_submit`). Exit 2 means "block this and show stderr to the
  /// user"; on every other observe event exit 2 stays fail-open. Null when
  /// nothing blocked (audit 2026-09-25).
  final String? blockedReason;

  /// At least one eligible hook could not execute. Session lifecycle callers
  /// can retry without replaying already-successful hooks.
  final bool retryableFailure;

  const HookFireResult({
    required this.output,
    this.systemMessages = const [],
    this.halted = false,
    this.promptBlockReason,
    this.blockedReason,
    this.retryableFailure = false,
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
/// Circuit breaker (§8.2): 3 consecutive execution failures of one plugin in
/// one session disable its hooks. Synchronous session_start and unavailable
/// runtimes remain retryable, without consuming the breaker.
class HookService extends ChangeNotifier {
  HookService._() {
    PluginContributionRegistry.I.addRegistrationListener(_registrationChanged);
  }
  static final HookService I = HookService._();

  /// Master kill-switch (Settings toggle, default ON).
  bool enabled = true;

  /// Wiring point for prompt-type hooks (item 3). The AgentService worker
  /// sets this to route prompt-hook evaluation through the agent's model:
  ///   HookService.I.promptHookEvaluator = (prompt, ctx) =>
  ///       AgentService.I.evaluatePromptHook(prompt, context: ctx);
  /// Null (default) = prompt hooks are skipped fail-open with a ledger note.
  PromptHookEvaluator? promptHookEvaluator;

  /// Wiring point for tool-capable agent-type hooks. AgentService currently
  /// wires only prompt hooks; production integration still needs a bounded
  /// agent loop that enforces
  /// [AgentHookEvaluation.approvedTools], its permission policy and
  /// [AgentHookEvaluation.cancelled].
  /// Null (default) = agent hooks are skipped fail-open with a ledger
  /// note. Never fall back to [promptHookEvaluator]: agent semantics
  /// require tool scope and cancellation that a prompt cannot honestly
  /// claim.
  AgentHookEvaluator? agentHookEvaluator;

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
  /// blow up the prompt. Explicit additionalContext fields are encrypted for
  /// restart restore; plain stdout context remains process-local.
  static const int maxSessionContextChars = 8192;

  /// Observe events where a COMMAND hook exiting 2 is a blocking decision
  /// rather than a failure (Claude Code semantics): `user_prompt_submit`
  /// blocks the prompt, `subagent_end` blocks the stop and sends the child
  /// back to work. Everywhere else exit 2 fails open.
  static const Set<String> kExit2BlockingEvents = {
    'user_prompt_submit',
    'subagent_end',
  };
  final Map<String, Map<String, String>> _sessionContexts = {};
  final Map<String, int> _sessionContextEpochs = {};
  final HookContextStore _contextStore = HookContextStore();
  // Environment files are ephemeral, plugin-owned and generation-scoped.
  // Never reopen a prior process's plaintext environment on restart.
  final String _envBoot = DateTime.now().microsecondsSinceEpoch.toString();
  int _envSerial = 0;
  final Map<String, Map<String, (String, int)>> _envFiles = {};
  final Map<String, (Object, int)> _endingSessions = {};

  // Each admitted event owns an immutable registration snapshot. Nested events
  // get their own snapshot; async completions retain the originating Zone.
  static final Object _registrationSnapshotKey = Object();
  Map<String, int> _registrationSnapshot(
    List<(String, PluginHook, String)> hooks,
  ) => {
    for (final entry in hooks)
      entry.$1: PluginContributionRegistry.I.revisionFor(entry.$1),
  };

  void _registrationChanged(
    String pluginId,
    NormalizedPluginManifest? previous,
  ) {
    // ABA fence: any register/unregister is a new lifetime. In-flight agent
    // evaluations of this plugin are cancelled before the caller's first
    // async disable/uninstall step can run.
    _fenceAgentEvals(pluginId: pluginId);
    final descriptors = {
      for (final hook in previous?.hooks ?? <PluginHook>[])
        HookContextStore.descriptor(previous!, hook),
    };
    final sessions = {
      ..._sessionContexts.keys,
      ..._sessionContextEpochs.keys,
      ..._envFiles.keys,
      // Durable contributions also live in sessions this process never
      // opened. Enumerate the app session list so a disable or same-object
      // re-registration erases them before a later start can revalidate the
      // identical descriptor and restore them.
      ...AppState.I.sessions.map((s) => s.id),
    };
    for (final sid in sessions) {
      _sessionContexts[sid]?.removeWhere((key, _) => descriptors.contains(key));
      final file = _envFiles[sid]?.remove(pluginId);
      if (file != null) _removeEnvFile(file.$1);
      // Enqueue targeted deletes synchronously, before a new start can restore.
      for (final descriptor in descriptors) {
        unawaited(
          _contextStore.put(sid, descriptor, null).catchError((Object _) {
            Diag.swallow(
              'hook_context',
              'encrypted context invalidation unavailable',
            );
          }),
        );
      }
    }
    _consecutiveFails.removeWhere((key, _) => key.startsWith('$pluginId|'));
    _tripped.removeWhere((key) => key.startsWith('$pluginId|'));
    _clearBlocker(pluginId);
  }

  bool _hookCurrent(
    String sessionId,
    String pluginId,
    PluginHook hook,
    int epoch,
  ) {
    if (!enabled || epoch != (_sessionContextEpochs[sessionId] ?? 0)) {
      return false;
    }
    if (pluginId.startsWith('legacy:')) {
      return _resolveHooks(
        hook.event,
        sessionId,
      ).any((e) => e.$1 == pluginId && e.$2.payload == hook.payload);
    }
    final registry = PluginContributionRegistry.I;
    final snapshot =
        Zone.current[_registrationSnapshotKey] as Map<String, int>?;
    return snapshot?[pluginId] == registry.revisionFor(pluginId) &&
        registry.isPluginActiveForSession(pluginId, sessionId) &&
        (registry.manifestFor(pluginId)?.hooks.any((h) => identical(h, hook)) ??
            false);
  }

  /// The `session_start` context a hook produced for [sessionId], or ''.
  String sessionContextFor(String sessionId) {
    if (!enabled) return '';
    final contributions = _sessionContexts[sessionId];
    if (contributions == null) return '';
    // Resolve at read time: disabled/uninstalled plugins cannot retain prompt
    // influence. Registry/manifest order is stable even after targeted installs.
    final hooks = _resolveHooks('session_start', sessionId);
    final valid = hooks.map((entry) => _contextKey(entry.$1, entry.$2)).toSet();
    final removed = contributions.keys
        .where((key) => !valid.contains(key))
        .toList();
    for (final key in removed) {
      contributions.remove(key);
    }
    // The synchronous model-context reader can filter immediately. Queue the
    // durable removal before any subsequent start can restore these entries.
    if (removed.isNotEmpty) {
      unawaited(
        _contextStore
            .reconcile(sessionId, valid)
            .then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {
                Diag.swallow(
                  'hook_context',
                  'encrypted context invalidation unavailable',
                );
              },
            ),
      );
    }
    final text = hooks
        .map((entry) => contributions[_contextKey(entry.$1, entry.$2)] ?? '')
        .where((text) => text.isNotEmpty)
        .join('\n');
    return _capContext(text, maxSessionContextChars);
  }

  String _contextKey(String pluginId, PluginHook hook) {
    final manifest = PluginContributionRegistry.I.manifestFor(pluginId);
    if (manifest != null) return HookContextStore.descriptor(manifest, hook);
    return jsonEncode([
      pluginId,
      manifest?.rootPath,
      manifest?.version,
      hook.toJson(),
    ]);
  }

  Future<void> _restoreSessionContext(String sessionId) async {
    final epoch = _sessionContextEpochs[sessionId] ?? 0;
    final hooks = _resolveHooks('session_start', sessionId);
    final revisions = _registrationSnapshot(hooks);
    final valid = hooks
        .where((entry) => !entry.$1.startsWith('legacy:'))
        .map((entry) => _contextKey(entry.$1, entry.$2))
        .toSet();
    try {
      _sessionContexts.putIfAbsent(sessionId, () => {});
      final restored = await _contextStore.reconcile(sessionId, valid);
      if (epoch != (_sessionContextEpochs[sessionId] ?? 0)) return;
      final current = hooks
          .where(
            (entry) =>
                revisions[entry.$1] ==
                PluginContributionRegistry.I.revisionFor(entry.$1),
          )
          .map((entry) => _contextKey(entry.$1, entry.$2))
          .toSet();
      final contexts = _sessionContexts.putIfAbsent(sessionId, () => {});
      // Fresh in-process results win over persisted results on targeted installs.
      for (final entry in restored.entries) {
        if (current.contains(entry.key)) {
          contexts.putIfAbsent(entry.key, () => entry.value);
        }
      }
      contexts.removeWhere(
        (key, _) =>
            RegExp(r'^[a-f0-9]{64}$').hasMatch(key) && !valid.contains(key),
      );
    } catch (_) {
      // Fail open without logging decrypted values or platform exception data.
      Diag.swallow('hook_context', 'encrypted context restore unavailable');
    }
  }

  static String _capContext(String text, int cap) {
    const suffix = '\n[hook output truncated]';
    return text.length <= cap
        ? text
        : '${text.substring(0, cap - suffix.length)}$suffix';
  }

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
    if (t.startsWith('{') || t.startsWith('[')) {
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
        return ''; // Malformed protocol output is never prompt context.
      }
      return '';
    }
    return t;
  }

  /// Reset the per-session context map + test seams (isolated tests).
  @visibleForTesting
  void resetForTest() {
    for (final files in _envFiles.values) {
      for (final file in files.values) {
        _removeEnvFile(file.$1);
      }
    }
    _envFiles.clear();
    _endingSessions.clear();
    _sessionContexts.clear();
    _sessionContextEpochs.clear();
    executorForTest = null;
    gateExecutorForTest = null;
    stdinExecutorForTest = null;
    execTimeoutForTest = null;
    promptHookEvaluator = null;
    userStopChecker = null;
    _consecutiveFails.clear();
    _tripped.clear();
    _hookBlockers.clear();
    _firingEvents.clear();
    fired = 0;
    failed = 0;
  }

  /// Restore the persisted kill-switch (call once at boot).
  Future<void> loadEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool('ovid_hooks_enabled') ?? true;
    } catch (e) {
      Diag.swallow('hook_service', e);
    }
    final dir = await _hookEnvDir();
    if (dir != null) await _sweepOrphanEnv(dir);
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    if (!v) {
      _fenceAgentEvals();
      for (final sid in {
        ..._sessionContextEpochs.keys,
        ..._sessionContexts.keys,
        ..._envFiles.keys,
      }) {
        _sessionContextEpochs[sid] = (_sessionContextEpochs[sid] ?? 0) + 1;
        await _deleteSessionEnv(sid);
      }
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ovid_hooks_enabled', v);
    } catch (e) {
      Diag.swallow('hook_service', e);
    }
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

  // In-flight agent evaluations, fenced as (pluginId, sessionId, completer).
  // Fencing completes the completer so a wired evaluator can stop work; any
  // result that arrives after the fence is dropped (fail-open).
  final List<(String, String, Completer<void>)> _agentEvals = [];

  static final Object _agentFenced = Object();
  static final Object _agentTimedOut = Object();

  Completer<void> _beginAgentEval(String pluginId, String sessionId) {
    final fence = Completer<void>();
    _agentEvals.add((pluginId, sessionId, fence));
    return fence;
  }

  void _endAgentEval(Completer<void> fence) {
    _agentEvals.removeWhere((e) => identical(e.$3, fence));
    if (!fence.isCompleted) fence.complete();
  }

  void _fenceAgentEvals({String? pluginId, String? sessionId}) {
    final matched = _agentEvals
        .where(
          (e) =>
              (pluginId == null || e.$1 == pluginId) &&
              (sessionId == null || e.$2 == sessionId),
        )
        .toList();
    for (final e in matched) {
      _endAgentEval(e.$3);
    }
  }

  /// Whether [pluginId]'s hooks are disabled for [sessionId] (breaker).
  bool pluginTrippedForTest(String pluginId, String sessionId) =>
      _tripped.contains('$pluginId|$sessionId');

  /// Breaker state for diagnostics/UI.
  bool isPluginTripped(String pluginId, String sessionId) =>
      _tripped.contains('$pluginId|$sessionId');

  void _recordSuccess(String pluginId, String sessionId) {
    _consecutiveFails.remove('$pluginId|$sessionId');
    _clearBlocker(pluginId);
  }

  void _recordFailure(String pluginId, String sessionId) {
    final key = '$pluginId|$sessionId';
    final n = (_consecutiveFails[key] ?? 0) + 1;
    if (n >= breakerThreshold) {
      _tripped.add(key);
      _consecutiveFails.remove(key);
      _noteBlocker(
        pluginId,
        'disabled for this session after $n consecutive failures '
        '(circuit breaker) — re-enable the plugin to retry',
      );
    } else {
      _consecutiveFails[key] = n;
    }
  }

  // ── Why hooks did not run ────────────────────────────────────────────
  /// Per-plugin reason its declared hooks are currently NOT running.
  ///
  /// Every skip path used to be completely silent: a plugin installed from the
  /// Plugins screen is `pendingGlobal` (spec §7 — deliberately not injected
  /// into running sessions), a legacy row is fail-closed until re-approved,
  /// hook execution hard-requires the Studio sandbox, and three failures trip
  /// the circuit breaker. All four produce exactly the same user-visible
  /// symptom — "the hook never fires" — with no evidence anywhere except
  /// ledger rows no screen renders (audit 2026-09-29). This makes the reason
  /// observable so the Plugins screen can say it.
  final Map<String, String> _hookBlockers = {};

  /// Diagnostic snapshot: pluginId → why its hooks are blocked. Empty when
  /// nothing is blocked. Cleared per plugin as soon as one of its hooks runs.
  Map<String, String> get hookBlockers => Map.unmodifiable(_hookBlockers);

  /// Test/diagnostic seam for a single plugin.
  String? hookBlockerFor(String pluginId) => _hookBlockers[pluginId];

  void _noteBlocker(String pluginId, String reason) {
    if (_hookBlockers[pluginId] == reason) return;
    _hookBlockers[pluginId] = reason;
    // Observable in logs too — this is the "silent skip" the audit flagged.
    Diag.swallow('hook_service.blocked', '$pluginId: $reason');
  }

  void _clearBlocker(String pluginId) => _hookBlockers.remove(pluginId);

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

  static Object? _decodedOutput(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static String _safeOutput(String text, Map<String, dynamic> known) {
    final secrets = <String>{};
    void collect(Object? value, [bool secret = false]) {
      if (value is Map) {
        for (final e in value.entries) {
          collect(e.value, secret || _isSecretKey(e.key.toString()));
        }
      } else if (value is List) {
        for (final item in value) {
          collect(item, secret);
        }
      } else if (secret && value is String && value.isNotEmpty) {
        secrets.add(value);
      }
    }

    collect(known);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      Diag.swallow('hook_output', 'non-JSON output handled as text');
    }
    collect(decoded);
    var safe = decoded is Map || decoded is List
        ? jsonEncode(_redactValue(decoded))
        : text;
    final ordered = secrets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in ordered) {
      safe = safe.replaceAll(secret, '[redacted]');
      final encoded = jsonEncode(secret);
      safe = safe.replaceAll(
        encoded.substring(1, encoded.length - 1),
        '[redacted]',
      );
    }
    return safe;
  }

  /// One resolved hook invocation target.
  ///
  /// [CC] matchers are event-specific: tool events match the tool name, but
  /// `SessionStart` matches the session SOURCE (`startup`/`resume`/`clear`/
  /// `compact`). Matching every event against `payload['tool']` silently
  /// dropped every SessionStart hook (e.g. `superpowers` declares
  /// `startup|clear|compact`). `*` and empty mean "all".
  @visibleForTesting
  static bool matcherAppliesForTest(
    String canonicalEvent,
    String? matcher,
    Map<String, dynamic> payload,
  ) => _matcherApplies(canonicalEvent, matcher, payload);

  static bool _matcherApplies(
    String canonicalEvent,
    String? matcher,
    Map<String, dynamic> payload,
  ) {
    if (matcher == null || matcher.isEmpty || matcher == '*') return true;
    if (!isSafeMatcher(matcher)) return false;
    final subject = _matcherSubject(canonicalEvent, payload);
    // This event has no matcher vocabulary in Claude Code, so a declared
    // matcher must not turn the hook permanently dead.
    if (subject == _kSubjectMatchesEverything) return true;
    // FULL-STRING match (audit 2026-09-25): a Claude Code matcher like `Edit`
    // must match the tool `Edit` only, NOT `MultiEdit`/`NotebookEdit`. The old
    // unanchored `hasMatch` did a substring match, so `Edit` fired on every
    // *Edit* tool and `startup` would fire on `startupx`. Anchor the whole
    // pattern; alternations (`Edit|Write`) and patterns (`Notebook.*`) still
    // work because the anchor wraps the entire user matcher.
    try {
      if (RegExp('^(?:$matcher)\$').hasMatch(subject)) return true;
    } catch (_) {
      return false; // malformed matcher → skip (fail-open)
    }
    // MCP SERVER PREFIX (regression fix, audit 2026-09-29). Claude Code
    // documents `mcp__server-name` as a matcher that catches EVERY tool of that
    // server, and Ovid dispatches those tools as `mcp__<server>__<tool>`. The
    // anchoring above is correct for plain tool names but killed this rule:
    // `^(?:mcp__github)$` never matches `mcp__github__create_issue`, so every
    // MCP-scoped plugin hook silently stopped firing — with no ledger entry,
    // because the skip happens per hook inside the resolution loop. Applied only
    // to literal (metacharacter-free) `mcp__` branches so a real regex such as
    // `mcp__.*` still goes through the anchored path above.
    if (_isToolEvent(canonicalEvent) && subject.startsWith('mcp__')) {
      for (final branch in matcher.split('|')) {
        final b = branch.trim();
        if (!b.startsWith('mcp__') || _hasRegexMeta(b)) continue;
        if (subject == b || subject.startsWith('${b}__')) return true;
      }
    }
    return false;
  }

  /// True for the events whose matcher subject is a tool name.
  static bool _isToolEvent(String canonicalEvent) =>
      canonicalEvent == 'pre_tool' || canonicalEvent == 'post_tool';

  /// Compatibility aliases apply only to manifests inspected by the [CC]
  /// adapter. The native name stays available to matchers and on stdin.
  Map<String, dynamic>? _ccAliasPayload(
    String pluginId,
    Map<String, dynamic> payload,
  ) {
    if (PluginContributionRegistry.I.manifestFor(pluginId)?.format !=
        PluginFormat.claudeCode) {
      return null;
    }
    final tool = payload['tool'] ?? payload['tool_name'];
    final input = payload['tool_input'] ?? payload['args'] ?? payload['input'];
    final operation = input is Map ? input['command'] : null;
    final alias = switch (tool) {
      'run_shell' => 'Bash',
      'file_read' => 'Read',
      'file_write' => 'Write',
      'fs_edit' => switch (operation) {
        'view' => 'Read',
        'create' => 'Write',
        _ => 'Edit',
      },
      _ => null,
    };
    return alias == null
        ? null
        : {...payload, 'tool': alias, 'tool_name': alias};
  }

  bool _hookMatches(
    String pluginId,
    PluginHook hook,
    String event,
    Map<String, dynamic> payload,
  ) {
    final source = hook.unknownFields['ovidSourceEvent'];
    if (event == 'post_tool' && source != null) {
      final failure =
          payload['hook_event_name'] == 'PostToolUseFailure' ||
          payload['is_error'] == true ||
          payload['error'] != null;
      if ((source == 'PostToolUseFailure') != failure) return false;
    }
    final alias = _ccAliasPayload(pluginId, payload);
    final toolEvent = _isToolEvent(event) || event == 'permission_request';
    final isCc =
        PluginContributionRegistry.I.manifestFor(pluginId)?.format ==
        PluginFormat.claudeCode;
    final matchEvent = event == 'permission_request' && isCc
        ? 'pre_tool'
        : event;
    if (!_matcherApplies(matchEvent, hook.matcher, payload) &&
        !(toolEvent &&
            alias != null &&
            _matcherApplies(matchEvent, hook.matcher, alias))) {
      return false;
    }
    final predicate = _hookIfPredicate(hook);
    return predicate == null ||
        ifPredicateMatches(predicate, payload) ||
        (toolEvent && alias != null && ifPredicateMatches(predicate, alias));
  }

  static bool _hasRegexMeta(String s) =>
      RegExp(r'[\\.\\+*?\[\](){}^$|]').hasMatch(s);

  /// The string a matcher runs against for [canonicalEvent].
  ///
  /// Claude Code only defines matcher semantics for three families: tool events
  /// (a tool name or pattern), session start/end (the source token), and
  /// compaction (`manual` | `auto`). Everything else has NO matcher vocabulary —
  /// so for those events a declared matcher is IGNORED (matches all) rather than
  /// compared against an empty subject, which is what made such hooks
  /// permanently and silently dead.
  static String _matcherSubject(
    String canonicalEvent,
    Map<String, dynamic> payload,
  ) {
    if (canonicalEvent == 'session_start' || canonicalEvent == 'session_end') {
      final reason =
          (canonicalEvent == 'session_start'
                  ? payload['source'] ?? payload['reason']
                  : payload['reason'])
              ?.toString() ??
          '';
      return _ccSessionSource(reason);
    }
    if (canonicalEvent == 'pre_compact' || canonicalEvent == 'post_compact') {
      return payload['trigger']?.toString() ?? '';
    }
    if (_isToolEvent(canonicalEvent)) {
      return (payload['tool'] ?? payload['tool_name'])?.toString() ?? '';
    }
    // No matcher vocabulary exists for this event.
    return _kSubjectMatchesEverything;
  }

  /// Sentinel subject: the anchored regex is skipped for it, so any declared
  /// matcher matches. Keeps "no matcher semantics" from becoming "never fires".
  static const String _kSubjectMatchesEverything = '\u0000*';

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
        // Worth reporting ONLY when this plugin actually declares a hook for
        // this event — otherwise every unrelated plugin looks "blocked".
        if (m.hooks.any((h) => h.event == canonical)) {
          final state =
              PluginContributionRegistry.I.activationFor(pid)?.name ??
              'unregistered';
          _noteBlocker(
            pid,
            state == 'pendingGlobal'
                ? 'installed, not activated yet — RESTART THE APP to activate '
                      'it in every session (a Plugins-screen install never '
                      'mutates an already-running session)'
                : 'not active in this session (activation: $state)',
          );
        }
        continue;
      }
      for (final h in m.hooks) {
        if (h.event != canonical) continue;
        out.add((pid, h, canonical));
      }
    }
    if (!AppState.I.legacyPluginExecutionAllowed) return out;
    for (final p in AppState.I.plugins) {
      if (p.runtimeId != null || !p.installed || !p.enabled) continue;
      if (p.migrationRequired) {
        // Legacy rows are fail-closed on purpose (README: no silent
        // auto-approval), but that must not look like a broken hook.
        if (p.hooks.isNotEmpty) {
          _noteBlocker(
            'legacy:${p.name}',
            'Migration required — legacy plugins stay fail-closed until you '
                'run inspect → approve → install',
          );
        }
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
      final ordered = p.pluginHooks.where((h) => h.event == canonical).toList();
      if (ordered.isNotEmpty) {
        for (final hook in ordered) {
          out.add(('legacy:${p.name}', hook, declared));
        }
      } else if (cmd != null) {
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
  StreamIterator<FileSystemEntity>? _envSweep;
  String? _envSweepPath;
  Future<void>? _envSweepPending;

  /// Incremental non-recursive GC. Keep the cursor between bounded batches
  /// so unrelated entries cannot starve later orphans. Never follow links.
  Future<void> _sweepOrphanEnv(Directory dir) {
    final pending = _envSweepPending;
    if (pending != null) return pending;
    final task = (() async {
      try {
        if (_envSweepPath != dir.path) {
          await _envSweep?.cancel();
          _envSweep = null;
          _envSweepPath = dir.path;
        }
        final iterator = _envSweep ??= StreamIterator(
          dir.list(followLinks: false),
        );
        final clock = Stopwatch()..start();
        for (
          var visited = 0;
          visited < 64 && clock.elapsedMilliseconds < 50;
          visited++
        ) {
          if (!await iterator.moveNext().timeout(
            const Duration(milliseconds: 100),
          )) {
            await iterator.cancel();
            _envSweep = null;
            break;
          }
          final entity = iterator.current;
          if (!entity.path.endsWith('.env') ||
              entity is Directory ||
              _liveEnvPaths.containsKey(entity.path) ||
              _envFiles.values.any(
                (files) => files.values.any((e) => e.$1 == entity.path),
              )) {
            continue;
          }
          _removeEnvFile(entity.path);
        }
      } catch (_) {
        await _envSweep?.cancel();
        _envSweep = null;
        Diag.swallow('hook_env', 'orphan environment cleanup unavailable');
      }
    })();
    _envSweepPending = task;
    return task.whenComplete(() => _envSweepPending = null);
  }

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
  Future<String> _sessionEnvFilePath(String sessionId, String pluginId) async {
    if (sessionId.isEmpty) return '';
    final epoch = _sessionContextEpochs.putIfAbsent(sessionId, () => 0);
    final revision = PluginContributionRegistry.I.revisionFor(pluginId);
    final dir = await _hookEnvDir();
    if (dir != null) await _sweepOrphanEnv(dir);
    if (dir == null ||
        epoch != _sessionContextEpochs[sessionId] ||
        revision != PluginContributionRegistry.I.revisionFor(pluginId)) {
      return '';
    }
    _reconcileSessionEnv(sessionId);
    final files = _envFiles.putIfAbsent(sessionId, () => {});
    return files.putIfAbsent(pluginId, () {
      final digest = sha256.convert(
        utf8.encode(jsonEncode([sessionId, pluginId, epoch])),
      );
      return ('${dir.path}/$_envBoot-${_envSerial++}-$digest.env', revision);
    }).$1;
  }

  void _removeEnvFile(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        File(path).deleteSync();
      }
    } catch (_) {
      Diag.swallow('hook_env', 'environment cleanup unavailable');
    }
  }

  void _reconcileSessionEnv(String sessionId) {
    _envFiles[sessionId]?.removeWhere((pid, entry) {
      final registry = PluginContributionRegistry.I;
      final valid = pid.startsWith('legacy:')
          ? _resolveHooks('session_start', sessionId).any((e) => e.$1 == pid)
          : registry.isPluginActiveForSession(pid, sessionId) &&
                entry.$2 == registry.revisionFor(pid);
      if (!valid) _removeEnvFile(entry.$1);
      return !valid;
    });
  }

  static bool _safeEnvName(String name) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name) &&
      !name.startsWith('PLUGIN_') &&
      !name.startsWith('OVID_') &&
      !name.startsWith('CLAUDE_') &&
      !name.startsWith('CODEX_') &&
      !name.startsWith('LD_') &&
      !name.startsWith('DYLD_') &&
      !const {
        'BASH_ENV',
        'ENV',
        'SHELLOPTS',
        'BASHOPTS',
        'IFS',
        'NODE_OPTIONS',
        'PYTHONSTARTUP',
      }.contains(name);

  // A data-only subset of shell exports: no expansion, substitution or source.
  static MapEntry<String, String>? _envAssignment(String raw) {
    var line = raw.trim();
    if (line.contains('\n') || line.contains('\r') || line.contains('\u0000')) {
      return null;
    }
    if (line.startsWith('export ')) line = line.substring(7).trimLeft();
    final eq = line.indexOf('=');
    if (eq <= 0) return null;
    final name = line.substring(0, eq).trim();
    if (!_safeEnvName(name)) return null;
    var value = line.substring(eq + 1);
    if (value.startsWith("'") && value.endsWith("'") && value.length >= 2) {
      value = value.substring(1, value.length - 1);
      if (value.contains("'")) return null;
    } else {
      if (value.contains(RegExp(r'[\$`;|&<>\\]'))) return null;
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      if (value.contains('"') || value.contains("'")) return null;
    }
    return MapEntry(name, value);
  }

  /// Load the session env file into a map (item 8). Malformed lines are
  /// skipped; the file is capped at 64 KB so a hostile hook cannot blow up
  /// every subsequent invocation's environment.
  Map<String, String> _loadSessionEnv(String path) {
    if (path.isEmpty) return const {};
    try {
      final f = File(path);
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.file ||
          f.lengthSync() > 65536) {
        return const {};
      }
      final text = f.readAsStringSync();
      final capped = text.length > 65536 ? text.substring(0, 65536) : text;
      final out = <String, String>{};
      for (final rawLine in capped.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final assignment = _envAssignment(line);
        if (assignment != null) {
          out[assignment.key] = assignment.value;
        } else {
          Diag.swallow(
            'hook_env',
            'unsupported environment assignment skipped',
          );
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Append validated `KEY=VALUE` lines to the session env file (called
  /// for SessionStart hook output). Best-effort — never throws.
  void _appendSessionEnv(String path, List<String> lines) {
    if (lines.isEmpty) return;
    try {
      if (path.isEmpty) return;
      final f = File(path);
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        return;
      }
      final bytes = utf8.encode('${lines.join('\n')}\n');
      if ((f.existsSync() ? f.lengthSync() : 0) + bytes.length > 65536) return;
      f.writeAsBytesSync(bytes, mode: FileMode.append);
    } catch (_) {
      Diag.swallow('hook_env', 'environment update unavailable');
    }
  }

  /// Delete the session env file (session_end cleanup).
  Future<void> _deleteSessionEnv(String sessionId) async {
    final files = _envFiles.remove(sessionId);
    if (files != null) {
      for (final entry in files.values) {
        _removeEnvFile(entry.$1);
      }
    }
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
    final envFilePath = await _sessionEnvFilePath(sessionId, pluginId);
    final sessionEnv = <String, String>{};
    for (final entry in _envFiles[sessionId]?.values ?? <(String, int)>[]) {
      sessionEnv.addAll(_loadSessionEnv(entry.$1));
    }
    final runtime = HookExecutionScope.dependencyRoot(
      PluginContributionRegistry.I.manifestFor(pluginId),
    );
    // pluginRuntimeEnv includes the installed shell directory in PATH. Resolve
    // an existing prefix before building it, including on a cold process boot.
    if (runtime != null && SandboxService.I.prefixPath == null) {
      await SandboxService.I.checkExisting();
    }
    return {
      if (runtime != null) ...SandboxService.pluginRuntimeEnv(runtime),
      if (runtime != null) 'NODE_PATH': '$runtime/node/node_modules',
      if (runtime != null) 'PYTHONPATH': '$runtime/python',
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
      // Codex hooks reference their own root variable.
      'CODEX_PLUGIN_ROOT': root,
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

  /// Execute one hook. Returns (exitCode, stdout, stderr) — throws on
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

  Future<(int, String, String)> _exec(
    PluginHook hook,
    Map<String, String> env,
    Directory? cwd, {
    bool gate = false,
    String stdinPayload = '',
  }) async {
    final path = env['CLAUDE_ENV_FILE'] ?? '';
    final sessionId = env['PLUGIN_SESSION'] ?? '';
    final epoch = _sessionContextEpochs[sessionId] ?? 0;
    _liveEnvPaths[path] = (_liveEnvPaths[path] ?? 0) + 1;
    try {
      return await _execCommand(
        hook,
        env,
        cwd,
        gate: gate,
        stdinPayload: stdinPayload,
      );
    } finally {
      final remaining = (_liveEnvPaths[path] ?? 1) - 1;
      if (remaining == 0) {
        _liveEnvPaths.remove(path);
      } else {
        _liveEnvPaths[path] = remaining;
      }
      if (!_hookCurrent(sessionId, hook.pluginId, hook, epoch)) {
        _removeEnvFile(path);
      }
    }
  }

  final Map<String, int> _liveEnvPaths = {};

  Future<(int, String, String)> _execCommand(
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
      if (g != null) {
        final (code, out) = await g(command, env);
        return (code, out, '');
      }
    }
    // Stdin-aware test seam (item 1) — consulted before the legacy seams.
    final se = stdinExecutorForTest;
    if (se != null) {
      final (code, out) = await se(command, env, stdinPayload);
      return (code, out, '');
    }
    final custom = executorForTest;
    if (custom != null) return (0, await custom(command, env), '');
    final t = execTimeoutForTest;
    if (t != null) return (0, await t(timeout.inSeconds), '');
    // The sandbox exec boundary — the hook env contract (CLAUDE_PLUGIN_ROOT,
    // PLUGIN_ROOT, PLUGIN_SESSION, ...). When a test override stands in for
    // the installed sandbox, route through `execChecked`, which consults it:
    // the override observes the FULL env map exactly as the production spawn
    // would receive it. Stdin delivery is additive — the stdin-aware seam
    // above already serves stdin-capable tests, and production keeps the
    // spawn path below. Without this, the spawn path bypassed the boundary
    // the contract tests pin, so hooks never reached it.
    if (SandboxService.hasExecOverride) {
      final (code, out) = await SandboxService.I
          .execChecked(
            [_hookShell(hook), '-c', command],
            hostWorkDir: cwd,
            env: env,
          )
          .timeout(timeout);
      return (code, out, '');
    }
    // Probe the existing sandbox, then verify the actual shell on disk. A stale
    // installed flag must not claim that a missing interpreter is usable.
    if (SandboxService.I.prefixPath == null) {
      await SandboxService.I.checkExisting();
    }
    final prefix = SandboxService.I.prefixPath;
    if (prefix == null ||
        !File('$prefix/bin/${_hookShell(hook)}').existsSync()) {
      // The single most common real reason "hooks don't work": hook commands
      // execute inside the Studio sandbox, which only installs on first Studio
      // open. Record the reason instead of failing invisibly three times and
      // then tripping the circuit breaker with nothing to show for it.
      _noteBlocker(
        hook.pluginId,
        prefix == null
            ? 'hook commands need the on-device sandbox, which is not installed yet — open Studio once to install it'
            : 'sandbox hook shell is missing — repair the Studio runtime and retry',
      );
      throw const HookRuntimeUnavailable();
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
    if (cwd == null) throw StateError('hook session workspace unavailable');
    final scope = HookExecutionScope.roots(
      manifest: PluginContributionRegistry.I.manifestFor(hook.pluginId),
      workspace: cwd,
      env: env,
      inherited: Zone.current[SandboxService.allowedRootsZoneKey],
    );
    final proc = await runZoned(
      () => SandboxService.I.spawn(
        [_hookShell(hook), '-c', command],
        hostWorkDir: cwd,
        env: env,
      ),
      zoneValues: {SandboxService.allowedRootsZoneKey: scope},
    );
    // Subscribe to stdout/stderr BEFORE touching stdin so a chatty hook
    // can never deadlock on a full pipe while we write.
    var oversized = false;
    Future<String> readBounded(Stream<List<int>> stream) async {
      final bytes = <int>[];
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > 65536) {
          oversized = true;
          proc.kill(ProcessSignal.sigkill);
        } else if (!oversized) {
          bytes.addAll(chunk);
        }
      }
      return utf8.decode(bytes, allowMalformed: true);
    }

    final stdoutFuture = readBounded(proc.stdout);
    final stderrFuture = readBounded(proc.stderr);
    try {
      return await (() async {
        try {
          if (stdinPayload.isNotEmpty) {
            proc.stdin.add(utf8.encode(stdinPayload));
          }
          await proc.stdin.close();
        } catch (_) {
          /* Early exit can close stdin before we finish writing. */
        }
        final code = await proc.exitCode;
        final out = await stdoutFuture;
        final err = await stderrFuture;
        if (oversized) throw StateError('hook output exceeds limit');
        return (code, out, err);
      })().timeout(timeout);
    } on TimeoutException {
      // The old execChecked path leaked the timed-out process; kill it so
      // a hung hook cannot outlive its timeout (Stop can also reach it via
      // the sandbox's live-process registry — spawn registers it).
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (e) {
        Diag.swallow('hook_service', e);
      }
      rethrow;
    }
  }

  Future<void> _ledger(String sessionId, String kind, Map<String, dynamic> d) {
    return SessionLedger.I.append(sessionId, kind, d);
  }

  // ── fire: observe events (fire-and-forget semantics at call sites) ──

  /// Fire [event] for [sessionId]. Context-injection events return extracted
  /// context (≤2 KB); other events return stdout — empty
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
  /// [completedStartHooks] is a lifecycle-owned retry receipt set: successful
  /// synchronous starts (including intentional halts) are not replayed.
  Future<HookFireResult> fireDetailed(
    String event,
    String sessionId, {
    Map<String, dynamic> payload = const {},
    String? model,
    String? onlyPluginId,
    Set<String>? completedStartHooks,
  }) async {
    final canonical = canonicalHookEvent(event) ?? event;
    // Admission must precede any start-generation mutation. A rejected nested
    // or overlapping start cannot invalidate the start already publishing.
    if (canonical == 'session_start') {
      if (!enabled) return const HookFireResult(output: '');
      if (_firingEvents.contains('$sessionId|$canonical') ||
          _chainDepth() >= maxDepth) {
        return const HookFireResult(output: '', retryableFailure: true);
      }
    }
    if (event == 'PostToolUseFailure') {
      payload = {...payload, 'hook_event_name': 'PostToolUseFailure'};
    }
    Map<String, (String, int)>? endingEnv;
    Object? endToken;
    void cleanEndingEnv() {
      if (endToken != null &&
          identical(_endingSessions[sessionId]?.$1, endToken)) {
        _endingSessions.remove(sessionId);
      }
      final files = endingEnv;
      if (files == null) return;
      if (identical(_envFiles[sessionId], files)) _envFiles.remove(sessionId);
      for (final entry in files.values) {
        _removeEnvFile(entry.$1);
      }
    }

    if (canonical == 'session_start' &&
        _endingSessions.containsKey(sessionId) &&
        _endingSessions[sessionId]!.$2 ==
            (_sessionContextEpochs[sessionId] ?? 0)) {
      // A new start owns a new epoch/map while the old end retains only its
      // captured files. Detach once: later targeted starts share the fresh map.
      _sessionContextEpochs[sessionId] =
          (_sessionContextEpochs[sessionId] ?? 0) + 1;
      _envFiles.remove(sessionId);
    }
    if (canonical == 'session_end') {
      if (_endingSessions.containsKey(sessionId)) {
        return const HookFireResult(output: '', retryableFailure: true);
      }
      endToken = Object();
      endingEnv = _envFiles.putIfAbsent(sessionId, () => {});
      _sessionContextEpochs[sessionId] =
          (_sessionContextEpochs[sessionId] ?? 0) + 1;
      _endingSessions[sessionId] = (
        endToken,
        _sessionContextEpochs[sessionId]!,
      );
      final endEpoch = _sessionContextEpochs[sessionId];
      _sessionContexts.remove(sessionId);
      try {
        await _contextStore.deleteSession(sessionId);
      } catch (_) {
        Diag.swallow('hook_context', 'encrypted context deletion unavailable');
      }
      if (endEpoch != _sessionContextEpochs[sessionId]) {
        cleanEndingEnv();
        return const HookFireResult(output: '');
      }
    }
    if (!enabled) {
      cleanEndingEnv();
      return const HookFireResult(output: '');
    }
    // Recursion prevention: never re-fire the SAME event for the SAME session
    // while it is executing. Concurrent DISTINCT sessions are independent and
    // must both run (workflow child fan-out).
    final guardKey = '$sessionId|$canonical';
    if (_firingEvents.contains(guardKey)) {
      cleanEndingEnv();
      return const HookFireResult(output: '', retryableFailure: true);
    }
    final chainDepth = _chainDepth();
    if (chainDepth >= maxDepth) {
      cleanEndingEnv();
      return const HookFireResult(output: '', retryableFailure: true);
    }
    final hooks = _resolveHooks(event, sessionId, onlyPluginId: onlyPluginId);
    final revisions = _registrationSnapshot(hooks);
    if (hooks.isEmpty && canonical != 'session_start') {
      cleanEndingEnv();
      return const HookFireResult(output: '');
    }

    _firingEvents.add(guardKey);
    final startEpoch = _sessionContextEpochs[sessionId] ?? 0;
    try {
      if (canonical == 'session_start') await _restoreSessionContext(sessionId);
      if (canonical == 'session_start' &&
          startEpoch != (_sessionContextEpochs[sessionId] ?? 0)) {
        return const HookFireResult(output: '');
      }
      if (hooks.isEmpty) return const HookFireResult(output: '');
      final result = await runZoned(
        () => _runHooks(
          sessionId: sessionId,
          canonical: canonical,
          hooks: hooks,
          payload: payload,
          model: model,
          completedStartHooks: completedStartHooks,
        ),
        zoneValues: {
          _depthKey: chainDepth + 1,
          _registrationSnapshotKey: revisions,
        },
      );
      return result;
    } finally {
      _firingEvents.remove(guardKey);
      cleanEndingEnv();
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
    final epoch = _sessionContextEpochs[sessionId] ?? 0;
    final record = {'plugin': pluginId, 'event': canonical, 'type': 'prompt'};
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
      } catch (e) {
        Diag.swallow('hook_service', e);
      }
      return null;
    }
    fired++;
    try {
      await _ledger(sessionId, 'hook/invoked', {
        ...Map<String, dynamic>.from(record),
        'promptChars': hook.payload.length,
      });
    } catch (e) {
      Diag.swallow('hook_service', e);
    }
    if (!_hookCurrent(sessionId, pluginId, hook, epoch)) return null;
    final prompt = _buildPromptHookPrompt(
      hook: hook,
      canonical: canonical,
      sessionId: sessionId,
      stdinJson: stdinJson,
    );
    String? response;
    try {
      response =
          await eval(prompt, {
            'event': canonical,
            'session': sessionId,
            'plugin': _displayName(pluginId),
            'hook': hook.canonicalId,
            'model': ?model,
          }).timeout(
            Duration(
              seconds: hook.timeoutS <= 0
                  ? 120
                  : hook.timeoutS.clamp(1, maxTimeoutS),
            ),
          );
    } catch (e) {
      if (!_hookCurrent(sessionId, pluginId, hook, epoch)) return null;
      failed++;
      _recordFailure(pluginId, sessionId);
      try {
        await _ledger(sessionId, 'hook/result', {
          ...record,
          'ok': false,
          'error': 'prompt-hook evaluation failed',
          'warning': 'prompt-hook evaluation failed (fail-open)',
        });
      } catch (e) {
        Diag.swallow('hook_service', e);
      }
      return null;
    }
    if (!_hookCurrent(sessionId, pluginId, hook, epoch)) return null;
    final parsed = parsePromptHookDecision(response ?? '');
    final verdict = parsed == null
        ? null
        : PromptHookVerdict(
            parsed.decision,
            parsed.reason == null ? null : _safeOutput(parsed.reason!, payload),
          );
    if (verdict == null) {
      _recordSuccess(pluginId, sessionId);
      try {
        await _ledger(sessionId, 'hook/result', {
          ...record,
          'ok': true,
          'decision': 'unparseable — fail-open',
        });
      } catch (e) {
        Diag.swallow('hook_service', e);
      }
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
    } catch (e) {
      Diag.swallow('hook_service', e);
    }
    return _hookCurrent(sessionId, pluginId, hook, epoch) ? verdict : null;
  }

  Future<AgentHookVerdict?> _evalAgentHook({
    required String pluginId,
    required PluginHook hook,
    required String canonical,
    required String sessionId,
    required Map<String, dynamic> payload,
    required String? model,
    required String stdinJson,
  }) async {
    final epoch = _sessionContextEpochs[sessionId] ?? 0;
    final record = {'plugin': pluginId, 'event': canonical, 'type': 'agent'};
    fired++;
    final evaluator = agentHookEvaluator;
    if (evaluator == null) {
      await _ledger(sessionId, 'hook/result', {
        ...record,
        'ok': false,
        'reason': 'AgentHookEvaluator unavailable (fail-open)',
      });
      return null;
    }
    final rawTools = hook.unknownFields['tools'];
    final tools = rawTools is List
        ? rawTools
              .whereType<String>()
              .where(
                (tool) =>
                    RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(tool),
              )
              .toSet()
        : <String>{};
    final fence = _beginAgentEval(pluginId, sessionId);
    final budget = Duration(
      seconds: hook.timeoutS <= 0 ? 120 : hook.timeoutS.clamp(1, maxTimeoutS),
    );
    try {
      final evaluation = AgentHookEvaluation(
        prompt: hook.payload,
        context: {
          'event': canonical,
          'session': sessionId,
          'plugin': _displayName(pluginId),
          'hook': hook.canonicalId,
          'stdin': _safeOutput(stdinJson, payload),
          'model': ?model,
        },
        approvedTools: Set.unmodifiable(tools),
        budget: budget,
        cancelled: fence.future,
      );
      final verdict = await Future.any<Object?>([
        evaluator(evaluation),
        fence.future.then((_) => _agentFenced),
        Future<Object?>.delayed(budget, () => _agentTimedOut),
      ]);
      if (verdict == _agentFenced ||
          !_hookCurrent(sessionId, pluginId, hook, epoch)) {
        return null;
      }
      if (verdict == _agentTimedOut) {
        await _ledger(sessionId, 'hook/result', {
          ...record,
          'ok': false,
          'reason': 'AgentHookEvaluator timed out (fail-open)',
        });
        await SessionLedger.I.flush(sessionId);
        return null;
      }
      if (verdict is! AgentHookVerdict ||
          !const {'block', 'approve'}.contains(verdict.decision)) {
        return null;
      }
      final safe = AgentHookVerdict(
        verdict.decision,
        verdict.reason == null ? null : _safeOutput(verdict.reason!, payload),
      );
      await _ledger(sessionId, 'hook/result', {
        ...record,
        'ok': true,
        'decision': safe.decision,
        if (safe.reason != null) 'reason': safe.reason,
      });
      return _hookCurrent(sessionId, pluginId, hook, epoch) ? safe : null;
    } catch (_) {
      if (_hookCurrent(sessionId, pluginId, hook, epoch)) {
        await _ledger(sessionId, 'hook/result', {
          ...record,
          'ok': false,
          'reason': 'AgentHookEvaluator failed (fail-open)',
        });
      }
      return null;
    } finally {
      _endAgentEval(fence);
    }
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
        '${hook.payload.replaceAll(r'$ARGUMENTS', stdinJson)}\n\n'
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
    Set<String>? completedStartHooks,
  }) async {
    final contextEpoch = _sessionContextEpochs[sessionId] ?? 0;
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
    final collected = <(String, PluginHook, String)>[];
    final systemMessages = <(String, PluginHook, String)>[];
    final promptBlocks = <(String, PluginHook, String)>[];
    var halted = false;
    var retryableFailure = false;
    String? blockedReason;
    for (final (pluginId, hook, declaredEvent) in hooks) {
      if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
      if (!_hookMatches(pluginId, hook, canonical, payload)) continue;
      final startKey = _contextKey(pluginId, hook);
      final receipt =
          '$startKey:${PluginContributionRegistry.I.revisionFor(pluginId)}';
      if (canonical == 'session_start' &&
          completedStartHooks?.contains(receipt) == true) {
        if (completedStartHooks!.contains('halt:$receipt')) {
          halted = true;
          break;
        }
        continue;
      }
      if (_tripped.contains('$pluginId|$sessionId')) {
        retryableFailure = true;
        continue;
      }
      if (hook.type == 'agent') {
        final verdict = await _evalAgentHook(
          pluginId: pluginId,
          hook: hook,
          canonical: canonical,
          sessionId: sessionId,
          payload: payload,
          model: model,
          stdinJson: stdinJson,
        );
        if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
        if (verdict?.isBlock == true) {
          promptBlocks.add((
            pluginId,
            hook,
            verdict!.reason ?? 'blocked by agent hook ($pluginId)',
          ));
        }
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
          if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
          if (verdict != null && verdict.decision == 'block') {
            promptBlocks.add((
              pluginId,
              hook,
              verdict.reason ?? 'blocked by prompt hook ($pluginId)',
            ));
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
        } catch (e) {
          Diag.swallow('hook_service', e);
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
        'hook': hook.canonicalId,
      };
      if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
      fired++;
      try {
        await _ledger(
          sessionId,
          'hook/invoked',
          _hookDeclaresAsync(hook)
              ? {...Map<String, dynamic>.from(record), 'async': true}
              : Map<String, dynamic>.from(record),
        );
      } catch (e) {
        Diag.swallow('hook_service', e);
      }
      // `async: true` hooks are fire-and-forget per the Claude Code
      // contract: launch without awaiting so they never block the session.
      // Their output is NOT collected into session context (it may arrive
      // after the turn), and failures only touch the health ledger.
      if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
      if (_hookDeclaresAsync(hook)) {
        // `_exec` resolves normally on nonzero exit — check the code the
        // same way the sync path does, instead of recording every
        // completed process as a success.
        unawaited(
          _exec(hook, env, cwd, stdinPayload: stdinJson)
              .then((result) async {
                if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) {
                  _removeEnvFile(env['CLAUDE_ENV_FILE'] ?? '');
                  return;
                }
                final (code, out, err) = result;
                if (code == 0) {
                  _recordSuccess(pluginId, sessionId);
                  return;
                }
                if (code == 126 || code == 127) {
                  _noteBlocker(
                    pluginId,
                    'hook executable or dependency unavailable (exit $code) — repair runtime and retry',
                  );
                } else {
                  _recordFailure(pluginId, sessionId);
                }
                try {
                  await _ledger(sessionId, 'hook/result', {
                    ...record,
                    'ok': false,
                    'exit': code,
                    'async': true,
                    'warning': 'async hook failed (fail-open) — output ignored',
                    'stdoutChars': out.length,
                    'stderrChars': err.length,
                  });
                } catch (e) {
                  Diag.swallow('hook_service', e);
                }
              })
              .catchError((Object error) {
                if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) {
                  return;
                }
                if (error is! HookRuntimeUnavailable) {
                  _recordFailure(pluginId, sessionId);
                }
              }),
        );
        continue;
      }
      try {
        if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
        final (code, rawOut, rawErr) = await _exec(
          hook,
          env,
          cwd,
          stdinPayload: stdinJson,
        );
        if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) {
          _removeEnvFile(env['CLAUDE_ENV_FILE'] ?? '');
          continue;
        }
        if (code == 0 && canonical == 'session_start') {
          _appendSessionEnv(
            env['CLAUDE_ENV_FILE'] ?? '',
            extractEnvFileAppend(rawOut),
          );
        }
        final known = <String, dynamic>{
          ...payload,
          ...env,
          ..._loadSessionEnv(env['CLAUDE_ENV_FILE'] ?? ''),
        };
        final out = _safeOutput(rawOut, known);
        final err = _safeOutput(rawErr, known);
        if (code != 0) {
          // CLAUDE CODE PARITY (audit 2026-09-25): on the two events Claude
          // Code lets a command hook block — `user_prompt_submit` (block the
          // prompt) and `subagent_end` (block the stop, keep working) — exit 2
          // is a DECISION, not a failure, and its stderr is the reason. On
          // every other observe event exit 2 stays fail-open, because a broken
          // hook must never brick a run.
          if (code == 2 && kExit2BlockingEvents.contains(canonical)) {
            final diagnostic = err.isNotEmpty ? err : out;
            blockedReason = diagnostic.trim().isEmpty
                ? 'plugin $pluginId blocked this prompt'
                : cleanHookJson(diagnostic.trim());
            try {
              await _ledger(sessionId, 'hook/result', {
                ...record,
                'ok': false,
                'exit': code,
                'decision': 'block',
                'reason': blockedReason,
              });
            } catch (e) {
              Diag.swallow('hook_service', e);
            }
            break;
          }
          failed++;
          retryableFailure = true;
          if (code == 126 || code == 127) {
            _noteBlocker(
              pluginId,
              'hook executable or dependency unavailable (exit $code) — repair runtime and retry',
            );
          } else if (canonical != 'session_start') {
            _recordFailure(pluginId, sessionId);
          }
          try {
            await _ledger(sessionId, 'hook/result', {
              ...record,
              'ok': false,
              'exit': code,
              'warning': 'hook failed (fail-open) — output ignored',
              'stdoutChars': out.length,
              'stderrChars': err.length,
            });
          } catch (e) {
            Diag.swallow('hook_service', e);
          }
          continue;
        }
        _recordSuccess(pluginId, sessionId);
        if (canonical == 'session_start' &&
            contextEpoch != (_sessionContextEpochs[sessionId] ?? 0)) {
          break;
        }
        // A SessionStart hook may persist vars for the session via
        // `hookSpecificOutput.envFileAppend` (item 8).
        final contract = HookOutputContract.parse(rawOut);
        final published = HookOutputContract.parse(out);
        final trimmed = out.trim();
        final context = contract.suppressOutput ? '' : extractHookContext(out);
        if (canonical == 'session_start') {
          // Appending the env file above awaits I/O; a session end or plugin
          // update in that interval must fence both in-memory and disk writes.
          if (contextEpoch != (_sessionContextEpochs[sessionId] ?? 0)) break;
          if (!pluginId.startsWith('legacy:') &&
              (!PluginContributionRegistry.I.isPluginActiveForSession(
                    pluginId,
                    sessionId,
                  ) ||
                  startKey != _contextKey(pluginId, hook))) {
            continue;
          }
          final contexts = _sessionContexts.putIfAbsent(sessionId, () => {});
          contexts[startKey] = _capContext(context, maxSessionContextChars);
          if (!pluginId.startsWith('legacy:')) {
            final explicit = HookContextStore.explicitContext(out);
            try {
              await _contextStore.put(
                sessionId,
                startKey,
                explicit == null
                    ? null
                    : _capContext(explicit, maxSessionContextChars),
              );
            } catch (_) {
              Diag.swallow(
                'hook_context',
                'encrypted context persistence unavailable',
              );
            }
          }
          if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
          completedStartHooks?.add(receipt);
          if (!contract.continueHooks) {
            completedStartHooks?.add('halt:$receipt');
          }
        }
        if (trimmed.isNotEmpty && !contract.suppressOutput) {
          final isContextEvent =
              canonical == 'pre_request' || canonical == 'user_prompt_submit';
          collected.add((pluginId, hook, isContextEvent ? context : trimmed));
        }
        if (published.systemMessage != null) {
          systemMessages.add((pluginId, hook, published.systemMessage!));
        }
        try {
          await _ledger(sessionId, 'hook/result', {
            ...record,
            'ok': true,
            'stdoutChars': out.length,
            'stderrChars': err.length,
            if (!contract.continueHooks) 'halted': true,
            if (contract.suppressOutput) 'suppressOutput': true,
            if (published.systemMessage != null)
              'systemMessage': published.systemMessage,
          });
        } catch (e) {
          Diag.swallow('hook_service', e);
        }
        // `continue:false` halts further hooks for this event (item 9).
        if (!contract.continueHooks) {
          if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
          halted = true;
          break;
        }
      } catch (e) {
        if (!_hookCurrent(sessionId, pluginId, hook, contextEpoch)) continue;
        failed++;
        retryableFailure = true;
        if (e is! HookRuntimeUnavailable && canonical != 'session_start') {
          _recordFailure(pluginId, sessionId);
        }
        try {
          await _ledger(sessionId, 'hook/result', {
            ...record,
            'ok': false,
            'error': e is HookRuntimeUnavailable
                ? e.toString()
                : 'hook execution failed',
            'warning': 'hook failed (fail-open) — run continues',
          });
        } catch (e) {
          Diag.swallow('hook_service', e);
        }
      }
    }
    if (!enabled || contextEpoch != (_sessionContextEpochs[sessionId] ?? 0)) {
      return const HookFireResult(output: '');
    }
    List<String> activeText(List<(String, PluginHook, String)> values) => [
      for (final entry in values)
        if (_hookCurrent(sessionId, entry.$1, entry.$2, contextEpoch)) entry.$3,
    ];
    final joined = activeText(collected).join('\n');
    // SessionStart's public output retains its legacy stdout shape. Standing
    // context is already parsed per hook above; never truncate a JSON envelope.
    final output =
        canonical == 'pre_request' || canonical == 'user_prompt_submit'
        ? _capContext(joined, 2048)
        : joined;
    return HookFireResult(
      output: output,
      systemMessages: activeText(systemMessages),
      halted: halted,
      promptBlockReason: activeText(promptBlocks).firstOrNull,
      blockedReason: blockedReason,
      retryableFailure: retryableFailure,
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
      'hook_event_name':
          canonicalEvent == 'post_tool' &&
              (redacted['hook_event_name'] == 'PostToolUseFailure' ||
                  redacted['is_error'] == true ||
                  redacted['error'] != null)
          ? 'PostToolUseFailure'
          : ccHookEventNames[canonicalEvent] ?? canonicalEvent,
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
    if (canonicalEvent == 'session_start') {
      m['source'] =
          redacted['source'] ?? _ccSessionSource(reason?.toString() ?? '');
    }
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
          if (j['ok'] is bool) {
            final reason = j['reason'];
            return PromptHookVerdict(
              j['ok'] == true ? 'approve' : 'block',
              reason is String ? reason : null,
            );
          }
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
      raw = [for (final e in append.entries) '${e.key}=${e.value}'];
    } else {
      final envMap = hm['env'];
      if (envMap is! Map) return const [];
      raw = [for (final e in envMap.entries) '${e.key}=${e.value}'];
    }
    final accepted = [
      for (final line in raw)
        if (_envAssignment(line) != null) line.trim(),
    ];
    if (accepted.length != raw.length) {
      Diag.swallow('hook_env', 'unsupported environment assignment skipped');
    }
    return accepted;
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
        zoneValues: {
          _depthKey: chainDepth + 1,
          _registrationSnapshotKey: _registrationSnapshot(hooks),
        },
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
        zoneValues: {
          _depthKey: chainDepth + 1,
          _registrationSnapshotKey: _registrationSnapshot(hooks),
        },
      );
      if (userStopChecker?.call(sessionId) == true) {
        return const HookStopResult.allow(userInitiated: true);
      }
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
    final epoch = _sessionContextEpochs[sessionId] ?? 0;
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
    final rewrites = <(String, PluginHook, Map<String, dynamic>)>[];
    final allows = <(String, PluginHook)>[];
    void reconcileContributions() {
      rewrites.removeWhere((e) => !_hookCurrent(sessionId, e.$1, e.$2, epoch));
      allows.removeWhere((e) => !_hookCurrent(sessionId, e.$1, e.$2, epoch));
      updatedInput = rewrites.lastOrNull?.$3;
    }

    // Set when any hook returns permissionDecision:"allow" — the caller then
    // skips the ordinary user approval prompt for this call (audit 2026-09-25).
    var bypassPermission = false;
    for (final (pluginId, hook, declaredEvent) in hooks) {
      reconcileContributions();
      bypassPermission = allows.isNotEmpty;
      if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
      if (!_hookMatches(pluginId, hook, canonical, payload)) continue;
      if (_tripped.contains('$pluginId|$sessionId')) continue;
      final displayName = _displayName(pluginId);
      if (hook.type == 'agent') {
        final verdict = await _evalAgentHook(
          pluginId: pluginId,
          hook: hook,
          canonical: canonical,
          sessionId: sessionId,
          payload: payload,
          model: model,
          stdinJson: stdinJson,
        );
        if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
        reconcileContributions();
        if (verdict?.isBlock == true) {
          final reason = verdict!.reason ?? '$displayName denied this action';
          return HookGateResult.deny(
            displayName,
            reason,
            updatedInput: updatedInput,
          );
        }
        continue;
      }
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
        if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
        reconcileContributions();
        if (verdict != null && verdict.decision == 'block') {
          failed++;
          final reason = verdict.reason ?? '$displayName denied this action';
          try {
            await _ledger(sessionId, 'hook/result', {
              'plugin': pluginId,
              'event': canonical,
              'type': 'prompt',
              'ok': false,
              'decision': 'deny',
              'reason': reason,
            });
          } catch (e) {
            Diag.swallow('hook_service', e);
          }
          if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
          reconcileContributions();
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
        'hook': hook.canonicalId,
      };
      if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
      fired++;
      try {
        await _ledger(
          sessionId,
          'hook/invoked',
          Map<String, dynamic>.from(record),
        );
      } catch (e) {
        Diag.swallow('hook_service', e);
      }
      try {
        if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
        final (code, rawOut, rawErr) = await _exec(
          hook,
          env,
          cwd,
          gate: true,
          stdinPayload: stdinJson,
        );
        if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
        final known = <String, dynamic>{
          'payload': payload,
          'env': env,
          'output': _decodedOutput(rawOut),
        };
        final out = _safeOutput(rawOut, known);
        final err = _safeOutput(rawErr, known);
        if (code != 0 && code != 2) {
          failed++;
          if (code == 126 || code == 127) {
            _noteBlocker(
              pluginId,
              'hook executable or dependency unavailable (exit $code) — repair runtime and retry',
            );
          } else {
            _recordFailure(pluginId, sessionId);
          }
          await _ledger(sessionId, 'hook/result', {
            ...record,
            'ok': false,
            'exit': code,
            'stdoutChars': out.length,
            'stderrChars': err.length,
          });
          continue;
        }
        // Decisions and executable arguments are operational data. Never parse
        // them from a publication copy: a credential can equal "deny".
        final contract = HookOutputContract.parse(rawOut);
        // Rewritten tool args (item 5) — collected even from hooks that
        // allow, so the caller can apply them pre-execution.
        if (contract.updatedInput != null) {
          rewrites.add((pluginId, hook, contract.updatedInput!));
        }
        reconcileContributions();
        final rawBlockReason = jsonBlockReason(rawOut);
        final blockReason = rawBlockReason == null
            ? null
            : _safeOutput(rawBlockReason, known);
        final decision = contract.decision;
        final permDecision = contract.permissionDecision;
        final denies =
            code == 2 ||
            blockReason != null ||
            decision == 'block' ||
            decision == 'deny' ||
            permDecision == 'deny';
        final asks = !denies && (decision == 'ask' || permDecision == 'ask');
        if (!denies && !asks && permDecision == 'allow') {
          allows.add((pluginId, hook));
          bypassPermission = true;
        }
        if (denies || asks) {
          failed++;
          final reason = _safeOutput(
            (code == 2 && err.trim().isNotEmpty
                    ? cleanHookJson(err.trim())
                    : null) ??
                blockReason ??
                contract.reason ??
                contract.permissionDecisionReason ??
                (out.trim().isEmpty
                    ? '$displayName denied this action'
                    : cleanHookJson(out.trim())),
            known,
          );
          try {
            await _ledger(sessionId, 'hook/result', {
              ...record,
              'ok': false,
              'exit': code,
              'decision': asks ? 'ask' : 'deny',
              'blockReason': ?blockReason,
              'reason': reason,
              if (contract.updatedInput != null)
                'updatedInput': _decodedOutput(
                  _safeOutput(jsonEncode(contract.updatedInput), known),
                ),
            });
          } catch (e) {
            Diag.swallow('hook_service', e);
          }
          if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
          reconcileContributions();
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
            'stdoutChars': out.length,
            'stderrChars': err.length,
            if (contract.updatedInput != null)
              'updatedInput': _decodedOutput(
                _safeOutput(jsonEncode(contract.updatedInput), known),
              ),
            if (!contract.continueHooks) 'halted': true,
          });
        } catch (e) {
          Diag.swallow('hook_service', e);
        }
        if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
        if (!contract.continueHooks) break;
      } catch (e) {
        // Exec error/timeout/missing sandbox — fail-open, but count
        // toward the breaker and record the visible warning.
        if (!_hookCurrent(sessionId, pluginId, hook, epoch)) continue;
        failed++;
        if (e is! HookRuntimeUnavailable) _recordFailure(pluginId, sessionId);
        try {
          await _ledger(sessionId, 'hook/result', {
            ...record,
            'ok': false,
            'error': e is HookRuntimeUnavailable
                ? e.toString()
                : 'hook execution failed',
            'reason': 'gate fails open on error',
          });
        } catch (e) {
          Diag.swallow('hook_service', e);
        }
      }
    }
    if (!enabled || epoch != (_sessionContextEpochs[sessionId] ?? 0)) {
      return const HookGateResult.allow();
    }
    reconcileContributions();
    bypassPermission = allows.isNotEmpty;
    return HookGateResult.allow(
      updatedInput: updatedInput,
      bypassPermission: bypassPermission,
    );
  }
}
