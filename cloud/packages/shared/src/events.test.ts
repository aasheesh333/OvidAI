import { describe, expect, it } from "vitest";
import { sessionEvent, sessionEventSchema } from "./events.js";
import type { SessionEvent, SessionEventType } from "./events.js";

const valid: SessionEvent = {
  sessionId: "01990b7a-2f6c-7d1e-8a3b-4c5d6e7f8090",
  seq: "1760529600000-0",
  type: "message_delta",
  payload: { text: "hello" },
  ts: "2026-10-15T12:00:00.000Z",
};

// The single authoritative list (Task 3 additions at the end, same order as
// the union and the zod enum in events.ts). `satisfies` makes the compiler
// reject a list member missing from the SessionEventType union; the
// ExhaustiveAssignment below makes it reject a union member missing here.
const allEventTypes = [
  "run_started",
  "message_delta",
  "message_completed",
  "run_started_retry",
  "run_failed",
  "run_completed",
  "system_note",
  // Ruling R5 (P3 Task 12): tool_started/tool_completed were landed by P2's
  // own Task 12 — DETECT AND SKIP, never re-append. The two assertions in
  // the "P3 additions" describe block pin them exactly-once.
  "tool_started",
  "tool_completed",
  // Task 3 additions (workspace/artifact protocol).
  "artifact_created",
  "workspace_hibernated",
  "workspace_hydrated",
  // P3 Task 12 additions (approvals + agent-core state events) — the
  // remaining nine members of P3-Q5, appended AFTER P2's tool_* pair.
  "approval_requested",
  "approval_resolved",
  "todo_updated",
  "goal_updated",
  "plan_mode_changed",
  "run_cancelled",
  "subagent_started",
  "subagent_completed",
  "compaction_completed",
] as const satisfies readonly SessionEventType[];

// Compile-time exhaustiveness: true is assignable only when every
// SessionEventType member appears in allEventTypes.
const exhaustive: SessionEventType extends (typeof allEventTypes)[number] ? true : never = true;
void exhaustive;

describe("sessionEvent", () => {
  it("round-trips a valid envelope", () => {
    expect(sessionEvent(valid)).toEqual(valid);
  });

  it("exposes the schema, which parses the same envelope", () => {
    expect(sessionEventSchema.parse(valid)).toEqual(valid);
  });

  it("rejects an unknown type", () => {
    expect(() => sessionEvent({ ...valid, type: "nope" })).toThrow();
  });

  it("rejects a missing seq", () => {
    const { seq: _seq, ...noSeq } = valid;
    expect(() => sessionEvent(noSeq)).toThrow();
  });

  it("rejects a non-object payload", () => {
    expect(() => sessionEvent({ ...valid, payload: "text" })).toThrow();
    expect(() => sessionEvent({ ...valid, payload: 42 })).toThrow();
    expect(() => sessionEvent({ ...valid, payload: null })).toThrow();
  });

  it("parses the workspace/artifact additions (Task 3)", () => {
    for (const type of ["artifact_created", "workspace_hibernated", "workspace_hydrated"] as const) {
      const event = { ...valid, type, payload: {} };
      expect(sessionEvent(event)).toEqual(event);
    }
  });

  it("still parses every pre-existing type (pin no regression)", () => {
    // Pre-existing = everything before the P3 Task 12 block (Task 3's three
    // additions are excluded the same way they were when they were the
    // newest members; the pinned count proves nothing was dropped).
    const oldTypes = allEventTypes.filter(
      (t) =>
        t !== "artifact_created" &&
        t !== "workspace_hibernated" &&
        t !== "workspace_hydrated" &&
        !P3_EVENT_TYPES.includes(t as (typeof P3_EVENT_TYPES)[number]),
    );
    expect(oldTypes).toHaveLength(9);
    for (const type of oldTypes) {
      const event = { ...valid, type, payload: {} };
      expect(sessionEventSchema.parse(event)).toEqual(event);
    }
  });

  it("the enum array accepts every member of the compile-time list", () => {
    // Runtime mirror of the compile-time check above: the zod enum in
    // sessionEventSchema must accept exactly the allEventTypes membership
    // (unknown types are already rejected by the "unknown type" test above).
    for (const type of allEventTypes) {
      const event = { ...valid, type, payload: {} };
      expect(sessionEventSchema.parse(event)).toEqual(event);
    }
  });
});

// P3 Task 12 — the remaining nine P3-Q5 members (approvals + agent-core
// state events). Ruling R5: P2's Task 12 already landed tool_started and
// tool_completed, so P3 appends only these nine — the first test below is
// the R5 detect-and-skip pin.
const P3_EVENT_TYPES = [
  "approval_requested",
  "approval_resolved",
  "todo_updated",
  "goal_updated",
  "plan_mode_changed",
  "run_cancelled",
  "subagent_started",
  "subagent_completed",
  "compaction_completed",
] as const;

describe("sessionEvent P3 Task 12 additions (additive)", () => {
  it("R5: P2's tool_started/tool_completed are present EXACTLY ONCE (detect-and-skip, never re-appended)", () => {
    expect(allEventTypes).toContain("tool_started");
    expect(allEventTypes).toContain("tool_completed");
    expect(allEventTypes.filter((t) => t === "tool_started")).toHaveLength(1);
    expect(allEventTypes.filter((t) => t === "tool_completed")).toHaveLength(1);
    expect(P3_EVENT_TYPES).not.toContain("tool_started");
    expect(P3_EVENT_TYPES).not.toContain("tool_completed");
  });

  it("round-trips every P3 addition through both parsers", () => {
    for (const type of P3_EVENT_TYPES) {
      const event = { ...valid, type, payload: {} };
      expect(sessionEvent(event)).toEqual(event);
      expect(sessionEventSchema.parse(event)).toEqual(event);
    }
  });

  it("approval_requested/resolved carry their payloads verbatim", () => {
    const requested = {
      ...valid,
      type: "approval_requested",
      payload: {
        approvalId: "ap-1",
        tool: "fetch_url",
        kind: "tool",
        summary: "Network access: example.com",
        detail: "…",
        allowAlways: true,
        expiresAt: "2026-10-17T12:02:00.000Z",
      },
    } as const;
    expect(sessionEvent(requested)).toEqual(requested);
    const resolved = {
      ...valid,
      type: "approval_resolved",
      payload: { approvalId: "ap-1", decision: "deny", reason: "timeout" },
    } as const;
    expect(sessionEvent(resolved)).toEqual(resolved);
  });

  it("the union count is 12 + 9 = 21 members (no reordering, nothing removed)", () => {
    expect(allEventTypes).toHaveLength(21);
    expect(allEventTypes.slice(0, 12)).toEqual([
      "run_started",
      "message_delta",
      "message_completed",
      "run_started_retry",
      "run_failed",
      "run_completed",
      "system_note",
      "tool_started",
      "tool_completed",
      "artifact_created",
      "workspace_hibernated",
      "workspace_hydrated",
    ]);
  });
});
