// Task 19 — lossless compaction. Ported from lib/core/compaction/*.dart and
// test/lossless_compaction_test.dart (the behavioral contract), adapted to the
// cloud AgentMessage seam:
//   * Dart's one-row tool card (toolName/toolInput/toolDetail/toolState) is
//     the cloud pair {role:"assistant", toolCalls:[…]} + {role:"tool", …}.
//     A tool row's name/args are resolved from the issuing call.
//   * Dart's MsgKind.compact visible row does not exist in the cloud request
//     array; the checkpoint is replayed as a SYSTEM row (plan pin) and the
//     user-visible analog is the compaction_completed event.
//   * Dart's session.compactedAtCount is the fold boundary INDEX; the cloud
//     plan's CompactionStateJson.compactedAtCount is a compaction COUNT.

import { describe, expect, it } from "vitest";
import type { EventSink, SandboxPort } from "../ports.js";
import { createMemoryStateStore } from "../ports.js";
import type { AgentMessage, ToolCall } from "../types.js";
import {
  COMPACTION,
  checkpointBudgetTokens,
  compactionThresholdTokens,
  estimateMessageTokens,
  snapCutoff,
  splitsToolRun,
} from "./policy.js";
import {
  CompactionLedger,
  shellFileOps,
  toolInputRecord,
} from "./ledger.js";
import {
  COMPACTED_SUMMARY_TAGS,
  compactedSystemBlock,
  digest,
  renderCheckpoint,
  renderCheckpointDetailed,
  summarizerSystemPrompt,
  summarizerUserPrompt,
} from "./checkpoint.js";
import { applyCheckpoint, createCompactor, foldBoundaryFor, isCheckpointRow, type CompactionSummarizeInput } from "./compactor.js";

// ── fixtures ────────────────────────────────────────────────────────────────

let callSeq = 0;
const call = (name: string, args: Record<string, unknown>): ToolCall => ({
  id: `call_${++callSeq}`,
  name,
  args,
});

function toolPair(
  name: string,
  args: Record<string, unknown>,
  content: string,
): AgentMessage[] {
  const c = call(name, args);
  return [
    { role: "assistant", content: "", toolCalls: [c] },
    { role: "tool", toolCallId: c.id, content },
  ];
}

const GOAL =
  "Build a CSV export feature for the invoices module in lib/invoices/.";

const CONSTRAINTS: Record<number, string> = {
  3: "Constraint: never use the http package; use dio instead.",
  10: "Always write tests under test/invoices/ and run them after edits.",
  25: "Actually, the delimiter must be a semicolon, not a comma.",
  120: "Prefer snake_case for every new file name.",
};

const PASTED_CONSTRAINT =
  "Do not modify lib/legacy/billing.dart under any circumstances.";

/** One synthetic turn, mirroring the Dart lossless fixture. */
function addTurn(msgs: AgentMessage[], i: number): void {
  let user: string;
  if (i === 0) user = GOAL;
  else if (CONSTRAINTS[i] !== undefined) user = CONSTRAINTS[i]!;
  else if (i === 60) {
    user =
      "Here is the failing log, please look.\n```\n" +
      "ERROR row parse failed at column 7\n".repeat(60) +
      "```\nThe parser chokes on quoted fields. " +
      PASTED_CONSTRAINT +
      " Thanks for checking this carefully, it matters for the release.";
  } else user = `Step ${i}: continue with the next part of the export.`;

  const userRow: AgentMessage = { role: "user", content: user };
  if (i === 5) {
    // The cloud AgentMessage has no attachment channel; compaction reads the
    // additive `attachments` annotation when the engine supplies one (Dart's
    // Message.attachments). See the report: T16 wiring should populate it.
    (userRow as AgentMessage & { attachments?: string[] }).attachments = [
      "spec.pdf (/ws/uploads/spec.pdf)",
    ];
  }
  msgs.push(userRow);

  const path = `lib/invoices/csv_part_${i}.dart`;
  msgs.push(
    ...toolPair(
      "fs_edit",
      {
        command: i % 2 === 0 ? "create" : "str_replace",
        path,
        new_str: "x".repeat(300),
      },
      `created ${path}`,
    ),
  );

  const failing = i === 30;
  msgs.push(
    ...toolPair(
      "run_shell",
      { command: `npx vitest run test/invoices/csv_${i}_test.ts` },
      failing
        ? 'Error: Expected ";" but found ","\n(exit code 1)'
        : `${"ok test passed\n".repeat(20)}(exit code 0)`,
    ),
  );

  if (i % 40 === 7) {
    msgs.push(
      ...toolPair(
        "run_shell",
        { command: `rm -f lib/tmp/scratch_${i}.dart` },
        "(exit code 0)",
      ),
    );
  }

  if (i === 50) {
    msgs.push(
      ...toolPair(
        "dispatch_agent",
        { prompt: "audit the CSV escaping rules" },
        "Subagent report: RFC 4180 quoting required",
      ),
    );
  }

  msgs.push({
    role: "assistant",
    content: `Done step ${i}. ${"detail ".repeat(30)}`,
  });
}

function session(turns: number): AgentMessage[] {
  const msgs: AgentMessage[] = [];
  for (let i = 0; i < turns; i += 1) addTurn(msgs, i);
  return msgs;
}

const TODOS = [
  { content: "Write the CSV encoder", status: "completed" as const },
  { content: "Handle quoted fields", status: "in_progress" as const },
  { content: "Wire the export button", status: "pending" as const },
];

