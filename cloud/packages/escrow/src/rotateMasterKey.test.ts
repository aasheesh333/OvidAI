import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "@ovid/db";
import { createEnvelopeCrypto } from "./envelope.js";
import { byokRecordId } from "./provider.js";
import { rotateMasterKey } from "./rotateMasterKey.js";

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
});
