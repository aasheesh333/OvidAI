import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { PLANS, PLAN_TIERS, planFor, tokenCapsFor, type PlanTier } from "@ovid/shared";
import { billingUsers } from "./billingRepos.js";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { plansRepo } from "./moneyRepos.js";
import { projectFileCap } from "./projectRepos.js";
import { RunQuotaService, StorageReservationStore } from "./quotaService.js";
import { messages, newId, runs, sessions, users } from "./repos.js";
import { runUsage } from "./runUsageRepos.js";

/**
 * Money-safety invariants for the quota/billing chain, on isolated real
 * Postgres. Every assertion reads the CANONICAL plan table (`@ovid/shared`)
 * rather than a copy of its numbers, so a drift between what the product
 * advertises and what the enforcement code applies fails here.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

/** A mutable clock so window boundaries can be crossed deterministically. */
function clock(start: Date) {
  let now = start;
  const read = () => now;
  read.set = (next: Date) => {
    now = next;
  };
  return read;
}

describe.skipIf(!TEST_DATABASE_URL).sequential(
  "billing money safety on isolated real Postgres",
  () => {
    let scratch: MigrationScratch;
    let db: Db;

    beforeAll(async () => {
      scratch = await createMigrationScratch(TEST_DATABASE_URL!, "billing_money_safety");
      await migrate(scratch.url);
      db = createDb(scratch.url, { max: 8 });
    }, 240_000);

    afterAll(async () => {
      await db?.$client.end({ timeout: 5 });
      await scratch?.close();
    }, 30_000);

    async function seedRun(tier: PlanTier = "free") {
      const actorUserId = newId();
      await users.ensure(db, actorUserId, null);
      await billingUsers.setTier(db, actorUserId, tier, null);
      const session = await sessions.create(db, actorUserId, "money safety");
      const prompt = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "money safety",
      });
      const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
      return { actorUserId, session, run };
    }

    async function counters(actorUserId: string) {
      return (await scratch.client`
        SELECT window_kind, window_start, window_end,
               used_tokens::bigint AS used_tokens,
               reserved_tokens::bigint AS reserved_tokens,
               used_usd::text AS used_usd, reserved_usd::text AS reserved_usd
          FROM usage_quota_counters
         WHERE actor_user_id = ${actorUserId}
         ORDER BY window_kind, window_start`) as unknown as Array<{
        window_kind: string;
        window_start: Date;
        window_end: Date;
        used_tokens: string;
        reserved_tokens: string;
        used_usd: string;
        reserved_usd: string;
      }>;
    }

    // -----------------------------------------------------------------------
    // 1. plans.ts is the enforcement table (never a copy)
    // -----------------------------------------------------------------------

    describe("plan limits in plans.ts are what the enforcement code uses", () => {
      it("resolves caps by reference from the canonical table, not a copy", () => {
        for (const tier of PLAN_TIERS) {
          // `scaledTokens` freezes one object per plan; referential equality
          // proves the gateway helper and the DB service both read THAT object.
          expect(tokenCapsFor(tier)).toBe(PLANS[tier].tokens);
          expect(planFor(tier).tokens).toBe(PLANS[tier].tokens);
        }
        // Legacy spellings must resolve to the same frozen object.
        expect(tokenCapsFor("7x")).toBe(PLANS.plus.tokens);
        expect(tokenCapsFor("15x")).toBe(PLANS.pro.tokens);
        expect(tokenCapsFor("3x")).toBe(PLANS.go.tokens);
      });

      it("denies the day window at exactly PLANS[tier].tokens.perDay with no override", async () => {
        for (const tier of PLAN_TIERS) {
          const { actorUserId, run } = await seedRun(tier);
          const caps = PLANS[tier].tokens;
          // No tokenCaps / usdCaps override: the service must fall back to plans.ts.
          const service = new RunQuotaService(db, {
            now: () => new Date("2026-10-24T12:00:00.000Z"),
          });
          const fill = await service.reserveModelCall({
            actorUserId,
            runId: run.id,
            reservationKey: `${tier}:fill-day`,
            inputTokens: caps.perDay,
            maxOutputTokens: 0,
          });
          expect(fill.ok, `${tier} must allow its own advertised daily allowance`).toBe(true);

          const over = await service.reserveModelCall({
            actorUserId,
            runId: run.id,
            reservationKey: `${tier}:over-day`,
            inputTokens: 1,
            maxOutputTokens: 0,
          });
          expect(over.ok).toBe(false);
          if (over.ok) throw new Error("unreachable");
          expect(over.window).toBe("day");
          expect(over.resetsAt.toISOString()).toBe("2026-10-25T00:00:00.000Z");
        }
      }, 60_000);

      it("denies the month window at exactly PLANS.free.tokens.perMonth with no override", async () => {
        const { actorUserId, run } = await seedRun("free");
        const caps = PLANS.free.tokens;
        // Fill the month from PREVIOUS days so today's day counter stays empty
        // and the refusal can only come from the monthly window.
        const dayTokens = caps.perDay;
        const daysNeeded = Math.round(caps.perMonth / dayTokens);
        expect(daysNeeded * dayTokens).toBe(caps.perMonth);
        let filled = 0;
        for (let day = 1; day <= 31 && filled < daysNeeded; day += 1) {
          if (day === 24) continue; // keep "today" empty
          await runUsage.record(db, {
            userId: actorUserId,
            sessionId: newId(),
            runId: newId(),
            model: "test-model",
            inputTokens: dayTokens,
            outputTokens: 0,
            createdAt: new Date(Date.UTC(2026, 9, day, 12)),
          });
          filled += 1;
        }
        expect(filled).toBe(daysNeeded);

        const service = new RunQuotaService(db, {
          now: () => new Date("2026-10-24T12:00:00.000Z"),
        });
        const over = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "free:over-month",
          inputTokens: 1,
          maxOutputTokens: 0,
        });
        expect(over.ok).toBe(false);
        if (over.ok) throw new Error("unreachable");
        expect(over.window).toBe("month");
        expect(over.resetsAt.toISOString()).toBe("2026-11-01T00:00:00.000Z");
      }, 60_000);

      it("derives the project-file cap from the plan table, not from plan rows or a copy", async () => {
        // `projectFileCap` used to index a hardcoded [80,100,150,250] by the
        // user's ordinal in the LIVE enabled `plans` rows. Two ways that
        // silently enforces a different number than `plans.ts` advertises:
        // a fresh install has no plan rows at all, and /admin can disable or
        // reorder a plan.
        const { actorUserId } = await seedRun("pro");
        expect(await projectFileCap(db, actorUserId)).toBe(PLANS.pro.projectFiles);

        for (const tier of PLAN_TIERS) {
          await billingUsers.setTier(db, actorUserId, tier, null);
          expect(await projectFileCap(db, actorUserId), tier).toBe(PLANS[tier].projectFiles);
        }

        // Legacy spellings resolve to the tier they mean.
        await billingUsers.setTier(db, actorUserId, "15x", null);
        expect(await projectFileCap(db, actorUserId)).toBe(PLANS.pro.projectFiles);

        // Disabling or reordering plan rows must not shift a paid tier's cap.
        const go = (await plansRepo.list(db)).find((row) => row.id === "go");
        if (go !== undefined) {
          await plansRepo.setEnabled(db, "go", false);
          await billingUsers.setTier(db, actorUserId, "pro", null);
          expect(await projectFileCap(db, actorUserId)).toBe(PLANS.pro.projectFiles);
          await plansRepo.setEnabled(db, "go", true);
        }
      }, 60_000);

      it("applies PLANS[tier].storageGb and PLANS[tier].uploads with no override", async () => {
        for (const tier of PLAN_TIERS) {
          const { actorUserId, session } = await seedRun(tier);
          const plan = PLANS[tier];
          const store = new StorageReservationStore(db, {
            now: () => new Date("2026-10-24T12:00:00.000Z"),
          });
          const atCap = plan.storageGb * 1024 ** 3;
          const fits = await store.reserve({
            reservationId: newId(),
            ownerUserId: actorUserId,
            uploaderUserId: actorUserId,
            sessionId: session.id,
            declaredBytes: atCap,
          });
          expect(fits.ok, `${tier} must allow exactly its advertised storage`).toBe(true);
          const over = await store.reserve({
            reservationId: newId(),
            ownerUserId: actorUserId,
            uploaderUserId: actorUserId,
            sessionId: session.id,
            declaredBytes: 1,
          });
          expect(over.ok).toBe(false);
          if (over.ok) throw new Error("unreachable");
          expect(over.scope).toBe("storage");
        }
      }, 90_000);
    });

    // -----------------------------------------------------------------------
    // 2. Window rollover at the exact UTC boundary
    // -----------------------------------------------------------------------

    describe("daily and monthly windows roll over at the exact UTC boundary", () => {
      it("refuses at 23:59:59.999 and allows at 00:00:00.000 of the next UTC day", async () => {
        const { actorUserId, run } = await seedRun("free");
        const caps = PLANS.free.tokens;
        const now = clock(new Date("2026-10-24T23:59:59.999Z"));
        const service = new RunQuotaService(db, { now });

        const fill = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "day:fill",
          inputTokens: caps.perDay,
          maxOutputTokens: 0,
        });
        expect(fill.ok).toBe(true);

        const refused = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "day:refused",
          inputTokens: 1,
          maxOutputTokens: 0,
        });
        expect(refused.ok).toBe(false);
        if (refused.ok) throw new Error("unreachable");
        expect(refused.window).toBe("day");
        // The refusal points at the very next UTC midnight, not +24h from now.
        expect(refused.resetsAt.toISOString()).toBe("2026-10-25T00:00:00.000Z");

        const before = await counters(actorUserId);
        const dayBefore = before.find((row) => row.window_kind === "day")!;
        expect(dayBefore.window_start.toISOString()).toBe("2026-10-24T00:00:00.000Z");
        expect(dayBefore.window_end.toISOString()).toBe("2026-10-25T00:00:00.000Z");
        expect(dayBefore.reserved_tokens).toBe(String(caps.perDay));

        // One millisecond later is a brand-new window with a zero counter.
        now.set(new Date("2026-10-25T00:00:00.000Z"));
        const allowed = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "day:next",
          inputTokens: 1,
          maxOutputTokens: 0,
        });
        expect(allowed.ok).toBe(true);

        const after = await counters(actorUserId);
        const days = after.filter((row) => row.window_kind === "day");
        expect(days.map((row) => row.window_start.toISOString())).toEqual([
          "2026-10-24T00:00:00.000Z",
          "2026-10-25T00:00:00.000Z",
        ]);
        expect(days[1]!.reserved_tokens).toBe("1");
        // The previous day's hold is untouched by the new day's reservation.
        expect(days[0]!.reserved_tokens).toBe(String(caps.perDay));
      }, 60_000);

      it("refuses at 23:59:59.999 on the last UTC day and allows at the first of the next month", async () => {
        const { actorUserId, run } = await seedRun("free");
        const caps = PLANS.free.tokens;
        const dayTokens = caps.perDay;
        const daysNeeded = Math.round(caps.perMonth / dayTokens);
        // Fill days 1..30 of October (the 31st is "today" and stays empty).
        for (let day = 1; day <= daysNeeded; day += 1) {
          await runUsage.record(db, {
            userId: actorUserId,
            sessionId: newId(),
            runId: newId(),
            model: "test-model",
            inputTokens: dayTokens,
            outputTokens: 0,
            createdAt: new Date(Date.UTC(2026, 9, day, 12)),
          });
        }

        const now = clock(new Date("2026-10-31T23:59:59.999Z"));
        const service = new RunQuotaService(db, { now });
        const refused = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "month:refused",
          inputTokens: 1,
          maxOutputTokens: 0,
        });
        expect(refused.ok).toBe(false);
        if (refused.ok) throw new Error("unreachable");
        expect(refused.window).toBe("month");
        expect(refused.resetsAt.toISOString()).toBe("2026-11-01T00:00:00.000Z");

        const october = (await counters(actorUserId)).filter((row) => row.window_kind === "month");
        expect(october.map((row) => row.window_start.toISOString())).toEqual([
          "2026-10-01T00:00:00.000Z",
        ]);
        expect(october[0]!.window_end.toISOString()).toBe("2026-11-01T00:00:00.000Z");

        now.set(new Date("2026-11-01T00:00:00.000Z"));
        const allowed = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "month:next",
          inputTokens: 1,
          maxOutputTokens: 0,
        });
        expect(allowed.ok).toBe(true);
        const november = (await counters(actorUserId)).filter(
          (row) => row.window_kind === "month" && row.window_start.toISOString().startsWith("2026-11"),
        );
        expect(november).toHaveLength(1);
        expect(november[0]!.reserved_tokens).toBe("1");
        expect(november[0]!.used_tokens).toBe("0");
      }, 60_000);

      it("releases a hold against the window it was taken in, not the current one", async () => {
        const { actorUserId, run } = await seedRun("free");
        const now = clock(new Date("2026-10-24T23:59:59.999Z"));
        const service = new RunQuotaService(db, { now });
        const reservation = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "rollover:release",
          inputTokens: 100,
          maxOutputTokens: 0,
        });
        if (!reservation.ok) throw new Error("reservation refused");
        expect((await counters(actorUserId)).find((r) => r.window_kind === "day")!.reserved_tokens)
          .toBe("100");

        // The release lands after midnight: the hold must come off day 1.
        now.set(new Date("2026-10-25T00:00:01.000Z"));
        await service.releaseModelCall(reservation.reservationId);

        const days = (await counters(actorUserId)).filter((r) => r.window_kind === "day");
        expect(days.map((row) => row.window_start.toISOString())).toEqual([
          "2026-10-24T00:00:00.000Z",
        ]);
        expect(days[0]!.reserved_tokens).toBe("0");
        expect(days[0]!.used_tokens).toBe("0");
      }, 60_000);

      it("charges a call that settles after the UTC day rolls, and never counts it twice", async () => {
        const { actorUserId, run } = await seedRun("free");
        const now = clock(new Date("2026-10-24T23:59:59.999Z"));
        const service = new RunQuotaService(db, { now });
        const reservation = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "rollover:settle",
          inputTokens: 100,
          maxOutputTokens: 0,
        });
        if (!reservation.ok) throw new Error("reservation refused");

        // The provider call finishes after midnight: the charge must survive
        // the boundary (it is real consumption) while the day-1 hold clears.
        now.set(new Date("2026-10-25T00:00:01.000Z"));
        await service.settleModelCall({
          reservationId: reservation.reservationId,
          usage: { inputTokens: 40, outputTokens: 10 },
        });

        const days = (await counters(actorUserId)).filter((r) => r.window_kind === "day");
        expect(days.map((row) => row.window_start.toISOString())).toEqual([
          "2026-10-24T00:00:00.000Z",
          "2026-10-25T00:00:00.000Z",
        ]);
        expect(days[0]!.reserved_tokens).toBe("0");
        expect(days[0]!.used_tokens).toBe("0");
        expect(days[1]!.used_tokens).toBe("50");
        expect(days[1]!.reserved_tokens).toBe("0");
        const ledger = await scratch.client`
          SELECT count(*)::int AS n FROM run_usage
           WHERE quota_reservation_id = ${reservation.reservationId}`;
        expect(ledger).toEqual([{ n: 1 }]);
      }, 60_000);
    });

    // -----------------------------------------------------------------------
    // 3. Idempotency replay never double-debits
    // -----------------------------------------------------------------------

    describe("a replayed idempotency key does not double-debit", () => {
      it("replays admission and reservation without adding allowance a second time", async () => {
        const { actorUserId, run } = await seedRun("free");
        const service = new RunQuotaService(db, {
          now: () => new Date("2026-10-24T12:00:00.000Z"),
        });
        const admission = {
          actorUserId,
          source: "interactive" as const,
          runId: run.id,
          idempotencyKey: `run:${run.id}:interactive`,
        };
        expect(await service.admitRun(admission)).toEqual({ ok: true });
        expect(await service.admitRun(admission)).toEqual({ ok: true });
        const admissions = await scratch.client`
          SELECT count(*)::int AS n FROM usage_run_admissions
           WHERE actor_user_id = ${actorUserId}`;
        expect(admissions).toEqual([{ n: 1 }]);

        const reservation = {
          actorUserId,
          runId: run.id,
          reservationKey: "replay:model-call:1",
          inputTokens: 40,
          maxOutputTokens: 10,
          requestedModel: "test-model",
        };
        const first = await service.reserveModelCall(reservation);
        const second = await service.reserveModelCall(reservation);
        expect(first.ok).toBe(true);
        expect(second).toEqual(first);
        expect((await counters(actorUserId)).find((r) => r.window_kind === "day")!.reserved_tokens)
          .toBe("50");

        // A changed payload under the same key is a conflict, never a second hold.
        await expect(
          service.reserveModelCall({ ...reservation, maxOutputTokens: 11 }),
        ).rejects.toThrow(/idempotency_conflict/);
        expect((await counters(actorUserId)).find((r) => r.window_kind === "day")!.reserved_tokens)
          .toBe("50");
      }, 60_000);

      it("settles a replayed reservation once and never double-charges the counters", async () => {
        const { actorUserId, run } = await seedRun("free");
        const service = new RunQuotaService(db, {
          now: () => new Date("2026-10-24T12:00:00.000Z"),
        });
        const reservation = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "replay:settle:1",
          inputTokens: 40,
          maxOutputTokens: 10,
        });
        if (!reservation.ok) throw new Error("reservation refused");
        const usage = {
          inputTokens: 30,
          outputTokens: 5,
          cacheReadTokens: 7,
          cacheWriteTokens: 3,
          requestedModel: "test-model",
          costUsd: "0.25",
          costSource: "provider" as const,
          billingClass: "ovid_allowance" as const,
        };
        await service.settleModelCall({ reservationId: reservation.reservationId, usage });
        await service.settleModelCall({ reservationId: reservation.reservationId, usage });

        const ledger = await scratch.client`
          SELECT count(*)::int AS n, sum(input_tokens)::int AS i, sum(output_tokens)::int AS o
            FROM run_usage WHERE quota_reservation_id = ${reservation.reservationId}`;
        expect(ledger).toEqual([{ n: 1, i: 30, o: 5 }]);

        const day = (await counters(actorUserId)).find((r) => r.window_kind === "day")!;
        // Charged once: used is the actual, and the hold is fully released.
        expect(day.used_tokens).toBe("35");
        expect(day.reserved_tokens).toBe("0");
        expect(day.used_usd).toBe("0.2500000000");

        // A different payload after settlement is a conflict, not a second charge.
        await expect(
          service.settleModelCall({
            reservationId: reservation.reservationId,
            usage: { ...usage, outputTokens: 6 },
          }),
        ).rejects.toThrow(/idempotency_conflict/);
        const after = (await counters(actorUserId)).find((r) => r.window_kind === "day")!;
        expect(after.used_tokens).toBe("35");
      }, 60_000);
    });

    // -----------------------------------------------------------------------
    // 4. Ovid allowance and BYOK never cross-charge
    // -----------------------------------------------------------------------

    describe("Ovid allowance and BYOK are billed to the right class", () => {
      it("keeps BYOK reservations, ledger rows and counters out of the Ovid allowance", async () => {
        const { actorUserId, run } = await seedRun("free");
        const caps = PLANS.free.tokens;
        const service = new RunQuotaService(db, {
          now: () => new Date("2026-10-24T12:00:00.000Z"),
        });

        // Exhaust the Ovid allowance completely.
        const fill = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "ovid:fill",
          inputTokens: caps.perDay,
          maxOutputTokens: 0,
          billingClass: "ovid_allowance",
        });
        expect(fill.ok).toBe(true);

        // BYOK must still be admitted, and must add nothing to the counters.
        const before = await counters(actorUserId);
        const byok = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "byok:call",
          inputTokens: 5_000,
          maxOutputTokens: 5_000,
          billingClass: "byok",
        });
        expect(byok.ok, "BYOK must not be blocked by an exhausted Ovid allowance").toBe(true);
        if (!byok.ok) throw new Error("unreachable");
        expect(await counters(actorUserId)).toEqual(before);

        await service.settleModelCall({
          reservationId: byok.reservationId,
          usage: {
            inputTokens: 5_000,
            outputTokens: 4_000,
            requestedModel: "byok-model",
            billingClass: "byok",
          },
        });

        // The trigger must not move the Ovid counters for a BYOK ledger row.
        expect(await counters(actorUserId)).toEqual(before);
        const ledger = await scratch.client`
          SELECT billing_class, input_tokens::int AS i, output_tokens::int AS o
            FROM run_usage WHERE quota_reservation_id = ${byok.reservationId}`;
        expect(ledger).toEqual([{ billing_class: "byok", i: 5000, o: 4000 }]);

        // And the Ovid usage view does not see the BYOK call.
        const ovid = await runUsage.totals(db, {
          userId: actorUserId,
          since: new Date("2026-10-01T00:00:00.000Z"),
          until: new Date("2026-11-01T00:00:00.000Z"),
          billingClass: "ovid_allowance",
        });
        expect(ovid.modelCalls).toBe(0);
        const byokView = await runUsage.totals(db, {
          userId: actorUserId,
          since: new Date("2026-10-01T00:00:00.000Z"),
          until: new Date("2026-11-01T00:00:00.000Z"),
          billingClass: "byok",
        });
        expect(byokView.modelCalls).toBe(1);
        expect(byokView.inputTokens).toBe(5_000);
      }, 60_000);

      it("refuses to settle a reservation under the other billing class", async () => {
        const { actorUserId, run } = await seedRun("free");
        const service = new RunQuotaService(db, {
          now: () => new Date("2026-10-24T12:00:00.000Z"),
        });
        const ovid = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "class:ovid",
          inputTokens: 10,
          maxOutputTokens: 10,
          billingClass: "ovid_allowance",
        });
        if (!ovid.ok) throw new Error("reservation refused");
        await expect(
          service.settleModelCall({
            reservationId: ovid.reservationId,
            usage: { inputTokens: 5, outputTokens: 5, billingClass: "byok" },
          }),
        ).rejects.toThrow(/billing_class_conflict/);
        // The failed settle left the hold in place, not silently released.
        const day = (await counters(actorUserId)).find((r) => r.window_kind === "day")!;
        expect(day.reserved_tokens).toBe("20");
        expect(day.used_tokens).toBe("0");
      }, 60_000);
    });

    // -----------------------------------------------------------------------
    // 5. Ambiguous outcome: staged usage is recovered exactly once
    // -----------------------------------------------------------------------

    describe("an ambiguous provider outcome is never double-charged and never silently released", () => {
      it("keeps staged usage pending, refuses release, and settles exactly once", async () => {
        const { actorUserId, run } = await seedRun("free");
        const service = new RunQuotaService(db, {
          now: () => new Date("2026-10-24T12:00:00.000Z"),
        });
        const reservation = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "ambiguous:1",
          inputTokens: 40,
          maxOutputTokens: 10,
        });
        if (!reservation.ok) throw new Error("reservation refused");

        // Simulate a crash between the provider call and the ledger commit:
        // the staging transaction committed, the settle transaction did not.
        await scratch.client`
          UPDATE usage_quota_reservations
             SET actual_input_tokens = 40, actual_output_tokens = 10,
                 actual_cache_read_tokens = 0, actual_cache_write_tokens = 0,
                 requested_model = 'test-model'
           WHERE id = ${reservation.reservationId}`;

        // A release must refuse: the provider call already happened.
        await expect(service.releaseModelCall(reservation.reservationId))
          .rejects.toThrow(/usage_settlement_pending/);

        const pending = await service.pendingSettlements();
        expect(pending.map((row) => row.reservationId)).toContain(reservation.reservationId);

        // Recovery runs twice; the second pass must be a no-op.
        for (let pass = 0; pass < 2; pass += 1) {
          for (const row of await service.pendingSettlements()) {
            await service.settleModelCall({
              reservationId: row.reservationId,
              usage: row.usage,
            });
          }
        }

        const state = await scratch.client`
          SELECT state FROM usage_quota_reservations WHERE id = ${reservation.reservationId}`;
        expect(state).toEqual([{ state: "settled" }]);
        const ledger = await scratch.client`
          SELECT count(*)::int AS n FROM run_usage
           WHERE quota_reservation_id = ${reservation.reservationId}`;
        expect(ledger).toEqual([{ n: 1 }]);
        const day = (await counters(actorUserId)).find((r) => r.window_kind === "day")!;
        expect(day.used_tokens).toBe("50");
        expect(day.reserved_tokens).toBe("0");
        expect(await service.pendingSettlements()).toEqual([]);
      }, 60_000);

      it("releases a reservation whose provider call never produced usage, exactly once", async () => {
        const { actorUserId, run } = await seedRun("free");
        const service = new RunQuotaService(db, {
          now: () => new Date("2026-10-24T12:00:00.000Z"),
        });
        const reservation = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "release:1",
          inputTokens: 40,
          maxOutputTokens: 10,
        });
        if (!reservation.ok) throw new Error("reservation refused");
        await service.releaseModelCall(reservation.reservationId);
        await service.releaseModelCall(reservation.reservationId);

        const day = (await counters(actorUserId)).find((r) => r.window_kind === "day")!;
        expect(day.reserved_tokens).toBe("0");
        expect(day.used_tokens).toBe("0");
        const ledger = await scratch.client`
          SELECT count(*)::int AS n FROM run_usage
           WHERE quota_reservation_id = ${reservation.reservationId}`;
        expect(ledger).toEqual([{ n: 0 }]);
      }, 60_000);

      it("releases a hold orphaned by a crash before the provider call, exactly once", async () => {
        const { actorUserId, run } = await seedRun("free");
        const now = new Date("2026-10-24T12:00:00.000Z");
        const service = new RunQuotaService(db, { now: () => now });
        // The owner took a hold and died before staging any usage. Nothing can
        // ever charge or release it: `releaseModelCall` is only called by the
        // recorder that reserved it, and `pendingSettlements` needs staged
        // actuals. The actor's allowance would stay spent forever.
        const reservation = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "abandoned:1",
          inputTokens: 40,
          maxOutputTokens: 10,
        });
        if (!reservation.ok) throw new Error("reservation refused");
        expect(await service.pendingSettlements()).toEqual([]);
        expect((await counters(actorUserId)).find((r) => r.window_kind === "day")!.reserved_tokens)
          .toBe("50");

        // While the run is still active the hold is NOT abandoned: a live
        // stream may still settle it.
        expect(await service.abandonedReservations({ now })).toEqual([]);

        await runs.finish(db, run.id, "failed", "run_lost");
        // ...and not until the sweep window has passed either.
        expect(await service.abandonedReservations({ now })).toEqual([]);
        const later = new Date(now.getTime() + 2 * 3_600_000);
        const abandoned = await service.abandonedReservations({ now: later });
        expect(abandoned.map((row) => row.reservationId)).toEqual([reservation.reservationId]);

        expect(await service.sweepAbandonedReservations({ now: later }))
          .toEqual([{ reservationId: reservation.reservationId, actorUserId, runId: run.id }]);
        // A second pass finds nothing and cannot release twice.
        expect(await service.sweepAbandonedReservations({ now: later })).toEqual([]);

        const day = (await counters(actorUserId)).find((r) => r.window_kind === "day")!;
        expect(day.reserved_tokens).toBe("0");
        expect(day.used_tokens).toBe("0");
        const ledger = await scratch.client`
          SELECT count(*)::int AS n FROM run_usage
           WHERE quota_reservation_id = ${reservation.reservationId}`;
        expect(ledger).toEqual([{ n: 0 }]);
      }, 60_000);

      it("never releases an abandoned hold whose usage was staged after the sweep read", async () => {
        const { actorUserId, run } = await seedRun("free");
        const now = new Date("2026-10-24T12:00:00.000Z");
        const service = new RunQuotaService(db, { now: () => now });
        const reservation = await service.reserveModelCall({
          actorUserId,
          runId: run.id,
          reservationKey: "abandoned:staged",
          inputTokens: 40,
          maxOutputTokens: 10,
        });
        if (!reservation.ok) throw new Error("reservation refused");
        await runs.finish(db, run.id, "failed", "run_lost");
        const later = new Date(now.getTime() + 2 * 3_600_000);
        const candidates = await service.abandonedReservations({ now: later });
        expect(candidates).toHaveLength(1);

        // The settlement commits between the candidate read and the release.
        await service.settleModelCall({
          reservationId: reservation.reservationId,
          usage: { inputTokens: 40, outputTokens: 10 },
        });
        expect(await service.sweepAbandonedReservations({ now: later })).toEqual([]);

        const day = (await counters(actorUserId)).find((r) => r.window_kind === "day")!;
        expect(day.used_tokens).toBe("50");
        expect(day.reserved_tokens).toBe("0");
      }, 60_000);
    });
  },
);
