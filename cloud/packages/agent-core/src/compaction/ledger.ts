// Lossless compaction ledger — a port of
// lib/core/compaction/compaction_ledger.dart.
//
// The ledger is the DETERMINISTIC half of a checkpoint: built straight from
// the transcript (user messages and tool calls), never from a model summary.
// It is CUMULATIVE — each compaction absorbs only the newly folded span into
// the ledger carried forward from the previous compaction, so repeated
// compactions never summarise a summary. User instructions and the work log
// only grow.
//
// Cloud adaptations (all documented, none weakening the ported assertions):
//  * A Dart tool card (toolName/toolInput/toolDetail/toolState on one row) is
//    the cloud pair {role:"assistant", toolCalls} + {role:"tool", toolCallId}.
//    `absorb` resolves a tool row's name/args from the issuing call in the
//    same span.
//  * AgentMessage carries no isError/toolState; the outcome is derived from
//    the result text (`exit code N`, cloud's `[exit N]`, and the loop's
//    "tool error:" / "DENIED by user" prefixes).
//  * AgentMessage has no attachment channel; an additive `attachments` field
//    is read when the engine supplies one (Dart Message.attachments).
//  * P2/P3 tool-name aliases (write_file/edit_file/read_file, multi_edit,
//    notebook_edit) map onto the Dart categories.

import type { AgentMessage, ToolCall } from "../types.js";
import type { CompactionStateJson } from "../ports.js";

export type ActionKind =
  | "write"
  | "delete"
  | "shell"
  | "read"
  | "subagent"
  | "mcp"
  | "vcs"
  | "reply"
  | "other";

/** One user message, stored verbatim (large pastes keep head+tail). */
export interface LedgerUserMessage {
  seq: number;
  text: string;
  fullLength: number;
  attachments?: string[];
}

/** One thing the agent did, derived from a tool call (or a turn reply). */
export interface LedgerAction {
  seq: number;
  tool: string;
  kind: ActionKind;
  input: string;
  /** `ok` | `error` | `exit N`. */
  outcome: string;
  note?: string;
}

/** An error the agent hit and, once seen, the action that resolved it. */
export interface LedgerError {
  actionSeq: number;
  tool: string;
  input: string;
  error: string;
  fix?: string;
}

/** Dart `toJson` wire shape (keys are load-bearing: `{s,t,n?,a?}`). */
export interface CompactionLedgerJson {
  v: 1;
  compactions: number;
  folded: number;
  userCount: number;
  actionCount: number;
  goal?: string;
  users: Array<{ s: number; t: string; n?: number; a?: string[] }>;
  actions: Array<{
    s: number;
    tool: string;
    k: ActionKind;
    in: string;
    o: string;
    note?: string;
  }>;
  files: Record<string, string[]>;
  errors: Array<{ s: number; tool: string; in: string; e: string; fix?: string }>;
  collapsed?: Record<string, number>;
  focus?: string[];
  narrative?: string;
}

const ERROR_LINE =
  /error|exception|failed|denied|not found|cannot|no such|traceback/i;

