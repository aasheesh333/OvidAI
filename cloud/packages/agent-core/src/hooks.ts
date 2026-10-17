// Hooks engine (P3 Task 18) — port of lib/core/hook_service.dart onto the
// cloud's SandboxPort / HookEngine seam.
//
// EVENT SET (deliberate cuts, AG4 delete-with-comment): the cloud union
// (ports.ts) is 9 events. Dart's session_end, permission_request,
// pre_compact, post_compact and subagent_start have NO cloud member:
//   • session_end       — cloud sessions are server-persistent; there is no
//                         per-process lifecycle to hook.
//   • permission_request— approvals are Task 12's ApprovalGate; a hook deny
//                         still wins at the pre_tool gate.
//   • pre/post_compact  — Task 19's Compactor seam.
//   • subagent_start    — Task 20.
// `subagent_stop` is Dart's `subagent_end` under the cloud name.
//
// CUT-with-comment: agent-type hooks (type:"agent") are skipped fail-open —
// Dart production never wires a tool-capable evaluator either; env-file
// persistence (CLAUDE_ENV_FILE is exported empty), the plugin
// registry/activation lifecycle, encrypted context restore, async hooks, and
// the on-device .cmd-sibling/shell selection. Command hooks run in the
// session jail through SandboxPort.exec.
//
// EXIT TAXONOMY (Dart parity):
//   0            success; stdout is context / the JSON output contract
//   2            BLOCK: pre_tool deny, stop/subagent_stop veto,
//                user_prompt_submit promptBlockReason; post_tool feedback
//                (tool already ran); every other observe event fails open
//   126 / 127    runtime unavailable — retryable, never trips the breaker
//   other != 0   non-blocking failure, counts toward the breaker
//   spawn throw  runtime unavailable — retryable, never trips the breaker
//   timeout      the sandbox returns a failed result / throws; retryable when
//                it surfaces as a spawn failure, otherwise a counted failure
//
// CONCURRENCY: pre_tool gates SERIALIZE per session (plan L753) so a blocking
// hook can never fail-open a concurrent call. Dart instead SKIPS a re-entrant
// same-event fire (hook_service.dart:2242–2251); the cloud deliberately
// strengthens this to an ordered queue. Observe events run concurrently.

import {
  ccMatcherNames,
  ccToolInput,
  ccToolName,
  nativeToolInput,
} from "./claudeCodeTools.js";
import type {
  HookEngine,
  HookEvent,
  HookFireResult,
  HookGateResult,
  HookStopResult,
  SandboxPort,
} from "./ports.js";

// ---------------------------------------------------------------------------
// Constants (Dart hook_service.dart)
// ---------------------------------------------------------------------------

/** Consecutive failures per (pluginId, sessionId) that trip the breaker. */
export const HOOK_BREAKER_THRESHOLD = 3;
/** Default per-hook command timeout (Dart defaultTimeoutS = 30). */
export const HOOK_DEFAULT_TIMEOUT_MS = 30_000;
/** Hard cap on a declared timeout (Dart maxTimeoutS = 300). */
export const HOOK_MAX_TIMEOUT_MS = 300_000;
/** Default prompt-evaluator timeout (Dart item 3: 120 s, clamp 1..300). */
export const PROMPT_HOOK_DEFAULT_TIMEOUT_MS = 120_000;
/** Standing session_start context cap (Dart maxSessionContextChars). */
export const MAX_SESSION_CONTEXT_CHARS = 8192;
/** pre_request / user_prompt_submit observe-output cap. */
export const MAX_OBSERVE_OUTPUT_CHARS = 2048;
/** Declared matchers longer than this are never compiled. */
export const MAX_MATCHER_LENGTH = 256;
/** stdout/stderr pipe cap; exceeding it kills the child (Dart 65536). */
export const HOOK_OUTPUT_PIPE_CAP = 65_536;
/** OVID_HOOK_PAYLOAD/PLUGIN_PAYLOAD one-line env cap. */
export const HOOK_ENV_PAYLOAD_CAP = 4096;
/** env tool_response preview (stdin carries the full value). */
export const HOOK_ENV_TOOL_RESPONSE_CHARS = 4000;
/** Prompt-verdict reason cap (Dart 500 + ellipsis). */
export const PROMPT_REASON_CAP = 500;
/** Workspace the session jail mounts (P2 JAIL_WORKSPACE). */
export const HOOK_WORKSPACE = "/workspace";
/** Workspace-relative hook manifest. */
export const HOOK_FILE = ".dsh/hooks.json";
/** Redaction spelling, pinned by the plan (Dart uses [redacted]). */
export const REDACTED = "[REDACTED]";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export interface HookDefinition {
  id: string;
  pluginId: string;
  event: HookEvent;
  matcher?: string;
  type: "command" | "prompt";
  command?: string;
  prompt?: string;
  timeoutMs?: number;
  /** Dart's optional `if` predicate (`ToolName(arg-pattern)`). */
  if?: string;
  /**
   * The DECLARED event spelling (Dart `ovidSourceEvent`), e.g. `PreToolUse`,
   * `on_turn_end`, `PostToolUseFailure`. Reported as OVID_HOOK_EVENT.
   */
  declaredEvent?: string;
  /**
   * Declared PostToolUse vs PostToolUseFailure. When set, a post_tool hook
   * fires only for the matching outcome (Dart hook_service.dart:1266–1275).
   */
  sourceEvent?: "PostToolUse" | "PostToolUseFailure";
}

export interface HookSource {
  hooksFor(sessionId: string): Promise<readonly HookDefinition[]>;
}

export type PromptHookEvaluator = (
  prompt: string,
  ctx: Record<string, unknown>,
) => Promise<string | null>;

export interface HookEngineDeps {
  sandbox: SandboxPort;
  sources: readonly HookSource[];
  promptEvaluator: PromptHookEvaluator;
  secrets?(): readonly string[];
  /**
   * Breaker diagnostics: called once when a plugin trips. The cloud engine has
   * no event sink of its own; the worker wires this to a `system_note` event.
   */
  onNotification?(
    message: string,
    ctx: { sessionId: string; pluginId: string },
  ): void;
  /**
   * SandboxPort.exec is keyed by userId, while HookEngine methods receive only
   * sessionId. At least one resolver is REQUIRED: a silent sessionId fallback
   * would run hooks in the wrong jail (or read no hooks.json) with no error.
   */
  userId?: string;
  userIdForSession?(sessionId: string): string | undefined;
  /** Jail workspace reported to hooks; defaults to /workspace. */
  workspaceDir?: string;
  /** The run's model id, exported as PLUGIN_MODEL and to prompt-hook ctx. */
  model?: string;
}

function assertUserResolver(deps: {
  userId?: string;
  userIdForSession?: (sessionId: string) => string | undefined;
}): void {
  if (deps.userIdForSession === undefined && (deps.userId ?? "") === "") {
    throw new Error(
      "hooks: userIdForSession (or a static userId) is required — hooks must " +
        "run in the session owner's jail, never a sessionId-keyed fallback",
    );
  }
}

// ---------------------------------------------------------------------------
// Event normalization
// ---------------------------------------------------------------------------

const CLOUD_EVENTS: ReadonlySet<string> = new Set([
  "session_start",
  "user_prompt_submit",
  "pre_request",
  "post_request",
  "pre_tool",
  "post_tool",
  "stop",
  "subagent_stop",
  "notification",
]);

/**
 * Dart `canonicalHookEvent` aliases accepted at the source layer. Events with
 * no cloud member map to undefined and are skipped (see the header cuts).
 */
