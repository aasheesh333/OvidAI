import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { SessionEvent } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import {
  attachments,
  eventMirror,
  messages,
  newId,
  sessionState,
  sessions,
  users as usersRepo,
} from "./repos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

function ev(sessionId: string, seq: string, type: string, payload: Record<string, unknown>, ts: Date): SessionEvent {
  return { sessionId, seq, type: type as SessionEvent["type"], payload, ts: ts.toISOString() };
}

describe.skipIf(!TEST_DATABASE_URL)("Wave 1b repos (history window, truncate, branch, attachment links)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function freshSession(): Promise<{ uid: string; sessionId: string }> {
    const uid = newId();
    await usersRepo.ensure(db, uid, null);
    const s = await sessions.create(db, uid, "t");
    return { uid, sessionId: s.id };
  }

  it("maxSeq / readWindow / deltasForRun order numerically and honour the bounds", async () => {
    const { sessionId } = await freshSession();
    expect(await eventMirror.maxSeq(db, sessionId)).toBeNull();
    const t0 = new Date("2026-01-01T00:00:00Z");
    const at = (s: number) => new Date(t0.getTime() + s * 1000);
    await eventMirror.put(db, ev(sessionId, "999-0", "run_started", { runId: "r1" }, at(1)));
    await eventMirror.put(db, ev(sessionId, "999-1", "message_delta", { runId: "r1", text: "a" }, at(2)));
    await eventMirror.put(db, ev(sessionId, "1000-0", "tool_started", { runId: "r1", callId: "c" }, at(3)));
    await eventMirror.put(db, ev(sessionId, "1000-1", "message_delta", { runId: "r1", text: "b" }, at(4)));
    await eventMirror.put(db, ev(sessionId, "1000-2", "message_delta", { runId: "r2", text: "x" }, at(4)));
    await eventMirror.put(db, ev(sessionId, "1001-0", "run_completed", { runId: "r1" }, at(5)));
    expect(await eventMirror.maxSeq(db, sessionId)).toBe("1001-0");

    const all = await eventMirror.readWindow(db, sessionId, { fromTs: null, toTs: null, maxSeq: null, limit: 100 });
    expect(all.map((e) => e.seq)).toEqual(["999-0", "1000-0", "1001-0"]);

    const windowed = await eventMirror.readWindow(db, sessionId, {
      fromTs: at(2),
      toTs: at(5),
      maxSeq: null,
      limit: 100,
    });
    expect(windowed.map((e) => e.seq)).toEqual(["1000-0"]);

    const capped = await eventMirror.readWindow(db, sessionId, { fromTs: null, toTs: null, maxSeq: "1000-0", limit: 100 });
    expect(capped.map((e) => e.seq)).toEqual(["999-0", "1000-0"]);

    const newest = await eventMirror.readWindow(db, sessionId, { fromTs: null, toTs: null, maxSeq: null, limit: 2 });
    expect(newest.map((e) => e.seq)).toEqual(["1000-0", "1001-0"]);

    const deltas = await eventMirror.deltasForRun(db, sessionId, "r1", { afterSeq: "1000-0", maxSeq: null, limit: 10 });
    expect(deltas.map((e) => e.payload.text)).toEqual(["b"]);
    const allDeltas = await eventMirror.deltasForRun(db, sessionId, "r1", { afterSeq: null, maxSeq: "999-1", limit: 10 });
    expect(allDeltas.map((e) => e.payload.text)).toEqual(["a"]);
  });

  it("truncateFrom removes the anchor and later rows, later mirror events, and a stale compaction", async () => {
    const { sessionId } = await freshSession();
    const m1 = await messages.append(db, { sessionId, role: "user", content: "one" });
    const m2 = await messages.append(db, { sessionId, role: "assistant", content: "two" });
    await new Promise((r) => setTimeout(r, 5));
    const m3 = await messages.append(db, { sessionId, role: "user", content: "three" });
    const m4 = await messages.append(db, { sessionId, role: "assistant", content: "four" });
    await eventMirror.put(db, ev(sessionId, "1-0", "message_completed", { messageId: m2.id }, m2.createdAt));
    await eventMirror.put(
      db,
      ev(sessionId, "2-0", "tool_started", { callId: "c" }, new Date(m3.createdAt.getTime() + 1)),
    );
    await sessionState.patch(db, sessionId, {
      compaction: { ledger: null, summary: "s", cutoffMessageId: m4.id, compactedAtCount: 1 },
    });

    // Not in the session → nothing happens.
    expect(await messages.truncateFrom(db, sessionId, newId())).toBe(0);

    expect(await messages.truncateFrom(db, sessionId, m3.id)).toBe(2);
    const left = await messages.page(db, sessionId, { limit: 10 });
    expect(left.rows.map((r) => r.id)).toEqual([m2.id, m1.id]);
    const evs = await eventMirror.readSince(db, sessionId, null, 10);
    expect(evs.map((e) => e.seq)).toEqual(["1-0"]);
    expect((await sessionState.get(db, sessionId)).compaction).toBeNull();
  });

  it("truncateFrom keepAnchor removes only the rows after the anchor", async () => {
    const { sessionId } = await freshSession();
    const u1 = await messages.append(db, { sessionId, role: "user", content: "q" });
    await messages.append(db, { sessionId, role: "assistant", content: "a" });
    expect(await messages.truncateFrom(db, sessionId, u1.id, { keepAnchor: true })).toBe(1);
    const left = await messages.page(db, sessionId, { limit: 10 });
    expect(left.rows.map((r) => r.id)).toEqual([u1.id]);
  });

  it("truncateFrom keeps a compaction whose boundary is before the cut", async () => {
    const { sessionId } = await freshSession();
    const m1 = await messages.append(db, { sessionId, role: "user", content: "one" });
    const m2 = await messages.append(db, { sessionId, role: "assistant", content: "two" });
    await sessionState.patch(db, sessionId, {
      compaction: { ledger: null, summary: "s", cutoffMessageId: m1.id, compactedAtCount: 1 },
    });
    expect(await messages.truncateFrom(db, sessionId, m2.id)).toBe(1);
    expect((await sessionState.get(db, sessionId)).compaction?.cutoffMessageId).toBe(m1.id);
  });

  it("latestUserBefore, upTo and copyInto support regenerate and branch", async () => {
    const { uid, sessionId } = await freshSession();
    const u1 = await messages.append(db, { sessionId, role: "user", content: "q1" });
    const a1 = await messages.append(db, { sessionId, role: "assistant", content: "a1" });
    const u2 = await messages.append(db, { sessionId, role: "user", content: "q2" });
    const a2 = await messages.append(db, { sessionId, role: "assistant", content: "a2" });
    expect((await messages.latestUserBefore(db, sessionId, a2.id))?.id).toBe(u2.id);
    expect((await messages.latestUserBefore(db, sessionId, a1.id))?.id).toBe(u1.id);
    expect(await messages.latestUserBefore(db, sessionId, u1.id)).toBeNull();
    expect((await messages.getInSession(db, sessionId, a1.id))?.content).toBe("a1");
    const other = await sessions.create(db, uid, "other");
    expect(await messages.getInSession(db, other.id, a1.id)).toBeNull();

    const head = await messages.upTo(db, sessionId, a1.id, 100);
    expect(head.map((r) => r.content)).toEqual(["q1", "a1"]);
    expect(await messages.copyInto(db, other.id, head)).toBe(2);
    const copied = await messages.page(db, other.id, { limit: 10 });
    expect(copied.rows.map((r) => r.content).reverse()).toEqual(["q1", "a1"]);
    expect(copied.rows[1]!.createdAt.getTime()).toBe(u1.createdAt.getTime());
  });

  it("linkToMessage / forMessages are session-scoped", async () => {
    const { uid, sessionId } = await freshSession();
    const other = await sessions.create(db, uid, "other");
    const m = await messages.append(db, { sessionId, role: "user", content: "see file" });
    const a = newId();
    const b = newId();
    await attachments.create(db, { id: a, sessionId, userId: uid, name: "a.png", size: 10, r2Key: "k/a" });
    await attachments.create(db, { id: b, sessionId: other.id, userId: uid, name: "b.png", size: 10, r2Key: "k/b" });
    await attachments.linkToMessage(db, sessionId, [a, b], m.id);
    const rows = await attachments.forMessages(db, sessionId, [m.id]);
    expect(rows.map((r) => r.id)).toEqual([a]);
    expect(await attachments.forMessages(db, other.id, [m.id])).toEqual([]);
    expect(await attachments.forMessages(db, sessionId, [])).toEqual([]);
  });
});
