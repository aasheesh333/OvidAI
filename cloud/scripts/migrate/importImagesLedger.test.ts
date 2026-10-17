import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
// Loaded via createRequire so Vite does not try to bundle `node:sqlite`
// (Vite 5's static external list predates the builtin).
import { createRequire } from "node:module";
const { DatabaseSync } = createRequire(import.meta.url)("node:sqlite") as {
  DatabaseSync: new (path: string) => {
    exec(sql: string): void;
    prepare(sql: string): { run(...args: unknown[]): unknown; all(): unknown[] };
    close(): void;
  };
};
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "../../apps/mint/src/test/env.js";
import {
  importImagesLedger,
  mapSourceRow,
  readSourceRows,
  REPLAY_RETENTION,
  RECEIPT_RETENTION,
} from "./importImagesLedger.js";
import { ovidDb } from "./runtime.js";

const NOW = 1_800_000_000;

function tempDbPath(): { dir: string; path: string } {
  const dir = mkdtempSync(join(tmpdir(), "ovid-img-import-"));
  return { dir, path: join(dir, "images.sqlite3") };
}

function currentSchema(path: string): DatabaseSync {
  const sqlite = new DatabaseSync(path);
  sqlite.exec(`
    CREATE TABLE image_jobs (
      account TEXT NOT NULL, request TEXT NOT NULL, fingerprint TEXT NOT NULL,
      state TEXT NOT NULL, reserved TEXT NOT NULL, charged TEXT NOT NULL DEFAULT '0',
      actual TEXT, response TEXT, budget_window TEXT NOT NULL,
      served_model TEXT, replay_until INTEGER, receipt_until INTEGER,
      PRIMARY KEY(account, request));
    CREATE TABLE image_deleted_accounts (
      account TEXT PRIMARY KEY, deleted_at INTEGER NOT NULL);
  `);
  return sqlite;
}

