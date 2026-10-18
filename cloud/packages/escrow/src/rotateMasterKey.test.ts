import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createDb, migrate, type Db } from "@ovid/db";
import { createEnvelopeCrypto } from "./envelope.js";
import { byokRecordId } from "./provider.js";
import {
  rotateMasterKey,
  rotationFailureState,
  runRotateMasterKeyCli,
} from "./rotateMasterKey.js";

/**
 * P10 Task 10 — master-key rotation drill (real Postgres).
 *
 * Pins the CLI's contract at the data layer: dry-run validates without
 * writing, a real rotate makes every row decrypt under the new key and fail
 * under the old one, and a wrong old key aborts before the first write.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const OLD_KEY = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const NEW_KEY = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";
const WRONG_KEY = "1111111111111111111111111111111111111111111111111111111111111111";

describe.skipIf(!TEST_DATABASE_URL)("rotate-master-key (real postgres)", () => {
  let db: Db;
  const uids: string[] = [];

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    for (const uid of uids) {
      await db.$client`DELETE FROM byok_keys WHERE user_id = ${uid}`;
      await db.$client`DELETE FROM users WHERE uid = ${uid}`;
    }
    await db.$client.end({ timeout: 5 });
  });

  async function seedRows(count: number): Promise<{
    uid: string;
    ids: string[];
    canaries: string[];
  }> {
    const uid = `rotate-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    uids.push(uid);
    await db.$client`INSERT INTO users (uid) VALUES (${uid})`;

    const crypto = createEnvelopeCrypto(OLD_KEY);
    const ids: string[] = [];
    const canaries: string[] = [];
    for (let index = 0; index < count; index += 1) {
      const id = randomUUID();
      const canary = `sk-CANARY-${randomUUID()}`;
      const envelope = crypto.encrypt(canary, byokRecordId(id));
      await db.$client`
        INSERT INTO byok_keys
          (id, user_id, provider_id, endpoint, label,
           wrapped_dek, iv, ciphertext, tag, status)
        VALUES
          (${id}, ${uid}, ${"openai"}, ${"https://api.example.com/v1"}, ${"drill"},
           ${envelope.wrappedDek}, ${envelope.iv}, ${envelope.ciphertext}, ${envelope.tag},
           ${"active"})
      `;
      ids.push(id);
      canaries.push(canary);
    }
    return { uid, ids, canaries };
  }

  async function readEnvelope(id: string) {
    const [row] = (await db.$client`
      SELECT wrapped_dek, iv, ciphertext, tag FROM byok_keys WHERE id = ${id}
    `) as Array<{ wrapped_dek: string; iv: string; ciphertext: string; tag: string }>;
    return {
      wrappedDek: row!.wrapped_dek,
      iv: row!.iv,
      ciphertext: row!.ciphertext,
      tag: row!.tag,
    };
  }

  it("dry-run validates 3 rows and writes nothing", async () => {
    const { uid, ids } = await seedRows(3);
    const before = await Promise.all(ids.map(readEnvelope));

    const result = await rotateMasterKey({
      db,
      oldKeyHex: OLD_KEY,
      newKeyHex: NEW_KEY,
      userId: uid,
      dryRun: true,
    });

    expect(result.total).toBe(3);
    expect(result.rotated).toBe(0);
    expect(result.failures).toEqual([]);
    const after = await Promise.all(ids.map(readEnvelope));
    expect(after).toEqual(before);
  });

  it("real rotate: new key decrypts the canaries, old key fails", async () => {
    const { uid, ids, canaries } = await seedRows(3);

    const result = await rotateMasterKey({
      db,
      oldKeyHex: OLD_KEY,
      newKeyHex: NEW_KEY,
      userId: uid,
    });
    expect(result.rotated).toBe(3);
    expect(result.failures).toEqual([]);

    const oldCrypto = createEnvelopeCrypto(OLD_KEY);
    const newCrypto = createEnvelopeCrypto(NEW_KEY);
    for (let index = 0; index < ids.length; index += 1) {
      const envelope = await readEnvelope(ids[index]!);
      expect(newCrypto.decrypt(envelope, byokRecordId(ids[index]!))).toBe(canaries[index]);
      expect(() => oldCrypto.decrypt(envelope, byokRecordId(ids[index]!))).toThrow(
        /failed authentication/,
      );
    }
  });

  it("wrong old key aborts before writing anything", async () => {
    const { uid, ids } = await seedRows(2);
    const before = await Promise.all(ids.map(readEnvelope));

    const result = await rotateMasterKey({
      db,
      oldKeyHex: WRONG_KEY,
      newKeyHex: NEW_KEY,
      userId: uid,
    });

    expect(result.rotated).toBe(0);
    expect(result.failures).toHaveLength(2);
    expect(result.failures[0]!.reason).toBe(
      "envelope failed authentication with the old key",
    );
    expect(await Promise.all(ids.map(readEnvelope))).toEqual(before);
  });

  it("refuses identical old/new keys", async () => {
    await expect(
      rotateMasterKey({ db, oldKeyHex: OLD_KEY, newKeyHex: OLD_KEY }),
    ).rejects.toThrow(/identical/);
  });

  it("reports a MIXED table after a mid-run write failure (never 'unchanged')", async () => {
    const { uid, ids } = await seedRows(3);

    // Fail the SECOND per-row write: row 1 rotates, row 2 fails, row 3 is
    // never attempted. The table is genuinely mixed.
    let writeAttempts = 0;
    const realClient = db.$client as unknown as {
      begin<T>(fn: (tx: unknown) => Promise<T>): Promise<T>;
    };
    const clientProxy = new Proxy(realClient as object, {
      get(target, prop) {
        if (prop === "begin") {
          return async (fn: (tx: unknown) => Promise<unknown>) => {
            writeAttempts += 1;
            if (writeAttempts === 2) throw new Error("injected write failure");
            return (target as typeof realClient).begin(fn);
          };
        }
        const value = Reflect.get(target, prop) as unknown;
        return typeof value === "function"
          ? (value as (...args: unknown[]) => unknown).bind(target)
          : value;
      },
      apply(target, _thisArg, args) {
        return Reflect.apply(
          target as unknown as (...a: unknown[]) => unknown,
          target,
          args,
        );
      },
    });
    const proxyDb = new Proxy(db as object, {
      get(target, prop) {
        if (prop === "$client") return clientProxy;
        const value = Reflect.get(target, prop) as unknown;
        return typeof value === "function"
          ? (value as (...args: unknown[]) => unknown).bind(target)
          : value;
      },
    }) as Db;

    const result = await rotateMasterKey({
      db: proxyDb,
      oldKeyHex: OLD_KEY,
      newKeyHex: NEW_KEY,
      userId: uid,
    });

    expect(result.total).toBe(3);
    expect(result.rotated).toBe(1);
    expect(result.failures).toHaveLength(1);
    expect(writeAttempts).toBe(2);

    // Exactly one row moved to the new key; the other two still open with the
    // old key. This is the state the CLI must describe.
    const oldCrypto = createEnvelopeCrypto(OLD_KEY);
    const newCrypto = createEnvelopeCrypto(NEW_KEY);
    let underNew = 0;
    let underOld = 0;
    for (const id of ids) {
      const envelope = await readEnvelope(id);
      try {
        newCrypto.decrypt(envelope, byokRecordId(id));
        underNew += 1;
      } catch {
        expect(() => oldCrypto.decrypt(envelope, byokRecordId(id))).not.toThrow();
        underOld += 1;
      }
    }
    expect({ underNew, underOld }).toEqual({ underNew: 1, underOld: 2 });

    const state = rotationFailureState(result);
    expect(state.mixed).toBe(true);
    expect(state.rotated).toBe(1);
    expect(state.remaining).toBe(2);
    expect(state.summary).toContain("table is MIXED");
    expect(state.summary).toContain("1/3");
    expect(state.guidance).toContain("OLD key");
    expect(state.guidance).toContain("NEW key");
  });

  it("CLI prints the mixed state and counts after a partial failure", async () => {
    process.env.ROTATE_TEST_OLD = OLD_KEY;
    process.env.ROTATE_TEST_NEW = NEW_KEY;
    const errors: string[] = [];
    const errorSpy = vi
      .spyOn(console, "error")
      .mockImplementation((...args: unknown[]) => {
        errors.push(args.map(String).join(" "));
      });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      const code = await runRotateMasterKeyCli(
        [
          "--database-url",
          "postgres://unused.invalid/db",
          "--old-key-env",
          "ROTATE_TEST_OLD",
          "--new-key-env",
          "ROTATE_TEST_NEW",
        ],
        async () => ({
          total: 3,
          rotated: 1,
          dryRun: false,
          failures: [{ id: "row-2", reason: "database write failed" }],
        }),
      );
      expect(code).toBe(1);
      const output = errors.join("\n");
      expect(output).toContain("row-2: FAIL (database write failed)");
      expect(output).toContain("1/3");
      expect(output).toContain("table is MIXED");
      expect(output).not.toContain("table unchanged");
    } finally {
      errorSpy.mockRestore();
      logSpy.mockRestore();
      delete process.env.ROTATE_TEST_OLD;
      delete process.env.ROTATE_TEST_NEW;
    }
  });
});