const EVENT_ALIASES: Readonly<Record<string, HookEvent>> = {
  // Legacy Ovid aliases.
  on_session_start: "session_start",
  on_pre_request: "pre_request",
  on_pre_tool: "pre_tool",
  on_post_tool: "post_tool",
  on_turn_start: "user_prompt_submit",
  on_turn_end: "stop",
  // [CC] PascalCase names.
  SessionStart: "session_start",
  UserPromptSubmit: "user_prompt_submit",
  PreToolUse: "pre_tool",
  PostToolUse: "post_tool",
  PostToolUseFailure: "post_tool",
  Stop: "stop",
  SubagentStop: "subagent_stop",
  Notification: "notification",
  // Dart canonical spelling for the cloud's subagent_stop.
  subagent_end: "subagent_stop",
};

function normalizeEvent(raw: unknown): HookEvent | null {
  if (typeof raw !== "string") return null;
  const key = raw.trim();
  if (key === "") return null;
  if (CLOUD_EVENTS.has(key)) return key as HookEvent;
  return EVENT_ALIASES[key] ?? null;
}

/** [CC] `hook_event_name` for a cloud event (Dart ccHookEventNames). */
const CC_EVENT_NAMES: Readonly<Record<HookEvent, string>> = {
  session_start: "SessionStart",
  user_prompt_submit: "UserPromptSubmit",
  pre_request: "pre_request",
  post_request: "post_request",
  pre_tool: "PreToolUse",
  post_tool: "PostToolUse",
  stop: "Stop",
  subagent_stop: "SubagentStop",
  notification: "Notification",
};

/**
 * Events on which prompt-type hooks are LLM-evaluated. Dart's set is
 * {stop, subagent_end, user_prompt_submit, pre_tool, permission_request};
 * the cloud adds `pre_request` so the brief's "a prompt block on an OBSERVE
 * event surfaces promptBlockReason but cannot halt the run" is observable —
 * loop.ts emits hook_block_ignored for pre_request and never halts there.
 */
const PROMPT_HOOK_EVENTS: ReadonlySet<HookEvent> = new Set([
  "stop",
  "subagent_stop",
  "user_prompt_submit",
  "pre_request",
  "pre_tool",
]);

/** Exit 2 is a DECISION (not a failure) on these observe events. */
const EXIT2_BLOCKING_EVENTS: ReadonlySet<HookEvent> = new Set([
  "user_prompt_submit",
  "subagent_stop",
]);

function isToolEvent(event: HookEvent): boolean {
  return event === "pre_tool" || event === "post_tool";
}

/** True when a post_tool payload describes a failed tool call. */
export function isPostToolFailure(payload: Record<string, unknown>): boolean {
  return (
    payload["hook_event_name"] === "PostToolUseFailure" ||
    payload["is_error"] === true ||
    payload["error"] !== undefined ||
    payload["ok"] === false
  );
}

// ---------------------------------------------------------------------------
// File hook source: workspace `.dsh/hooks.json`
// ---------------------------------------------------------------------------

export interface FileHookSourceDeps {
  sandbox: SandboxPort;
  userId?: string;
  userIdForSession?(sessionId: string): string | undefined;
  path?: string;
}

/**
 * Reads the workspace hook manifest:
 *
 *   [{ "event": "PreToolUse", "matcher": "Bash", "type": "command",
 *      "command": "…", "timeoutMs": 30000, "id": "…" }]
 *
 * `type` may be omitted when `command`/`prompt` is present; `timeoutS` is
 * accepted as the Dart spelling. Plugin-manifest sources plug in at P5 — the
 * engine itself is source-agnostic. Re-read on every call (hot reload); a
 * missing or malformed file yields [].
 */
export function createFileHookSource(deps: FileHookSourceDeps): HookSource {
  const path = deps.path ?? HOOK_FILE;
  assertUserResolver(deps);
  const userIdFor = (sessionId: string): string => {
    const resolved = deps.userIdForSession?.(sessionId) ?? deps.userId;
    if (resolved === undefined || resolved === "") {
      throw new Error(
        `hooks: no userId for session ${sessionId} — hooks must run in the ` +
          "session owner's jail, never a sessionId-keyed fallback",
      );
    }
    return resolved;
  };
  return {
    async hooksFor(sessionId: string): Promise<readonly HookDefinition[]> {
      const userId = userIdFor(sessionId);
      let raw: string;
      try {
        raw = await deps.sandbox.readFile(userId, path);
      } catch {
        return [];
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        return [];
      }
      const entries = Array.isArray(parsed)
        ? parsed
        : isRecord(parsed) && Array.isArray(parsed["hooks"])
          ? parsed["hooks"]
          : [];
      const out: HookDefinition[] = [];
      entries.forEach((entry, index) => {
        if (!isRecord(entry)) return;
        const event = normalizeEvent(entry["event"]);
        if (event === null) return; // unsupported / cut event
        const declaredEvent = String(entry["event"]).trim();
        // PostToolUse and PostToolUseFailure both normalize to post_tool; the
        // declared spelling filters success vs failure payloads.
        const sourceEvent =
          declaredEvent === "PostToolUseFailure"
            ? ("PostToolUseFailure" as const)
            : declaredEvent === "PostToolUse"
              ? ("PostToolUse" as const)
              : undefined;
        const declaredType =
          typeof entry["type"] === "string" ? entry["type"].trim() : "";
        // Agent-type hooks are not wired in the cloud (Dart production leaves
        // the tool-capable evaluator unwired too) — skip fail-open.
        if (declaredType === "agent") return;
        const command =
          typeof entry["command"] === "string" ? entry["command"] : undefined;
        const prompt =
          typeof entry["prompt"] === "string" ? entry["prompt"] : undefined;
        const type: "command" | "prompt" | null =
          declaredType === "command" || declaredType === "prompt"
            ? declaredType
            : command !== undefined
              ? "command"
              : prompt !== undefined
                ? "prompt"
                : null;
        if (type === null) return;
        if (type === "command" && (command === undefined || command.trim() === "")) {
          return;
        }
        if (type === "prompt" && (prompt === undefined || prompt.trim() === "")) {
          return;
        }
        const pluginId =
          typeof entry["pluginId"] === "string" && entry["pluginId"].trim() !== ""
            ? entry["pluginId"].trim()
            : typeof entry["plugin"] === "string" && entry["plugin"].trim() !== ""
              ? entry["plugin"].trim()
              : "workspace";
        const id =
          typeof entry["id"] === "string" && entry["id"].trim() !== ""
            ? entry["id"].trim()
            : `${pluginId}:${event}:${index}`;
        const matcher =
          typeof entry["matcher"] === "string" ? entry["matcher"] : undefined;
        const timeoutMs = readTimeoutMs(entry);
        out.push({
          id,
          pluginId,
          event,
          type,
          ...(matcher !== undefined ? { matcher } : {}),
          ...(command !== undefined ? { command } : {}),
          ...(prompt !== undefined ? { prompt } : {}),
          ...(timeoutMs !== undefined ? { timeoutMs } : {}),
          ...(typeof entry["if"] === "string" ? { if: entry["if"] } : {}),
          declaredEvent,
          ...(sourceEvent !== undefined ? { sourceEvent } : {}),
        });
      });
      return out;
    },
  };
}

function readTimeoutMs(entry: Record<string, unknown>): number | undefined {
  if (typeof entry["timeoutMs"] === "number" && Number.isFinite(entry["timeoutMs"])) {
    return entry["timeoutMs"];
  }
  if (typeof entry["timeoutS"] === "number" && Number.isFinite(entry["timeoutS"])) {
    return entry["timeoutS"] * 1000;
  }
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// ---------------------------------------------------------------------------
// Redaction (hook_security_test.dart parity)
// ---------------------------------------------------------------------------

const SECRET_KEY_MARKERS = [
  "apikey",
  "api_key",
  "key",
  "token",
  "secret",
  "password",
  "passwd",
  "authorization",
  "auth",
  "credential",
  "private_key",
  "access_key",
] as const;

function isSecretKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9_]/g, "");
  return SECRET_KEY_MARKERS.some(
    (marker) =>
      normalized === marker ||
      normalized.endsWith(`_${marker}`) ||
      normalized.includes(marker),
  );
}