function fakeSandbox(): { sandbox: SandboxPort; writes: Array<{ path: string; content: string }> } {
  const writes: Array<{ path: string; content: string }> = [];
  const nope = async (): Promise<never> => {
    throw new Error("not used by the compactor");
  };
  const sandbox: SandboxPort = {
    exec: nope,
    killCall: nope,
    readFile: nope,
    async writeFile(_userId: string, path: string, content: string) {
      writes.push({ path, content });
    },
    exists: nope,
    listDir: nope,
    jobStart: nope,
    jobOutput: nope,
    jobList: nope,
    jobKill: nope,
  };
  return { sandbox, writes };
}

function recordingSink(): {
  sink: EventSink;
  events: Array<{ type: string; payload: Record<string, unknown> }>;
} {
  const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
  return {
    sink: {
      async emit(type, payload) {
        events.push({ type, payload });
      },
    },
    events,
  };
}

function setup(o?: {
  summarize?: (i: CompactionSummarizeInput) => Promise<string | null>;
  windowTokens?: number;
}) {
  const state = createMemoryStateStore();
  const { sandbox, writes } = fakeSandbox();
  const { sink, events } = recordingSink();
  const summarizeCalls: CompactionSummarizeInput[] = [];
  const summarize =
    o?.summarize ??
    (async () =>
      "## Decisions\n- dio over http (user constraint)\n## Next Steps\n- finish quoted-field handling");
  const compactor = createCompactor({
    state,
    sandbox,
    sink,
    summarize: async (i) => {
      if (o?.summarize === undefined) summarizeCalls.push(i);
      return summarize(i);
    },
    userId: "u1",
    workspaceRelDir: "",
    workingFolder: "/ws",
    runId: "run1",
  });
  return { state, sandbox, writes, sink, events, summarizeCalls, compactor };
}

async function patchState(
  state: ReturnType<typeof createMemoryStateStore>,
  sessionId: string,
  todos = TODOS,
) {
  await state.patch(sessionId, {
    todos: [...todos],
    goal: { objective: "Ship the CSV export", notes: "" },
    planMode: false,
  });
}

// ── policy ─────────────────────────────────────────────────────────────────

describe("compaction policy", () => {
  it("pins the Dart constants and the token heuristics", () => {
    expect(COMPACTION).toEqual({
      thresholdRatio: 0.8,
      retainRatio: 0.16,
      absoluteThresholdTokens: 100_000,
      manualRetainMessages: 24,
      manualRetainTokens: 8_000,
      oversizedToolResultChars: 12_000,
    });
    expect(estimateMessageTokens("")).toBe(4);
    expect(estimateMessageTokens("a".repeat(400))).toBe(104);
    // Dart: (window * 0.12).round().clamp(2500, 24000)
    expect(checkpointBudgetTokens(16_000)).toBe(2500);
    expect(checkpointBudgetTokens(100_000)).toBe(12_000);
    expect(checkpointBudgetTokens(1_000_000)).toBe(24_000);
    // Plan pins Math.round(window*0.8); Dart floors it (map §1.2) — the brief
    // is binding. 100_000 caps every large window.
    expect(compactionThresholdTokens(32_000)).toBe(25_600);
    expect(compactionThresholdTokens(1_000_000)).toBe(100_000);
  });

  it("snapCutoff never lands on a tool row (Dart pure-unit parity)", () => {
    const msgs: AgentMessage[] = [
      { role: "user", content: "u0" },
      { role: "tool", toolCallId: "t1", content: "r1" },
      { role: "tool", toolCallId: "t2", content: "r2" },
      { role: "assistant", content: "a" },
      { role: "user", content: "u1" },
      { role: "tool", toolCallId: "t3", content: "r3" },
      { role: "tool", toolCallId: "t4", content: "r4" },
      { role: "assistant", content: "b" },
    ];
    for (let c = 1; c < msgs.length; c += 1) {
      const snapped = snapCutoff(msgs, 0, c);
      expect(splitsToolRun(msgs, snapped)).toBe(false);
      expect(msgs[snapped]?.role).not.toBe("tool");
    }
    // Prefers the user-turn start that keeps at least half the intended fold.
    expect(snapCutoff(msgs, 0, 5)).toBe(4);
    // No safe cut anywhere -> fold nothing (the final Dart branch).
    const allTools: AgentMessage[] = [
      { role: "tool", toolCallId: "a", content: "ra" },
      { role: "tool", toolCallId: "b", content: "rb" },
      { role: "tool", toolCallId: "c", content: "rc" },
    ];
    expect(snapCutoff(allTools, 0, 1)).toBe(0);
  });

  it("splitsToolRun detects a tail starting on a tool row", () => {
    const msgs: AgentMessage[] = [
      { role: "user", content: "u" },
      { role: "tool", toolCallId: "t", content: "r" },
      { role: "user", content: "u2" },
    ];
    expect(splitsToolRun(msgs, 1)).toBe(true);
    expect(splitsToolRun(msgs, 2)).toBe(false);
    expect(splitsToolRun(msgs, msgs.length)).toBe(false);
  });
});

// ── ledger ─────────────────────────────────────────────────────────────────

