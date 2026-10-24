import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import Redis from "ioredis";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import { APPROVAL_RESPONSES_CHANNEL } from "@ovid/shared";
import { createDb, migrate, sessions, users, type Db } from "@ovid/db";
import { createProviderOperationAuthorizer, createRedisApprovalBridge } from "./approvalBridge.js";
import type { ApprovalGate, ApprovalRequest, ToolContext } from "@ovid/agent-core";
import type { ProviderOperation } from "@ovid/mcp";

/**
 * Worker approval bridge (P3 Task 12) over REAL Redis + REAL Postgres
 * (TEST_REDIS_URL + TEST_DATABASE_URL): SUBSCRIBEs the approval-responses
 * channel once, resolves pending asks by approvalId, drops cross-user
 * answers (sessions.get ownership), no-ops after settle (Review Focus #1),
 * and answers abort with deny.
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Race a promise against a deadline: has it settled, and with what? */
async function state<T>(p: Promise<T>, waitMs: number): Promise<{ settled: boolean; value?: T }> {
  const holder: { value?: { v: T } } = {};
  await Promise.race([
    p.then((v) => {
      holder.value = { v };
    }),
    sleep(waitMs),
  ]);
  return holder.value === undefined ? { settled: false } : { settled: true, value: holder.value.v };
}

function request(approvalId: string): ApprovalRequest {
  return {
    approvalId,
    kind: "tool",
    tool: "run_shell",
    summary: "Run: echo hi",
    detail: "The agent wants to run: echo hi",
    allowAlways: true,
    pathTargets: [],
    hostTargets: [],
  };
}

