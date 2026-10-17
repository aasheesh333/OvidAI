import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { Decimal } from "decimal.js";
import { discounted, money, type Money } from "@ovid/money";
import { imagesRepo, type Db } from "@ovid/db";
import { closeDb, resetTestDb, TEST_DATABASE_URL } from "../test/env.js";
import { createImageLedger } from "./ledger.js";
import { ImageError } from "./types.js";

/**
 * Port of the ledger half of server/images/tests/test_images.py plus
 * parallel_images_receipts_test.py and parallel_images_retention_test.py,
 * against real Postgres (TEST_DATABASE_URL).
 *
 * Value fidelity: Python prints `str(discounted(...))` with trailing zeros;
 * decimal.js canonicalizes them away. Assertions therefore compare Money by
 * VALUE where a Python golden string is byte-strict, and assert the stored
 * `charged` equals `discounted(actual).toString()` (the wire contract).
 */

const REQUEST = "request-1234";
const FINGERPRINT = "f".repeat(64);
const RESPONSE = {
  model: "ovid-image",
  data: [{ b64_json: "QUJD", mime_type: "image/png" }],
};

function eqMoney(actual: Money | null, expected: string): void {
  expect(actual).not.toBeNull();
  expect(actual!.equals(new Decimal(expected))).toBe(true);
}

async function imageError(promise: Promise<unknown>): Promise<ImageError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(ImageError);
    return error as ImageError;
  }
  throw new Error("expected ImageError");
}

