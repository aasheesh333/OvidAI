import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { messages, newId, runs, sessions, users } from "./repos.js";
import { runUsage } from "./runUsageRepos.js";
import {
  RUN_SOURCES,
  RunQuotaService,
  StorageReservationStore,
  type QuotaBillingClass,
  type RunSource,
} from "./quotaService.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const NOW = new Date("2026-10-24T12:00:00.000Z");
const TOKEN_CAPS = { perDay: 100, perMonth: 1_000 };

function quota(db: Db, now: () => Date = () => NOW, tokenCaps = TOKEN_CAPS) {
  return new RunQuotaService(db, {
    now,
    tokenCaps,
    usdCaps: { perDay: "10", perMonth: "100" },
  });
}

describe.skipIf(!TEST_DATABASE_URL).sequential("RunQuotaService on isolated real Postgres", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "quota_0038_service");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function seedRun(actorUserId = newId(), ownerUserId = actorUserId) {
    await users.ensure(db, actorUserId, null);
    await users.ensure(db, ownerUserId, null);
    const session = await sessions.create(db, ownerUserId, "quota test");
    const prompt = await messages.append(db, {
      sessionId: session.id,
      role: "user",
      content: "quota test",
    });
    const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    return { actorUserId, ownerUserId, session, run };
  }

  async function counters(actorUserId: string) {
    return scratch.client`
      SELECT window_kind, used_tokens::int, reserved_tokens::int,
             used_usd::text, reserved_usd::text
        FROM usage_quota_counters
       WHERE actor_user_id = ${actorUserId}
       ORDER BY window_kind`;
  }

  it("admits and charges every RunSource, including parent wake, to its initiating actor", async () => {
    const actorUserId = newId();
    for (const source of RUN_SOURCES) {
      const { run } = await seedRun(actorUserId);
      const service = quota(db);
      expect(await service.admitRun({
        actorUserId,
        source,
        runId: run.id,
        idempotencyKey: `admit-${source}`,
      })).toEqual({ ok: true });
      const reservation = await service.reserveModelCall({
        actorUserId,
        runId: run.id,
        reservationKey: `call-${source}`,
        inputTokens: 1,
        maxOutputTokens: 0,
        requestedModel: "auto",
      });
      expect(reservation.ok).toBe(true);
      if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
      await service.settleModelCall({
        reservationId: reservation.reservationId,
        usage: { inputTokens: 1, outputTokens: 0, requestedModel: "auto" },
      });
    }

    expect(RUN_SOURCES).toEqual([
      "interactive",
      "schedule_create",
      "schedule_run_now",
      "schedule_tick",
      "schedule_retry",
      "parent_wake",
      "subagent",
      "collab",
    ]);
    const admissions = await scratch.client`
      SELECT DISTINCT source FROM usage_run_admissions WHERE actor_user_id = ${actorUserId}`;
    expect(admissions.map((row) => row.source).sort()).toEqual([...RUN_SOURCES].sort());
    const usage = await scratch.client`
      SELECT count(*)::int AS calls, sum(input_tokens + output_tokens)::int AS tokens
        FROM run_usage WHERE user_id = ${actorUserId}`;
    expect(usage).toEqual([{ calls: RUN_SOURCES.length, tokens: RUN_SOURCES.length }]);
    const wakeUsage = await scratch.client`
      SELECT count(*)::int AS count FROM usage_run_admissions
       WHERE actor_user_id = ${actorUserId} AND source = 'parent_wake'`;
    expect(wakeUsage[0]?.count).toBe(1);
  });

  it("keeps BYOK telemetry out of Ovid allowance admission, reservations, and counters", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const byokAdmission = await service.admitRun({
      actorUserId,
      source: "collab",
      runId: run.id,
      idempotencyKey: "byok-admission",
      billingClass: "byok",
    });
    expect(byokAdmission).toEqual({ ok: true });
    const byokReservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "byok-call",
      inputTokens: 500,
      maxOutputTokens: 500,
      billingClass: "byok",
    });
    expect(byokReservation.ok).toBe(true);
    if (!byokReservation.ok) throw new Error("BYOK was incorrectly capped");
    await service.settleModelCall({
      reservationId: byokReservation.reservationId,
      usage: { inputTokens: 400, outputTokens: 100, billingClass: "byok" },
    });
    expect(await counters(actorUserId)).toEqual([]);

    const ovidRun = await seedRun(actorUserId);
    expect(await service.admitRun({
      actorUserId,
      source: "interactive",
      runId: ovidRun.run.id,
      idempotencyKey: "ovid-after-byok",
      billingClass: "ovid_allowance",
    })).toEqual({ ok: true });
    const ovidReservation = await service.reserveModelCall({
      actorUserId,
      runId: ovidRun.run.id,
      reservationKey: "ovid-call",
      inputTokens: 60,
      maxOutputTokens: 40,
      billingClass: "ovid_allowance",
    });
    expect(ovidReservation.ok).toBe(true);
    if (!ovidReservation.ok) throw new Error("Ovid reservation unexpectedly exhausted");
    await service.settleModelCall({
      reservationId: ovidReservation.reservationId,
      usage: { inputTokens: 60, outputTokens: 40, billingClass: "ovid_allowance" },
    });

    const blockedRun = await seedRun(actorUserId);
    expect(await service.admitRun({
      actorUserId,
      source: "interactive",
      runId: blockedRun.run.id,
      idempotencyKey: "ovid-at-cap",
      billingClass: "ovid_allowance",
    })).toMatchObject({ ok: false, window: "day" });
    const byokAfterCap = await seedRun(actorUserId);
    expect(await service.admitRun({
      actorUserId,
      source: "collab",
      runId: byokAfterCap.run.id,
      idempotencyKey: "byok-after-ovid-cap",
      billingClass: "byok",
    })).toEqual({ ok: true });

    const ledger = await scratch.client`
      SELECT billing_class, count(*)::int AS calls,
             sum(input_tokens + output_tokens)::int AS tokens
        FROM run_usage WHERE user_id = ${actorUserId}
       GROUP BY billing_class ORDER BY billing_class`;
    expect(ledger).toEqual([
      { billing_class: "byok", calls: 1, tokens: 500 },
      { billing_class: "ovid_allowance", calls: 1, tokens: 100 },
    ]);
    expect((await counters(actorUserId)).map((row) => row.used_tokens)).toEqual([100, 100]);
    expect(await runUsage.totals(db, {
      userId: actorUserId,
      since: new Date("2026-10-24T00:00:00Z"),
      until: new Date("2026-10-25T00:00:00Z"),
      billingClass: "byok",
    })).toMatchObject({ modelCalls: 1, inputTokens: 400, outputTokens: 100 });
    expect(await runUsage.totals(db, {
      userId: actorUserId,
      since: new Date("2026-10-24T00:00:00Z"),
      until: new Date("2026-10-25T00:00:00Z"),
      billingClass: "ovid_allowance",
    })).toMatchObject({ modelCalls: 1, inputTokens: 60, outputTokens: 40 });
  });

  // UNEXECUTED real-Postgres regression under the heavy-command pause.
  it("preserves distinctive options through real forTransaction savepoints and outer rollback/commit", async () => {
    const { actorUserId, run } = await seedRun();
    const distinctiveNow = new Date("2031-04-05T06:07:08.090Z");
    const service = new RunQuotaService(db, {
      now: () => distinctiveNow,
      tokenCaps: { perDay: 7, perMonth: 13 },
      usdCaps: { perDay: "0.0000000007", perMonth: "0.0000000013" },
    });
    const admissionInput = {
      actorUserId,
      source: "collab" as const,
      runId: run.id,
      idempotencyKey: "nested-admission",
    };
    const reservationInput = {
      actorUserId,
      runId: run.id,
      reservationKey: "nested-reservation",
      inputTokens: 3,
      maxOutputTokens: 4,
      requestedModel: "auto",
      maxCostUsd: "0.0000000006",
    };

    await expect(db.transaction(async (tx) => {
      const nested = service.forTransaction(tx as unknown as Db);
      expect(await nested.admitRun(admissionInput)).toEqual({ ok: true });
      const reservation = await nested.reserveModelCall(reservationInput);
      expect(reservation.ok).toBe(true);
      throw new Error("force quota outer rollback");
    })).rejects.toThrow("force quota outer rollback");
    expect(await scratch.client`
      SELECT
        (SELECT count(*)::int FROM usage_run_admissions
          WHERE actor_user_id = ${actorUserId}) AS admissions,
        (SELECT count(*)::int FROM usage_quota_reservations
          WHERE actor_user_id = ${actorUserId}) AS reservations`)
      .toEqual([{ admissions: 0, reservations: 0 }]);
    expect(await counters(actorUserId)).toEqual([]);

    const committed = await db.transaction(async (tx) => {
      const nested = service.forTransaction(tx as unknown as Db);
      const admission = await nested.admitRun(admissionInput);
      const reservation = await nested.reserveModelCall(reservationInput);
      if (!reservation.ok) throw new Error("nested reservation unexpectedly exhausted");
      const tokenLimited = await nested.admitRun({
        ...admissionInput,
        idempotencyKey: "nested-token-cap",
      });
      const usdLimited = await nested.reserveModelCall({
        ...reservationInput,
        reservationKey: "nested-usd-cap",
        inputTokens: 0,
        maxOutputTokens: 0,
        maxCostUsd: "0.0000000002",
      });
      return { admission, reservation, tokenLimited, usdLimited };
    });
    expect(committed.admission).toEqual({ ok: true });
    expect(committed.tokenLimited).toEqual({
      ok: false,
      window: "day",
      resetsAt: new Date("2031-04-06T00:00:00.000Z"),
    });
    expect(committed.usdLimited).toEqual({
      ok: false,
      window: "day",
      resetsAt: new Date("2031-04-06T00:00:00.000Z"),
    });
    expect(await scratch.client`
      SELECT
        (SELECT count(*)::int FROM usage_run_admissions
          WHERE actor_user_id = ${actorUserId}) AS admissions,
        (SELECT count(*)::int FROM usage_quota_reservations
          WHERE actor_user_id = ${actorUserId}) AS reservations`)
      .toEqual([{ admissions: 1, reservations: 1 }]);
    expect(await scratch.client`
      SELECT
        (SELECT created_at = ${distinctiveNow.toISOString()}::timestamptz
           FROM usage_run_admissions
          WHERE actor_user_id = ${actorUserId}
            AND idempotency_key = ${admissionInput.idempotencyKey}) AS admission_clock,
        (SELECT reserved_at = ${distinctiveNow.toISOString()}::timestamptz
            AND day_window_start = ${"2031-04-05T00:00:00.000Z"}::timestamptz
            AND month_window_start = ${"2031-04-01T00:00:00.000Z"}::timestamptz
           FROM usage_quota_reservations
          WHERE id = ${committed.reservation.reservationId}) AS reservation_clock_and_windows`)
      .toEqual([{ admission_clock: true, reservation_clock_and_windows: true }]);
    expect(await counters(actorUserId)).toEqual([
      { window_kind: "day", used_tokens: 0, reserved_tokens: 7, used_usd: "0.0000000000", reserved_usd: "0.0000000006" },
      { window_kind: "month", used_tokens: 0, reserved_tokens: 7, used_usd: "0.0000000000", reserved_usd: "0.0000000006" },
    ]);
  });

  // UNEXECUTED real-Postgres regression under the heavy-command pause.
  it("rejects invalid runtime billingClass before admission or reservation writes", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const invalidBillingClass = "invalid" as unknown as QuotaBillingClass;
    await expect(service.admitRun({
      actorUserId,
      source: "interactive",
      runId: run.id,
      idempotencyKey: "invalid-billing-admission",
      billingClass: invalidBillingClass,
    })).rejects.toThrow("invalid billingClass");
    await expect(service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "invalid-billing-reservation",
      inputTokens: 1,
      maxOutputTokens: 1,
      billingClass: invalidBillingClass,
    })).rejects.toThrow("invalid billingClass");
    expect(await scratch.client`
      SELECT
        (SELECT count(*)::int FROM usage_run_admissions
          WHERE actor_user_id = ${actorUserId}) AS admissions,
        (SELECT count(*)::int FROM usage_quota_reservations
          WHERE actor_user_id = ${actorUserId}) AS reservations`)
      .toEqual([{ admissions: 0, reservations: 0 }]);
    expect(await counters(actorUserId)).toEqual([]);
  });

  // UNEXECUTED real-Postgres regression under the heavy-command pause.
  it("treats billingClass as admission and reservation idempotency identity", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const admissionInput = {
      actorUserId,
      source: "subagent" as const,
      runId: run.id,
      idempotencyKey: "billing-identity-admission",
      billingClass: "ovid_allowance" as const,
    };
    expect(await service.admitRun(admissionInput)).toEqual({ ok: true });
    await expect(service.admitRun({
      ...admissionInput,
      billingClass: "byok" as const,
    })).rejects.toMatchObject({ code: "idempotency_conflict" });

    const reservationInput = {
      actorUserId,
      runId: run.id,
      reservationKey: "billing-identity-reservation",
      inputTokens: 11,
      maxOutputTokens: 19,
      requestedModel: "auto",
      attemptId: newId(),
      maxCostUsd: "0.0000000001",
      billingClass: "ovid_allowance" as const,
    };
    const reservation = await service.reserveModelCall(reservationInput);
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    await expect(service.reserveModelCall({
      ...reservationInput,
      billingClass: "byok" as const,
    })).rejects.toMatchObject({ code: "idempotency_conflict" });

    expect(await scratch.client`
      SELECT billing_class FROM usage_run_admissions
       WHERE actor_user_id = ${actorUserId}`)
      .toEqual([{ billing_class: "ovid_allowance" }]);
    expect(await scratch.client`
      SELECT billing_class FROM usage_quota_reservations
       WHERE id = ${reservation.reservationId}`)
      .toEqual([{ billing_class: "ovid_allowance" }]);
    expect(await counters(actorUserId)).toEqual([
      { window_kind: "day", used_tokens: 0, reserved_tokens: 30, used_usd: "0.0000000000", reserved_usd: "0.0000000001" },
      { window_kind: "month", used_tokens: 0, reserved_tokens: 30, used_usd: "0.0000000000", reserved_usd: "0.0000000001" },
    ]);
  });

  // UNEXECUTED real-Postgres regression under the heavy-command pause.
  it("rejects invalid and mismatched settlement billingClass without staged or ledger mutation", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const reservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "billing-settlement-conflict",
      inputTokens: 5,
      maxOutputTokens: 7,
      requestedModel: "auto",
      billingClass: "ovid_allowance",
    });
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    const invalidBillingClass = "invalid" as unknown as QuotaBillingClass;
    await expect(service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 5, outputTokens: 7, billingClass: invalidBillingClass },
    })).rejects.toThrow("invalid billingClass");
    await expect(service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 5, outputTokens: 7, billingClass: "byok" },
    })).rejects.toMatchObject({ code: "billing_class_conflict" });

    expect(await scratch.client`
      SELECT state, billing_class, requested_model, provider_model,
             actual_input_tokens::int, actual_output_tokens::int,
             actual_cache_read_tokens::int, actual_cache_write_tokens::int,
             cost_usd::text, cost_source, run_usage_id
        FROM usage_quota_reservations WHERE id = ${reservation.reservationId}`)
      .toEqual([{
        state: "reserved",
        billing_class: "ovid_allowance",
        requested_model: "auto",
        provider_model: null,
        actual_input_tokens: null,
        actual_output_tokens: null,
        actual_cache_read_tokens: null,
        actual_cache_write_tokens: null,
        cost_usd: null,
        cost_source: null,
        run_usage_id: null,
      }]);
    expect(await scratch.client`
      SELECT count(*)::int AS count FROM run_usage
       WHERE quota_reservation_id = ${reservation.reservationId}`)
      .toEqual([{ count: 0 }]);
    expect(await counters(actorUserId)).toEqual([
      { window_kind: "day", used_tokens: 0, reserved_tokens: 12, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
      { window_kind: "month", used_tokens: 0, reserved_tokens: 12, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
    ]);
  });

  it("settles actual usage exactly at the reserved input-plus-output boundary", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const reservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "exact-boundary-call",
      inputTokens: 40,
      maxOutputTokens: 10,
      billingClass: "ovid_allowance",
    });
    expect(reservation.ok).toBe(true);
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 40, outputTokens: 10 },
    });
    expect(await scratch.client`
      SELECT sum(input_tokens + output_tokens)::int AS tokens
        FROM run_usage WHERE run_id = ${run.id}`).toEqual([{ tokens: 50 }]);
    expect((await counters(actorUserId)).map((row) => row.used_tokens)).toEqual([50, 50]);
  });

  it("settles actual over-reservation usage and blocks the next allowance call", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const reservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "bounded-call",
      inputTokens: 40,
      maxOutputTokens: 10,
      billingClass: "ovid_allowance",
    });
    expect(reservation.ok).toBe(true);
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 40, outputTokens: 11 },
    });
    expect(await scratch.client`
      SELECT input_tokens, output_tokens FROM run_usage WHERE run_id = ${run.id}`)
      .toEqual([{ input_tokens: 40, output_tokens: 11 }]);
    expect((await counters(actorUserId)).map((row) => row.used_tokens)).toEqual([51, 51]);
    await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 40, outputTokens: 11 },
    });
    expect((await counters(actorUserId)).map((row) => row.used_tokens)).toEqual([51, 51]);
    const next = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "after-over-reservation",
      inputTokens: 40,
      maxOutputTokens: 11,
      billingClass: "ovid_allowance",
    });
    expect(next).toMatchObject({ ok: false, window: "day" });
    expect((await counters(actorUserId)).map((row) => row.used_tokens)).toEqual([51, 51]);
  });

  // UNEXECUTED real-Postgres regression under the heavy-command pause.
  it("recovers staged actual usage without release or double settlement", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const reservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "staged-recovery-call",
      inputTokens: 40,
      maxOutputTokens: 10,
      billingClass: "ovid_allowance",
    });
    expect(reservation.ok).toBe(true);
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    // Model a provider response whose actual facts were staged before a failed
    // ledger commit. No provider is called again during recovery.
    await scratch.client`
      UPDATE usage_quota_reservations
         SET actual_input_tokens = 40, actual_output_tokens = 11,
             actual_cache_read_tokens = 0, actual_cache_write_tokens = 0,
             provider_model = 'served-model', cost_usd = 0.0123456789,
             cost_source = 'litellm'
       WHERE id = ${reservation.reservationId}`;
    const pending = await service.pendingSettlements();
    expect(pending).toHaveLength(1);
    expect(pending[0]).toMatchObject({
      reservationId: reservation.reservationId,
      usage: {
        inputTokens: 40,
        outputTokens: 11,
        providerModel: "served-model",
        costUsd: "0.0123456789",
        costSource: "litellm",
      },
    });
    await expect(service.releaseModelCall(reservation.reservationId))
      .rejects.toMatchObject({ code: "usage_settlement_pending" });
    const recoveredUsage = pending[0]!.usage;
    await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: recoveredUsage,
    });
    expect(await service.pendingSettlements()).toEqual([]);
    expect(await scratch.client`
      SELECT input_tokens, output_tokens, provider_model, cost_usd::text
        FROM run_usage WHERE quota_reservation_id = ${reservation.reservationId}`)
      .toEqual([{ input_tokens: 40, output_tokens: 11, provider_model: "served-model", cost_usd: "0.0123456789" }]);
    const recoveredCounters = await counters(actorUserId);
    expect(recoveredCounters).toEqual([
      { window_kind: "day", used_tokens: 51, reserved_tokens: 0, used_usd: "0.0123456789", reserved_usd: "0.0000000000" },
      { window_kind: "month", used_tokens: 51, reserved_tokens: 0, used_usd: "0.0123456789", reserved_usd: "0.0000000000" },
    ]);

    await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: recoveredUsage,
    });
    expect(await scratch.client`
      SELECT count(*)::int AS count FROM run_usage
       WHERE quota_reservation_id = ${reservation.reservationId}`)
      .toEqual([{ count: 1 }]);
    expect(await counters(actorUserId)).toEqual(recoveredCounters);
    await expect(service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { ...recoveredUsage, outputTokens: 12 },
    })).rejects.toMatchObject({ code: "idempotency_conflict" });
    expect(await scratch.client`
      SELECT count(*)::int AS count FROM run_usage
       WHERE quota_reservation_id = ${reservation.reservationId}`)
      .toEqual([{ count: 1 }]);
    expect(await counters(actorUserId)).toEqual(recoveredCounters);
  });

  it("replays actor run admission after exhaustion and rejects changed idempotency payloads", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const input = {
      actorUserId,
      source: "interactive" as const,
      runId: run.id,
      idempotencyKey: "same-admission",
    };
    expect(await service.admitRun(input)).toEqual({ ok: true });
    const reservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "consume-cap",
      inputTokens: 100,
      maxOutputTokens: 0,
    });
    expect(reservation.ok).toBe(true);
    expect(await service.admitRun(input)).toEqual({ ok: true });
    const other = await seedRun(actorUserId);
    await expect(service.admitRun({ ...input, runId: other.run.id }))
      .rejects.toMatchObject({ code: "idempotency_conflict" });
    const rows = await scratch.client`
      SELECT count(*)::int AS count FROM usage_run_admissions
       WHERE actor_user_id = ${actorUserId} AND idempotency_key = 'same-admission'`;
    expect(rows[0]?.count).toBe(1);
  });

  it("refuses initial admission for a nonexistent run without counters or admission rows", async () => {
    const actorUserId = newId();
    await users.ensure(db, actorUserId, null);
    const service = quota(db);
    const outcome = await service.admitRun({
      actorUserId,
      source: "interactive",
      runId: newId(),
      idempotencyKey: "missing-run-admission",
    }).then(
      () => ({ code: null as string | null }),
      (error: unknown) => ({ code: (error as { code?: string }).code ?? "unexpected_error" }),
    );
    const leaked = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM usage_run_admissions WHERE actor_user_id = ${actorUserId}) AS admissions,
        (SELECT count(*)::int FROM usage_quota_reservations WHERE actor_user_id = ${actorUserId}) AS reservations,
        (SELECT count(*)::int FROM run_usage WHERE user_id = ${actorUserId}) AS usage`;
    expect({
      outcome: outcome.code,
      counters: await counters(actorUserId),
      leaked,
    }).toEqual({
      outcome: "run_not_found",
      counters: [],
      leaked: [{ admissions: 0, reservations: 0, usage: 0 }],
    });
  });

  it("refuses initial reservation for a nonexistent run without counters or reservation rows", async () => {
    const actorUserId = newId();
    await users.ensure(db, actorUserId, null);
    const service = quota(db);
    const outcome = await service.reserveModelCall({
      actorUserId,
      runId: newId(),
      reservationKey: "missing-run-reservation",
      inputTokens: 7,
      maxOutputTokens: 3,
      maxCostUsd: "0.0000000001",
    }).then(
      () => ({ code: null as string | null }),
      (error: unknown) => ({ code: (error as { code?: string }).code ?? "unexpected_error" }),
    );
    const leaked = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM usage_run_admissions WHERE actor_user_id = ${actorUserId}) AS admissions,
        (SELECT count(*)::int FROM usage_quota_reservations WHERE actor_user_id = ${actorUserId}) AS reservations,
        (SELECT count(*)::int FROM run_usage WHERE user_id = ${actorUserId}) AS usage`;
    expect({
      outcome: outcome.code,
      counters: await counters(actorUserId),
      leaked,
    }).toEqual({
      outcome: "run_not_found",
      counters: [],
      leaked: [{ admissions: 0, reservations: 0, usage: 0 }],
    });
  });

  it("preserves captured lineage across release, run/session deletion, and reacquire for exact ledger settlement", async () => {
    const { actorUserId, run, session } = await seedRun();
    const service = quota(db);
    expect(await service.admitRun({
      actorUserId,
      source: "subagent",
      runId: run.id,
      idempotencyKey: "deleted-lineage-admission",
    })).toEqual({ ok: true });
    const input = {
      actorUserId,
      runId: run.id,
      reservationKey: "deleted-lineage-call",
      inputTokens: 3,
      maxOutputTokens: 4,
      requestedModel: "auto",
      maxCostUsd: "0.0000000001",
    };
    const first = await service.reserveModelCall(input);
    if (!first.ok) throw new Error("reservation unexpectedly exhausted");
    await service.releaseModelCall(first.reservationId);

    await scratch.client`DELETE FROM runs WHERE id = ${run.id}`;
    await scratch.client`DELETE FROM messages WHERE session_id = ${session.id}`;
    await scratch.client`DELETE FROM sessions WHERE id = ${session.id}`;
    expect(await service.reserveModelCall(input)).toEqual(first);
    await service.settleModelCall({
      reservationId: first.reservationId,
      usage: {
        inputTokens: 3,
        outputTokens: 4,
        requestedModel: "auto",
        providerModel: "provider/after-delete",
        costUsd: "0.0000000001",
        costSource: "provider",
      },
    });

    const reservation = await scratch.client`
      SELECT state, session_id::text, run_id::text, run_source, run_usage_id,
             cost_usd::text
        FROM usage_quota_reservations WHERE id = ${first.reservationId}`;
    const ledger = await scratch.client`
      SELECT session_id::text, run_id::text, requested_model, provider_model,
             cost_usd::text, cost_source, input_tokens, output_tokens
        FROM run_usage WHERE quota_reservation_id = ${first.reservationId}`;
    expect({ reservation, ledger, counters: await counters(actorUserId) }).toEqual({
      reservation: [{
        state: "settled",
        session_id: session.id,
        run_id: run.id,
        run_source: "subagent",
        run_usage_id: reservation[0]?.run_usage_id,
        cost_usd: "0.0000000001",
      }],
      ledger: [{
        session_id: session.id,
        run_id: run.id,
        requested_model: "auto",
        provider_model: "provider/after-delete",
        cost_usd: "0.0000000001",
        cost_source: "provider",
        input_tokens: 3,
        output_tokens: 4,
      }],
      counters: [
        { window_kind: "day", used_tokens: 7, reserved_tokens: 0, used_usd: "0.0000000001", reserved_usd: "0.0000000000" },
        { window_kind: "month", used_tokens: 7, reserved_tokens: 0, used_usd: "0.0000000001", reserved_usd: "0.0000000000" },
      ],
    });
    expect(reservation[0]?.run_usage_id).not.toBeNull();
  });

  it("refuses counter-only settlement when captured session lineage is absent", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const reservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "missing-lineage-settlement",
      inputTokens: 5,
      maxOutputTokens: 0,
    });
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    // Simulate a pre-repair/corrupt reservation which has no authoritative
    // session key. The service must not hide it with a counter-only settlement.
    await scratch.client`
      UPDATE usage_quota_reservations SET session_id = NULL
       WHERE id = ${reservation.reservationId}`;
    const outcome = await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 5, outputTokens: 0 },
    }).then(
      () => ({ code: null as string | null }),
      (error: unknown) => ({ code: (error as { code?: string }).code ?? "unexpected_error" }),
    );
    const stored = await scratch.client`
      SELECT state, run_usage_id FROM usage_quota_reservations
       WHERE id = ${reservation.reservationId}`;
    const ledger = await scratch.client`
      SELECT count(*)::int AS count FROM run_usage WHERE run_id = ${run.id}`;
    expect({
      outcome: outcome.code,
      stored,
      ledger,
      counters: await counters(actorUserId),
    }).toEqual({
      outcome: "run_lineage_missing",
      stored: [{ state: "reserved", run_usage_id: null }],
      ledger: [{ count: 0 }],
      counters: [
        { window_kind: "day", used_tokens: 0, reserved_tokens: 5, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
        { window_kind: "month", used_tokens: 0, reserved_tokens: 5, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
      ],
    });
  });

  it("atomically admits only one of two instances at the remaining token cap", async () => {
    const { actorUserId, run } = await seedRun();
    const second = createDb(scratch.url, { max: 2 });
    const third = createDb(scratch.url, { max: 2 });
    try {
      const [a, b] = await Promise.all([
        quota(second).reserveModelCall({
          actorUserId, runId: run.id, reservationKey: "race-a",
          inputTokens: 20, maxOutputTokens: 40,
        }),
        quota(third).reserveModelCall({
          actorUserId, runId: run.id, reservationKey: "race-b",
          inputTokens: 20, maxOutputTokens: 40,
        }),
      ]);
      expect([a, b].filter((result) => result.ok)).toHaveLength(1);
      const exhausted = [a, b].find((result) => !result.ok);
      expect(exhausted).toMatchObject({
        ok: false,
        window: "day",
        resetsAt: new Date("2026-10-25T00:00:00.000Z"),
      });
      expect(await counters(actorUserId)).toEqual([
        { window_kind: "day", used_tokens: 0, reserved_tokens: 60, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
        { window_kind: "month", used_tokens: 0, reserved_tokens: 60, used_usd: "0.0000000000", reserved_usd: "0.0000000000" },
      ]);
    } finally {
      await second.$client.end({ timeout: 5 });
      await third.$client.end({ timeout: 5 });
    }
  });

  it("reuses reservation identity without doubling allowance and reacquires it after release", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const input = {
      actorUserId,
      runId: run.id,
      reservationKey: "retryable-call",
      inputTokens: 10,
      maxOutputTokens: 20,
      requestedModel: "auto",
      attemptId: newId(),
    };
    const first = await service.reserveModelCall(input);
    const replay = await service.reserveModelCall(input);
    expect(first.ok).toBe(true);
    expect(replay).toEqual(first);
    await expect(service.reserveModelCall({ ...input, maxOutputTokens: 21 }))
      .rejects.toMatchObject({ code: "idempotency_conflict" });
    expect((await counters(actorUserId))[0]?.reserved_tokens).toBe(30);

    await service.releaseModelCall(first.ok ? first.reservationId : "missing");
    await service.releaseModelCall(first.ok ? first.reservationId : "missing");
    expect((await counters(actorUserId))[0]?.reserved_tokens).toBe(0);
    const reacquired = await service.reserveModelCall(input);
    expect(reacquired).toEqual(first);
    expect((await counters(actorUserId))[0]?.reserved_tokens).toBe(30);
  });

  it("settles once with exact decimal cost and full run/attempt/model lineage", async () => {
    const { actorUserId, run, session } = await seedRun();
    const attemptId = newId();
    const service = quota(db);
    const reservation = await service.reserveModelCall({
      actorUserId,
      runId: run.id,
      reservationKey: "exact-cost",
      inputTokens: 3,
      maxOutputTokens: 4,
      requestedModel: "auto",
      attemptId,
      maxCostUsd: "0.0000000001",
    });
    expect(reservation.ok).toBe(true);
    if (!reservation.ok) return;
    const usage = {
      inputTokens: 3,
      outputTokens: 4,
      cacheReadTokens: 2,
      cacheWriteTokens: 1,
      requestedModel: "auto",
      providerModel: "provider/exact",
      costUsd: "0.0000000001",
      costSource: "provider" as const,
    };
    await service.settleModelCall({ reservationId: reservation.reservationId, usage });
    await service.settleModelCall({ reservationId: reservation.reservationId, usage });
    await expect(service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { ...usage, outputTokens: 5 },
    })).rejects.toMatchObject({ code: "idempotency_conflict" });

    const stored = await scratch.client`
      SELECT state, actual_input_tokens::int, actual_output_tokens::int,
             cost_usd::text, provider_model, run_usage_id
        FROM usage_quota_reservations WHERE id = ${reservation.reservationId}`;
    expect(stored).toEqual([{
      state: "settled",
      actual_input_tokens: 3,
      actual_output_tokens: 4,
      cost_usd: "0.0000000001",
      provider_model: "provider/exact",
      run_usage_id: stored[0]?.run_usage_id,
    }]);
    expect(stored[0]?.run_usage_id).not.toBeNull();
    const ledger = await scratch.client`
      SELECT session_id::text, run_id::text, attempt_id::text, quota_call_id,
             requested_model, provider_model, cost_usd::text, cost_source,
             input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
        FROM run_usage WHERE quota_reservation_id = ${reservation.reservationId}`;
    expect(ledger).toEqual([{
      session_id: session.id,
      run_id: run.id,
      attempt_id: attemptId,
      quota_call_id: "exact-cost",
      requested_model: "auto",
      provider_model: "provider/exact",
      cost_usd: "0.0000000001",
      cost_source: "provider",
      input_tokens: 3,
      output_tokens: 4,
      cache_read_tokens: 2,
      cache_write_tokens: 1,
    }]);
    expect(await counters(actorUserId)).toEqual([
      { window_kind: "day", used_tokens: 7, reserved_tokens: 0, used_usd: "0.0000000001", reserved_usd: "0.0000000000" },
      { window_kind: "month", used_tokens: 7, reserved_tokens: 0, used_usd: "0.0000000001", reserved_usd: "0.0000000000" },
    ]);
    const ledgerCount = await scratch.client`
      SELECT count(*)::int AS count FROM run_usage WHERE quota_reservation_id = ${reservation.reservationId}`;
    expect(ledgerCount[0]?.count).toBe(1);
  });

  it("keeps unknown provider model, cost, and cost source null instead of inventing zeroes", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const reservation = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "unknown-provider",
      inputTokens: 1, maxOutputTokens: 1, requestedModel: "auto",
    });
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 1, outputTokens: 1, requestedModel: "auto" },
    });
    const rows = await scratch.client`
      SELECT requested_model, provider_model, cost_usd, cost_source
        FROM run_usage WHERE quota_reservation_id = ${reservation.reservationId}`;
    expect(rows).toEqual([{
      requested_model: "auto",
      provider_model: null,
      cost_usd: null,
      cost_source: null,
    }]);
  });

  it("releases transient reservations and prevents the next call after mid-run exhaustion", async () => {
    const { actorUserId, run } = await seedRun();
    const service = quota(db);
    const transient = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "transient",
      inputTokens: 40, maxOutputTokens: 0,
    });
    if (!transient.ok) throw new Error("reservation unexpectedly exhausted");
    await service.releaseModelCall(transient.reservationId);
    await expect(service.settleModelCall({
      reservationId: transient.reservationId,
      usage: { inputTokens: 40, outputTokens: 0 },
    })).rejects.toMatchObject({ code: "reservation_released" });
    expect((await counters(actorUserId))[0]?.used_tokens).toBe(0);

    const first = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "first-real-call",
      inputTokens: 70, maxOutputTokens: 0,
    });
    if (!first.ok) throw new Error("reservation unexpectedly exhausted");
    await service.settleModelCall({
      reservationId: first.reservationId,
      usage: { inputTokens: 70, outputTokens: 0 },
    });
    const blocked = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "must-not-reach-provider",
      inputTokens: 31, maxOutputTokens: 0,
    });
    expect(blocked).toEqual({
      ok: false,
      window: "day",
      resetsAt: new Date("2026-10-25T00:00:00.000Z"),
    });
    const exactBoundary = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "exact-boundary",
      inputTokens: 30, maxOutputTokens: 0,
    });
    expect(exactBoundary.ok).toBe(true);
  });

  it("uses existing run_usage as authoritative legacy usage through the database trigger", async () => {
    const { actorUserId, run, session } = await seedRun();
    await runUsage.record(db, {
      userId: actorUserId,
      sessionId: session.id,
      runId: run.id,
      model: "legacy",
      inputTokens: 90,
      outputTokens: 0,
      createdAt: NOW,
    });
    const blocked = await quota(db).reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "legacy-over-cap",
      inputTokens: 11, maxOutputTokens: 0,
    });
    expect(blocked.ok).toBe(false);
    const allowed = await quota(db).reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "legacy-at-cap",
      inputTokens: 10, maxOutputTokens: 0,
    });
    expect(allowed.ok).toBe(true);
  });

  it("enforces USD used+reserved caps with the correct daily reset window", async () => {
    const { actorUserId, run } = await seedRun();
    const service = new RunQuotaService(db, {
      now: () => NOW,
      tokenCaps: { perDay: 1_000, perMonth: 100 },
      usdCaps: { perDay: "0.0000000001", perMonth: "1" },
    });
    const first = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "usd-cap",
      inputTokens: 100, maxOutputTokens: 0, maxCostUsd: "0.0000000001",
    });
    expect(first.ok).toBe(true);
    const usdBlocked = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "usd-over-cap",
      inputTokens: 0, maxOutputTokens: 0, maxCostUsd: "0.0000000001",
    });
    expect(usdBlocked).toEqual({
      ok: false,
      window: "day",
      resetsAt: new Date("2026-10-25T00:00:00.000Z"),
    });
  });

  it("enforces the monthly used+reserved cap with the next-month reset window", async () => {
    const { actorUserId, run } = await seedRun();
    const service = new RunQuotaService(db, {
      now: () => NOW,
      tokenCaps: { perDay: 1_000, perMonth: 100 },
    });
    const first = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "monthly-cap",
      inputTokens: 100, maxOutputTokens: 0,
    });
    if (!first.ok) throw new Error("reservation unexpectedly exhausted");
    await service.settleModelCall({
      reservationId: first.reservationId,
      usage: { inputTokens: 100, outputTokens: 0 },
    });
    const monthBlocked = await service.admitRun({
      actorUserId,
      source: "schedule_retry",
      runId: run.id,
      idempotencyKey: "month-cap-admission",
    });
    expect(monthBlocked).toEqual({
      ok: false,
      window: "month",
      resetsAt: new Date("2026-11-01T00:00:00.000Z"),
    });
  });

  it("charges a collab participant actor and never the host owner", async () => {
    const hostUserId = newId();
    const actorUserId = newId();
    const { run } = await seedRun(actorUserId, hostUserId);
    const service = quota(db);
    expect(await service.admitRun({
      actorUserId,
      source: "collab" satisfies RunSource,
      runId: run.id,
      idempotencyKey: "collab-turn",
    })).toEqual({ ok: true });
    const reservation = await service.reserveModelCall({
      actorUserId, runId: run.id, reservationKey: "collab-model-call",
      inputTokens: 9, maxOutputTokens: 0, requestedModel: "auto",
    });
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    await service.settleModelCall({
      reservationId: reservation.reservationId,
      usage: { inputTokens: 9, outputTokens: 0, requestedModel: "auto" },
    });
    const usageOwners = await scratch.client`
      SELECT user_id, count(*)::int AS count FROM run_usage
       WHERE run_id = ${run.id} GROUP BY user_id`;
    expect(usageOwners).toEqual([{ user_id: actorUserId, count: 1 }]);
    expect(await counters(actorUserId)).toHaveLength(2);
    expect(await counters(hostUserId)).toEqual([]);
  });
});

