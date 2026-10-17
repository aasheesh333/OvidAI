import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import { createDb, grantsRepo, migrate, sessions, users, type Db } from "@ovid/db";
import type { SessionEventType } from "@ovid/shared";
import { APPROVAL_TIMEOUT_MS, approvalDenialKey, createApprovalGate } from "./approvals.js";
import type {
  ApprovalBridge,
  ApprovalDecision,
  ApprovalGate,
  ApprovalRequest,
  EventSink,
} from "./ports.js";
import type { ToolContext } from "./types.js";

/**
 * Approval gate (P3 Task 12) — fake bridge + fake sink + REAL Postgres
 * (TEST_DATABASE_URL): the grant consultation and the "always" persistence
 * hit grantsRepo for real; the prompt/timeout/race semantics run against a
 * fake bridge whose settle() is once-only (the real bridge's contract).
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

type GateCtx = Pick<
  ToolContext,
  "sessionId" | "runId" | "userId" | "mode" | "planMode" | "unattended" | "signal"
>;

interface RecordedAsk {
  req: ApprovalRequest;
  opts: { sessionId: string; userId: string; timeoutMs: number; signal: AbortSignal };
  settled: boolean;
  /**
   * First resolution wins (the bridge contract): a second call — e.g. a user
   * answer landing after the bridge's own timer — is a NO-OP.
   */
  settle(decision: ApprovalDecision | "timeout"): void;
}

function fakeBridge(): { bridge: ApprovalBridge; asks: RecordedAsk[] } {
  const asks: RecordedAsk[] = [];
  const bridge: ApprovalBridge = {
    async ask(req, opts) {
      let settled = false;
      let resolveAsk!: (d: ApprovalDecision | "timeout") => void;
      const promise = new Promise<ApprovalDecision | "timeout">((resolve) => {
        resolveAsk = resolve;
      });
      const recorded: RecordedAsk = {
        req,
        opts: { ...opts },
        settled: false,
        settle(decision) {
          if (settled) return; // once-only: the bridge guarantees first-wins
          settled = true;
          recorded.settled = true;
          resolveAsk(decision);
        },
      };
      asks.push(recorded);
      return promise;
    },
  };
  return { bridge, asks };
}

interface SinkEvent {
  type: SessionEventType;
  payload: Record<string, unknown>;
}

function fakeSinkFactory(): {
  sinkFactory: (sessionId: string) => EventSink;
  eventsFor(sessionId: string): SinkEvent[];
} {
  const bySession = new Map<string, SinkEvent[]>();
  return {
    sinkFactory: (sessionId) => ({
      async emit(type, payload) {
        const list = bySession.get(sessionId) ?? [];
        list.push({ type, payload });
        bySession.set(sessionId, list);
      },
    }),
    eventsFor: (sessionId) => bySession.get(sessionId) ?? [],
  };
}

function approvalRequest(overrides: Partial<ApprovalRequest> = {}): ApprovalRequest {
  return {
    approvalId: randomUUID(),
    kind: "tool",
    tool: "run_shell",
    summary: "Run: echo hi",
    detail: "The agent wants to run: echo hi",
    allowAlways: true,
    pathTargets: [],
    hostTargets: [],
    ...overrides,
  };
}