/** Collect secret VALUES: explicit secrets + every value under a secret key. */
function collectSecretValues(value: unknown, into: Set<string>): void {
  if (Array.isArray(value)) {
    for (const item of value) collectSecretValues(item, into);
    return;
  }
  if (!isRecord(value)) return;
  for (const [key, item] of Object.entries(value)) {
    if (isSecretKey(key)) {
      if (typeof item === "string" && item !== "") into.add(item);
    }
    collectSecretValues(item, into);
  }
}

function scrubText(text: string, secrets: readonly string[]): string {
  const ordered = [...new Set(secrets)]
    .filter((s) => s !== "")
    .sort((a, b) => b.length - a.length);
  let out = text;
  for (const secret of ordered) {
    out = out.split(secret).join(REDACTED);
    // JSON-escaped form (Dart _safeOutput parity).
    const escaped = JSON.stringify(secret).slice(1, -1);
    if (escaped !== secret) out = out.split(escaped).join(REDACTED);
  }
  return out;
}

/**
 * Redact a hook payload before it reaches stdin/env/ledger:
 *  • entries whose KEY looks secret are replaced wholesale with [REDACTED]
 *    (Dart `_isSecretKey` markers, recursive through maps and lists);
 *  • the VALUES of those entries plus [secrets] are exact-substring replaced
 *    everywhere else (so a key copied into a command cannot leak).
 * Never mutates the input.
 */
export function redactHookPayload(
  payload: Record<string, unknown>,
  secrets: readonly string[],
): Record<string, unknown> {
  // Only EXPLICIT secrets are substring-replaced. Values under secret keys are
  // replaced wholesale by the key rule; feeding them into the substring set
  // would let a short value ("s") corrupt unrelated text ("visible").
  const allSecrets = [...new Set(secrets)].filter((s) => s !== "");

  const walk = (value: unknown, key?: string): unknown => {
    if (key !== undefined && isSecretKey(key)) return REDACTED;
    if (Array.isArray(value)) return value.map((item) => walk(item));
    if (isRecord(value)) {
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(value)) out[k] = walk(v, k);
      return out;
    }
    if (typeof value === "string") return scrubText(value, allSecrets);
    return value;
  };

  return walk(payload) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Matchers (hook_matcher_parity_test.dart)
// ---------------------------------------------------------------------------

const MATCHES_EVERYTHING = "\u0000*";

/** Oversized patterns and nested quantifiers are never compiled (ReDoS). */
export function isSafeMatcher(matcher: string): boolean {
  if (matcher === "" || matcher === "*") return true;
  if (matcher.length > MAX_MATCHER_LENGTH) return false;
  if (/\([^)]*[*+?][^)]*\)[*+?]/.test(matcher)) return false;
  return true;
}

function hasRegexMeta(value: string): boolean {
  return /[\\^$.*+?()[\]{}|]/.test(value);
}

function mapSessionSource(reason: string): string {
  switch (reason) {
    case "created":
    case "implicit":
    case "subagent":
      return "startup";
    case "restored":
      return "resume";
    default:
      return reason;
  }
}

/** The subject strings a matcher runs against for [event]. */
function matcherSubjects(
  event: HookEvent,
  payload: Record<string, unknown>,
): string[] {
  if (isToolEvent(event)) {
    const tool = String(payload["tool"] ?? payload["tool_name"] ?? "");
    if (tool === "") return [MATCHES_EVERYTHING];
    const rawInput = payload["tool_input"] ?? payload["args"] ?? payload["input"];
    const input = isRecord(rawInput) ? rawInput : undefined;
    // CC aliases + the native name (Ovid-aware matchers keep working).
    return [...new Set([...ccMatcherNames(tool, input), tool])];
  }
  if (event === "session_start") {
    // Cloud session_start carries no source today: every cloud session is a
    // fresh start, so the default token is "startup" (Dart would map an
    // absent reason to "", silently killing `startup|clear|compact` hooks).
    const reason = String(payload["source"] ?? payload["reason"] ?? "startup");
    return [mapSessionSource(reason)];
  }
  if (event === "subagent_stop") {
    const type = String(payload["agent_type"] ?? "");
    return [type === "" ? MATCHES_EVERYTHING : type];
  }
  // No matcher vocabulary: a declared matcher never kills the hook.
  return [MATCHES_EVERYTHING];
}

function subjectMatches(
  event: HookEvent,
  matcher: string,
  subject: string,
): boolean {
  if (subject === MATCHES_EVERYTHING) return true;
  if (event === "subagent_stop" && matcher.includes(":")) {
    try {
      return new RegExp(matcher).test(subject);
    } catch {
      return false;
    }
  }
  try {
    if (new RegExp(`^(?:${matcher})$`).test(subject)) return true;
  } catch {
    return false; // malformed matcher → skip (fail-open)
  }
  // MCP server-prefix rule, boundary-exact, tool events only.
  if (isToolEvent(event) && subject.startsWith("mcp__")) {
    for (const branch of matcher.split("|")) {
      const b = branch.trim();
      if (!b.startsWith("mcp__") || hasRegexMeta(b)) continue;
      if (subject === b || subject.startsWith(`${b}__`)) return true;
    }
  }
  return false;
}

export function matcherApplies(
  event: HookEvent,
  matcher: string | undefined,
  payload: Record<string, unknown>,
): boolean {
  if (matcher === undefined || matcher === "" || matcher === "*") return true;
  if (!isSafeMatcher(matcher)) return false;
  return matcherSubjects(event, payload).some((subject) =>
    subjectMatches(event, matcher, subject),
  );
}