describe.skipIf(!TEST_DATABASE_URL).sequential("StorageReservationStore on isolated real Postgres", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let clock = NOW;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "quota_0038_storage");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  function store(overrides: { storageBytes?: number; uploads?: { count: number; windowHours: number } } = {}) {
    return new StorageReservationStore(db, {
      now: () => clock,
      storageBytes: overrides.storageBytes ?? 100,
      uploads: overrides.uploads ?? { count: 2, windowHours: 24 },
    });
  }

  async function identities() {
    const ownerUserId = newId();
    const uploaderUserId = newId();
    await users.ensure(db, ownerUserId, null);
    await users.ensure(db, uploaderUserId, null);
    const session = await sessions.create(db, ownerUserId, "collab storage");
    return { ownerUserId, uploaderUserId, sessionId: session.id };
  }

  it("finalizes actual HEAD bytes once, preserves actor/owner separation, and replays identity", async () => {
    const { ownerUserId, uploaderUserId, sessionId } = await identities();
    const service = store();
    const reservation = await service.reserve({
      reservationId: newId(),
      ownerUserId,
      uploaderUserId,
      sessionId,
      declaredBytes: 99,
    });
    expect(reservation.ok).toBe(true);
    expect(await service.reserve({
      reservationId: reservation.ok ? reservation.reservationId : "missing",
      ownerUserId,
      uploaderUserId,
      sessionId,
      declaredBytes: 99,
    })).toEqual(reservation);
    if (!reservation.ok) return;
    expect(await service.finalize({
      reservationId: reservation.reservationId,
      actualBytes: 11,
      contentType: "text/plain",
      etag: "etag-1",
    })).toEqual({ ok: true, reservationId: reservation.reservationId });
    expect(await service.finalize({
      reservationId: reservation.reservationId,
      actualBytes: 11,
      contentType: "text/plain",
      etag: "etag-1",
    })).toEqual({ ok: true, reservationId: reservation.reservationId });
    await expect(service.finalize({
      reservationId: reservation.reservationId,
      actualBytes: 12,
      contentType: "text/plain",
      etag: "etag-1",
    })).rejects.toMatchObject({ code: "idempotency_conflict" });

    const owner = await scratch.client`
      SELECT used_bytes::int, reserved_bytes::int FROM storage_usage_counters
       WHERE owner_user_id = ${ownerUserId}`;
    expect(owner).toEqual([{ used_bytes: 11, reserved_bytes: 0 }]);
    const actorWindow = await scratch.client`
      SELECT used_uploads, reserved_uploads FROM upload_window_counters
       WHERE actor_user_id = ${uploaderUserId}`;
    expect(actorWindow).toEqual([{ used_uploads: 1, reserved_uploads: 0 }]);
    expect(await scratch.client`
      SELECT count(*)::int AS count FROM storage_usage_counters WHERE owner_user_id = ${uploaderUserId}`)
      .toEqual([{ count: 0 }]);
    expect(await scratch.client`
      SELECT count(*)::int AS count FROM upload_window_counters WHERE actor_user_id = ${ownerUserId}`)
      .toEqual([{ count: 0 }]);
    const stored = await scratch.client`
      SELECT state, actor_user_id, owner_user_id, declared_bytes::int, actual_bytes::int,
             actual_content_type, etag
        FROM storage_reservations WHERE id = ${reservation.reservationId}`;
    expect(stored).toEqual([{
      state: "finalized",
      actor_user_id: uploaderUserId,
      owner_user_id: ownerUserId,
      declared_bytes: 99,
      actual_bytes: 11,
      actual_content_type: "text/plain",
      etag: "etag-1",
    }]);
  });

  it("releases failed reservations idempotently and never finalizes released identity", async () => {
    const { ownerUserId, uploaderUserId, sessionId } = await identities();
    const service = store();
    const reservation = await service.reserve({
      reservationId: newId(), ownerUserId, uploaderUserId, sessionId, declaredBytes: 60,
    });
    if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
    await service.release({ reservationId: reservation.reservationId });
    await service.release({ reservationId: reservation.reservationId });
    expect(await scratch.client`
      SELECT used_bytes::int, reserved_bytes::int FROM storage_usage_counters
       WHERE owner_user_id = ${ownerUserId}`)
      .toEqual([{ used_bytes: 0, reserved_bytes: 0 }]);
    expect(await scratch.client`
      SELECT used_uploads, reserved_uploads FROM upload_window_counters
       WHERE actor_user_id = ${uploaderUserId}`)
      .toEqual([{ used_uploads: 0, reserved_uploads: 0 }]);
    await expect(service.finalize({
      reservationId: reservation.reservationId,
      actualBytes: 60,
      contentType: null,
      etag: null,
    })).rejects.toMatchObject({ code: "reservation_released" });
  });

  it("enforces rolling actor upload windows independently of host byte capacity", async () => {
    clock = NOW;
    const { ownerUserId, uploaderUserId, sessionId } = await identities();
    const service = store({ storageBytes: 1_000 });
    for (const reservationId of [newId(), newId()]) {
      expect((await service.reserve({
        reservationId, ownerUserId, uploaderUserId, sessionId, declaredBytes: 1,
      })).ok).toBe(true);
    }
    expect(await service.reserve({
      reservationId: newId(), ownerUserId, uploaderUserId, sessionId, declaredBytes: 1,
    })).toEqual({
      ok: false,
      scope: "upload",
      resetsAt: new Date("2026-10-25T12:00:00.000Z"),
    });
    clock = new Date("2026-10-25T13:00:00.000Z");
    expect((await service.reserve({
      reservationId: newId(), ownerUserId, uploaderUserId, sessionId, declaredBytes: 1,
    })).ok).toBe(true);
    expect(await scratch.client`
      SELECT used_uploads, reserved_uploads FROM upload_window_counters
       WHERE actor_user_id = ${uploaderUserId}`)
      .toEqual([{ used_uploads: 0, reserved_uploads: 1 }]);
    clock = NOW;
  });

  it("serializes two owners' reservations against the host cap across instances", async () => {
    const { ownerUserId, uploaderUserId, sessionId } = await identities();
    const second = createDb(scratch.url, { max: 2 });
    try {
      const other = new StorageReservationStore(second, {
        now: () => NOW,
        storageBytes: 100,
        uploads: { count: 80, windowHours: 3 },
      });
      const [a, b] = await Promise.all([
        store({ uploads: { count: 80, windowHours: 3 } }).reserve({
          reservationId: newId(), ownerUserId, uploaderUserId, sessionId, declaredBytes: 60,
        }),
        other.reserve({
          reservationId: newId(), ownerUserId, uploaderUserId, sessionId, declaredBytes: 60,
        }),
      ]);
      expect([a, b].filter((result) => result.ok)).toHaveLength(1);
      expect([a, b].find((result) => !result.ok)).toMatchObject({ ok: false, scope: "storage" });
      expect(await scratch.client`
        SELECT used_bytes::int, reserved_bytes::int FROM storage_usage_counters
         WHERE owner_user_id = ${ownerUserId}`)
        .toEqual([{ used_bytes: 0, reserved_bytes: 60 }]);
    } finally {
      await second.$client.end({ timeout: 5 });
    }
  });

  it("rechecks actual bytes at finalization instead of trusting a smaller declaration", async () => {
    const { ownerUserId, uploaderUserId, sessionId } = await identities();
    const service = store({ uploads: { count: 80, windowHours: 3 } });
    const first = await service.reserve({
      reservationId: newId(), ownerUserId, uploaderUserId, sessionId, declaredBytes: 60,
    });
    expect((await service.reserve({
      reservationId: newId(), ownerUserId, uploaderUserId, sessionId, declaredBytes: 20,
    })).ok).toBe(true);
    if (!first.ok) return;
    expect(await service.finalize({
      reservationId: first.reservationId,
      actualBytes: 90,
      contentType: null,
      etag: null,
    })).toMatchObject({ ok: false, scope: "storage" });
    expect(await scratch.client`
      SELECT state, declared_bytes::int, actual_bytes FROM storage_reservations WHERE id = ${first.reservationId}`)
      .toEqual([{ state: "reserved", declared_bytes: 60, actual_bytes: null }]);
    expect(await scratch.client`
      SELECT used_bytes::int, reserved_bytes::int FROM storage_usage_counters
       WHERE owner_user_id = ${ownerUserId}`)
      .toEqual([{ used_bytes: 0, reserved_bytes: 80 }]);
  });
});