describe("compaction ledger", () => {
  it("round-trips the Dart wire shape and parses shell file ops", () => {
    const l = new CompactionLedger();
    l.absorb([
      { role: "user", content: "goal here" },
      ...toolPair(
        "run_shell",
        { command: "mv a.txt b.txt && rm -rf build/ && echo hi > out.log" },
        "(exit code 0)",
      ),
      ...toolPair(
        "mcp__github__create_issue",
        { repo: "o/r" },
        "created issue #42",
      ),
    ]);
    const json = l.toJson();
    // Exact Dart wire keys.
    expect(json.users[0]).toEqual({ s: 1, t: "goal here" });
    expect(json.actions[0]).toMatchObject({
      tool: "run_shell",
      k: "shell",
      o: "exit 0",
    });
    const r = CompactionLedger.fromJson(json);
    expect(r.goal).toBe("goal here");
    expect(r.files.get("a.txt")).toEqual(new Set(["deleted"]));
    expect(r.files.get("b.txt")).toEqual(new Set(["created"]));
    expect(r.files.get("build/")).toEqual(new Set(["deleted"]));
    expect(r.files.get("out.log")).toEqual(new Set(["edited"]));
    expect(r.actions.at(-1)?.kind).toBe("mcp");
    expect(r.actions.at(-1)?.note).toBe("created issue #42");
    expect(r.toJson()).toEqual(json);
  });

  it("round-trips the attachment wire key `a`", () => {
    const row = {
      role: "user",
      content: "see the spec",
      attachments: ["spec.pdf (/ws/uploads/spec.pdf)"],
    } as AgentMessage;
    const l = new CompactionLedger();
    l.absorb([row]);
    const json = l.toJson();
    expect(json.users[0]).toEqual({
      s: 1,
      t: "see the spec",
      a: ["spec.pdf (/ws/uploads/spec.pdf)"],
    });
    expect(CompactionLedger.fromJson(json).userMessages[0]!.attachments).toEqual([
      "spec.pdf (/ws/uploads/spec.pdf)",
    ]);
  });

  it("stores user rows verbatim and clips oversized pastes with the exact marker", () => {
    const big = "x".repeat(20_000);
    const l = new CompactionLedger();
    l.absorb([{ role: "user", content: big }]);
    const u = l.userMessages[0]!;
    expect(u.fullLength).toBe(20_000);
    expect(u.text.length).toBeLessThan(20_000);
    expect(u.text).toContain("more chars of pasted content omitted here");
    expect(u.text).toContain("full original is user message #1 in the visible transcript");
    // The `n` key is emitted only when the text was clipped.
    expect(l.toJson().users[0]).toMatchObject({ s: 1, n: 20_000 });
  });

  it("closes an open error when the same tool later succeeds", () => {
    const l = new CompactionLedger();
    l.absorb([
      ...toolPair("run_shell", { command: "npx vitest run" }, 'Error: bad\n(exit code 1)'),
      ...toolPair("run_shell", { command: "npx vitest run" }, "ok\n(exit code 0)"),
    ]);
    expect(l.errors).toHaveLength(1);
    expect(l.errors[0]!.fix).toContain("→ exit 0");
    expect(l.actions[0]!.outcome).toBe("exit 1");
    expect(l.actions[1]!.outcome).toBe("exit 0");
  });

  it("shellFileOps mirrors the Dart parser", () => {
    expect(shellFileOps("mv a.txt b.txt && rm -rf build/ && echo hi > out.log")).toEqual([
      ["a.txt", "deleted"],
      ["b.txt", "created"],
      ["build/", "deleted"],
      ["out.log", "edited"],
    ]);
    expect(shellFileOps("cp src.ts dist.ts")).toEqual([["dist.ts", "created"]]);
    expect(shellFileOps("mkdir -p a/b")).toEqual([["a/b", "created"]]);
  });

  it("toolInputRecord stores sizes, never file bodies", () => {
    const rec = toolInputRecord("file_write", {
      path: "a.dart",
      content: "SECRET BODY".repeat(100),
    });
    expect(rec).toContain("a.dart");
    expect(rec).toContain("content_chars");
    expect(rec).not.toContain("SECRET BODY");
  });
});

// ── checkpoint ─────────────────────────────────────────────────────────────

describe("checkpoint render", () => {
  it("renders the structured template in order", async () => {
    const l = new CompactionLedger();
    l.absorb(session(30).slice(0, 100));
    l.compactions = 1;
    l.foldedMessages = 100;
    const text = renderCheckpoint(l, "## Decisions\n- d", {
      todos: TODOS,
      goal: { objective: "Ship the CSV export", notes: "" },
      planMode: false,
      workingFolder: "/ws",
      retainedMessages: 20,
    });
    let at = -1;
    for (const h of [
      "## Goal",
      "## User instructions & constraints",
      "## Facts & data the user provided",
      "## Files & artifacts",
      "## Actions taken",
      "## Decisions",
      "## Errors & fixes",
      "## Current state / todos",
      "## Next steps",
    ]) {
      const i = text.indexOf(h);
      expect(i, `${h} in order`).toBeGreaterThan(at);
      at = i;
    }
    expect(text).toContain("run_shell: npx vitest run test/invoices/csv_");
    expect(text).toContain("exit 0");
    expect(text).toContain("[~] Handle quoted fields");
    expect(text).toContain("[ ] Wire the export button");
  });

  it("is deterministic byte-for-byte for identical inputs", () => {
    const l = new CompactionLedger();
    l.absorb(session(30).slice(0, 100));
    l.compactions = 1;
    const state = {
      todos: TODOS,
      goal: { objective: "Ship the CSV export", notes: "" },
      planMode: true,
      workingFolder: "/ws",
      retainedMessages: 12,
    };
    expect(renderCheckpoint(l, "## Decisions\n- d", state)).toBe(
      renderCheckpoint(l, "## Decisions\n- d", state),
    );
  });

  it("digest keeps directive sentences verbatim", () => {
    const long =
      "Intro sentence about the project. " +
      "Filler words here. ".repeat(30) +
      "You must never call the payments API from tests. " +
      "See docs/payments/README.md for details.";
    const d = digest(long);
    expect(d).toContain("Intro sentence about the project.");
    expect(d).toContain("You must never call the payments API from tests.");
    expect(d).toContain("docs/payments/README.md");
    expect(d.length).toBeLessThan(long.length);
  });

  it("preservedLine reports the deterministic counts and the missing narrative", () => {
    const l = new CompactionLedger();
    l.absorb([{ role: "user", content: "a" }, { role: "user", content: "b" }]);
    const ck = renderCheckpointDetailed(l, null, {
      todos: [],
      goal: null,
      planMode: false,
      workingFolder: null,
      retainedMessages: 0,
    }, { narrativeAvailable: false });
    expect(ck.preservedLine).toContain("kept 2 user messages");
    expect(ck.preservedLine).toContain("no model summary");
    expect(ck.text).toContain("model summary unavailable");
  });

  it("uses the full Dart replay preamble and summary tags", () => {
    const block = compactedSystemBlock("CHECKPOINT");
    expect(block).toContain(COMPACTED_SUMMARY_TAGS.open);
    expect(block).toContain(COMPACTED_SUMMARY_TAGS.close);
    expect(block).toContain(
      "This is an automatically generated checkpoint condensing an earlier span of the conversation to free up context.",
    );
    expect(block).toContain("without acknowledging this checkpoint.");
    expect(block).toContain("<compacted-summary>\nCHECKPOINT\n</compacted-summary>");
  });

  it("summarizer prompts carry the focus and the prior narrative", () => {
    const l = new CompactionLedger();
    l.goal = "g";
    l.files.set("a.ts", new Set(["created"]));
    const p = summarizerUserPrompt({
      replay: "User: hi",
      priorNarrative: "## Decisions\n- old",
      ledger: l,
      focus: "semicolon",
    });
    expect(p).toContain("FOCUS (from the user): semicolon");
    expect(p).toContain("PRIOR NARRATIVE (merge into it):");
    expect(p).toContain("Original goal: g");
    expect(p).toContain("Files touched: a.ts");
    expect(p).toContain("Conversation span to condense:");
    expect(summarizerSystemPrompt()).toContain("## Decisions");
    expect(summarizerSystemPrompt({ strict: true })).toContain("STRICTNESS:");
  });
});

