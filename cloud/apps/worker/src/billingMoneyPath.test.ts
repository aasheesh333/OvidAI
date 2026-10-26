import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { ModelQuotaExceededError, type AgentRequest, type AgentResponse, type AgentTransport } from "@ovid/agent-core";
import {
  RunQuotaService,
  createDb,
  messages,
  migrate,
  newId,
  runs,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import { PLANS } from "@ovid/shared";
import { recoverPendingModelCallSettlements, releaseAbandonedModelReservations, type SchedulerDeps } from "./schedulerTick.js";
import { usageFor, withUsageRecording } from "./usageRecorder.js";

/**
 * End-to-end money path on isolated real Postgres:
 * reserve (quota) → provider call → settle → durable `run_usage` ledger,
 * plus the scheduler's recovery of a settlement that lost its commit.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const REQ = {
  model: "auto",
  baseUrl: "http://litellm",
  apiKey: "sk",
  system: [],
  messages: [],
  tools: [],
  cacheMode: "none",
} as unknown as AgentRequest;

function response(usage: AgentResponse["usage"]): AgentResponse {
  return { content: "hi", thinking: "", toolCalls: [], finishReason: "stop", usage };
}

/** A provider that counts how many times it was actually invoked. */
function countingTransport(usage: AgentResponse["usage"]): AgentTransport & { calls: number } {
  const t = {
    apiFormat: "openai" as const,
    calls: 0,
    async stream(_req: AgentRequest) {
      t.calls += 1;
      return response(usage);
    },
  };
  return t;
}

/** Forwards everything, but throws instead of running the Nth transaction. */
function dbFailingOnTransaction(base: Db, failOn: number): Db {
  let seen = 0;
  return new Proxy(base, {
    get(target, prop, receiver) {
      if (prop === "transaction") {
        return async (...args: unknown[]) => {
          seen += 1;
          if (seen === failOn) throw new Error("simulated crash before the ledger commit");
          return (target.transaction as (...a: unknown[]) => unknown).apply(target, args);
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  }) as Db;
}

describe.skipIf(!TEST_DATABASE_URL).sequential(
  "billing money path on isolated real Postgres",
  () => {
    let db: Db;

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
    }, 240_000);

    afterAll(async () => {
      await db?.$client.end({ timeout: 5 });
    }, 30_000);

    async function seedRun(tier = "free") {
      const actorUserId = newId();
      await users.ensure(db, actorUserId, null);
      await db.$client`UPDATE users SET tier = ${tier} WHERE uid = ${actorUserId}`;
      const session = await sessions.create(db, actorUserId, "money path");
      const prompt = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "money path",
      });
      const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
      return { actorUserId, session, run };
    }

    it("releases the hold left by a crash between reserve and the provider call", async () => {
      const { actorUserId, session, run } = await seedRun("free");
      const quota = new RunQuotaService(db);
      const provider: AgentTransport & { calls: number } = {
        apiFormat: "openai" as const,
        calls: 0,
        // The process dies here: no usage is ever staged, and no release runs.
        async stream() {
          provider.calls += 1;
          throw Object.assign(new Error("process died"), { fatal: true });
        },
      };
      // Reserve succeeds; the "crash" leaves the reservation held with no
      // staged usage and no release.
      const reservation = await quota.reserveModelCall({
        actorUserId,
        runId: run.id,
        reservationKey: "crash:before-provider",
        inputTokens: 4_000,
        maxOutputTokens: 1_000,
      });
      if (!reservation.ok) throw new Error("reservation refused");
      await runs.finish(db, run.id, "failed", "run_lost");

      const held = await db.$client`
        SELECT reserved_tokens::int AS reserved FROM usage_quota_counters
         WHERE actor_user_id = ${actorUserId} AND window_kind = 'day'`;
      expect(held).toEqual([{ reserved: 5_000 }]);

      // The scheduler's recovery pass must return it, exactly once.
      const deps = { db, quota } as unknown as SchedulerDeps;
      await releaseAbandonedModelReservations(deps, { olderThanMs: 0 });
      await releaseAbandonedModelReservations(deps, { olderThanMs: 0 });

      const after = await db.$client`
        SELECT used_tokens::int AS used, reserved_tokens::int AS reserved
          FROM usage_quota_counters
         WHERE actor_user_id = ${actorUserId} AND window_kind = 'day'`;
      expect(after).toEqual([{ used: 0, reserved: 0 }]);
      const state = await db.$client`
        SELECT state FROM usage_quota_reservations WHERE id = ${reservation.reservationId}`;
      expect(state).toEqual([{ state: "released" }]);
      // Nothing was charged and no provider usage was invented.
      const ledger = await db.$client`
        SELECT count(*)::int AS n FROM run_usage WHERE run_id = ${run.id}`;
      expect(ledger).toEqual([{ n: 0 }]);
      expect(provider.calls).toBe(0);
    }, 60_000);

    it("refuses a quota-exhausted call BEFORE any provider invocation", async () => {
      const { actorUserId, session, run } = await seedRun("free");
      const quota = new RunQuotaService(db);
      // Exhaust the daily allowance with a live hold.
      const fill = await quota.reserveModelCall({
        actorUserId,
        runId: run.id,
        reservationKey: "precheck:fill",
        inputTokens: PLANS.free.tokens.perDay,
        maxOutputTokens: 0,
      });
      expect(fill.ok).toBe(true);

      const provider = countingTransport({ inputTokens: 1, outputTokens: 1 });
      const recorded = withUsageRecording(provider, {
        ...usageFor(db, actorUserId, session.id, run.id),
        quota,
      });

      await expect(recorded.stream(REQ, { onTextDelta() {} }, new AbortController().signal))
        .rejects.toBeInstanceOf(ModelQuotaExceededError);

      // Zero provider invocations: the refusal is strictly before the call.
      expect(provider.calls).toBe(0);
      const ledger = await db.$client`
        SELECT count(*)::int AS n FROM run_usage WHERE user_id = ${actorUserId}`;
      expect(ledger).toEqual([{ n: 0 }]);
    }, 60_000);

    it("reserves, calls the provider once, and charges the actual usage to the ledger", async () => {
      const { actorUserId, session, run } = await seedRun("free");
      const quota = new RunQuotaService(db);
      const provider = countingTransport({
        inputTokens: 1_200,
        outputTokens: 300,
        providerModel: "provider-model",
        costUsd: "0.0123",
        costSource: "provider",
      });
      const recorded = withUsageRecording(provider, {
        ...usageFor(db, actorUserId, session.id, run.id),
        quota,
      });
      const result = await recorded.stream(REQ, { onTextDelta() {} }, new AbortController().signal);
      expect(result.usage?.inputTokens).toBe(1_200);
      expect(provider.calls).toBe(1);

      const ledger = await db.$client`
        SELECT input_tokens::int AS i, output_tokens::int AS o,
               billing_class, provider_model, cost_usd::text AS cost
          FROM run_usage WHERE run_id = ${run.id}`;
      expect(ledger).toEqual([{
        i: 1_200,
        o: 300,
        billing_class: "ovid_allowance",
        provider_model: "provider-model",
        cost: "0.0123000000",
      }]);
      const reservation = await db.$client`
        SELECT state FROM usage_quota_reservations WHERE run_id = ${run.id}`;
      expect(reservation).toEqual([{ state: "settled" }]);
      const counters = await db.$client`
        SELECT used_tokens::int AS used, reserved_tokens::int AS reserved
          FROM usage_quota_counters
         WHERE actor_user_id = ${actorUserId} AND window_kind = 'day'`;
      expect(counters).toEqual([{ used: 1_500, reserved: 0 }]);
    }, 60_000);

    it("keeps a failed settlement pending (never released) and recovers it exactly once", async () => {
      const { actorUserId, session, run } = await seedRun("free");
      const realQuota = new RunQuotaService(db);
      // The staging transaction (settle #1) commits; the ledger transaction
      // (settle #2) "crashes". The counter starts at the settle call, so the
      // reservation's own transaction does not consume a slot.
      const crashing = new RunQuotaService(dbFailingOnTransaction(db, 2));
      const provider = countingTransport({ inputTokens: 700, outputTokens: 200 });
      const recorded = withUsageRecording(provider, {
        ...usageFor(db, actorUserId, session.id, run.id),
        quota: {
          reserveModelCall: (input) => realQuota.reserveModelCall(input),
          releaseModelCall: (id) => realQuota.releaseModelCall(id),
          settleModelCall: (input) => crashing.settleModelCall(input),
        },
      });

      await expect(
        recorded.stream(REQ, { onTextDelta() {} }, new AbortController().signal),
      ).rejects.toThrow(/simulated crash/);
      expect(provider.calls).toBe(1);

      // Not released, not double-charged: the staged actuals are durable.
      const staged = await db.$client`
        SELECT state, actual_input_tokens::int AS i, actual_output_tokens::int AS o
          FROM usage_quota_reservations WHERE run_id = ${run.id}`;
      expect(staged).toEqual([{ state: "reserved", i: 700, o: 200 }]);
      const chargedBefore = await db.$client`
        SELECT count(*)::int AS n FROM run_usage WHERE run_id = ${run.id}`;
      expect(chargedBefore).toEqual([{ n: 0 }]);

      const deps = { db, quota: realQuota } as unknown as SchedulerDeps;
      // Two scheduler passes: the second must be a no-op, not a second charge.
      await recoverPendingModelCallSettlements(deps);
      await recoverPendingModelCallSettlements(deps);

      const settled = await db.$client`
        SELECT state FROM usage_quota_reservations WHERE run_id = ${run.id}`;
      expect(settled).toEqual([{ state: "settled" }]);
      const ledger = await db.$client`
        SELECT count(*)::int AS n, sum(input_tokens)::int AS i, sum(output_tokens)::int AS o
          FROM run_usage WHERE run_id = ${run.id}`;
      expect(ledger).toEqual([{ n: 1, i: 700, o: 200 }]);
      const counters = await db.$client`
        SELECT used_tokens::int AS used, reserved_tokens::int AS reserved
          FROM usage_quota_counters
         WHERE actor_user_id = ${actorUserId} AND window_kind = 'day'`;
      expect(counters).toEqual([{ used: 900, reserved: 0 }]);
      // No provider re-call during recovery.
      expect(provider.calls).toBe(1);
    }, 60_000);

    it("releases the hold when the provider call itself fails, charging nothing", async () => {
      const { actorUserId, session, run } = await seedRun("free");
      const quota = new RunQuotaService(db);
      const provider: AgentTransport & { calls: number } = {
        apiFormat: "openai" as const,
        calls: 0,
        async stream() {
          provider.calls += 1;
          throw new Error("provider unavailable");
        },
      };
      const recorded = withUsageRecording(provider, {
        ...usageFor(db, actorUserId, session.id, run.id),
        quota,
      });
      await expect(
        recorded.stream(REQ, { onTextDelta() {} }, new AbortController().signal),
      ).rejects.toThrow(/provider unavailable/);
      expect(provider.calls).toBe(1);

      const reservation = await db.$client`
        SELECT state FROM usage_quota_reservations WHERE run_id = ${run.id}`;
      expect(reservation).toEqual([{ state: "released" }]);
      const counters = await db.$client`
        SELECT used_tokens::int AS used, reserved_tokens::int AS reserved
          FROM usage_quota_counters
         WHERE actor_user_id = ${actorUserId} AND window_kind = 'day'`;
      expect(counters).toEqual([{ used: 0, reserved: 0 }]);
      const ledger = await db.$client`
        SELECT count(*)::int AS n FROM run_usage WHERE run_id = ${run.id}`;
      expect(ledger).toEqual([{ n: 0 }]);
    }, 60_000);
  },
);
