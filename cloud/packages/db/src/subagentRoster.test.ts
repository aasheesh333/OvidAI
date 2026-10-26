import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { subagentSessionProjectionSchema } from "@ovid/shared";

import {
  createDb,
  eventMirror,
  sessions,
  SubagentRosterCursorError,
  SubagentRosterTooLargeError,
  subagentCounts,
  projectSubagentLifecycle,
  paginateSubagentRoster,
  decodeSubagentRosterCursor,
  encodeSubagentRosterCursor,
  SUBAGENT_ROSTER_MAX_CURSOR_CHARS,
  SUBAGENT_ROSTER_MAX_CURSOR_IDENTITY_CHARS,
  type Db,
  readSubagentRosterSession,
} from "./index.js";
import { users as usersTable } from "./schema.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const SESSION = "11111111-1111-4111-8111-111111111111";
const CHILD_A = "22222222-2222-4222-8222-222222222222";
const CHILD_B = "33333333-3333-4333-8333-333333333333";
const ROOT_RUN = "44444444-4444-4444-8444-444444444444";
const CHILD_RUN_A = "55555555-5555-4555-8555-555555555555";
const CHILD_RUN_B = "66666666-6666-4666-8666-666666666666";
const BASE = Date.parse("2026-10-24T12:00:00.000Z");

function row(seq: string, type: string, payload: Record<string, unknown>, atMs = BASE): {
  seq: string;
  type: string;
  payload: Record<string, unknown>;
  ts: Date;
} {
  return { seq, type, payload, ts: new Date(atMs) };
}

function started(seq: string, childSessionId: string, childRunId: string, atMs = BASE): ReturnType<typeof row> {
  return row(seq, "subagent_started", {
    sessionId: SESSION,
    runId: ROOT_RUN,
    rootTaskRunId: ROOT_RUN,
    parentRunId: ROOT_RUN,
    requestId: `request-${childSessionId}`,
    batchId: "batch-1",
    childSessionId,
    childRunId,
    attemptId: `attempt-${childSessionId}`,
    attemptNumber: 1,
    agentType: "general-purpose",
    launchReason: "Independent work",
    prompt: "x".repeat(500),
    startedAt: new Date(atMs).toISOString(),
    status: "running",
    logAvailable: false,
  }, atMs);
}

function terminal(seq: string, childSessionId: string, childRunId: string, atMs = BASE + 10_000): ReturnType<typeof row> {
  return row(seq, "subagent_completed", {
    sessionId: SESSION,
    runId: ROOT_RUN,
    childSessionId,
    childRunId,
    agentType: "general-purpose",
    status: "completed",
    summary: "done",
    structuredReport: {
      subagent_id: childSessionId,
      status: "completed",
      files_modified: ["src/a.ts"],
      artifacts_created: [],
      key_findings: "actual finding",
      error_if_any: null,
    },
  }, atMs);
}