// ── compactor ──────────────────────────────────────────────────────────────

describe("compactor", () => {
  it("leaves a below-threshold history untouched (no model call, no state write)", async () => {
    const { state, summarizeCalls, compactor } = setup();
    await patchState(state, "s1");
    const msgs: AgentMessage[] = [
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello" },
    ];
    const r = await compactor.maybeCompact({ sessionId: "s1", messages: msgs, windowTokens: 32_000 });
    expect(r.compacted).toBe(false);
    expect(r.messages).toBe(msgs);
    expect(summarizeCalls).toHaveLength(0);
    expect((await state.get("s1")).compaction).toBeNull();
  });

  it("folds above the threshold, keeps a user-row tail, and emits the event", async () => {
    const { state, events, summarizeCalls, compactor } = setup();
    await patchState(state, "s2");
    const msgs = session(200);
    const r = await compactor.maybeCompact({ sessionId: "s2", messages: msgs, windowTokens: 32_000 });

    expect(r.compacted).toBe(true);
    expect(summarizeCalls).toHaveLength(1);
    expect(r.messages[0]!.role).toBe("system");
    expect(r.messages[0]!.content).toContain("<compacted-summary>");
    const tail = r.messages.slice(1);
    expect(tail[0]!.role).toBe("user");
    expect(tail.length).toBeLessThan(msgs.length);
    // The retained tail is byte-identical and reference-identical.
    expect(msgs.slice(msgs.length - tail.length)).toEqual(tail);
    for (let i = 0; i < tail.length; i += 1) {
      expect(tail[i]).toBe(msgs[msgs.length - tail.length + i]);
    }
    // Never an ORPHANED tool row in the rebuilt request: every tool result
    // still has its issuing assistant toolCalls row in the same request.
    const callIds = new Set<string>();
    for (const m of r.messages) {
      if (m.role === "assistant" && m.toolCalls !== undefined) {
        for (const c of m.toolCalls) callIds.add(c.id);
      }
    }
    for (const m of r.messages.filter((x) => x.role === "tool")) {
      expect(m.toolCallId !== undefined && callIds.has(m.toolCallId)).toBe(true);
    }

    const compaction = (await state.get("s2")).compaction!;
    expect(compaction.summary).toContain("# Session checkpoint");
    expect(compaction.compactedAtCount).toBe(1);
    const event = events.find((e) => e.type === "compaction_completed")!;
    expect(event.payload).toMatchObject({
      runId: "run1",
      retained: tail.length,
      narrative: true,
    });
    expect(event.payload.folded).toBe(msgs.length - tail.length);
  });

  it("replays each tool output exactly once in the summarizer prompt (review I1)", async () => {
    const { state, summarizeCalls, compactor } = setup();
    await patchState(state, "s2b");
    const marker = "UNIQUE-TOOL-OUTPUT-MARKER";
    const msgs: AgentMessage[] = [
      { role: "user", content: "goal" },
      ...toolPair("run_shell", { command: "cat big.log" }, `${marker}\n${"x".repeat(7_990)}`),
    ];
    for (let i = 0; i < 20; i += 1) {
      msgs.push({ role: i % 2 === 0 ? "user" : "assistant", content: "y".repeat(100) });
    }
    const r = await compactor.maybeCompact({ sessionId: "s2b", messages: msgs, windowTokens: 2_000 });
    expect(r.compacted).toBe(true);
    const prompt = summarizeCalls[0]!.userPrompt;
    // The tool result is the `[tool output]` line ONLY; the assistant marker
    // line must not repeat it (Dart's tool-card content is empty/short).
    expect(prompt.split(marker)).toHaveLength(2);
    expect(prompt).toContain("Assistant: [tool run_shell]");
    expect(prompt).toContain("  [tool output] ");
  });

  it("serializes concurrent compactions per session (review I2)", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let started!: () => void;
    const summarizeStarted = new Promise<void>((resolve) => {
      started = resolve;
    });
    const { state, compactor } = setup({
      summarize: async () => {
        started();
        await gate;
        return "## Decisions\n- d";
      },
    });
    await patchState(state, "s2c");
    const msgs = session(200);

    // First compaction holds the session lock across the model call.
    const first = compactor.maybeCompact({
      sessionId: "s2c",
      messages: msgs,
      windowTokens: 32_000,
    });
    await summarizeStarted;
    // A second AUTO compaction no-ops; the MANUAL path reports Dart's busy
    // string instead of a second fold from the same base.
    const second = await compactor.maybeCompact({
      sessionId: "s2c",
      messages: msgs,
      windowTokens: 32_000,
    });
    const busy = await compactor.compactNow({
      sessionId: "s2c",
      messages: msgs,
      windowTokens: 32_000,
    });
    release();
    const r1 = await first;

    expect(r1.compacted).toBe(true);
    expect(second.compacted).toBe(false);
    expect(busy.compacted).toBe(false);
    expect(busy.status).toBe("Compaction is already running in this chat.");
    const compaction = (await state.get("s2c")).compaction!;
    // One absorption, one count increment — no lost ledger entry.
    expect(compaction.compactedAtCount).toBe(1);
    expect(CompactionLedger.fromJson(compaction.ledger).compactions).toBe(1);
  });

  it("replays the checkpoint as a system row with the full preamble", async () => {
    const { state, compactor } = setup();
    await patchState(state, "s3");
    const r = await compactor.maybeCompact({
      sessionId: "s3",
      messages: session(200),
      windowTokens: 32_000,
    });
    const block = r.messages[0]!.content;
    expect(block).toContain("<compacted-summary>");
    expect(block).toContain("</compacted-summary>");
    expect(block).toContain(
      "This is an automatically generated checkpoint condensing an earlier span of the conversation to free up context.",
    );
  });

  it("applyCheckpoint prepends the stable row and truncates at the fold boundary (review I3)", async () => {
    const { state, compactor } = setup();
    await patchState(state, "fb1");
    const msgs = session(200);
    const r = await compactor.maybeCompact({
      sessionId: "fb1",
      messages: msgs,
      windowTokens: 32_000,
    });
    expect(r.foldBoundary).toBe(1);
    const saved = (await state.get("fb1")).compaction!;

    // Idempotent on the in-memory array: the leading checkpoint row is
    // stripped and exactly one is re-prepended.
    const replay = applyCheckpoint(saved, r.messages);
    expect(isCheckpointRow(replay[0])).toBe(true);
    expect(replay.filter(isCheckpointRow)).toHaveLength(1);
    expect(replay.slice(1)).toEqual(r.messages.slice(1));

    // A full history rebuilt from durable rows uses the cumulative ledger's
    // `folded` count as the boundary (no checkpoint row present).
    const replayDb = applyCheckpoint(saved, msgs);
    expect(isCheckpointRow(replayDb[0])).toBe(true);
    expect(replayDb.slice(1)).toEqual(msgs.slice(msgs.length - (r.messages.length - 1)));

    // No compaction -> pass-through.
    expect(applyCheckpoint(null, msgs)).toEqual(msgs);
  });

  /** A durable history with stable ids, as the loop rebuilds it from rows. */
  function durableSession(count: number): AgentMessage[] {
    const out: AgentMessage[] = [];
    for (let i = 0; i < count; i += 1) {
      out.push({
        role: "user",
        content: `user message ${i} ${"x".repeat(80)}`,
        id: `durable-${i}-user`,
      });
      out.push({
        role: "assistant",
        content: `assistant reply ${i} ${"y".repeat(80)}`,
        id: `durable-${i}-assistant`,
      });
    }
    return out;
  }

  it("manual compactNow after a durable rebuild does not double-count (fix I-3: 8→16 probe)", async () => {
    const { state, compactor } = setup();
    await patchState(state, "fix-i3-manual");
    const first = await compactor.compactNow({
      sessionId: "fix-i3-manual",
      messages: durableSession(20),
      windowTokens: 128_000,
    });
    expect(first.compacted).toBe(true);
    const users1 = CompactionLedger.of((await state.get("fix-i3-manual")).compaction)!
      .userMessages.length;
    expect(users1).toBe(8);
    // The durable boundary is the last folded row's id, not the in-memory
    // (tool-row-inclusive) folded count.
    expect((await state.get("fix-i3-manual")).compaction!.cutoffMessageId).toBe(
      "durable-7-assistant",
    );

    // The /compact path rebuilds the SAME history from durable rows and
    // passes the mapped boundary.
    const rebuilt = durableSession(20);
    const second = await compactor.compactNow({
      sessionId: "fix-i3-manual",
      messages: rebuilt,
      windowTokens: 128_000,
      foldBoundary: foldBoundaryFor(
        (await state.get("fix-i3-manual")).compaction,
        rebuilt,
      ),
    });
    expect(second.compacted).toBe(false);
    const users2 = CompactionLedger.of((await state.get("fix-i3-manual")).compaction)!
      .userMessages.length;
    expect(users2).toBe(users1); // was 16 before the fix
  });

  it("next-run replay + auto compaction does not double-count (fix I-3: 17→34 probe)", async () => {
    const { state, compactor } = setup();
    await patchState(state, "fix-i3-replay");
    const first = await compactor.maybeCompact({
      sessionId: "fix-i3-replay",
      messages: durableSession(20),
      windowTokens: 1_000,
    });
    expect(first.compacted).toBe(true);
    const saved = (await state.get("fix-i3-replay")).compaction!;
    const users1 = CompactionLedger.of(saved)!.userMessages.length;
    expect(users1).toBeGreaterThan(0);

    // The loop's next run: rebuild from durable rows, map the boundary, replay
    // (checkpoint row + unfolded tail), then compact at a budget boundary with
    // the checkpoint row excluded.
    const dbHistory = durableSession(20);
    const boundary = foldBoundaryFor(saved, dbHistory);
    expect(boundary).toBeGreaterThan(0);
    const replay = applyCheckpoint(saved, dbHistory, boundary);
    expect(isCheckpointRow(replay[0])).toBe(true);
    expect(replay.length).toBe(1 + dbHistory.length - boundary);

    const second = await compactor.maybeCompact({
      sessionId: "fix-i3-replay",
      messages: replay,
      windowTokens: 1_000,
      foldBoundary: 1,
    });
    expect(second.compacted).toBe(false);
    const users2 = CompactionLedger.of((await state.get("fix-i3-replay")).compaction)!
      .userMessages.length;
    expect(users2).toBe(users1); // was 34 before the fix
  });

  it("absorbs only the span after an explicit fold boundary (no re-absorption)", async () => {
    const { state, compactor } = setup();
    await patchState(state, "fb2");
    const first = session(200);
    const r1 = await compactor.maybeCompact({
      sessionId: "fb2",
      messages: first,
      windowTokens: 32_000,
    });
    const ledger1 = CompactionLedger.of((await state.get("fb2")).compaction)!;
    expect(ledger1.foldedMessages).toBe(first.length - (r1.messages.length - 1));

    // Simulate a NEW run: history rebuilt from durable rows, boundary passed.
    const grown = [...first];
    for (let k = 200; k < 260; k += 1) addTurn(grown, k);
    const r2 = await compactor.maybeCompact({
      sessionId: "fb2",
      messages: grown,
      windowTokens: 32_000,
      foldBoundary: ledger1.foldedMessages,
    });
    expect(r2.compacted).toBe(true);
    const ledger2 = CompactionLedger.of((await state.get("fb2")).compaction)!;
    expect(ledger2.compactions).toBe(2);
    // Every user row appears exactly once, in order.
    expect(ledger2.userMessages.map((u) => u.seq)).toEqual(
      Array.from({ length: ledger2.userMessages.length }, (_, i) => i + 1),
    );
    const retained = r2.messages.length - 1;
    const totalUserRows = grown
      .slice(0, grown.length - retained)
      .filter((m) => m.role === "user").length;
    expect(ledger2.userMessages).toHaveLength(totalUserRows);
  });

  it("keeps every user instruction, path, todo and the last turns across three compactions", async () => {
    let round = 0;
    const { state, compactor } = setup({
      summarize: async () => {
        round += 1;
        return (
          "## Decisions\n- dio over http (user constraint)\n" +
          "## Next Steps\n- finish quoted-field handling (round " +
          round +
          ")"
        );
      },
    });
    await patchState(state, "s4");
    let msgs = session(200);
    const foldedUserCounts: number[] = [];
    let totalFolded = 0;
    const calls = 3;
    for (let n = 0; n < calls; n += 1) {
      const before = msgs.length;
      const r = await compactor.maybeCompact({ sessionId: "s4", messages: msgs, windowTokens: 16_000 });
      expect(r.compacted).toBe(true);
      const retained = r.messages.length - 1;
      // Rounds 2+ pass [checkpoint row, ...tail]; the row is not a real
      // message, so it must not count as folded (review Minor 3).
      const realInput = before - (n === 0 ? 0 : 1);
      const folded = realInput - retained;
      totalFolded += folded;
      const start = n === 0 ? 0 : 1;
      foldedUserCounts.push(
        msgs
          .slice(start, start + folded)
          .filter((m) => m.role === "user").length,
      );
      msgs = r.messages;
      if (n < calls - 1) {
        for (let k = 0; k < 60; k += 1) addTurn(msgs, 200 + n * 60 + k);
      }
    }

    const checkpoint = (await state.get("s4")).compaction!;
    const ledger = CompactionLedger.fromJson(checkpoint.ledger)!;
    expect(ledger.compactions).toBe(3);
    expect(ledger.foldedMessages).toBe(totalFolded);
    expect(ledger.goal).toBe(GOAL);
    const expectedUsers = foldedUserCounts.reduce((a, b) => a + b, 0);
    expect(ledger.userMessages).toHaveLength(expectedUsers);
    expect(ledger.userMessages.map((u) => u.seq)).toEqual(
      Array.from({ length: expectedUsers }, (_, i) => i + 1),
    );

    const text = checkpoint.summary!;
    expect(text).toContain("round 3");
    expect(text).toContain("dio over http");
    expect(text).toContain("fixed by");
    expect(text).toContain("deleted: lib/tmp/scratch_7.dart");
    expect(text).toContain("## User instructions");

    // Losslessness across the checkpoint: goal, every early constraint, the
    // buried paste constraint, every touched path, attachments, todos, the
    // subagent report and the failing error string.
    expect(text).toContain(GOAL);
    for (const c of Object.values(CONSTRAINTS)) expect(text).toContain(c);
    expect(text).toContain(PASTED_CONSTRAINT);
    expect(text).toContain("spec.pdf (/ws/uploads/spec.pdf)");
    expect(text).toContain("[~] Handle quoted fields");
    expect(text).toContain("[ ] Wire the export button");
    expect(text).toContain("Subagent report: RFC 4180 quoting required");
    expect(text).toContain('Expected ";" but found ","');
    expect(text).toContain("## Goal (original request, verbatim)");
    // The last turns replay verbatim after the checkpoint.
    expect(msgs.map((m) => m.content).join("\n")).toContain(
      "Step 319: continue with the next part",
    );
  });

  it("carries the previous narrative into a later checkpoint even when the model fails", async () => {
    const state = createMemoryStateStore();
    const { sandbox } = fakeSandbox();
    const { sink } = recordingSink();
    const good = createCompactor({
      state,
      sandbox,
      sink,
      summarize: async () =>
        "## Decisions\n- chose RFC 4180 quoting because of the subagent audit",
      userId: "u1",
      workspaceRelDir: "",
      workingFolder: "/ws",
    });
    await patchState(state, "s5");
    let msgs = session(60);
    const first = await good.maybeCompact({ sessionId: "s5", messages: msgs, windowTokens: 8_000 });
    expect(first.compacted).toBe(true);
    msgs = first.messages;

    // 40 more turns on the retained tail, then a summarizer that returns null.
    const tail = msgs.slice(1);
    for (let k = 60; k < 100; k += 1) addTurn(tail, k);
    msgs = [msgs[0]!, ...tail];
    const failing = createCompactor({
      state,
      sandbox,
      sink,
      summarize: async () => null,
      userId: "u1",
      workspaceRelDir: "",
      workingFolder: "/ws",
    });
    const r = await failing.maybeCompact({ sessionId: "s5", messages: msgs, windowTokens: 8_000 });
    expect(r.compacted).toBe(true);
    const checkpoint = (await state.get("s5")).compaction!;
    expect(checkpoint.summary).toContain("chose RFC 4180 quoting");
    expect(CompactionLedger.fromJson(checkpoint.ledger).compactions).toBe(2);
  });

  it("never blocks on a summarizer failure (null or throw)", async () => {
    for (const mode of ["null", "throw"] as const) {
      const { state, events, compactor } = setup({
        summarize: async () => {
          if (mode === "throw") throw new Error("provider down");
          return null;
        },
      });
      const sessionId = `s6-${mode}`;
      await patchState(state, sessionId);
      const r = await compactor.maybeCompact({
        sessionId,
        messages: session(60),
        windowTokens: 8_000,
      });
      expect(r.compacted).toBe(true);
      const compaction = (await state.get(sessionId)).compaction!;
      expect(compaction.summary).toContain("model summary unavailable");
      const event = events.find((e) => e.type === "compaction_completed")!;
      expect(event.payload.narrative).toBe(false);
    }
  });

  it("retries a non-shrinking summary once with the strict prompt", async () => {
    const seen: Array<boolean | undefined> = [];
    const { state, compactor } = setup({
      summarize: async (i) => {
        seen.push(i.strict);
        // Deliberately longer than the folded span on attempt 1.
        return i.strict ? "## Decisions\n- short" : "x".repeat(10_000_000);
      },
    });
    await patchState(state, "s7");
    await compactor.maybeCompact({ sessionId: "s7", messages: session(60), windowTokens: 8_000 });
    expect(seen).toEqual([false, true]);
    expect((await state.get("s7")).compaction!.summary).toContain("short");
  });

  it("adopts a legacy LLM-only summary: re-absorbs the prefix and keeps the old narrative", async () => {
    const { state, compactor } = setup({ summarize: async () => null });
    await patchState(state, "s8");
    await state.patch("s8", {
      compaction: {
        ledger: null,
        summary: "## Primary Request and Intent\n- legacy narrative",
        cutoffMessageId: null,
        compactedAtCount: 40,
      },
    });
    const r = await compactor.maybeCompact({
      sessionId: "s8",
      messages: session(80),
      windowTokens: 8_000,
    });
    expect(r.compacted).toBe(true);
    const text = (await state.get("s8")).compaction!.summary!;
    expect(text).toContain(GOAL);
    expect(text).toContain(CONSTRAINTS[3]!);
    expect(text).toContain("legacy narrative");
  });

  it("persists a ledger that reads back identically (state round-trip pin)", async () => {
    const { state, compactor } = setup();
    await patchState(state, "s9");
    await compactor.maybeCompact({ sessionId: "s9", messages: session(200), windowTokens: 32_000 });
    const saved = (await state.get("s9")).compaction!;
    const readBack = CompactionLedger.of(saved)!;
    expect(readBack.toJson()).toEqual(saved.ledger);
    expect(saved.cutoffMessageId).toBeNull(); // AgentMessage carries no ids
  });
});

