import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "@ovid/db";
import type { EventLog, SystemBus } from "@ovid/events";
import {
  createByokKeyProvider,
  createEnvelopeCrypto,
  byokRecordId,
  EnvelopeAuthError,
  type EnvelopeCrypto,
} from "@ovid/escrow";
import { buildGateway, createTestVerifier } from "@ovid/gateway";

/**
 * P10 Task 10 — secrets at rest (BYOK escrow).
 *
 * Real Postgres + the REAL @ovid/escrow envelope crypto through the REAL
 * gateway route. The invariant under test is byte-level: after
 * `POST /cloud/v1/byok`, no column of `byok_keys` may contain the plaintext
 * canary (checked with `encode(col,'escape')`, not a JS string scan of a
 * projection), the envelope must decrypt back to the exact canary through
 * P9's read path, and a different master key must fail closed with a fixed
 * message that carries neither the key nor the plaintext.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

/** The e2e package does not depend on fastify directly; derive its app type. */
type GatewayApp = ReturnType<typeof buildGateway>;

const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const OTHER_MASTER_KEY_HEX =
  "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";

function testUid(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function authHeaders(uid: string): Record<string, string> {
  return {
    authorization: `Bearer test:${uid}`,
    "x-firebase-appcheck": "app-check-stub",
  };
}

/** No-op SystemBus: the BYOK routes never publish scheduler events. */
const noopSystemBus: SystemBus = {
  async publish() {},
  async subscribe() {
    return async () => {};
  },
};

describe.skipIf(!TEST_DATABASE_URL)("secrets at rest — BYOK escrow (real postgres)", () => {
  let db: Db;
  const apps: GatewayApp[] = [];
  const uids: string[] = [];

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterEach(async () => {
    while (apps.length > 0) await apps.pop()!.close();
  });

  afterAll(async () => {
    for (const uid of uids) {
      await db.$client`DELETE FROM byok_keys WHERE user_id = ${uid}`;
      await db.$client`DELETE FROM users WHERE uid = ${uid}`;
    }
    await db.$client.end({ timeout: 5 });
  });

  function makeApp(crypto: EnvelopeCrypto = createEnvelopeCrypto(MASTER_KEY_HEX)): GatewayApp {
    // Only the outermost seams are stubs; Postgres and the envelope crypto are
    // real. The BYOK routes never touch queues/tickets/keys/mint/events.
    const app = buildGateway({
      system: noopSystemBus,
      db,
      queues: {
        agentRuns: {
          add: async () => ({ id: "job" }),
          client: Promise.resolve({ ping: async () => "PONG" }),
        },
        schedules: { add: async () => ({ id: "schedule" }) },
      } as never,
      verifier: createTestVerifier(),
      tickets: {
        mint: async (uid: string) => `ticket-${uid}`,
        verify: async () => null,
      },
      keys: { getKeyForUser: async () => null },
      mint: { ensureKeyForUid: async () => ({ key: "sk-stub", tier: "free", baseUrl: "" }) },
      events: {} as EventLog,
      crypto,
    });
    apps.push(app);
    return app;
  }

  async function createKey(
    app: GatewayApp,
    uid: string,
    apiKey: string,
  ): Promise<{ id: string; statusCode: number }> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/byok",
      headers: authHeaders(uid),
      payload: {
        providerId: "openai",
        endpoint: "https://api.example.com/v1",
        apiKey,
        label: "security-suite",
      },
    });
    expect(res.statusCode).toBe(201);
    return { id: (res.json() as { id: string }).id, statusCode: res.statusCode };
  }

  /** Every column as text, with byte-level escaping (never a JSON projection). */
  async function rawRow(id: string): Promise<Record<string, string>> {
    const [row] = await db.$client<Record<string, string>[]>`
      SELECT
        id,
        provider_id,
        endpoint,
        coalesce(label, '') AS label,
        encode(convert_to(wrapped_dek, 'UTF8'), 'escape') AS wrapped_dek,
        encode(convert_to(iv, 'UTF8'), 'escape') AS iv,
        encode(convert_to(ciphertext, 'UTF8'), 'escape') AS ciphertext,
        encode(convert_to(tag, 'UTF8'), 'escape') AS tag,
        status,
        coalesce(last_test_at::text, '') AS last_test_at,
        coalesce(last_test_ok::text, '') AS last_test_ok,
        created_at::text AS created_at
      FROM byok_keys
      WHERE id = ${id}
    `;
    return row!;
  }

  it("escrowed key is ciphertext at the byte level", async () => {
    const uid = testUid("sec-at-rest");
    uids.push(uid);
    const canary = `sk-CANARY-${randomUUID()}`;
    const app = makeApp();

    const first = await createKey(app, uid, canary);
    const second = await createKey(app, uid, `sk-CANARY-${randomUUID()}`);

    const row = await rawRow(first.id);
    // Raw escaped bytes of EVERY column — no column may carry the canary.
    for (const [column, value] of Object.entries(row)) {
      expect(value, `column ${column} must not hold the plaintext`).not.toContain(canary);
    }
    // The envelope fields are populated base64 ciphertext, not empty strings.
    for (const column of ["wrapped_dek", "iv", "ciphertext", "tag"] as const) {
      expect(row[column]!.length).toBeGreaterThan(0);
      expect(row[column]).toMatch(/^[A-Za-z0-9+/]+={0,2}$/);
    }
    // Distinct records must not reuse the data-layer IV.
    const other = await rawRow(second.id);
    expect(row.iv).not.toBe(other.iv);
    expect(row.ciphertext).not.toBe(other.ciphertext);
  });

  it("decrypt round-trip returns the canary exactly (P9 read path)", async () => {
    const uid = testUid("sec-roundtrip");
    uids.push(uid);
    const canary = `sk-CANARY-${randomUUID()}`;
    const app = makeApp();
    const { id } = await createKey(app, uid, canary);

    const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
    const provider = createByokKeyProvider(db, crypto, { log: () => {} });
    const decrypted = await provider.getDecrypted(id, uid);
    expect(decrypted).not.toBeNull();
    expect(decrypted!.apiKey).toBe(canary);
    expect(decrypted!.providerId).toBe("openai");
    expect(decrypted!.endpoint).toBe("https://api.example.com/v1");

    // A different owner gets the same answer as an unknown id: null.
    expect(await provider.getDecrypted(id, testUid("stranger"))).toBeNull();
  });

  it("wrong master key fails closed without leaking plaintext or key material", async () => {
    const uid = testUid("sec-wrong-key");
    uids.push(uid);
    const canary = `sk-CANARY-${randomUUID()}`;
    const app = makeApp();
    const { id } = await createKey(app, uid, canary);

    const row = await rawRow(id);
    const wrongCrypto = createEnvelopeCrypto(OTHER_MASTER_KEY_HEX);
    const envelope = {
      wrappedDek: row.wrapped_dek!,
      iv: row.iv!,
      ciphertext: row.ciphertext!,
      tag: row.tag!,
    };

    let caught: unknown;
    try {
      wrongCrypto.decrypt(envelope, byokRecordId(id));
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(EnvelopeAuthError);
    const message = (caught as Error).message;
    expect(message).toBe("envelope failed authentication");
    expect(message).not.toContain(canary);
    expect(message).not.toContain(MASTER_KEY_HEX);
    expect(message).not.toContain(OTHER_MASTER_KEY_HEX);

    // The provider degrades to null (no throw into a run) and logs nothing
    // that carries the secret.
    const logs: string[] = [];
    const provider = createByokKeyProvider(db, wrongCrypto, {
      log: (line, detail) => logs.push(`${line} ${JSON.stringify(detail ?? "")}`),
    });
    expect(await provider.getDecrypted(id, uid)).toBeNull();
    expect(logs.join("\n")).not.toContain(canary);
  });
});