describe("client-compatible subagent roster projection", () => {
  it("returns every shipped SubagentSummaryDto field and keeps counts page-independent", () => {
    const items = projectSubagentLifecycle([
      started("1000-0", CHILD_A, CHILD_RUN_A),
      terminal("1001-0", CHILD_A, CHILD_RUN_A),
      started("1002-0", CHILD_B, CHILD_RUN_B, BASE + 1000),
    ]);
    expect(items).toHaveLength(2);
    expect(items.map((item) => item.status).sort()).toEqual(["completed", "running"]);
    expect(Object.keys(items[0]!).sort()).toEqual([
      "admittedAt", "agentType", "attemptId", "attemptNumber", "batchId",
      "childRunId", "childSessionId", "compaction", "deferredAt", "deferredRequestId",
      "endedAt", "error", "lastActivity", "lastActivityAt", "lastCursor",
      "launchReason", "logAvailable", "logicalWorkerId", "parentRunId", "prompt",
      "promptTruncated", "requestId", "requestedAt", "rootTaskRunId",
      "schedulingReason", "startKnown", "startedAt", "status", "steps",
      "structuredReport", "summary",
    ]);
    expect(items[0]).toMatchObject({
      prompt: "x".repeat(200),
      promptTruncated: true,
      startKnown: true,
      steps: [],
      lastCursor: null,
    });
    expect(subagentCounts(items)).toEqual({
      total: 2, running: 1, awaiting_next_user_task: 0,
      completed: 1, failed: 0, cancelled: 0, timeout: 0,
    });
  });

  it("supports limit=200 and after continuation without skipping valid children mixed with malformed rows", () => {
    const rows = [started("1000-0", CHILD_A, CHILD_RUN_A), started("1001-0", CHILD_B, CHILD_RUN_B, BASE + 1000)];
    for (let index = 0; index < 199; index += 1) {
      rows.push(row(`2${String(index).padStart(3, "0")}-0`, "subagent_completed", {
        childSessionId: `malformed-${index}`,
        childRunId: `malformed-run-${index}`,
        agentType: "general-purpose",
        status: "not-a-status",
        // A malformed completion must not become a synthetic running worker.
        summary: "invalid",
      }, BASE + 2000 + index));
    }
    const all = projectSubagentLifecycle(rows);
    expect(all).toHaveLength(2);
    const first = paginateSubagentRoster(all, { limit: 1 });
    expect(first.items).toHaveLength(1);
    expect(first.nextCursor).not.toBeNull();
    const second = paginateSubagentRoster(all, { limit: 200, after: first.nextCursor });
    expect(second.items).toHaveLength(1);
    expect(second.items[0]!.childSessionId).not.toBe(first.items[0]!.childSessionId);
    expect(second.nextCursor).toBeNull();
    expect(second.counts.total).toBe(2);
  });

  it("does not invent endedAt for live controls and does set it for terminal controls", () => {
    const live = projectSubagentLifecycle([
      started("1000-0", CHILD_A, CHILD_RUN_A),
      row("1001-0", "subagent_controlled", {
        sessionId: SESSION,
        runId: ROOT_RUN,
        childSessionId: CHILD_A,
        childRunId: CHILD_RUN_A,
        logicalWorkerId: "worker-a",
        attemptId: "attempt-a",
        action: "continue",
        status: "running",
        controlledAt: new Date(BASE + 5000).toISOString(),
      }, BASE + 5000),
    ])[0]!;
    expect(live.status).toBe("running");
    expect(live.endedAt).toBeNull();

    const stopped = projectSubagentLifecycle([
      started("1002-0", CHILD_B, CHILD_RUN_B, BASE + 1000),
      row("1003-0", "subagent_controlled", {
        sessionId: SESSION,
        runId: ROOT_RUN,
        childSessionId: CHILD_B,
        childRunId: CHILD_RUN_B,
        logicalWorkerId: "worker-b",
        attemptId: "attempt-b",
        action: "stop",
        status: "cancelled",
        controlledAt: new Date(BASE + 6000).toISOString(),
      }, BASE + 6000),
    ])[0]!;
    expect(stopped.status).toBe("cancelled");
    expect(stopped.endedAt).toBe(new Date(BASE + 6000).toISOString());
  });

  it("round-trips only a validated opaque after cursor", () => {
    const cursor = encodeSubagentRosterCursor("request-a");
    expect(decodeSubagentRosterCursor(cursor)).toBe("request-a");
    expect(decodeSubagentRosterCursor("not-a-cursor")).toBeNull();
  });

  it("rejects base64 padding and trailing-bit cursor aliases through canonical re-encoding", () => {
    const identity = "request-a";
    const canonical = encodeSubagentRosterCursor(identity);
    const canonicalBytes = Buffer.from(canonical, "base64url").toString("utf8");
    const padded = `${canonical}==`;
    const extraChar = `${canonical}A`;

    expect(padded).not.toBe(canonical);
    expect(extraChar).not.toBe(canonical);
    expect(Buffer.from(padded, "base64url").toString("utf8")).toBe(canonicalBytes);
    expect(Buffer.from(extraChar, "base64url").toString("utf8")).toBe(canonicalBytes);
    expect(decodeSubagentRosterCursor(canonical)).toBe(identity);
    expect(decodeSubagentRosterCursor(padded)).toBeNull();
    expect(decodeSubagentRosterCursor(extraChar)).toBeNull();
  });

  it("rejects a cursor with noncanonical JSON spacing despite an identical identity", () => {
    const noncanonical = Buffer.from(JSON.stringify(
      { v: 1, identity: "request-a" },
      null,
      2,
    ), "utf8").toString("base64url");

    expect(JSON.parse(Buffer.from(noncanonical, "base64url").toString("utf8")))
      .toEqual({ v: 1, identity: "request-a" });
    expect(noncanonical).not.toBe(encodeSubagentRosterCursor("request-a"));
    expect(decodeSubagentRosterCursor(noncanonical)).toBeNull();
  });

  it("accepts exactly the maximum wire-sized cursor and its response schema", () => {
    const identity = "x".repeat(SUBAGENT_ROSTER_MAX_CURSOR_IDENTITY_CHARS);
    const cursor = encodeSubagentRosterCursor(identity);
    expect(cursor).toHaveLength(SUBAGENT_ROSTER_MAX_CURSOR_CHARS);
    expect(decodeSubagentRosterCursor(cursor)).toBe(identity);
    expect(subagentSessionProjectionSchema.safeParse({
      counts: subagentCounts([]),
      items: [],
      nextCursor: cursor,
    }).success).toBe(true);
  });

  it("fails closed for identities and cursors beyond the wire bound", () => {
    expect(() => encodeSubagentRosterCursor(
      "x".repeat(SUBAGENT_ROSTER_MAX_CURSOR_IDENTITY_CHARS + 1),
    )).toThrow(RangeError);
    const oversized = Buffer.from(JSON.stringify({
      v: 1,
      identity: "x".repeat(SUBAGENT_ROSTER_MAX_CURSOR_IDENTITY_CHARS + 1),
    }), "utf8").toString("base64url");
    expect(oversized.length).toBeGreaterThan(SUBAGENT_ROSTER_MAX_CURSOR_CHARS);
    expect(decodeSubagentRosterCursor(oversized)).toBeNull();
  });

  it("continues across a maximum-length nextCursor without skipping a child", () => {
    const identity = "x".repeat(SUBAGENT_ROSTER_MAX_CURSOR_IDENTITY_CHARS);
    const long = started("1001-0", CHILD_A, CHILD_RUN_A);
    long.payload.requestId = identity;
    const all = projectSubagentLifecycle([
      started("1000-0", CHILD_B, CHILD_RUN_B),
      long,
    ]);
    expect(all[0]!.requestId).toBe(identity);

    const first = paginateSubagentRoster(all, { limit: 1 });
    expect(first.items[0]!.requestId).toBe(identity);
    expect(first.nextCursor).toHaveLength(SUBAGENT_ROSTER_MAX_CURSOR_CHARS);
    expect(subagentSessionProjectionSchema.safeParse(first).success).toBe(true);

    const second = paginateSubagentRoster(all, { limit: 1, after: first.nextCursor });
    expect(second.items[0]!.childSessionId).toBe(CHILD_B);
    expect(second.nextCursor).toBeNull();
  });

  it("uses distinct roster error classes instead of a broad RangeError boundary", () => {
    const cursor = new SubagentRosterCursorError("invalid cursor");
    const tooLarge = new SubagentRosterTooLargeError("roster too large");
    expect(cursor).toBeInstanceOf(Error);
    expect(cursor).not.toBeInstanceOf(RangeError);
    expect(tooLarge).toBeInstanceOf(Error);
    expect(tooLarge).not.toBeInstanceOf(SubagentRosterCursorError);
    expect(tooLarge).not.toBeInstanceOf(RangeError);
  });
});