// ── pruning ────────────────────────────────────────────────────────────────

describe("oversized tool-result pruning", () => {
  const bigRow = (chars: number, tool = "run_shell"): AgentMessage[] => {
    const c = call(tool, { command: "cat huge.log" });
    return [
      { role: "user", content: "hi" },
      { role: "assistant", content: "", toolCalls: [c] },
      { role: "tool", toolCallId: c.id, content: "z".repeat(chars) },
      { role: "assistant", content: "done" },
    ];
  };

  it("spills a 30k tool row and makes ZERO summarizer calls when pressure is relieved", async () => {
    const { state, writes, summarizeCalls, compactor } = setup();
    await patchState(state, "p1");
    const msgs = bigRow(30_000);
    const r = await compactor.maybeCompact({ sessionId: "p1", messages: msgs, windowTokens: 8_000 });
    expect(r.compacted).toBe(false);
    expect(summarizeCalls).toHaveLength(0);
    expect(writes).toHaveLength(1);
    expect(writes[0]!.content).toBe("z".repeat(30_000));
    expect(r.messages[2]!.content).toContain(".spill/");
    expect(r.messages[2]!.content).toContain("characters omitted");
    expect(r.messages[2]!.content.length).toBeLessThan(20_000);
    // The original array is untouched (purity).
    expect(msgs[2]!.content).toHaveLength(30_000);
    expect((await state.get("p1")).compaction).toBeNull();
  });

  it("prunes only at the pinned 12_000-char threshold", async () => {
    const { state, writes, compactor } = setup();
    await patchState(state, "p2");
    const under = bigRow(11_999);
    const r1 = await compactor.pruneOversizedToolResults({
      sessionId: "p2",
      messages: under,
      thresholdTokens: 1,
    });
    expect(r1.pruned).toBe(0);
    expect(writes).toHaveLength(0);

    const at = bigRow(12_000);
    const r2 = await compactor.pruneOversizedToolResults({
      sessionId: "p2",
      messages: at,
      thresholdTokens: 1,
    });
    expect(r2.pruned).toBe(1);
    expect(writes).toHaveLength(1);
  });

  it("prunes a P2-adapter-sized row — the reachable class in the real flow (review I4)", async () => {
    // T9's finish() already spills P3 sandbox/git rows at 6k and fetch_url at
    // 8k, so those never reach the 12k trigger. P2-adapter rows (adapted
    // through agentToolAdapter) and MCP/subagent rows do not pass through
    // finish(), so a 15k P2 row is the class the pruner actually sees.
    const { state, writes, summarizeCalls, compactor } = setup();
    await patchState(state, "p4");
    const msgs = bigRow(15_000, "read_file");
    const r = await compactor.maybeCompact({
      sessionId: "p4",
      messages: msgs,
      windowTokens: 4_000,
    });
    expect(r.compacted).toBe(false);
    expect(summarizeCalls).toHaveLength(0);
    expect(writes).toHaveLength(1);
    expect(writes[0]!.content).toBe("z".repeat(15_000));
    expect(r.messages[2]!.content).toContain(".spill/");
  });

  it("does not prune below the pressure threshold", async () => {
    const { compactor, writes } = setup();
    const r = await compactor.pruneOversizedToolResults({
      sessionId: "p3",
      messages: bigRow(20_000),
      thresholdTokens: 1_000_000,
    });
    expect(r.pruned).toBe(0);
    expect(writes).toHaveLength(0);
  });
});