describe("importImagesLedger mapping (pure)", () => {
  it("preserves exact money strings and deadlines", () => {
    const columns = new Set([
      "account", "request", "fingerprint", "state", "reserved", "charged",
      "actual", "response", "budget_window", "served_model", "replay_until",
      "receipt_until",
    ]);
    const row = mapSourceRow(
      {
        account: "u1",
        request: "r1",
        fingerprint: "f".repeat(64),
        state: "done",
        reserved: "0.300000000000000000000000000",
        charged: "0.0370370367037037036703703703670",
        actual: "0.123456789012345678901234567890",
        response: JSON.stringify({ model: "ovid-image", data: [] }),
        budget_window: "u1:24h",
        served_model: "ovid-image:img-abc123",
        replay_until: NOW + REPLAY_RETENTION,
        receipt_until: NOW + RECEIPT_RETENTION,
      },
      columns,
      NOW,
    );
    expect(row.reserved).toBe("0.300000000000000000000000000");
    expect(row.charged).toBe("0.0370370367037037036703703703670");
    expect(row.actual).toBe("0.123456789012345678901234567890");
    expect(row.replay_until).toBe(NOW + REPLAY_RETENTION);
    expect(row.receipt_until).toBe(NOW + RECEIPT_RETENTION);
    expect(row.created_at).toBe(NOW);
    expect(row.served_model).toBe("ovid-image:img-abc123");
    expect(row.response).toEqual({ model: "ovid-image", data: [] });
  });

  it("legacy schema (no lease columns): completed rows lose replay, keep 90d receipt; pending/unknown stay unresolved", () => {
    const columns = new Set([
      "account", "request", "fingerprint", "state", "reserved", "charged",
      "actual", "response", "budget_window",
    ]);
    const done = mapSourceRow(
      {
        account: "u1", request: "r1", fingerprint: "f", state: "done",
        reserved: "0.30", charged: "0.09", actual: "0.30",
        response: JSON.stringify({ ok: true }), budget_window: "w",
      },
      columns,
      NOW,
    );
    expect(done.replay_until).toBe(0);
    expect(done.receipt_until).toBe(NOW + RECEIPT_RETENTION);
    expect(done.response).toBeNull();

    const pending = mapSourceRow(
      {
        account: "u1", request: "r2", fingerprint: "f", state: "pending",
        reserved: "1.00", charged: "0", actual: null,
        response: null, budget_window: "w",
      },
      columns,
      NOW,
    );
    expect(pending.replay_until).toBeNull();
    expect(pending.receipt_until).toBeNull();
    expect(pending.reserved).toBe("1.00");
  });

  it("never converts unknown→failed and refuses unknown states", () => {
    const columns = new Set(["account", "request", "fingerprint", "state", "reserved", "charged", "actual", "response", "budget_window", "replay_until", "receipt_until"]);
    const unknown = mapSourceRow(
      { account: "u", request: "r", fingerprint: "f", state: "unknown", reserved: "0.5", charged: "0", actual: null, response: null, budget_window: "w", replay_until: null, receipt_until: null },
      columns,
      NOW,
    );
    expect(unknown.state).toBe("unknown");
    expect(unknown.reserved).toBe("0.5");
    expect(() =>
      mapSourceRow(
        { account: "u", request: "r", fingerprint: "f", state: "failed", reserved: "0", charged: "0", actual: null, response: null, budget_window: "w", replay_until: null, receipt_until: null },
        new Set(["account", "request", "fingerprint", "state", "reserved", "charged", "actual", "response", "budget_window"]),
        NOW,
      ),
    ).not.toThrow(); // failed IS a valid state
    expect(() =>
      mapSourceRow(
        { account: "u", request: "r", fingerprint: "f", state: "refunded", reserved: "0", charged: "0", actual: null, response: null, budget_window: "w", replay_until: null, receipt_until: null },
        columns,
        NOW,
      ),
    ).toThrow(/unknown state/);
  });

  it("refuses invalid JSON responses instead of silently dropping a replay blob", () => {
    expect(() =>
      mapSourceRow(
        { account: "u", request: "r", fingerprint: "f", state: "done", reserved: "0", charged: "0", actual: null, response: "{not json", budget_window: "w", replay_until: 1, receipt_until: 2 },
        new Set(["account", "request", "fingerprint", "state", "reserved", "charged", "actual", "response", "budget_window", "replay_until", "receipt_until"]),
        NOW,
      ),
    ).toThrow(/not valid JSON/);
  });

  it("readSourceRows reads tombstones and orders deterministically", () => {
    const { dir, path } = tempDbPath();
    try {
      const sqlite = currentSchema(path);
      sqlite
        .prepare("INSERT INTO image_jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
        .run("u2", "r2", "f2", "pending", "1.0", "0", null, null, "w2", null, null, null);
      sqlite
        .prepare("INSERT INTO image_jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
        .run("u1", "r1", "f1", "unknown", "0.5", "0", null, null, "w1", null, null, null);
      sqlite.prepare("INSERT INTO image_deleted_accounts VALUES (?,?)").run("gone", 1234);
      sqlite.close();
      const source = readSourceRows(path, NOW);
      expect(source.rows.map((r) => `${r.account}/${r.request}`)).toEqual(["u1/r1", "u2/r2"]);
      expect(source.tombstones).toEqual([{ account: "gone", deleted_at: 1234 }]);
      expect(source.legacy).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe.skipIf(!TEST_DATABASE_URL || !TEST_MINT_REDIS_URL)("importImagesLedger (Postgres)", () => {
  let db: Awaited<ReturnType<typeof resetTestDb>>;
  let redis: Awaited<ReturnType<typeof openFlushedRedis>>;
  let dir = "";
  let path = "";

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    ({ dir, path } = tempDbPath());
    const sqlite = currentSchema(path);
    const insert = sqlite.prepare(
      "INSERT INTO image_jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
    );
    insert.run("u1", "done-1", "f".repeat(64), "done", "0.30", "0.09", "0.30", JSON.stringify({ model: "ovid-image" }), "u1:24h", "ovid-image:img-abc123", NOW + 86_400, NOW + 7_776_000);
    insert.run("u1", "pending-1", "f".repeat(64), "pending", "1.00000000000000000001", "0", null, null, "u1:24h", null, null, null);
    insert.run("u2", "unknown-1", "f".repeat(64), "unknown", "0.123456789012345678901234567890", "0", null, null, "u2:24h", null, null, null);
    insert.run("u2", "failed-1", "f".repeat(64), "failed", "0", "0", null, null, "u2:24h", null, NOW + 7_776_000);
    sqlite.prepare("INSERT INTO image_deleted_accounts VALUES (?,?)").run("gone", 999);
    sqlite.close();
  }, 60_000);

  afterAll(async () => {
    await closeDb(db);
    await closeRedis(redis);
    if (dir !== "") rmSync(dir, { recursive: true, force: true });
  });

  it("refuses to run without --drained", async () => {
    await expect(
      importImagesLedger({ db, sqlitePath: path, drained: false }),
    ).rejects.toThrow(/drain\/stop/);
  });

  it("imports insert-if-absent with exact money and unresolved reservations", async () => {
    const report = await importImagesLedger({ db, sqlitePath: path, drained: true, now: NOW });
    expect(report.rows).toBe(4);
    expect(report.byState).toEqual({ done: 1, pending: 1, unknown: 1, failed: 1 });
    expect(report.tombstones).toBe(1);
    expect(report.unresolved).toEqual([
      { account: "u1", request: "pending-1", state: "pending", reserved: "1.00000000000000000001" },
      { account: "u2", request: "unknown-1", state: "unknown", reserved: "0.123456789012345678901234567890" },
    ]);

    const rows = await ovidDb.imageJobsRepo.listRaw(db);
    const byKey = new Map(rows.map((r) => [`${r.account}/${r.request}`, r]));
    const done = byKey.get("u1/done-1")!;
    expect(done.charged).toBe("0.09");
    expect(done.actual).toBe("0.30");
    expect(done.reserved).toBe("0.30");
    expect(done.replayUntil).toBe(NOW + 86_400);
    expect(done.receiptUntil).toBe(NOW + 7_776_000);
    expect(done.response).toEqual({ model: "ovid-image" });
    expect(byKey.get("u1/pending-1")!.reserved).toBe("1.00000000000000000001");
    expect(byKey.get("u2/unknown-1")!.reserved).toBe("0.123456789012345678901234567890");
    expect(await ovidDb.imageJobsRepo.countByState(db)).toEqual({
      done: 1, pending: 1, unknown: 1, failed: 1,
    });
  });

  it("is idempotent and never rewrites a charge", async () => {
    // Corrupt the Postgres charge, re-run: ON CONFLICT DO NOTHING must keep it.
    await db.$client`UPDATE image_jobs SET charged = '9.99' WHERE account='u1' AND request='done-1'`;
    await importImagesLedger({ db, sqlitePath: path, drained: true, now: NOW });
    const [row] = await db.$client`SELECT charged FROM image_jobs WHERE account='u1' AND request='done-1'`;
    expect(row?.charged).toBe("9.99");
  });
});