describe.skipIf(!TEST_DATABASE_URL)("subagent roster against real postgres", () => {
  let db: Db;

  beforeAll(() => {
    db = createDb(TEST_DATABASE_URL!);
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function ownerSession(): Promise<{ uid: string; sessionId: string }> {
    const uid = `roster-${crypto.randomUUID()}`;
    await db.insert(usersTable).values({ uid });
    const session = await sessions.create(db, uid, "roster");
    return { uid, sessionId: session.id };
  }

  async function seed(sessionId: string, event: ReturnType<typeof row>): Promise<void> {
    await eventMirror.put(db, {
      sessionId,
      seq: event.seq,
      type: event.type as never,
      payload: event.payload,
      ts: event.ts.toISOString(),
    });
  }

  it("reads the exact parent projection with owner sessions and an empty roster", async () => {
    const a = await ownerSession();
    const b = await ownerSession();
    expect(await sessions.get(db, b.sessionId, a.uid)).toBeNull();
    await seed(a.sessionId, started("1000-0", CHILD_A, CHILD_RUN_A));
    const page = await readSubagentRosterSession(db, { sessionId: a.sessionId, limit: 200 });
    expect(page.items).toHaveLength(1);
    expect(page.items[0]).toMatchObject({ childSessionId: CHILD_A, startKnown: true });
    expect(page.counts.total).toBe(1);
    const empty = await readSubagentRosterSession(db, { sessionId: b.sessionId, limit: 200 });
    expect(empty).toEqual({
      counts: { total: 0, running: 0, awaiting_next_user_task: 0, completed: 0, failed: 0, cancelled: 0, timeout: 0 },
      items: [],
      nextCursor: null,
    });
  });
});