// ── manual /compact ────────────────────────────────────────────────────────

describe("manual compact", () => {
  it("uses the 24-message retention bound", async () => {
    const { state, compactor } = setup();
    await patchState(state, "m1");
    // Small contents: the message bound (24), not the 8000-token bound, wins.
    const msgs: AgentMessage[] = [];
    for (let i = 0; i < 50; i += 1) {
      msgs.push({ role: "user", content: `u${i}` });
      msgs.push({ role: "assistant", content: `a${i}` });
      msgs.push({ role: "user", content: `u${i}b` });
      msgs.push({ role: "assistant", content: `a${i}b` });
    }
    const r = await compactor.compactNow({ sessionId: "m1", messages: msgs, windowTokens: 32_000 });
    expect(r.compacted).toBe(true);
    expect(r.status).toContain("Session compacted");
    const retained = r.messages.length - 1;
    expect(retained).toBe(24);
    expect(r.messages[1]!.role).toBe("user");
  });

  it("uses the 8_000-token retention bound when it wins first", async () => {
    const { state, compactor } = setup();
    await patchState(state, "m1b");
    // ~1,004 tokens per row: the token bound (8,000) fires at 8 retained
    // rows, well before the 24-message bound.
    const msgs: AgentMessage[] = [];
    for (let i = 0; i < 40; i += 1) {
      msgs.push({
        role: i % 2 === 0 ? "user" : "assistant",
        content: "w".repeat(4_000),
      });
    }
    const r = await compactor.compactNow({
      sessionId: "m1b",
      messages: msgs,
      windowTokens: 32_000,
    });
    expect(r.compacted).toBe(true);
    expect(r.messages.length - 1).toBe(8);
  });

  it("reports 'already fully compacted' when only the checkpoint row is left", async () => {
    const { state, compactor } = setup();
    await patchState(state, "m1c");
    await state.patch("m1c", {
      compaction: {
        ledger: null,
        summary: "# Session checkpoint",
        cutoffMessageId: null,
        compactedAtCount: 1,
      },
    });
    const r = await compactor.compactNow({
      sessionId: "m1c",
      messages: [{ role: "system", content: compactedSystemBlock("# Session checkpoint") }],
      windowTokens: 32_000,
    });
    expect(r.compacted).toBe(false);
    expect(r.status).toContain("already fully compacted");
  });

  it("reports honestly when nothing is foldable", async () => {
    const { state, compactor } = setup();
    await patchState(state, "m2");
    const r = await compactor.compactNow({
      sessionId: "m2",
      messages: [
        { role: "user", content: "hi" },
        { role: "assistant", content: "hello" },
      ],
      windowTokens: 32_000,
    });
    expect(r.compacted).toBe(false);
    expect(r.status).toContain("Nothing to compact yet");
    expect(r.status).toContain("need ≥4 foldable");
  });

  it("threads /compact <focus> into the prompt and the checkpoint", async () => {
    const { state, summarizeCalls, compactor } = setup();
    await patchState(state, "m3");
    const r = await compactor.compactNow({
      sessionId: "m3",
      messages: session(40),
      windowTokens: 16_000,
      focus: "focus on the semicolon delimiter bug",
    });
    expect(r.compacted).toBe(true);
    expect(summarizeCalls.at(-1)?.focus).toBe("focus on the semicolon delimiter bug");
    const text = (await state.get("m3")).compaction!.summary!;
    expect(text).toContain("## Compaction focus");
    expect(text).toContain("focus on the semicolon delimiter bug");
  });
});