function clip(s: string, max: number): string {
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`;
}

function firstLine(s: string, max: number): string {
  const line = s
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.length > 0);
  return clip(line ?? "", max);
}

function exitCodeOf(detail: string): number | null {
  // Dart: `exit(?:ed with)? code (-?\d+)` (LAST match). Cloud run_code emits
  // `[exit N]`; accept both, still LAST match.
  const re = /exit(?:ed with)? code (-?\d+)|\[exit (-?\d+)\]/g;
  let last: number | null = null;
  for (let m = re.exec(detail); m !== null; m = re.exec(detail)) {
    last = Number.parseInt(m[1] ?? m[2]!, 10);
  }
  return last;
}

function looksLikeError(detail: string): boolean {
  const first = detail.split("\n")[0]?.trim() ?? "";
  return (
    /^tool error:/i.test(first) ||
    /^denied by user\b/i.test(first) ||
    /^(?:error|exception)\b/i.test(first) ||
    /^[a-z0-9_.]+ failed[:.]/i.test(first)
  );
}

function diffPath(detail: string): string | null {
  const first = detail.split("\n")[0]!.trim();
  return first.startsWith("diff ") && first.length > 5
    ? first.slice(5).trim()
    : null;
}

/** `buildEditDiff` renders a whole-file create as only `+` lines. */
function diffIsCreate(detail: string): boolean {
  const lines = detail.split("\n");
  if (lines.length < 2 || !lines[0]!.startsWith("diff ")) return false;
  const body = lines.slice(1).filter((l) => l.length > 0);
  return (
    body.length > 0 && body.every((l) => l.startsWith("+") || l.startsWith("…"))
  );
}

function kindFor(tool: string): ActionKind {
  if (tool.startsWith("mcp_")) return "mcp";
  switch (tool) {
    case "file_write":
    case "write_file":
    case "fs_edit":
    case "edit_file":
    case "multi_edit":
    case "notebook_edit":
      return "write";
    case "run_shell":
    case "job_start":
    case "run_code":
      return "shell";
    case "file_read":
    case "read_file":
    case "fs_glob":
    case "fs_grep":
    case "read_image":
    case "git_status":
    case "git_diff":
    case "git_log":
    case "web_search":
    case "fetch_url":
    case "memory_search":
    case "session_search":
    case "session_read":
    case "job_output":
    case "job_list":
      return "read";
    case "dispatch_agent":
    case "workflow":
    case "ralph":
      return "subagent";
    case "commit":
    case "git_push":
    case "git_pull":
    case "git_clone":
      return "vcs";
    default:
      return tool.startsWith("browser_") ? "read" : "other";
  }
}

/**
 * File operations implied by a shell command (best effort): `rm` deletes,
 * `mv a b` deletes a and creates b, `cp`/`touch`/`mkdir` create, and
 * `> file` writes. Ported verbatim from Dart.
 */
export function shellFileOps(cmd: string): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  for (const seg of cmd.split(/&&|\|\||;|\n/)) {
    const words = seg
      .trim()
      .split(/\s+/)
      .filter((w) => w.length > 0);
    if (words.length === 0) continue;
    const verb = words[0]!;
    const operands = words
      .slice(1)
      .filter((w) => !w.startsWith("-") && !w.includes(">"))
      .map((w) => w.replace(/^['"]|['"]$/g, ""));
    switch (verb) {
      case "rm":
      case "rmdir":
      case "unlink":
        for (const p of operands) out.push([p, "deleted"]);
        break;
      case "mv":
        if (operands.length >= 2) {
          for (const p of operands.slice(0, -1)) out.push([p, "deleted"]);
          out.push([operands[operands.length - 1]!, "created"]);
        }
        break;
      case "cp":
        if (operands.length >= 2) {
          out.push([operands[operands.length - 1]!, "created"]);
        }
        break;
      case "touch":
      case "mkdir":
        for (const p of operands) out.push([p, "created"]);
        break;
      default:
        break;
    }
    for (const m of seg.matchAll(/(?<![0-9&])>>?\s*([^\s;&|<>]+)/g)) {
      const p = m[1]!;
      if (p !== "/dev/null" && !p.startsWith("&")) out.push([p, "edited"]);
    }
  }
  return out;
}

/**
 * The tool-input record stored on a tool card at dispatch: a JSON object of
 * the SMALL identifying args only. File bodies are recorded as sizes, never
 * as content (Dart `toolInputRecord`).
 */
export function toolInputRecord(
  tool: string,
  args: Record<string, unknown>,
): string {
  void tool;
  const keys = [
    "path",
    "file",
    "command",
    "cmd",
    "url",
    "query",
    "queries",
    "pattern",
    "prompt",
    "message",
    "selector",
    "old_path",
    "new_path",
    "from",
    "to",
    "server",
    "agent",
    "subagent_type",
    "objective",
    "mode",
    "cwd",
    "repo",
    "branch",
    "name",
  ];
  const out: Record<string, unknown> = {};
  for (const k of keys) {
    const v = args[k];
    if (v === null || v === undefined) continue;
    if (Array.isArray(v)) {
      out[k] = v.slice(0, 8).map((x) => clip(String(x), 200));
    } else if (typeof v === "string") {
      out[k] = clip(v, 300);
    } else if (typeof v === "number" || typeof v === "boolean") {
      out[k] = v;
    }
  }
  for (const k of ["content", "file_text", "new_str", "code"]) {
    const v = args[k];
    if (typeof v === "string") out[`${k}_chars`] = v.length;
  }
  return JSON.stringify(out);
}

/** The ledger itself (mutable accumulator; use {@link buildLedger}). */
export class CompactionLedger {
  /** Stored cap for one user message (Dart: 16000). */
  static readonly storedUserChars = 16_000;
  /** Stored cap for the action list (Dart: 3000). */
  static readonly storedActions = 3_000;

  compactions = 0;
  foldedMessages = 0;
  userCount = 0;
  actionCount = 0;
  goal: string | null = null;
  userMessages: LedgerUserMessage[] = [];
  actions: LedgerAction[] = [];
  /** path -> operations (created/edited/deleted/read), first-touch order. */
  files = new Map<string, Set<string>>();
  errors: LedgerError[] = [];
  /** Actions folded out under the storage cap: tool -> count. */
  collapsed = new Map<string, number>();
  /** Every `/compact <focus>` text, in order. */
  focus: string[] = [];
  /** The latest model-written narrative — the ONLY model-authored part. */
  narrative = "";

  /** Fold [span] (the newly compacted messages, in order) into the ledger. */
  absorb(span: readonly AgentMessage[]): void {
    const calls = new Map<string, ToolCall>();
    for (const m of span) {
      if (m.role === "assistant" && m.toolCalls !== undefined) {
        for (const c of m.toolCalls) calls.set(c.id, c);
      }
    }
    for (let i = 0; i < span.length; i += 1) {
      const m = span[i]!;
      if (m.role === "tool") {
        this.absorbTool(m, m.toolCallId !== undefined ? calls.get(m.toolCallId) : undefined);
        continue;
      }
      if (m.role === "user") {
        this.absorbUser(m);
        continue;
      }
      // A turn-ending assistant reply: its first line anchors "what the agent
      // told the user". A row carrying toolCalls is the tool card, not a reply.
      if (
        m.role === "assistant" &&
        (m.toolCalls === undefined || m.toolCalls.length === 0)
      ) {
        const next = i + 1 < span.length ? span[i + 1]! : undefined;
        const endsTurn = next === undefined || next.role === "user";
        const text = m.content.trim();
        if (endsTurn && text.length > 0) {
          this.addAction({
            tool: "reply",
            kind: "reply",
            input: firstLine(text, 200),
            outcome: "ok",
          });
        }
      }
    }
    this.enforceActionCap();
  }

  private absorbUser(m: AgentMessage): void {
    const raw = m.content.trim();
    // Dart Message.attachments -> the cloud's additive annotation.
    const attachments = (m as AgentMessage & { attachments?: readonly unknown[] })
      .attachments;
    const atts: string[] = [];
    if (Array.isArray(attachments)) {
      for (const a of attachments) {
        if (typeof a === "string") atts.push(a);
      }
    }
    if (raw.length === 0 && atts.length === 0) return;
    this.userCount += 1;
    const stored =
      raw.length <= CompactionLedger.storedUserChars
        ? raw
        : `${raw.slice(0, CompactionLedger.storedUserChars - 1_200)}\n` +
          `…[${raw.length - CompactionLedger.storedUserChars + 200} more chars of pasted ` +
          "content omitted here; the full original is user message " +
          `#${this.userCount} in the visible transcript]…\n` +
          raw.slice(raw.length - 1_000);
    this.userMessages.push({
      seq: this.userCount,
      text: stored,
      fullLength: raw.length,
      ...(atts.length > 0 ? { attachments: atts } : {}),
    });
    if (this.goal === null && raw.length > 0) this.goal = stored;
  }

  private absorbTool(m: AgentMessage, call: ToolCall | undefined): void {
    const tool = call?.name ?? "tool";
    const args = call?.args ?? {};
    const detail = m.content.trim();
    const input = displayInput(tool, args, m);
    const exit = exitCodeOf(detail);
    const outcome =
      exit !== null ? `exit ${exit}` : looksLikeError(detail) ? "error" : "ok";
    const kind = kindFor(tool);
    let note: string | undefined;
    const failed = outcome === "error" || (exit !== null && exit !== 0);
    if (failed) {
      note = errorLine(detail);
    } else if (kind === "subagent" || kind === "mcp") {
      const head = firstLine(detail, 200);
      if (head.length > 0) note = head;
    }
    const action = this.addAction({ tool, kind, input, outcome, ...(note !== undefined ? { note } : {}) });
    if (action.outcome === "error" || (exit !== null && exit !== 0)) {
      this.errors.push({
        actionSeq: action.seq,
        tool,
        input,
        error: note ?? "(failed)",
      });
    } else if (outcome === "ok" || outcome === "exit 0") {
      // The first later success of the same tool closes its open errors.
      for (const e of this.errors) {
        if (e.fix === undefined && e.tool === tool) {
          e.fix = `#${action.seq} ${tool} ${clip(input, 160)} → ${outcome}`;
        }
      }
    }
    this.recordFiles(tool, args, input, detail, failed);
  }

  private addAction(a: Omit<LedgerAction, "seq">): LedgerAction {
    this.actionCount += 1;
    const action: LedgerAction = { seq: this.actionCount, ...a };
    this.actions.push(action);
    return action;
  }

  private touch(path: string, op: string): void {
    const p = path.trim();
    if (p.length === 0 || p === "/dev/null" || p.startsWith("&")) return;
    let ops = this.files.get(p);
    if (ops === undefined) {
      ops = new Set<string>();
      this.files.set(p, ops);
    }
    ops.add(op);
  }

  private recordFiles(
    tool: string,
    args: Record<string, unknown>,
    input: string,
    detail: string,
    failed: boolean,
  ): void {
    const rawPath = args["path"] ?? args["file"] ?? args["file_path"];
    const path = rawPath !== undefined && rawPath !== null ? String(rawPath) : "";
    switch (tool) {
      case "file_write":
      case "write_file": {
        if (failed) return;
        const p = path.length > 0 ? path : diffPath(detail) ?? input;
        this.touch(p, diffIsCreate(detail) ? "created" : "edited");
        break;
      }
      case "fs_edit":
      case "edit_file": {
        if (failed) return;
        const p = path.length > 0 ? path : diffPath(detail) ?? "";
        const cmd = typeof args["command"] === "string" ? args["command"] : "";
        if (cmd === "view") this.touch(p, "read");
        else if (cmd === "create" || (cmd === "" && diffIsCreate(detail))) {
          this.touch(p, "created");
        } else this.touch(p, "edited");
        break;
      }
      case "multi_edit":
      case "notebook_edit":
        if (!failed) this.touch(path.length > 0 ? path : input, "edited");
        break;
      case "file_read":
      case "read_file":
      case "read_image":
        this.touch(path.length > 0 ? path : input, "read");
        break;
      case "run_shell":
      case "job_start": {
        if (failed) return;
        const cmd =
          typeof args["command"] === "string" ? args["command"] : input;
        for (const [p, op] of shellFileOps(cmd)) this.touch(p, op);
        break;
      }
      default:
        if (tool.startsWith("fs_") && path.length > 0) this.touch(path, "read");
        break;
    }
  }

  private enforceActionCap(): void {
    if (this.actions.length <= CompactionLedger.storedActions) return;
    const lowValue = (a: LedgerAction): boolean =>
      a.kind === "read" || a.kind === "reply";
    const keep = (a: LedgerAction): boolean =>
      a.outcome === "error" ||
      (a.outcome.startsWith("exit ") && a.outcome !== "exit 0") ||
      a.kind === "write" ||
      a.kind === "delete" ||
      a.kind === "subagent" ||
      a.kind === "mcp" ||
      a.kind === "vcs";
    for (const pass of [lowValue, (a: LedgerAction) => !keep(a)]) {
      let i = 0;
      while (
        this.actions.length > CompactionLedger.storedActions &&
        i < this.actions.length
      ) {
        if (pass(this.actions[i]!)) {
          const removed = this.actions.splice(i, 1)[0]!;
          this.collapsed.set(
            removed.tool,
            (this.collapsed.get(removed.tool) ?? 0) + 1,
          );
        } else i += 1;
      }
    }
  }

  // ── persistence ──────────────────────────────────────────────────────────

  toJson(): CompactionLedgerJson {
    const files: Record<string, string[]> = {};
    for (const [path, ops] of this.files) files[path] = [...ops];
    return {
      v: 1,
      compactions: this.compactions,
      folded: this.foldedMessages,
      userCount: this.userCount,
      actionCount: this.actionCount,
      ...(this.goal !== null ? { goal: this.goal } : {}),
      users: this.userMessages.map((u) => ({
        s: u.seq,
        t: u.text,
        ...(u.fullLength !== u.text.length ? { n: u.fullLength } : {}),
        ...(u.attachments !== undefined && u.attachments.length > 0
          ? { a: u.attachments }
          : {}),
      })),
      actions: this.actions.map((a) => ({
        s: a.seq,
        tool: a.tool,
        k: a.kind,
        in: a.input,
        o: a.outcome,
        ...(a.note !== undefined ? { note: a.note } : {}),
      })),
      files,
      errors: this.errors.map((e) => ({
        s: e.actionSeq,
        tool: e.tool,
        in: e.input,
        e: e.error,
        ...(e.fix !== undefined ? { fix: e.fix } : {}),
      })),
      ...(this.collapsed.size > 0
        ? { collapsed: Object.fromEntries(this.collapsed) }
        : {}),
      ...(this.focus.length > 0 ? { focus: [...this.focus] } : {}),
      ...(this.narrative.length > 0 ? { narrative: this.narrative } : {}),
    };
  }

  static fromJson(raw: unknown): CompactionLedger {
    const j = (raw ?? {}) as Partial<CompactionLedgerJson>;
    const l = new CompactionLedger();
    l.compactions = num(j.compactions);
    l.foldedMessages = num(j.folded);
    l.userCount = num(j.userCount);
    l.actionCount = num(j.actionCount);
    l.goal = typeof j.goal === "string" ? j.goal : null;
    l.narrative = typeof j.narrative === "string" ? j.narrative : "";
    for (const u of Array.isArray(j.users) ? j.users : []) {
      const text = typeof u?.t === "string" ? u.t : "";
      l.userMessages.push({
        seq: num(u?.s),
        text,
        fullLength: typeof u?.n === "number" ? u.n : text.length,
        ...(Array.isArray(u?.a) ? { attachments: u.a.map(String) } : {}),
      });
    }
    for (const a of Array.isArray(j.actions) ? j.actions : []) {
      l.actions.push({
        seq: num(a?.s),
        tool: typeof a?.tool === "string" ? a.tool : "tool",
        kind: (typeof a?.k === "string" ? a.k : "other") as ActionKind,
        input: typeof a?.in === "string" ? a.in : "",
        outcome: typeof a?.o === "string" ? a.o : "ok",
        ...(typeof a?.note === "string" ? { note: a.note } : {}),
      });
    }
    if (j.files !== null && typeof j.files === "object") {
      for (const [path, ops] of Object.entries(j.files)) {
        l.files.set(path, new Set(Array.isArray(ops) ? ops.map(String) : []));
      }
    }
    for (const e of Array.isArray(j.errors) ? j.errors : []) {
      l.errors.push({
        actionSeq: num(e?.s),
        tool: typeof e?.tool === "string" ? e.tool : "tool",
        input: typeof e?.in === "string" ? e.in : "",
        error: typeof e?.e === "string" ? e.e : "",
        ...(typeof e?.fix === "string" ? { fix: e.fix } : {}),
      });
    }
    if (j.collapsed !== null && typeof j.collapsed === "object") {
      for (const [tool, count] of Object.entries(j.collapsed)) {
        l.collapsed.set(tool, num(count));
      }
    }
    if (Array.isArray(j.focus)) l.focus.push(...j.focus.map(String));
    return l;
  }

  /** The ledger carried on a persisted state, or null when never ledgered. */
  static of(compaction: CompactionStateJson | null): CompactionLedger | null {
    if (compaction === null || compaction.ledger === null || compaction.ledger === undefined) {
      return null;
    }
    try {
      return CompactionLedger.fromJson(compaction.ledger);
    } catch {
      return null;
    }
  }
}

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function errorLine(detail: string): string {
  const lines = detail
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  if (lines.length === 0) return "(failed)";
  const hit = lines.find((l) => ERROR_LINE.test(l)) ?? lines[lines.length - 1]!;
  return clip(hit, 240);
}

function displayInput(
  tool: string,
  args: Record<string, unknown>,
  m: AgentMessage,
): string {
  void tool;
  const entries = Object.entries(args);
  if (entries.length > 0) {
    const parts: string[] = [];
    for (const [k, v] of entries) {
      const value = Array.isArray(v) ? v.join(" | ") : v;
      parts.push(
        entries.length === 1 && (k === "command" || k === "path")
          ? `${String(value)}`
          : `${k}=${String(value)}`,
      );
    }
    return clip(parts.join(" · "), 400);
  }
  // Legacy card without recorded input: the diff header or the content.
  return clip(diffPath(m.content) ?? m.content.trim(), 400);
}

/**
 * Build the ledger for a compaction: the previous ledger is carried forward
 * and only [folded] is absorbed; a session without a ledger (never compacted,
 * or compacted by the old LLM-only path) absorbs its whole retained prefix.
 */
export function buildLedger(
  prev: CompactionLedger | null,
  folded: readonly AgentMessage[],
): CompactionLedger {
  const ledger = prev ?? new CompactionLedger();
  ledger.absorb(folded);
  return ledger;
}