describe.skipIf(!TEST_DATABASE_URL)("image ledger (Postgres port)", () => {
  let db: Db;
  let now: number;
  let ledger: ReturnType<typeof createImageLedger>;
  let account: string;
  let seq = 0;

  const clock = () => now;
  const beginFor = (
    target: ReturnType<typeof createImageLedger>,
    account: string,
    request: string,
  ) => target.begin(account, request, FINGERPRINT, money("0.30"), money("10"), "default");

  const begin = (
    account: string,
    request: string,
    opts: { fingerprint?: string; reservation?: Money; budget?: Money; window?: string } = {},
  ) =>
    ledger.begin(
      account,
      request,
      opts.fingerprint ?? FINGERPRINT,
      opts.reservation ?? money("0.30"),
      opts.budget ?? money("10"),
      opts.window ?? "default",
    );

  beforeAll(async () => {
    db = await resetTestDb();
  }, 60_000);

  afterAll(async () => {
    await closeDb(db);
  });

  beforeEach(() => {
    now = 1_000;
    // Unique account per test: ledger rows are intentionally durable across
    // restarts, so tests must not share an idempotency namespace.
    account = `owner-${++seq}-${Date.now().toString(36)}`;
    ledger = createImageLedger(db, { clock });
  });

  // -------------------------------------------------------------------------
  // Happy path + replay
  // -------------------------------------------------------------------------

  it("settles with the discounted exact string and replays the stored response", async () => {
    await begin(account, REQUEST);
    const result = await ledger.settle(account, REQUEST, money("0.10"), RESPONSE);

    expect(result.model).toBe("ovid-image");
    expect(result.data).toEqual(RESPONSE.data);
    const receipt = result.receipt as Record<string, unknown>;
    expect(receipt).toEqual({
      account_id: account,
      request_id: REQUEST,
      fingerprint: FINGERPRINT,
      state: "confirmed",
      charged: discounted(money("0.10")).toString(),
    });
    // exact value against the Python vector (0.10 -> 0.0300)
    eqMoney(money(receipt.charged as string), "0.0300");
    eqMoney(await ledger.spent(account), "0.0300");

    const replayed = await ledger.replay(account, REQUEST);
    expect(replayed).toEqual(result);
    expect((replayed.receipt as Record<string, unknown>).charged).toBe(receipt.charged);
  });

  it("preserves a 29-digit numeric provider cost exactly across a restart", async () => {
    const actual = "0.12345678901234567890123456789";
    await begin(account, REQUEST);
    const first = await ledger.settle(account, REQUEST, money(actual), RESPONSE);
    const receipt = first.receipt as Record<string, unknown>;

    expect(receipt.charged).toBe(discounted(money(actual)).toString());
    eqMoney(money(receipt.charged as string), "0.0370370367037037036703703703670");
    expect(receipt.state).toBe("confirmed");
    expect(receipt.fingerprint).toMatch(/^[0-9a-f]{64}$/);

    const restarted = createImageLedger(db, { clock });
    expect(await restarted.replay(account, REQUEST)).toEqual(first);
    expect(await restarted.receipt(account, REQUEST)).toEqual(receipt);
    eqMoney(await restarted.spent(account), "0.0370370367037037036703703703670");
    expect(JSON.stringify(first)).not.toContain("fixture");
  });

  it("done is idempotent: a second settle cannot overwrite charge or response", async () => {
    await begin(account, REQUEST);
    const first = await ledger.settle(account, REQUEST, money("0.123456"), RESPONSE);
    const other = { model: "ovid-image", data: [{ b64_json: "different" }] };

    const second = await ledger.settle(account, REQUEST, money("9"), other);
    expect(second).toEqual(first);
    expect(second.data).toEqual(RESPONSE.data);

    await ledger.fail(account, REQUEST); // no-op on a done row
    expect(await ledger.replay(account, REQUEST)).toEqual(first);
    eqMoney(await ledger.spent(account), "0.0370368");
    expect((await ledger.receipt(account, REQUEST)).charged).toBe(
      discounted(money("0.123456")).toString(),
    );
  });

  it("begin replays a done row and survives a budget-window reset", async () => {
    await begin(account, REQUEST, { window: "october" });
    const first = await ledger.settle(account, REQUEST, money("0.1"), RESPONSE);
    const replay = await begin(account, REQUEST, { window: "november" });
    expect(replay).toEqual(first);
    eqMoney(await ledger.spent(account), "0.03");
  });

  it("served model is exposed on the receipt, never the provider id", async () => {
    await begin(account, REQUEST);
    const result = await ledger.settle(
      account,
      REQUEST,
      money("0.1"),
      RESPONSE,
      "gpt-image-1",
    );
    expect((result.receipt as Record<string, unknown>).model).toBe("gpt-image-1");
  });

  // -------------------------------------------------------------------------
  // Idempotency conflicts + existing states
  // -------------------------------------------------------------------------

  it("fingerprint mismatch is 409 idempotency_conflict", async () => {
    await begin(account, REQUEST);
    const error = await imageError(
      ledger.begin(account, REQUEST, "a".repeat(64), money("0.3"), money("10"), "default"),
    );
    expect(error.status).toBe(409);
    expect(error.code).toBe("idempotency_conflict");
  });

  it("existing pending/unknown rows are 409 image_request_pending with a receipt", async () => {
    await begin(account, REQUEST);
    let error = await imageError(begin(account, REQUEST));
    expect(error.code).toBe("image_request_pending");
    expect(error.receipt).toMatchObject({ state: "pending", charged: null });

    await ledger.unknown(account, REQUEST);
    error = await imageError(begin(account, REQUEST));
    expect(error.code).toBe("image_request_pending");
    expect(error.receipt).toMatchObject({ state: "unknown", charged: null });
  });

  it("failed rows answer 409 image_request_failed and replay/begin refuse them", async () => {
    await begin(account, REQUEST);
    await ledger.fail(account, REQUEST);

    for (const attempt of [
      () => begin(account, REQUEST),
      () => ledger.replay(account, REQUEST),
    ]) {
      const error = await imageError(attempt());
      expect(error.code).toBe("image_request_failed");
      expect(error.receipt).toMatchObject({ state: "failed", charged: "0" });
    }

    const receipt = await ledger.receipt(account, REQUEST);
    expect(receipt).toMatchObject({ state: "failed", charged: "0" });
  });

  it("settle refuses a failed row with 409", async () => {
    await begin(account, REQUEST);
    await ledger.fail(account, REQUEST);
    const error = await imageError(ledger.settle(account, REQUEST, money("0.1"), RESPONSE));
    expect(error.code).toBe("image_request_failed");
  });

  // -------------------------------------------------------------------------
  // Budget admission
  // -------------------------------------------------------------------------

  it("reservations count toward admission and prevent overdraw", async () => {
    await begin(account, "req-a", { reservation: money("0.3"), budget: money("1") });
    await begin(account, "req-b", { reservation: money("0.3"), budget: money("1") });
    const error = await imageError(
      begin(account, "req-c", { reservation: money("0.5"), budget: money("1") }),
    );
    expect(error.status).toBe(402);
    expect(error.code).toBe("image_limit_reached");
    eqMoney(await ledger.spent(account, { includePending: true }), "0.6");
  });

  it("two concurrent begins admit only one paid job (advisory-lock serialization)", async () => {
    const outcomes = await Promise.allSettled([
      begin(account, "req-a", { reservation: money("0.3"), budget: money("0.5") }),
      begin(account, "req-b", { reservation: money("0.3"), budget: money("0.5") }),
    ]);
    const fulfilled = outcomes.filter((o) => o.status === "fulfilled");
    const rejected = outcomes.filter((o) => o.status === "rejected");
    expect(fulfilled).toHaveLength(1);
    expect(fulfilled[0]!.status === "fulfilled" && fulfilled[0]!.value).toBeNull();
    expect(rejected).toHaveLength(1);
    const error = (rejected[0] as PromiseRejectedResult).reason as ImageError;
    expect(error.code).toBe("image_limit_reached");
    eqMoney(await ledger.spent(account, { includePending: true }), "0.3");
  });

  it("an unresolved reservation in another window still blocks a window reset", async () => {
    await begin(account, "pending-1234", {
      reservation: money("0.3"),
      budget: money("1"),
      window: "old",
    });
    now += 100_000;
    await ledger.purgeExpired();
    expect((await ledger.receipt(account, "pending-1234")).state).toBe("pending");

    const error = await imageError(
      begin(account, "new-request", {
        reservation: money("0.3"),
        budget: money("0.59"),
        window: "new",
      }),
    );
    expect(error.code).toBe("image_limit_reached");
  });

  it("a sub-cent overdraw is not rounded away", async () => {
    await begin(account, "already-paid", {
      reservation: money("1"),
      budget: money("2"),
    });
    await ledger.settle(
      account,
      "already-paid",
      money("0.00000000000000000000000000001"),
      {},
    );
    const error = await imageError(
      begin(account, "request-1234", {
        reservation: money("0.30"),
        budget: money("0.30"),
      }),
    );
    expect(error.code).toBe("image_limit_reached");
  });

  // -------------------------------------------------------------------------
  // spent()
  // -------------------------------------------------------------------------

  it("spent counts pending/unknown reservations only with includePending", async () => {
    await begin(account, "done-req", { reservation: money("0.3"), budget: money("10") });
    await ledger.settle(account, "done-req", money("0.1"), RESPONSE);
    await begin(account, "pending-req", {
      reservation: money("0.3"),
      budget: money("10"),
      window: "default",
    });
    await begin(account, "unknown-req", {
      reservation: money("0.3"),
      budget: money("10"),
      window: "default",
    });
    await ledger.unknown(account, "unknown-req");

    eqMoney(await ledger.spent(account), "0.03");
    eqMoney(await ledger.spent(account, { includePending: true }), "0.63");

    // window filter: only rows in that window
    const otherWindow = `other-window-${account}`;
    await begin(otherWindow, "x-req", {
      reservation: money("0.3"),
      budget: money("10"),
      window: "elsewhere",
    });
    eqMoney(await ledger.spent(otherWindow, { budgetWindow: "default" }), "0");
    eqMoney(
      await ledger.spent(otherWindow, { budgetWindow: "elsewhere", includePending: true }),
      "0.3",
    );
  });

  // -------------------------------------------------------------------------
  // unknown() / fail()
  // -------------------------------------------------------------------------

  it("unknown never expires and never auto-resubmits", async () => {
    await begin(account, REQUEST);
    await ledger.unknown(account, REQUEST);
    now += 100 * 24 * 60 * 60;
    await ledger.purgeExpired();

    const receipt = await ledger.receipt(account, REQUEST);
    expect(receipt.state).toBe("unknown");
    expect(receipt.charged).toBeNull();

    const error = await imageError(ledger.replay(account, REQUEST));
    expect(error.code).toBe("image_request_pending");
    expect(error.receipt).toMatchObject({ state: "unknown" });
  });

  it("fail zeroes the reservation and keeps the receipt for 90 days", async () => {
    await begin(account, REQUEST);
    await ledger.fail(account, REQUEST);

    const row = await imagesRepo.get(db, account, REQUEST);
    expect(row).toMatchObject({ state: "failed", reserved: "0", charged: "0" });
    expect(row!.receiptUntil).toBe(now + 90 * 24 * 60 * 60);

    eqMoney(await ledger.spent(account, { includePending: true }), "0");

    now += 89 * 24 * 60 * 60;
    expect((await ledger.receipt(account, REQUEST)).state).toBe("failed");
    now += 2 * 24 * 60 * 60;
    const expired = await imageError(ledger.receipt(account, REQUEST));
    expect(expired.status).toBe(410);
    expect(expired.code).toBe("image_receipt_expired");
  });

  it("unknown/fail are no-ops on done rows", async () => {
    await begin(account, REQUEST);
    await ledger.settle(account, REQUEST, money("0.1"), RESPONSE);
    await ledger.unknown(account, REQUEST);
    await ledger.fail(account, REQUEST);
    expect((await imagesRepo.get(db, account, REQUEST))!.state).toBe("done");
  });

  // -------------------------------------------------------------------------
  // Retention + purge
  // -------------------------------------------------------------------------

  it("replay expiry keeps the receipt; receipt expiry is terminal", async () => {
    ledger = createImageLedger(db, {
      clock,
      replayRetention: 10,
      receiptRetention: 20,
    });
    await begin(account, REQUEST);
    const first = await ledger.settle(account, REQUEST, money("0.1"), RESPONSE);
    const charged = (first.receipt as Record<string, unknown>).charged;

    now = 1_010;
    const replayError = await imageError(ledger.replay(account, REQUEST));
    expect(replayError.status).toBe(410);
    expect(replayError.code).toBe("image_replay_expired");
    expect(replayError.receipt).toMatchObject({ state: "confirmed", charged });
    expect((await ledger.receipt(account, REQUEST)).charged).toBe(charged);

    await ledger.purgeExpired();
    expect((await imagesRepo.get(db, account, REQUEST))!.response).toBeNull();

    now = 1_020;
    await ledger.purgeExpired();
    const expired = await imageError(ledger.receipt(account, REQUEST));
    expect(expired.status).toBe(410);
    expect(expired.code).toBe("image_receipt_expired");

    // restarted ledger: done row replays as replay-expired, never resubmits
    const restarted = createImageLedger(db, { clock });
    const restartedError = await imageError(beginFor(restarted, account, REQUEST));
    expect(restartedError.code).toBe("image_replay_expired");
    eqMoney(await restarted.spent(account), "0.03");
  });

  it("purgeExpired bounds and never removes dedup rows, charges or reservations", async () => {
    ledger = createImageLedger(db, {
      clock,
      replayRetention: 10,
      receiptRetention: 20,
    });
    await begin(account, "done-req");
    await ledger.settle(account, "done-req", money("0.1"), RESPONSE);
    await begin(account, "pending-req", { reservation: money("0.3"), budget: money("10") });

    for (const bad of [0, 10_001, -1, 1.5, Number.NaN]) {
      await expect(ledger.purgeExpired(bad)).rejects.toThrow();
    }

    now += 100;
    expect(await ledger.purgeExpired(10_000)).toBeGreaterThanOrEqual(1);

    const done = await imagesRepo.get(db, account, "done-req");
    expect(done).toMatchObject({ state: "done", charged: "0.03", actual: null, response: null });
    const pending = await imagesRepo.get(db, account, "pending-req");
    expect(pending).toMatchObject({ state: "pending", reserved: "0.3" });
    eqMoney(await ledger.spent(account, { includePending: true }), "0.33");
  });

  it("receipt expiry is checked before replay/state on replay and begin", async () => {
    ledger = createImageLedger(db, {
      clock,
      replayRetention: 10,
      receiptRetention: 20,
    });
    await begin(account, REQUEST);
    await ledger.settle(account, REQUEST, money("0.1"), RESPONSE);
    now = 1_020;

    const replayError = await imageError(ledger.replay(account, REQUEST));
    expect(replayError.code).toBe("image_receipt_expired");

    const beginError = await imageError(begin(account, REQUEST));
    expect(beginError.status).toBe(410);
    expect(beginError.code).toBe("image_replay_expired"); // done branch -> _response
    expect(beginError.receipt).toBeNull();
  });

  // -------------------------------------------------------------------------
  // deleteAccount tombstones
  // -------------------------------------------------------------------------

  it("deleteAccount is an idempotent tombstone: reads 410, late settle charges but stores nothing", async () => {
    await begin(account, REQUEST, { reservation: money("0.3"), budget: money("10") });
    await ledger.deleteAccount(account);
    await ledger.deleteAccount(account);

    const settleError = await imageError(
      ledger.settle(account, REQUEST, money("0.10"), RESPONSE),
    );
    expect(settleError.status).toBe(410);
    expect(settleError.code).toBe("image_account_deleted");

    const row = await imagesRepo.get(db, account, REQUEST);
    expect(row).toMatchObject({
      state: "done",
      charged: "0.03",
      actual: null,
      response: null,
      replayUntil: 0,
      receiptUntil: 0,
    });
    eqMoney(await ledger.spent(account), "0.03");

    for (const attempt of [
      () => begin(account, "new-request"),
      () => ledger.receipt(account, REQUEST),
      () => ledger.replay(account, REQUEST),
    ]) {
      const error = await imageError(attempt());
      expect(error.status).toBe(410);
      expect(error.code).toBe("image_account_deleted");
    }

    // settling a row that completed before deletion also answers 410
    const doneError = await imageError(
      ledger.settle(account, REQUEST, money("0.1"), RESPONSE),
    );
    expect(doneError.code).toBe("image_account_deleted");
  });

  it("deletion clears completed blobs but preserves unknown reservations", async () => {
    await begin(account, "done-req");
    await ledger.settle(account, "done-req", money("0.12345678901234567890123456789"), RESPONSE);
    await begin(account, "unknown-req", { reservation: money("0.3"), budget: money("10") });
    await ledger.unknown(account, "unknown-req");

    await ledger.deleteAccount(account);
    expect((await imagesRepo.get(db, account, "done-req"))!.response).toBeNull();
    eqMoney(
      await ledger.spent(account, { includePending: true }),
      "0.3370370367037037036703703703670",
    );
    const error = await imageError(ledger.receipt(account, "done-req"));
    expect(error.status).toBe(410);
    expect(error.code).toBe("image_account_deleted");
  });

  // -------------------------------------------------------------------------
  // Error mapping + not-found
  // -------------------------------------------------------------------------

  it("receipt/settle on an unknown request is 404 image_request_not_found", async () => {
    for (const attempt of [
      () => ledger.receipt("nobody", "missing"),
      () => ledger.replay("nobody", "missing"),
      () => ledger.settle("nobody", "missing", money("0.1"), RESPONSE),
    ]) {
      const error = await imageError(attempt());
      expect(error.status).toBe(404);
      expect(error.code).toBe("image_request_not_found");
    }
  });

  it("invalid actual values map to 502 invalid_image_response and leave the row pending", async () => {
    const bad: unknown[] = ["abc", Number.NaN, Number.POSITIVE_INFINITY, -1, {}, true, "1e999"];
    let i = 0;
    for (const value of bad) {
      const request = `bad-${i++}`;
      await begin(account, request);
      const error = await imageError(
        ledger.settle(account, request, value as Money, RESPONSE),
      );
      expect(error.status, String(value)).toBe(502);
      expect(error.code).toBe("invalid_image_response");
      expect((await imagesRepo.get(db, account, request))!.state).toBe("pending");
    }
  });

  it("invalid reservation/budget values map to 502", async () => {
    let error = await imageError(
      begin(account, "r1", { reservation: "abc" as unknown as Money }),
    );
    expect(error.code).toBe("invalid_image_response");
    error = await imageError(begin(account, "r2", { budget: "1e999" as unknown as Money }));
    expect(error.code).toBe("invalid_image_response");
    expect(await imagesRepo.get(db, account, "r1")).toBeNull();
  });

  it("rejects an invalid retention policy at construction", () => {
    expect(() => createImageLedger(db, { replayRetention: 0 })).toThrow();
    expect(() => createImageLedger(db, { replayRetention: -1 })).toThrow();
    expect(() => createImageLedger(db, { replayRetention: Number.NaN })).toThrow();
    expect(() => createImageLedger(db, { receiptRetention: Number.POSITIVE_INFINITY })).toThrow();
    expect(() =>
      createImageLedger(db, { replayRetention: 20, receiptRetention: 10 }),
    ).toThrow();
    expect(() =>
      createImageLedger(db, {
        replayRetention: true as unknown as number,
        receiptRetention: 10,
      }),
    ).toThrow();
    expect(() => createImageLedger(db)).not.toThrow();
  });
});