/** Dart's `if` predicate: `ToolName(arg-pattern)` against the tool input. */
function ifPredicateMatches(
  predicate: string,
  payload: Record<string, unknown>,
): boolean {
  const p = predicate.trim();
  if (p === "") return true;
  const paren = p.indexOf("(");
  let toolPart: string;
  let argPattern: string | null = null;
  if (paren < 0) {
    toolPart = p;
  } else {
    if (!p.endsWith(")")) return false;
    toolPart = p.slice(0, paren).trim();
    argPattern = p.slice(paren + 1, -1).trim();
  }
  if (toolPart === "") return false;
  const tool = String(payload["tool"] ?? payload["tool_name"] ?? "");
  if (toolPart !== "*" && toolPart !== tool) return false;
  if (argPattern === null || argPattern === "" || argPattern === "*") return true;
  const input = payload["tool_input"] ?? payload["args"] ?? payload["input"];
  const subject = typeof input === "string" ? input : JSON.stringify(input ?? null);
  let pattern = "";
  for (const ch of argPattern) {
    if (ch === "*") pattern += ".*";
    else if (ch === ":") pattern += "[:\\s]";
    else pattern += ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
  try {
    return new RegExp(pattern, "s").test(subject);
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// stdin / env contract (hook_stdin_test.dart, hook_service.dart:3065)
// ---------------------------------------------------------------------------

function cleanHookJson(value: string): string {
  const compact = value.replace(/\n/g, " ").replace(/\r/g, "");
  return compact.length > HOOK_ENV_PAYLOAD_CAP
    ? `${compact.slice(0, HOOK_ENV_PAYLOAD_CAP)}…`
    : compact;
}

function envSizedPayload(
  payload: Record<string, unknown>,
): Record<string, unknown> {
  const out = { ...payload };
  // The caller may spell the response `tool_response` (CC) or `result`
  // (the loop's post_tool payload) — bound both env copies.
  for (const key of ["tool_response", "tool_result", "result"]) {
    const response = out[key];
    if (typeof response === "string" && response.length > HOOK_ENV_TOOL_RESPONSE_CHARS) {
      out[key] = `${response.slice(0, HOOK_ENV_TOOL_RESPONSE_CHARS)}…`;
    }
  }
  return out;
}

/**
 * The FULL JSON payload a command hook receives on stdin. Absent optionals
 * are OMITTED (never null), matching the [CC] contract. Tool events speak
 * [CC]: `tool_name` is the CC name and `ovid_tool_name` keeps the native one
 * when they differ; `tool_input` carries both key sets.
 */
export function buildHookStdinJson(
  event: HookEvent,
  sessionId: string,
  payload: Record<string, unknown>,
  o: { cwd?: string; secrets?: readonly string[] } = {},
): string {
  const redacted = redactHookPayload(payload, o.secrets ?? []);
  const transcriptPath = String(
    redacted["transcript_path"] ?? redacted["transcriptPath"] ?? "",
  );
  const isFailure = event === "post_tool" && isPostToolFailure(redacted);

  const m: Record<string, unknown> = {
    session_id: sessionId,
    transcript_path: transcriptPath,
    cwd: o.cwd ?? HOOK_WORKSPACE,
    permission_mode: String(redacted["permission_mode"] ?? ""),
    hook_event_name: isFailure ? "PostToolUseFailure" : CC_EVENT_NAMES[event],
  };

  if (isToolEvent(event)) {
    const native = String(redacted["tool"] ?? redacted["tool_name"] ?? "");
    if (native !== "") {
      const rawInput = redacted["tool_input"] ?? redacted["args"] ?? redacted["input"];
      const input = isRecord(rawInput) ? rawInput : {};
      const cc = ccToolName(native, input);
      m["tool_name"] = cc;
      if (cc !== native) m["ovid_tool_name"] = native;
      m["tool_input"] = ccToolInput(native, input);
    }
    const response =
      redacted["tool_result"] ?? redacted["tool_response"] ?? redacted["result"];
    if (response !== undefined && response !== null) m["tool_response"] = response;
  }

  for (const key of [
    "tool_use_id",
    "duration_ms",
    "stop_hook_active",
    "last_assistant_message",
  ]) {
    if (redacted[key] !== undefined && redacted[key] !== null) m[key] = redacted[key];
  }
  // Subagent identity keys (CC common input fields).
  for (const key of [
    "agent_id",
    "agent_type",
    "agent_transcript_path",
    "root_session_id",
    "root_transcript_path",
  ]) {
    if (redacted[key] !== undefined && redacted[key] !== null) m[key] = redacted[key];
  }
  if (m["agent_id"] !== undefined) m["ovid_session_id"] = sessionId;

  const prompt = redacted["prompt"] ?? redacted["user_prompt"];
  if (prompt !== undefined && prompt !== null) m["prompt"] = prompt;
  if (redacted["reason"] !== undefined && redacted["reason"] !== null) {
    m["reason"] = String(redacted["reason"]);
  }
  if (event === "session_start") {
    const rawSource = redacted["source"];
    const source =
      rawSource !== undefined && rawSource !== null
        ? String(rawSource)
        : mapSessionSource(String(redacted["reason"] ?? "")) || "startup";
    m["source"] = source === "" ? "startup" : source;
  }
  if (event === "notification" && redacted["message"] !== undefined) {
    m["message"] = redacted["message"];
  }
  return JSON.stringify(m);
}

/** The four OVID_HOOK_* vars plus the [CC] canonical spellings. */
export function buildHookEnv(o: {
  definition: HookDefinition;
  event: HookEvent;
  sessionId: string;
  payload: Record<string, unknown>;
  secrets: readonly string[];
  workspace?: string;
  model?: string;
  stdinFile?: string;
}): Record<string, string> {
  const workspace = o.workspace ?? HOOK_WORKSPACE;
  const payloadJson = cleanHookJson(
    JSON.stringify({
      event: o.event,
      session: o.sessionId,
      ...redactHookPayload(envSizedPayload(o.payload), o.secrets),
    }),
  );
  return {
    // Legacy env contract: the DECLARED spelling (a hook registered as
    // `on_turn_end` or `PreToolUse` sees exactly that), never the normalized
    // internal name (Dart _envFor).
    OVID_HOOK_EVENT: o.definition.declaredEvent ?? o.definition.event,
    OVID_HOOK_PLUGIN: o.definition.pluginId,
    OVID_HOOK_SESSION: o.sessionId,
    OVID_HOOK_PAYLOAD: payloadJson,
    // [CC] canonical spellings (Dart _envFor).
    PLUGIN_ID: o.definition.pluginId,
    PLUGIN_EVENT: o.event,
    PLUGIN_SESSION: o.sessionId,
    PLUGIN_MODEL: o.model ?? "",
    PLUGIN_PAYLOAD: payloadJson,
    PLUGIN_ROOT: "",
    PLUGIN_STORAGE: "",
    PLUGIN_WORKSPACE: workspace,
    CLAUDE_PLUGIN_ROOT: "",
    CODEX_PLUGIN_ROOT: "",
    OVID_PLUGIN_ROOT: "",
    CLAUDE_PROJECT_DIR: workspace,
    CLAUDE_ENV_FILE: "",
    CLAUDE_CODE_REMOTE: "",
    // Set only for the oversized-payload path (see wrapHookCommand): the hook
    // reads its stdin JSON from this jail file instead of argv.
    ...(o.stdinFile !== undefined ? { OVID_HOOK_STDIN_FILE: o.stdinFile } : {}),
  };
}

/** argv payloads above this are delivered through a jail temp file. */
export const HOOK_ARGV_PAYLOAD_LIMIT = 96 * 1024;

/**
 * The post_tool payload the LOOP should pass to `hooks.fireDetailed("post_tool")`
 * (T16 wiring helper — loop.ts is owned by another task). It carries the FULL
 * tool input and the UNTRUNCATED tool result; the engine bounds only the env
 * copy (4000 chars) while stdin keeps the whole response.
 *
 * T16 call change (currently `result: rowContent.slice(0, 400)`, no input):
 *
 *   await deps.hooks.fireDetailed(
 *     "post_tool",
 *     sessionId,
 *     buildPostToolPayload({
 *       tool: call.name,
 *       args: effectiveArgs,
 *       result: rowContent,          // untruncated
 *       ok: result.isError !== true,
 *       toolUseId: call.id,
 *     }),
 *   );
 *
 * and apply `exit2Feedback`/`blockReasons`/`additionalContext`/
 * `updatedToolOutput` to the tool row (Dart PostToolHookResult.apply).
 */
export function buildPostToolPayload(o: {
  tool: string;
  args: Record<string, unknown>;
  result: string;
  ok: boolean;
  toolUseId?: string;
  durationMs?: number;
}): Record<string, unknown> {
  return {
    tool: o.tool,
    tool_name: o.tool,
    args: o.args,
    tool_input: o.args,
    result: o.result,
    tool_response: o.result,
    ok: o.ok,
    is_error: !o.ok,
    ...(o.toolUseId !== undefined ? { tool_use_id: o.toolUseId } : {}),
    ...(o.durationMs !== undefined ? { duration_ms: o.durationMs } : {}),
  };
}

/** UTF-8 byte length (argv limits are bytes, not UTF-16 code units). */
export function hookPayloadBytes(stdinJson: string): number {
  return Buffer.byteLength(stdinJson, "utf8");
}

/**
 * SandboxPort.exec has no stdin pipe, so the payload is piped with printf.
 * Single-quote escaping is POSIX-safe and byte-exact; the fake SandboxPort in
 * tests decodes the same wrapper. (`json.load(sys.stdin)` parity.)
 *
 * E2BIG guard: Linux MAX_ARG_STRLEN is 128 KiB of UTF-8 BYTES per argv
 * element, and the environment competes for the same budget. The guard is
 * therefore BYTE-based: a CJK/emoji payload can be well under the limit in
 * JS string units yet far over it in bytes. A larger payload is written to
 * `stdinFile` (workspace-relative, jail-absolute here) and redirected, so a
 * large `file_write`/`tool_response` can never make a pre_tool gate silently
 * fail open.
 *
 * The redirect path assumes `workspace` IS the jail mount point (P2
 * JAIL_WORKSPACE, default /workspace): SandboxPort file methods take
 * workspace-relative paths while exec runs with jail-absolute ones.
 */
export function wrapHookCommand(
  command: string,
  stdinJson: string,
  o: { stdinFile?: string } = {},
): string {
  if (
    hookPayloadBytes(stdinJson) > HOOK_ARGV_PAYLOAD_LIMIT &&
    o.stdinFile !== undefined
  ) {
    // Feed stdin from the file, then remove it in the same shell invocation so
    // the payload (which may contain secrets) does not linger in the jail. A
    // timeout kill can still strand it — the file is per-call and inert.
    return (
      `( ${command}\n) < '${o.stdinFile}'; ` +
      `__ovid_hook_rc=$?; rm -f '${o.stdinFile}'; exit $__ovid_hook_rc`
    );
  }
  const quoted = `'${stdinJson.replace(/'/g, `'\\''`)}'`;
  return `printf '%s' ${quoted} | ( ${command}\n)`;
}

// ---------------------------------------------------------------------------
// Output contract (HookOutputContract)
// ---------------------------------------------------------------------------

interface HookOutputContract {
  continueHooks: boolean;
  suppressOutput: boolean;
  systemMessage: string | null;
  decision: string | null;
  reason: string | null;
  additionalContext: string | null;
  permissionDecision: string | null;
  permissionDecisionReason: string | null;
  updatedInput: Record<string, unknown> | null;
  updatedToolOutput: string | null;
}

const EMPTY_CONTRACT: HookOutputContract = {
  continueHooks: true,
  suppressOutput: false,
  systemMessage: null,
  decision: null,
  reason: null,
  additionalContext: null,
  permissionDecision: null,
  permissionDecisionReason: null,
  updatedInput: null,
  updatedToolOutput: null,
};

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/**
 * Parse a hook's stdout for the [CC] JSON output contract. Non-JSON output is
 * context, never a decision. The PermissionRequest envelope
 * (`hookSpecificOutput.decision.behavior`) is deliberately NOT interpreted:
 * the cloud has no permission_request event, and it must never approve a
 * pre_tool gate (hook_permission_request_contract_test.dart:94).
 */
export function parseHookOutputContract(stdout: string): HookOutputContract {
  const t = stdout.trim();
  if (t === "" || !t.startsWith("{") || !t.endsWith("}")) return EMPTY_CONTRACT;
  let parsed: unknown;
  try {
    parsed = JSON.parse(t);
  } catch {
    return EMPTY_CONTRACT;
  }
  if (!isRecord(parsed)) return EMPTY_CONTRACT;
  const hso = isRecord(parsed["hookSpecificOutput"])
    ? parsed["hookSpecificOutput"]
    : null;
  const updatedRaw = hso?.["updatedInput"];
  const replaced = hso?.["updatedToolOutput"] ?? hso?.["updatedMCPToolOutput"];
  return {
    continueHooks: typeof parsed["continue"] === "boolean" ? parsed["continue"] : true,
    suppressOutput: parsed["suppressOutput"] === true,
    systemMessage: nonEmptyString(parsed["systemMessage"]),
    decision:
      typeof parsed["decision"] === "string"
        ? parsed["decision"].trim().toLowerCase()
        : null,
    reason: nonEmptyString(parsed["reason"]),
    additionalContext: nonEmptyString(hso?.["additionalContext"]),
    permissionDecision:
      typeof hso?.["permissionDecision"] === "string"
        ? hso["permissionDecision"].trim().toLowerCase()
        : null,
    permissionDecisionReason: nonEmptyString(hso?.["permissionDecisionReason"]),
    updatedInput: isRecord(updatedRaw) ? updatedRaw : null,
    updatedToolOutput:
      replaced === undefined || replaced === null
        ? null
        : typeof replaced === "string"
          ? replaced
          : JSON.stringify(replaced),
  };
}

/** `{"decision":"block","reason":"…"}` reason, or null. */
function jsonBlockReason(stdout: string): string | null {
  const t = stdout.trim();
  if (!t.startsWith("{") || !t.endsWith("}")) return null;
  try {
    const parsed: unknown = JSON.parse(t);
    if (!isRecord(parsed) || parsed["decision"] !== "block") return null;
    return nonEmptyString(parsed["reason"]);
  } catch {
    return null;
  }
}

/**
 * Injectable context from a hook's stdout: [CC]
 * `hookSpecificOutput.additionalContext`, Cursor `additional_context`, SDK
 * `additionalContext`, plain stdout. A JSON envelope without a context field
 * yields '' (the envelope never leaks into the prompt).
 */
export function extractHookContext(stdout: string): string {
  const t = stdout.trim();
  if (t === "") return "";
  if (t.startsWith("{") || t.startsWith("[")) {
    try {
      const parsed: unknown = JSON.parse(t);
      if (isRecord(parsed)) {
        const nested = parsed["hookSpecificOutput"];
        if (isRecord(nested) && typeof nested["additionalContext"] === "string") {
          return nested["additionalContext"].trim();
        }
        for (const key of ["additional_context", "additionalContext", "context"]) {
          const value = parsed[key];
          if (typeof value === "string" && value.trim() !== "") {
            return value.trim();
          }
        }
      }
    } catch {
      // Malformed protocol output is never prompt context.
    }
    return "";
  }
  return t;
}

function capContext(text: string, cap: number): string {
  const suffix = "\n[hook output truncated]";
  return text.length <= cap ? text : `${text.slice(0, cap - suffix.length)}${suffix}`;
}

// ---------------------------------------------------------------------------
// Prompt-hook decisions (Dart parsePromptHookDecision)
// ---------------------------------------------------------------------------

export function parsePromptHookDecision(raw: string | null): {
  decision: "block" | "approve" | null;
  reason: string | null;
} {
  const t = (raw ?? "").trim();
  if (t === "") return { decision: null, reason: null };
  if (t.startsWith("{") && t.endsWith("}")) {
    try {
      const parsed: unknown = JSON.parse(t);
      if (isRecord(parsed)) {
        if (typeof parsed["ok"] === "boolean") {
          const reason = parsed["reason"];
          return {
            decision: parsed["ok"] ? "approve" : "block",
            reason: typeof reason === "string" ? reason : null,
          };
        }
        const decision = String(parsed["decision"] ?? "")
          .trim()
          .toLowerCase();
        if (decision === "block" || decision === "approve") {
          const reason = parsed["reason"];
          return {
            decision,
            reason: typeof reason === "string" && reason.trim() !== "" ? reason.trim() : null,
          };
        }
      }
    } catch {
      // Fall through to the text heuristics.
    }
  }
  const lower = t.toLowerCase();
  const capped = t.length > PROMPT_REASON_CAP ? `${t.slice(0, PROMPT_REASON_CAP)}…` : t;
  if (lower.startsWith("block")) return { decision: "block", reason: capped };
  if (lower.startsWith("approve")) return { decision: "approve", reason: capped };
  const negatedBlock = /\b(do not|don't|dont|never|no)\s+block\b/.test(lower);
  if (!negatedBlock && /\bblock\b/.test(lower)) {
    return { decision: "block", reason: capped };
  }
  if (/\bapprove\b/.test(lower)) return { decision: "approve", reason: capped };
  return { decision: null, reason: null };
}

function buildPromptHookPrompt(
  rule: string,
  event: HookEvent,
  sessionId: string,
  stdinJson: string,
): string {
  return (
    `You are evaluating a plugin hook rule for the "${CC_EVENT_NAMES[event]}" ` +
    `event (session "${sessionId}"). The plugin registered this rule:\n\n` +
    `${rule.replace(/\$ARGUMENTS/g, stdinJson)}\n\n` +
    `The current event context (JSON):\n${stdinJson}\n\n` +
    `Decide whether this event violates the rule. Reply with exactly ` +
    `one word — "block" or "approve" — or with JSON ` +
    `{"decision": "block"|"approve", "reason": "..."}. ` +
    `"block" stops the event; "approve" lets it proceed.`
  );
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

interface CommandResult {
  kind: "ok" | "runtime-unavailable" | "oversized";
  exitCode: number;
  stdout: string;
  stderr: string;
}

export function createHookEngine(deps: HookEngineDeps): HookEngine {
  assertUserResolver(deps);
  const workspace = deps.workspaceDir ?? HOOK_WORKSPACE;
  /** `${pluginId}\0${sessionId}` → consecutive failures (breaker). */
  const failures = new Map<string, number>();
  /** Tripped plugins: hooks are skipped for the session. */
  const tripped = new Set<string>();
  /** Per-session ordered gate queue (plan L753). */
  const gateQueues = new Map<string, Promise<void>>();
  /** Standing session_start context, per hook id (Dart _sessionContexts). */
  const sessionContexts = new Map<string, Map<string, string>>();
  /** Standing user_prompt_submit context for the run (overwritten per entry). */
  const promptContexts = new Map<string, string | null>();
  let callSeq = 0;

  const breakerKey = (pluginId: string, sessionId: string): string =>
    `${pluginId}\u0000${sessionId}`;

  const secrets = (): readonly string[] => deps.secrets?.() ?? [];

  const userIdFor = (sessionId: string): string => {
    const resolved = deps.userIdForSession?.(sessionId) ?? deps.userId;
    if (resolved === undefined || resolved === "") {
      throw new Error(
        `hooks: no userId for session ${sessionId} — hooks must run in the ` +
          "session owner's jail, never a sessionId-keyed fallback",
      );
    }
    return resolved;
  };

  function recordSuccess(pluginId: string, sessionId: string): void {
    failures.delete(breakerKey(pluginId, sessionId));
  }

  function recordFailure(pluginId: string, sessionId: string): void {
    const key = breakerKey(pluginId, sessionId);
    const n = (failures.get(key) ?? 0) + 1;
    if (n >= HOOK_BREAKER_THRESHOLD) {
      failures.delete(key);
      tripped.add(key);
      deps.onNotification?.(
        `disabled for this session after ${n} consecutive failures ` +
          `(circuit breaker) — re-enable the plugin to retry`,
        { sessionId, pluginId },
      );
    } else {
      failures.set(key, n);
    }
  }

  function isTripped(pluginId: string, sessionId: string): boolean {
    return tripped.has(breakerKey(pluginId, sessionId));
  }

  async function definitionsFor(
    event: HookEvent,
    sessionId: string,
  ): Promise<HookDefinition[]> {
    const out: HookDefinition[] = [];
    for (const source of deps.sources) {
      try {
        const hooks = await source.hooksFor(sessionId);
        for (const hook of hooks) {
          if (hook.event === event) out.push(hook);
        }
      } catch {
        // A broken source is fail-open.
      }
    }
    return out;
  }

  function applies(
    definition: HookDefinition,
    event: HookEvent,
    payload: Record<string, unknown>,
  ): boolean {
    // Declared PostToolUse vs PostToolUseFailure: both normalize to post_tool,
    // so the outcome decides which declarations fire (Dart ovidSourceEvent).
    if (event === "post_tool" && definition.sourceEvent !== undefined) {
      const failure = isPostToolFailure(payload);
      if ((definition.sourceEvent === "PostToolUseFailure") !== failure) {
        return false;
      }
    }
    if (!matcherApplies(event, definition.matcher, payload)) return false;
    if (definition.if !== undefined && !ifPredicateMatches(definition.if, payload)) {
      // Dart tests the predicate against the native payload AND every [CC]
      // alias payload (`_hookMatches` → `_ccAliasPayloads`): `Bash(git …)`
      // must gate the native `run_shell` tool.
      if (!isToolEvent(event)) return false;
      const native = String(payload["tool"] ?? payload["tool_name"] ?? "");
      const rawInput = payload["tool_input"] ?? payload["args"] ?? payload["input"];
      const input = isRecord(rawInput) ? rawInput : undefined;
      const aliases = ccMatcherNames(native, input).map((alias) => ({
        ...payload,
        tool: alias,
        tool_name: alias,
      }));
      if (!aliases.some((alias) => ifPredicateMatches(definition.if!, alias))) {
        return false;
      }
    }
    return true;
  }

  function timeoutMsFor(definition: HookDefinition, fallback: number): number {
    const declared = definition.timeoutMs ?? fallback;
    // Dart: `timeoutS <= 0` means "use the default" (30 s command / 120 s
    // prompt), not a 1 ms timeout.
    if (!Number.isFinite(declared) || declared <= 0) return fallback;
    return Math.min(Math.max(declared, 1), HOOK_MAX_TIMEOUT_MS);
  }

  async function execCommand(
    definition: HookDefinition,
    event: HookEvent,
    sessionId: string,
    payload: Record<string, unknown>,
  ): Promise<CommandResult> {
    const stdinJson = buildHookStdinJson(event, sessionId, payload, {
      cwd: workspace,
      secrets: secrets(),
    });
    const userId = userIdFor(sessionId);
    const callKey = `hook:${sessionId}:${definition.id}:${(callSeq += 1)}`;
    // E2BIG guard (BYTE-based): a >96 KiB UTF-8 payload cannot ride in one
    // argv element, so it is written into the session jail and fed through a
    // stdin redirect. Failing to write the file is a runtime failure
    // (fail-open, retryable) — it must never become a silent hook skip with
    // the gate half-run. `workspace` must be the jail mount point because the
    // file path is workspace-relative for writeFile and jail-absolute for the
    // shell redirect.
    let stdinFile: string | undefined;
    if (hookPayloadBytes(stdinJson) > HOOK_ARGV_PAYLOAD_LIMIT) {
      const relPath = `.dsh/tmp/hook-stdin-${callSeq}.json`;
      try {
        await deps.sandbox.writeFile(userId, relPath, stdinJson);
      } catch {
        return { kind: "runtime-unavailable", exitCode: -1, stdout: "", stderr: "" };
      }
      stdinFile = `${workspace}/${relPath}`;
    }
    const env = buildHookEnv({
      definition,
      event,
      sessionId,
      payload,
      secrets: secrets(),
      workspace,
      ...(deps.model !== undefined ? { model: deps.model } : {}),
      ...(stdinFile !== undefined ? { stdinFile } : {}),
    });
    try {
      const result = await deps.sandbox.exec(userId, {
        cmd: wrapHookCommand(
          definition.command ?? "",
          stdinJson,
          stdinFile !== undefined ? { stdinFile } : {},
        ),
        timeoutMs: timeoutMsFor(definition, HOOK_DEFAULT_TIMEOUT_MS),
        callKey,
        env,
      });
      if (
        result.stdout.length > HOOK_OUTPUT_PIPE_CAP ||
        result.stderr.length > HOOK_OUTPUT_PIPE_CAP
      ) {
        // The port cannot stream-kill mid-flight; kill the tracked call now
        // and fail open (Dart kills at 64 KiB and throws).
        try {
          await deps.sandbox.killCall(userId, callKey);
        } catch {
          // best effort
        }
        return {
          kind: "oversized",
          exitCode: result.exitCode,
          stdout: result.stdout.slice(0, HOOK_OUTPUT_PIPE_CAP),
          stderr: result.stderr.slice(0, HOOK_OUTPUT_PIPE_CAP),
        };
      }
      return {
        kind: "ok",
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      };
    } catch {
      // Spawn/runtime failure (Dart HookRuntimeUnavailable): retryable, never
      // consumes the breaker.
      return { kind: "runtime-unavailable", exitCode: -1, stdout: "", stderr: "" };
    }
  }

  interface PromptVerdict {
    decision: "block" | "approve";
    reason: string | null;
  }

  async function evalPromptHook(
    definition: HookDefinition,
    event: HookEvent,
    sessionId: string,
    payload: Record<string, unknown>,
    stdinJson: string,
  ): Promise<PromptVerdict | null> {
    if (!PROMPT_HOOK_EVENTS.has(event)) return null;
    if (typeof deps.promptEvaluator !== "function") return null;
    const rule = definition.prompt ?? "";
    const prompt = buildPromptHookPrompt(rule, event, sessionId, stdinJson);
    const timeoutMs = timeoutMsFor(definition, PROMPT_HOOK_DEFAULT_TIMEOUT_MS);
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const response = await Promise.race([
        deps.promptEvaluator(prompt, {
          event,
          session: sessionId,
          plugin: definition.pluginId,
          hook: definition.id,
          stdin: scrubText(stdinJson, secrets()),
          ...(deps.model !== undefined ? { model: deps.model } : {}),
        }),
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error("prompt hook timed out")),
            timeoutMs,
          );
        }),
      ]);
      const parsed = parsePromptHookDecision(response ?? null);
      if (parsed.decision === null) {
        recordSuccess(definition.pluginId, sessionId);
        return null;
      }
      recordSuccess(definition.pluginId, sessionId);
      return {
        decision: parsed.decision,
        reason: parsed.reason === null ? null : scrubText(parsed.reason, secrets()),
      };
    } catch {
      // Fail open; Dart records the evaluation failure (breaker).
      recordFailure(definition.pluginId, sessionId);
      return null;
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }

  function displayDenyReason(
    pluginId: string,
    reason: string | null,
  ): string {
    return reason ?? `${pluginId} denied this action`;
  }

  // ── observe events ──────────────────────────────────────────────────────

  /**
   * Secret values for publication scrubbing: explicit secrets + values under
   * secret-looking payload keys + values under secret-looking keys in the
   * hook's own decoded output (Dart `_safeOutput(raw, known)` includes the
   * payload on BOTH the observe and gate paths).
   */
  function knownSecretsFor(
    payload: Record<string, unknown>,
    stdout?: string,
  ): string[] {
    const set = new Set<string>(secrets());
    collectSecretValues(payload, set);
    if (stdout !== undefined) {
      try {
        collectSecretValues(JSON.parse(stdout), set);
      } catch {
        // Non-JSON output contributes nothing beyond the explicit secrets.
      }
    }
    return [...set];
  }

  async function fireDetailedInner(
    event: HookEvent,
    sessionId: string,
    payload: Record<string, unknown>,
  ): Promise<HookFireResult> {
    const hooks = await definitionsFor(event, sessionId);
    const stdinJson = buildHookStdinJson(event, sessionId, payload, {
      cwd: workspace,
      secrets: secrets(),
    });
    const collected: string[] = [];
    const systemMessages: string[] = [];
    const promptBlocks: string[] = [];
    const hookOutputs: string[] = [];
    const exit2Feedback: string[] = [];
    const blockReasons: string[] = [];
    const additionalContext: string[] = [];
    let updatedToolOutput: string | null = null;
    let blockedReason: string | null = null;
    const promptContextParts: string[] = [];

    for (const definition of hooks) {
      if (isTripped(definition.pluginId, sessionId)) continue;
      if (!applies(definition, event, payload)) continue;

      if (definition.type === "prompt") {
        const verdict = await evalPromptHook(
          definition,
          event,
          sessionId,
          payload,
          stdinJson,
        );
        if (verdict?.decision === "block") {
          promptBlocks.push(
            scrubText(
              verdict.reason ?? `blocked by prompt hook (${definition.pluginId})`,
              knownSecretsFor(payload),
            ),
          );
        }
        continue;
      }
      if (definition.type !== "command") continue;

      const result = await execCommand(definition, event, sessionId, payload);
      if (result.kind === "runtime-unavailable") continue; // retryable
      if (result.kind === "oversized") {
        recordFailure(definition.pluginId, sessionId);
        continue;
      }
      const known = knownSecretsFor(payload, result.stdout);
      if (result.exitCode !== 0) {
        const err = scrubText(result.stderr.trim(), known);
        const out = scrubText(result.stdout.trim(), known);
        if (result.exitCode === 2) {
          if (EXIT2_BLOCKING_EVENTS.has(event)) {
            blockedReason =
              cleanHookJson(err !== "" ? err : out) ||
              `plugin ${definition.pluginId} blocked this prompt`;
            break; // later hooks are skipped
          }
          if (event === "post_tool") {
            // Feedback for the model; the tool already ran (Dart
            // PostToolHookResult.feedback). Never a breaker failure.
            const diagnostic = err !== "" ? err : out;
            if (diagnostic !== "") exit2Feedback.push(diagnostic);
            recordSuccess(definition.pluginId, sessionId);
            continue;
          }
          // Every other observe event: fail open.
          if (event !== "session_start") {
            recordFailure(definition.pluginId, sessionId);
          }
          continue;
        }
        if (result.exitCode === 126 || result.exitCode === 127) {
          // Runtime unavailable — retryable, never consumes the breaker.
          continue;
        }
        if (event !== "session_start") {
          recordFailure(definition.pluginId, sessionId);
        }
        continue;
      }

      recordSuccess(definition.pluginId, sessionId);
      const contract = parseHookOutputContract(result.stdout);
      const context = contract.suppressOutput
        ? ""
        : scrubText(extractHookContext(result.stdout), known);
      const trimmed = scrubText(result.stdout.trim(), known);
      const isEnvelope = trimmed.startsWith("{") || trimmed.startsWith("[");
      const published = contract.suppressOutput ? "" : trimmed;

      if (published !== "") hookOutputs.push(published);
      if (event === "post_tool") {
        if (contract.decision === "block") {
          // Publication copy: the reason may interpolate a payload secret
          // (e.g. the failing command echoed back) — scrub it like every
          // other published field. The DECISION itself stays raw.
          blockReasons.push(
            scrubText(
              contract.reason ?? "blocked by a PostToolUse hook",
              known,
            ),
          );
        }
        if (contract.additionalContext !== null) {
          additionalContext.push(scrubText(contract.additionalContext, known));
        }
        if (contract.updatedToolOutput !== null) {
          updatedToolOutput = scrubText(contract.updatedToolOutput, known);
        }
      }

      if (event === "session_start") {
        const contexts = sessionContexts.get(sessionId) ?? new Map<string, string>();
        contexts.set(definition.id, capContext(context, MAX_SESSION_CONTEXT_CHARS));
        sessionContexts.set(sessionId, contexts);
      }
      if (event === "user_prompt_submit" && context !== "") {
        promptContextParts.push(context);
      }

      if (published !== "") {
        const isContextEvent =
          event === "pre_request" || event === "user_prompt_submit";
        // A JSON envelope is protocol, never prompt context: expose the
        // extracted `additionalContext` instead of the raw object.
        collected.push(isContextEvent ? context : isEnvelope ? context : trimmed);
      }
      if (contract.systemMessage !== null) {
        systemMessages.push(scrubText(contract.systemMessage, known));
      }
      if (!contract.continueHooks) break;
    }

    if (event === "user_prompt_submit") {
      const joined = promptContextParts.join("\n");
      // Brief/map: the standing prompt context is bounded at 2 KB (Dart caps
      // the fireDetailed output at 2048 BEFORE the run stores it).
      promptContexts.set(
        sessionId,
        joined === "" ? null : capContext(joined, MAX_OBSERVE_OUTPUT_CHARS),
      );
    }

    const joined = collected.join("\n");
    const output =
      event === "pre_request" || event === "user_prompt_submit"
        ? capContext(joined, MAX_OBSERVE_OUTPUT_CHARS)
        : joined;
    return {
      output,
      systemMessages,
      promptBlockReason: blockedReason ?? promptBlocks[0] ?? null,
      exit2Feedback,
      blockReasons,
      additionalContext,
      updatedToolOutput,
      hookOutputs,
    };
  }

  /** Never-throw wrapper: an engine bug must never break a run. */
  async function fireDetailed(
    event: HookEvent,
    sessionId: string,
    payload: Record<string, unknown>,
  ): Promise<HookFireResult> {
    try {
      return await fireDetailedInner(event, sessionId, payload);
    } catch {
      return {
        output: "",
        systemMessages: [],
        promptBlockReason: null,
        exit2Feedback: [],
        blockReasons: [],
        additionalContext: [],
        updatedToolOutput: null,
        hookOutputs: [],
      };
    }
  }

  // ── gate events ─────────────────────────────────────────────────────────

  interface GateOutcome {
    decision: "allow" | "deny" | "ask";
    reason: string | null;
    updatedInput: Record<string, unknown> | undefined;
    bypassPermission: boolean;
    pluginId: string | null;
  }

  async function runGate(
    event: HookEvent,
    sessionId: string,
    payload: Record<string, unknown>,
  ): Promise<GateOutcome> {
    const hooks = await definitionsFor(event, sessionId);
    const stdinJson = buildHookStdinJson(event, sessionId, payload, {
      cwd: workspace,
      secrets: secrets(),
    });
    let updatedInput: Record<string, unknown> | undefined;
    let bypassPermission = false;

    for (const definition of hooks) {
      if (isTripped(definition.pluginId, sessionId)) continue;
      if (!applies(definition, event, payload)) continue;

      if (definition.type === "prompt") {
        const verdict = await evalPromptHook(
          definition,
          event,
          sessionId,
          payload,
          stdinJson,
        );
        if (verdict?.decision === "block") {
          return {
            decision: "deny",
            reason: displayDenyReason(definition.pluginId, verdict.reason),
            updatedInput,
            bypassPermission,
            pluginId: definition.pluginId,
          };
        }
        continue;
      }
      if (definition.type !== "command") continue;

      const result = await execCommand(definition, event, sessionId, payload);
      if (result.kind === "runtime-unavailable") continue; // fail open
      if (result.kind === "oversized") {
        recordFailure(definition.pluginId, sessionId);
        continue;
      }
      if (result.exitCode !== 0 && result.exitCode !== 2) {
        if (result.exitCode !== 126 && result.exitCode !== 127) {
          recordFailure(definition.pluginId, sessionId);
        }
        continue;
      }

      const contract = parseHookOutputContract(result.stdout);
      const knownSecrets = (() => {
        const set = new Set<string>(secrets());
        collectSecretValues(payload, set);
        try {
          collectSecretValues(JSON.parse(result.stdout), set);
        } catch {
          // non-JSON output
        }
        return [...set];
      })();

      if (contract.updatedInput !== null) {
        const native = String(payload["tool"] ?? payload["tool_name"] ?? "");
        const rawInput = payload["tool_input"] ?? payload["args"] ?? payload["input"];
        const original = isRecord(rawInput) ? rawInput : {};
        updatedInput = nativeToolInput(native, original, contract.updatedInput);
      }

      const rawBlockReason = jsonBlockReason(result.stdout);
      const decision = contract.decision;
      const permDecision = contract.permissionDecision;
      const denies =
        result.exitCode === 2 ||
        rawBlockReason !== null ||
        decision === "block" ||
        decision === "deny" ||
        permDecision === "deny";
      const asks = !denies && (decision === "ask" || permDecision === "ask");

      if (!denies && !asks && permDecision === "allow") {
        bypassPermission = true;
      }

      if (denies || asks) {
        const reason = scrubText(
          (result.exitCode === 2 && result.stderr.trim() !== ""
            ? cleanHookJson(result.stderr.trim())
            : null) ??
            rawBlockReason ??
            contract.reason ??
            contract.permissionDecisionReason ??
            (result.stdout.trim() === ""
              ? `${definition.pluginId} denied this action`
              : cleanHookJson(result.stdout.trim())),
          knownSecrets,
        );
        return {
          decision: asks ? "ask" : "deny",
          reason,
          updatedInput,
          bypassPermission,
          pluginId: definition.pluginId,
        };
      }

      recordSuccess(definition.pluginId, sessionId);
      if (!contract.continueHooks) break;
    }

    return {
      decision: "allow",
      reason: null,
      updatedInput,
      bypassPermission,
      pluginId: null,
    };
  }

  function enqueueGate<T>(sessionId: string, task: () => Promise<T>): Promise<T> {
    const previous = gateQueues.get(sessionId) ?? Promise.resolve();
    const next = previous.then(task, task);
    const settled = next.then(
      () => undefined,
      () => undefined,
    );
    gateQueues.set(sessionId, settled);
    void settled.then(() => {
      if (gateQueues.get(sessionId) === settled) gateQueues.delete(sessionId);
    });
    return next;
  }

  return {
    async hasListeners(event: HookEvent, sessionId: string): Promise<boolean> {
      const hooks = await definitionsFor(event, sessionId);
      return hooks.some(
        (hook) =>
          (hook.type === "command" || hook.type === "prompt") &&
          !isTripped(hook.pluginId, sessionId),
      );
    },

    async fire(event, sessionId, payload): Promise<void> {
      await fireDetailed(event, sessionId, payload);
    },

    fireDetailed,

    async fireGate(
      sessionId: string,
      payload: { tool: string; args: Record<string, unknown> },
    ): Promise<HookGateResult> {
      // Blocking hooks SERIALIZE per session: a concurrent blocking call must
      // never observe a half-run hook chain and fail open.
      try {
        return await enqueueGate(sessionId, async () => {
        const outcome = await runGate("pre_tool", sessionId, {
          tool: payload.tool,
          args: payload.args,
        });
        if (outcome.decision === "deny") {
          return {
            decision: "deny",
            reason: outcome.reason,
            deniedByPlugin: outcome.pluginId,
            ...(outcome.updatedInput !== undefined
              ? { updatedInput: outcome.updatedInput }
              : {}),
          };
        }
        if (outcome.decision === "ask") {
          return {
            decision: "ask",
            reason: outcome.reason,
            decidedByPlugin: outcome.pluginId,
            ...(outcome.updatedInput !== undefined
              ? { updatedInput: outcome.updatedInput }
              : {}),
          };
        }
        return {
          decision: "allow",
          ...(outcome.updatedInput !== undefined
            ? { updatedInput: outcome.updatedInput }
            : {}),
          ...(outcome.bypassPermission ? { bypassPermission: true } : {}),
        };
        });
      } catch {
        // A broken engine must never deny a tool call.
        return { decision: "allow" };
      }
    },

    async fireStop(
      sessionId: string,
      payload: Record<string, unknown>,
      event: "stop" | "subagent_stop" = "stop",
    ): Promise<HookStopResult> {
      // A user-initiated stop ALWAYS wins — hooks are not even resolved.
      if (payload["userStopRequested"] === true) return { veto: false };
      try {
        const outcome = await runGate(event, sessionId, payload);
        if (payload["userStopRequested"] === true) return { veto: false };
        if (outcome.decision === "deny") {
          return {
            veto: true,
            reason: outcome.reason ?? "stopped by hook",
            vetoedByPlugin: outcome.pluginId,
          };
        }
        // "ask" is meaningless at stop time — allow.
        return { veto: false };
      } catch {
        return { veto: false };
      }
    },

    sessionContextFor(sessionId: string): string {
      const contexts = sessionContexts.get(sessionId);
      if (contexts === undefined) return "";
      const text = [...contexts.values()].filter((v) => v !== "").join("\n");
      return capContext(text, MAX_SESSION_CONTEXT_CHARS);
    },

    promptContextFor(sessionId: string): string | null {
      return promptContexts.get(sessionId) ?? null;
    },
  };
}