describe.skipIf(!TEST_REDIS_URL || !TEST_DATABASE_URL)(
  "createRedisApprovalBridge (real redis + postgres)",
  () => {
    let db: Db;
    let redisQ: Redis;
    let events: EventLog;
    let bridge: ReturnType<typeof createRedisApprovalBridge>;
    let ownerUid: string;
    let sessionId: string;

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redisQ = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redisQ);
      ownerUid = `br-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
      await users.ensure(db, ownerUid, null);
      const row = await sessions.create(db, ownerUid, null);
      sessionId = row.id;
      bridge = createRedisApprovalBridge({ redisQ, events, db });
      await bridge.ready; // SUBSCRIBE acknowledged before any test publishes
    }, 60_000);

    afterAll(async () => {
      await bridge?.close();
      redisQ?.disconnect();
      await db?.$client.end({ timeout: 5 });
    });

    function publish(payload: { approvalId: string; userId: string; decision: string }): void {
      void redisQ.publish(APPROVAL_RESPONSES_CHANNEL, JSON.stringify(payload));
    }

    it("a published response resolves the matching pending ask", async () => {
      const approvalId = randomUUID();
      const ask = bridge.ask(request(approvalId), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 30_000,
        signal: new AbortController().signal,
      });
      expect((await state(ask, 100)).settled).toBe(false); // pending before the answer
      publish({ approvalId, userId: ownerUid, decision: "allow" });
      expect(await ask).toBe("allow");
    });

    it("a WRONG-USER publish is dropped (cross-user answers never resolve)", async () => {
      const approvalId = randomUUID();
      const ask = bridge.ask(request(approvalId), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 30_000,
        signal: new AbortController().signal,
      });
      publish({ approvalId, userId: "attacker-uid", decision: "always" });
      const afterAttack = await state(ask, 400);
      expect(afterAttack.settled).toBe(false); // dropped: not the session owner

      publish({ approvalId, userId: ownerUid, decision: "deny" });
      expect(await ask).toBe("deny");
    });

    it("a publish after the timeout is a no-op (Review Focus #1: first resolution wins)", async () => {
      const approvalId = randomUUID();
      const ask = bridge.ask(request(approvalId), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 60,
        signal: new AbortController().signal,
      });
      expect(await ask).toBe("timeout");
      // The user's late "always" lands after settle — ignored, no error.
      publish({ approvalId, userId: ownerUid, decision: "always" });
      await sleep(200);
      expect(await state(ask, 50)).toEqual({ settled: true, value: "timeout" });
    });

    it("two concurrent asks resolve independently by approvalId", async () => {
      const idA = randomUUID();
      const idB = randomUUID();
      const askA = bridge.ask(request(idA), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 30_000,
        signal: new AbortController().signal,
      });
      const askB = bridge.ask(request(idB), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 30_000,
        signal: new AbortController().signal,
      });

      publish({ approvalId: idB, userId: ownerUid, decision: "deny" });
      expect(await askB).toBe("deny");
      expect((await state(askA, 150)).settled).toBe(false); // A untouched by B's answer

      publish({ approvalId: idA, userId: ownerUid, decision: "always" });
      expect(await askA).toBe("always");
    });

    it("a malformed decision on the channel is dropped, not resolved", async () => {
      const approvalId = randomUUID();
      const ask = bridge.ask(request(approvalId), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 30_000,
        signal: new AbortController().signal,
      });
      publish({ approvalId, userId: ownerUid, decision: "maybe" }); // garbage: fail-closed
      expect((await state(ask, 300)).settled).toBe(false);
      publish({ approvalId, userId: ownerUid, decision: "allow" });
      expect(await ask).toBe("allow");
    });

    it("an ABORT signal resolves deny (run cancellation)", async () => {
      const controller = new AbortController();
      const ask = bridge.ask(request(randomUUID()), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 0, // would otherwise wait forever
        signal: controller.signal,
      });
      controller.abort();
      expect(await ask).toBe("deny");
    });

    it("timeoutMs 0 with no answer stays pending (attended question/plan wait)", async () => {
      const ask = bridge.ask(request(randomUUID()), {
        sessionId,
        userId: ownerUid,
        timeoutMs: 0,
        signal: new AbortController().signal,
      });
      expect((await state(ask, 300)).settled).toBe(false);
      // Left pending on purpose: close() (afterAll) must reap it as deny so
      // the suite can never hang on a wait-forever ask.
    });
  },
);

describe("provider approval adapter", () => {
  const operation: ProviderOperation = {
    name: "send_message",
    description: "Send one message.",
    effect: "external_communication",
    approval: "per_action",
    requiredScopes: ["messages:write"],
    inputSchema: {
      type: "object",
      additionalProperties: false,
      maxProperties: 1,
      properties: { text: { type: "string", minLength: 1, maxLength: 32 } },
      required: ["text"],
    },
    outputPolicy: { kind: "redacted_json", maxBytes: 1_024 },
    request: { originKey: "comms", method: "POST", pathTemplate: "/messages" },
    limits: { timeoutMs: 1_000, responseBytes: 1_024, frameBytes: 1_024, pageBytes: 1_024 },
  };

  function ctx(): ToolContext & { connectionId: string; providerId: string } {
    return {
      sessionId: "session-1",
      runId: "run-1",
      userId: "user-1",
      mode: "auto",
      planMode: false,
      unattended: false,
      isSubagent: false,
      depth: 0,
      callKey: "call-1",
      signal: new AbortController().signal,
      connectionId: "connection-1",
      providerId: "comms",
    };
  }

  it("adapts the canonical SessionMode context into a non-reusable per-action request", async () => {
    const requests: ApprovalRequest[] = [];
    const contexts: unknown[] = [];
    const gate: ApprovalGate = {
      async approve(approvalCtx, req) {
        contexts.push(approvalCtx);
        requests.push(req);
        return "allow";
      },
    };
    const authorize = createProviderOperationAuthorizer({
      approvals: gate,
      now: () => new Date("2026-10-24T00:00:00.000Z"),
    });
    const result = await authorize(ctx(), operation, { text: "do-not-put-in-the-card" });
    expect(result.kind).toBe("allow");
    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({
      kind: "tool",
      tool: "provider:comms/send_message",
      allowAlways: false,
      pathTargets: [],
      hostTargets: [],
    });
    expect(JSON.stringify(requests[0])).not.toContain("do-not-put-in-the-card");
    expect(contexts[0]).toMatchObject({ mode: "auto", runId: "run-1", userId: "user-1" });
  });

  it("fails closed if the underlying gate attempts an always grant", async () => {
    const authorize = createProviderOperationAuthorizer({
      approvals: { approve: async () => "always" },
      now: () => new Date("2026-10-24T00:00:00.000Z"),
    });
    expect(await authorize(ctx(), operation, { text: "hello" })).toEqual({
      kind: "deny",
      code: "approval_required",
    });
  });
});