describe.skipIf(!TEST_DATABASE_URL)("createApprovalGate (real postgres)", () => {
  let db: Db;
  const createdSessions: Array<{ userId: string; sessionId: string }> = [];

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  /** Fresh user + session per test (data isolation, gateway convention). */
  async function seedSession(): Promise<GateCtx> {
    const uid = `ap-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await users.ensure(db, uid, null);
    const row = await sessions.create(db, uid, null);
    createdSessions.push({ userId: uid, sessionId: row.id });
    return {
      sessionId: row.id,
      runId: randomUUID(),
      userId: uid,
      mode: "auto",
      planMode: false,
      unattended: false,
      signal: new AbortController().signal,
    };
  }

  it("APPROVAL_TIMEOUT_MS pins the spec §6.2/§8 default (120 s)", () => {
    expect(APPROVAL_TIMEOUT_MS).toBe(120_000);
  });

  it("a matching allow/always path grant resolves 'allow' with NO prompt", async () => {
    const ctx = await seedSession();
    await grantsRepo.add(db, {
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "always",
      mode: "auto",
    });
    const { bridge, asks } = fakeBridge();
    const { sinkFactory, eventsFor } = fakeSinkFactory();
    const gate = createApprovalGate({ db, bridge, sinkFactory });

    const decision = await gate.approve(ctx, approvalRequest({ pathTargets: ["/ws/a/b/c"] }));
    expect(decision).toBe("allow");
    expect(asks).toHaveLength(0); // no bridge call
    expect(eventsFor(ctx.sessionId)).toEqual([]); // silent: no approval events
  });

  it("a matching host grant covers child domains with NO prompt", async () => {
    const ctx = await seedSession();
    await grantsRepo.add(db, {
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      kind: "host",
      pattern: "example.com",
      decision: "always",
      mode: "auto",
    });
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const decision = await gate.approve(ctx, approvalRequest({ hostTargets: ["api.example.com:8443"] }));
    expect(decision).toBe("allow");
    expect(asks).toHaveLength(0);
  });

  it("a matching deny grant resolves 'deny' with NO prompt", async () => {
    const ctx = await seedSession();
    await grantsRepo.add(db, {
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "deny",
      mode: "auto",
    });
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const decision = await gate.approve(ctx, approvalRequest({ pathTargets: ["/ws/a/f.txt"] }));
    expect(decision).toBe("deny");
    expect(asks).toHaveLength(0);
  });

  it("a deny grant among several targets dominates (combined card semantics)", async () => {
    const ctx = await seedSession();
    await grantsRepo.add(db, {
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      kind: "path",
      pattern: "/ws/b",
      decision: "deny",
      mode: "auto",
    });
    await grantsRepo.add(db, {
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "always",
      mode: "auto",
    });
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const decision = await gate.approve(
      ctx,
      approvalRequest({ pathTargets: ["/ws/a/f", "/ws/b/g"] }),
    );
    expect(decision).toBe("deny");
    expect(asks).toHaveLength(0);
  });

  it("partially granted targets still prompt (only ALL targets granted skip the card)", async () => {
    const ctx = await seedSession();
    await grantsRepo.add(db, {
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "always",
      mode: "auto",
    });
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const pending = gate.approve(ctx, approvalRequest({ pathTargets: ["/ws/a/f", "/ws/b/g"] }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks).toHaveLength(1);
    asks[0]!.settle("allow");
    expect(await pending).toBe("allow");
  });

  it("grants are session-scoped: another session's grant never applies", async () => {
    const ctxA = await seedSession();
    const ctxB = await seedSession();
    await grantsRepo.add(db, {
      userId: ctxA.userId,
      sessionId: ctxA.sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "always",
      mode: "auto",
    });
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const pending = gate.approve(ctxB, approvalRequest({ pathTargets: ["/ws/a/f"] }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks).toHaveLength(1); // B was asked despite A's grant
    asks[0]!.settle("deny");
    expect(await pending).toBe("deny");
  });

  it("prompt path emits approval_requested then approval_resolved, in order", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const { sinkFactory, eventsFor } = fakeSinkFactory();
    const gate = createApprovalGate({ db, bridge, sinkFactory });
    const req = approvalRequest({ tool: "fetch_url", hostTargets: ["example.com"] });

    const pending = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("allow");
    expect(await pending).toBe("allow");

    const events = eventsFor(ctx.sessionId);
    expect(events.map((e) => e.type)).toEqual(["approval_requested", "approval_resolved"]);
    expect(events[0]!.payload).toMatchObject({
      approvalId: req.approvalId,
      tool: "fetch_url",
      kind: "tool",
      summary: req.summary,
      detail: req.detail,
      allowAlways: true,
    });
    expect(typeof events[0]!.payload.expiresAt).toBe("string"); // 120 s default is a deadline
    expect(events[1]!.payload).toEqual({
      approvalId: req.approvalId,
      decision: "allow",
    }); // plain allow: no reason, no grant written
    const rows = await grantsRepo.listForSession(db, ctx.userId, ctx.sessionId);
    expect(rows).toHaveLength(0);
  });

  it("'always' with pathTargets writes a grants row (asserted via listForSession)", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const { sinkFactory, eventsFor } = fakeSinkFactory();
    const gate = createApprovalGate({ db, bridge, sinkFactory });
    const req = approvalRequest({ pathTargets: ["/ws/a", "/ws/a/"] });

    const pending = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("always");
    expect(await pending).toBe("always");

    const rows = await grantsRepo.listForSession(db, ctx.userId, ctx.sessionId);
    expect(rows).toHaveLength(1); // both spellings normalize to the same pattern
    expect(rows[0]).toMatchObject({
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      kind: "path",
      pattern: "/ws/a",
      decision: "always",
      mode: "auto",
    });
    expect(eventsFor(ctx.sessionId)[1]!.payload).toEqual({
      approvalId: req.approvalId,
      decision: "always",
    });
  });

  it("'always' with hostTargets writes a host grants row, normalized", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const pending = gate.approve(ctx, approvalRequest({ hostTargets: ["Example.COM:8443"] }));
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("always");
    expect(await pending).toBe("always");

    const rows = await grantsRepo.listForSession(db, ctx.userId, ctx.sessionId);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ kind: "host", pattern: "example.com", decision: "always" });
  });

  it("'always' with NO targets writes nothing (tool-level memory is out of scope)", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const pending = gate.approve(ctx, approvalRequest());
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("always");
    expect(await pending).toBe("always");
    expect(await grantsRepo.listForSession(db, ctx.userId, ctx.sessionId)).toHaveLength(0);
  });

  it("timeout → deny + approval_resolved {reason:'timeout'} (attended)", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const { sinkFactory, eventsFor } = fakeSinkFactory();
    const gate = createApprovalGate({ db, bridge, sinkFactory });
    const req = approvalRequest();

    const pending = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("timeout");
    expect(await pending).toBe("deny");

    const events = eventsFor(ctx.sessionId);
    expect(events.map((e) => e.type)).toEqual(["approval_requested", "approval_resolved"]);
    expect(events[1]!.payload).toEqual({
      approvalId: req.approvalId,
      decision: "deny",
      reason: "timeout",
    });
  });

  it("timeout while unattended → reason 'unattended_timeout'", async () => {
    const ctx = { ...(await seedSession()), unattended: true };
    const { bridge, asks } = fakeBridge();
    const { sinkFactory, eventsFor } = fakeSinkFactory();
    const gate = createApprovalGate({ db, bridge, sinkFactory });
    const req = approvalRequest();

    const pending = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("timeout");
    expect(await pending).toBe("deny");
    expect(eventsFor(ctx.sessionId)[1]!.payload).toEqual({
      approvalId: req.approvalId,
      decision: "deny",
      reason: "unattended_timeout",
    });
  });

  it("double-resolve race (Review Focus #1): late 'always' after a timeout is a NO-OP", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const { sinkFactory, eventsFor } = fakeSinkFactory();
    const gate = createApprovalGate({ db, bridge, sinkFactory });
    const req = approvalRequest({ pathTargets: ["/ws/a"] });

    const pending = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("timeout"); // first resolution: the bridge's timer fired
    expect(await pending).toBe("deny");
    // The user's "always" lands AFTER the timeout — the bridge must ignore it.
    asks[0]!.settle("always");

    await new Promise((r) => setTimeout(r, 50)); // let any (wrong) second emission land
    const events = eventsFor(ctx.sessionId);
    expect(events.filter((e) => e.type === "approval_resolved")).toHaveLength(1);
    expect(events[1]!.payload.decision).toBe("deny");
    expect(await grantsRepo.listForSession(db, ctx.userId, ctx.sessionId)).toHaveLength(0);
  });

  it("remembered denial: an identical targetless request auto-denies WITHOUT prompting", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const { sinkFactory, eventsFor } = fakeSinkFactory();
    const gate = createApprovalGate({ db, bridge, sinkFactory });
    const req = approvalRequest({ tool: "run_shell", summary: "Run: rm -rf build" });

    const first = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("deny");
    expect(await first).toBe("deny");

    // Second IDENTICAL request: denied from memory, bridge never called.
    const second = gate.approve(ctx, { ...req, approvalId: randomUUID() });
    expect(await second).toBe("deny");
    expect(asks).toHaveLength(1);
    expect(eventsFor(ctx.sessionId).filter((e) => e.type === "approval_requested")).toHaveLength(1);

    // A DIFFERENT request still prompts (the key is tool+summary).
    const third = gate.approve(ctx, approvalRequest({ summary: "Run: ls" }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks).toHaveLength(2);
    asks[1]!.settle("allow");
    expect(await third).toBe("allow");
  });

  it("forgetDenial clears the memory: the next identical request asks again", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const handle = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });
    const req = approvalRequest({ tool: "run_shell", summary: "Run: cargo build" });

    const first = handle.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("deny");
    expect(await first).toBe("deny");

    const key = approvalDenialKey(req.tool, req.summary);
    expect(handle.forgetDenial(ctx.sessionId, key)).toBe(true);
    expect(handle.forgetDenial(ctx.sessionId, key)).toBe(false); // already forgotten

    const second = handle.approve(ctx, { ...req, approvalId: randomUUID() });
    await new Promise((r) => setTimeout(r, 20));
    expect(asks).toHaveLength(2); // prompted again
    asks[1]!.settle("allow");
    expect(await second).toBe("allow");
  });

  it("denials WITH targets are not remembered as denials (only targetless ones are)", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });
    const req = approvalRequest({ pathTargets: ["/ws/a"] });

    const first = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("deny");
    expect(await first).toBe("deny");

    const second = gate.approve(ctx, { ...req, approvalId: randomUUID() });
    await new Promise((r) => setTimeout(r, 20));
    expect(asks).toHaveLength(2); // not remembered → prompted again
    asks[1]!.settle("allow");
    expect(await second).toBe("allow");
  });

  // ---- timeout seam (spec §6.2/§8 + the Task 16 env-override + P4 policy) ----

  it("attended question/plan kinds get NO timeout (timeoutMs 0 = wait)", async () => {
    const ctx = await seedSession(); // attended
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const pending = gate.approve(ctx, approvalRequest({ kind: "question" }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks[0]!.opts.timeoutMs).toBe(0);
    asks[0]!.settle("allow");
    expect(await pending).toBe("allow");

    const pendingPlan = gate.approve(ctx, approvalRequest({ kind: "plan" }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks[1]!.opts.timeoutMs).toBe(0);
    asks[1]!.settle("deny");
    expect(await pendingPlan).toBe("deny");
  });

  it("unattended question → timeoutMs 120000 (spec §8: 120 s for ALL kinds)", async () => {
    const ctx = { ...(await seedSession()), unattended: true };
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const pending = gate.approve(ctx, approvalRequest({ kind: "question" }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks[0]!.opts.timeoutMs).toBe(120_000);
    asks[0]!.settle("allow");
    expect(await pending).toBe("allow");
  });

  it("timeoutMs OVERRIDES the 120 s default (the env-override seam, FINDING 4)", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({
      db,
      bridge,
      sinkFactory: fakeSinkFactory().sinkFactory,
      timeoutMs: 500,
    });

    const pending = gate.approve(ctx, approvalRequest());
    await new Promise((r) => setTimeout(r, 20));
    expect(asks[0]!.opts.timeoutMs).toBe(500);
    asks[0]!.settle("allow");
    expect(await pending).toBe("allow");
  });

  it("timeoutPolicy computes the per-request timeout (P4's UnattendedApprovalHook seam)", async () => {
    const ctxUnattended = { ...(await seedSession()), unattended: true };
    const ctxAttended = await seedSession();
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({
      db,
      bridge,
      sinkFactory: fakeSinkFactory().sinkFactory,
      timeoutPolicy: (req, ctx) => (ctx.unattended ? 750 : 250),
    });

    const pendingU = gate.approve(ctxUnattended, approvalRequest({ kind: "question" }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks[0]!.opts.timeoutMs).toBe(750); // unattended: the policy wins over the 0/120 rules
    asks[0]!.settle("allow");
    expect(await pendingU).toBe("allow");

    const pendingA = gate.approve(ctxAttended, approvalRequest({ kind: "question" }));
    await new Promise((r) => setTimeout(r, 20));
    expect(asks[1]!.opts.timeoutMs).toBe(0); // attended question/plan keeps NO timeout (structural rule)
    asks[1]!.settle("deny");
    expect(await pendingA).toBe("deny");
  });

  it("the timeout policy context carries runId (P4-T10 carry)", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    let seenRunId: string | null = null;
    const gate = createApprovalGate({
      db,
      bridge,
      sinkFactory: fakeSinkFactory().sinkFactory,
      timeoutPolicy: (_req, policyCtx) => {
        seenRunId = policyCtx.runId;
        return 250;
      },
    });
    const pending = gate.approve(ctx, approvalRequest());
    await new Promise((r) => setTimeout(r, 20));
    expect(seenRunId).toBe(ctx.runId);
    asks[0]!.settle("allow");
    expect(await pending).toBe("allow");
  });

  it("onRequested fires before the bridge asks; onTimeout only on a timeout (P4-T10 carry)", async () => {
    const ctx = { ...(await seedSession()), unattended: true };
    const { bridge, asks } = fakeBridge();
    const seen: Array<{ phase: string; runId: string; unattended: boolean; tool: string }> = [];
    const gate = createApprovalGate({
      db,
      bridge,
      sinkFactory: fakeSinkFactory().sinkFactory,
      onRequested: (promptCtx, req) => {
        // The bridge has NOT been called yet: the push beats the clock.
        expect(asks).toHaveLength(0);
        seen.push({
          phase: "requested",
          runId: promptCtx.runId,
          unattended: promptCtx.unattended,
          tool: req.tool,
        });
      },
      onTimeout: (promptCtx, req) => {
        seen.push({
          phase: "timeout",
          runId: promptCtx.runId,
          unattended: promptCtx.unattended,
          tool: req.tool,
        });
      },
    });
    const req = approvalRequest();
    const pending = gate.approve(ctx, req);
    await new Promise((r) => setTimeout(r, 20));
    expect(seen).toEqual([
      { phase: "requested", runId: ctx.runId, unattended: true, tool: req.tool },
    ]);
    asks[0]!.settle("timeout");
    expect(await pending).toBe("deny");
    expect(seen.map((s) => s.phase)).toEqual(["requested", "timeout"]);

    // A user allow never fires onTimeout. (A different tool/summary: the
    // timed-out targetless request above is remembered as a denial.)
    const pending2 = gate.approve(
      ctx,
      approvalRequest({ tool: "fetch_url", summary: "Fetch: example.test" }),
    );
    await new Promise((r) => setTimeout(r, 20));
    asks[1]!.settle("allow");
    expect(await pending2).toBe("allow");
    expect(seen.filter((s) => s.phase === "timeout")).toHaveLength(1);
  });

  it("a failing side-effect callback never breaks the approval (best-effort seam)", async () => {
    const ctx = await seedSession();
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({
      db,
      bridge,
      sinkFactory: fakeSinkFactory().sinkFactory,
      onRequested: () => {
        throw new Error("push backend down");
      },
      onTimeout: () => {
        throw new Error("ledger down");
      },
    });
    const pending = gate.approve(ctx, approvalRequest());
    await new Promise((r) => setTimeout(r, 20));
    asks[0]!.settle("timeout");
    expect(await pending).toBe("deny");
  });

  it("the ctx signal is passed through to the bridge (abort → deny is the bridge's contract)", async () => {
    const ctx = await seedSession();
    const controller = new AbortController();
    const { bridge, asks } = fakeBridge();
    const gate = createApprovalGate({ db, bridge, sinkFactory: fakeSinkFactory().sinkFactory });

    const pending = gate.approve({ ...ctx, signal: controller.signal }, approvalRequest());
    await new Promise((r) => setTimeout(r, 20));
    expect(asks[0]!.opts.signal).toBe(controller.signal);
    asks[0]!.settle("allow");
    expect(await pending).toBe("allow");
  });
});
