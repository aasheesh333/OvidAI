import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import { createEnvelopeCrypto } from "@ovid/escrow";
import { browserCredentialRecordId } from "@ovid/shared";

import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

/**
 * Wave 6 W4 — the browser Credentials Vault routes, end to end against real
 * Postgres. The real envelope crypto is used: the API never echoes the
 * secret, the DB never holds it in plaintext, and every mutation is
 * owner-scoped.
 */
const MASTER_KEY_HEX = "cd".repeat(32);
const SECRET = "SENTINEL-password-do-not-leak-0001";
const NOTES = "SENTINEL-notes-do-not-leak-0002";

describe.skipIf(!TEST_DATABASE_URL)("gateway credential routes (real postgres)", () => {
  let db: Db;
  const built: FastifyInstance[] = [];
  const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  /** Raw row read (the gateway package has no direct drizzle dependency). */
  async function rawRow(id: string): Promise<Record<string, unknown>> {
    const rows = await db.$client.unsafe(
      `select id, user_id, label, site, username, secret_kind, secret_sealed, notes_sealed
         from browser_credentials where id = $1`,
      [id],
    );
    return rows[0] as Record<string, unknown>;
  }

  function makeApp(noCrypto = false): FastifyInstance {    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      ...(noCrypto ? {} : { crypto }),
    });
    built.push(app);
    return app;
  }

  async function create(
    app: FastifyInstance,
    uid: string,
    payload: Record<string, unknown> = {},
  ): Promise<{ statusCode: number; body: Record<string, unknown> }> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/credentials",
      headers: authHeaders(uid),
      payload: {
        label: "Example",
        site: "example.test",
        username: "me@example.test",
        secret: SECRET,
        secretKind: "password",
        notes: NOTES,
        ...payload,
      },
    });
    return { statusCode: res.statusCode, body: res.json() as Record<string, unknown> };
  }

  it("POST seals the secret and notes; the response carries metadata only", async () => {
    const uid = testUid("cred-post");
    const app = makeApp();
    const { statusCode, body } = await create(app, uid);

    expect(statusCode).toBe(201);
    expect(Object.keys(body).sort()).toEqual(
      ["createdAt", "hasNotes", "id", "label", "secretKind", "site", "updatedAt", "username"].sort(),
    );
    expect(JSON.stringify(body)).not.toContain(SECRET);
    expect(JSON.stringify(body)).not.toContain(NOTES);

    const row = await rawRow(body.id as string);
    const dump = JSON.stringify(row);
    expect(dump).not.toContain(SECRET);
    expect(dump).not.toContain(NOTES);
    expect(crypto.decrypt(row.secret_sealed as never, browserCredentialRecordId(row.id as string))).toBe(SECRET);
    expect(crypto.decrypt(row.notes_sealed as never, browserCredentialRecordId(row.id as string))).toBe(NOTES);
  });

  it("GET lists metadata only (no secret, no ciphertext)", async () => {
    const uid = testUid("cred-get");
    const app = makeApp();
    await create(app, uid);

    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/credentials",
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    const items = (res.json() as { items: Array<Record<string, unknown>> }).items;
    expect(items).toHaveLength(1);
    expect(items[0].label).toBe("Example");
    expect(items[0].hasNotes).toBe(true);
    expect(JSON.stringify(items)).not.toContain(SECRET);
    expect(JSON.stringify(items)).not.toContain("secretSealed");
  });

  it("PATCH re-seals a new secret and can clear notes", async () => {
    const uid = testUid("cred-patch");
    const app = makeApp();
    const created = await create(app, uid);

    const res = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/credentials/${created.body.id as string}`,
      headers: authHeaders(uid),
      payload: { label: "Renamed", secret: "SENTINEL-new-secret", notes: null },
    });
    expect(res.statusCode).toBe(200);
    expect((res.json() as Record<string, unknown>).hasNotes).toBe(false);
    expect(JSON.stringify(res.json())).not.toContain("SENTINEL-new-secret");

    const row = await rawRow(created.body.id as string);
    expect(
      crypto.decrypt(row.secret_sealed as never, browserCredentialRecordId(row.id as string)),
    ).toBe("SENTINEL-new-secret");
    expect(row.notes_sealed).toBeNull();
  });

  it("DELETE is owner-scoped and idempotent (unknown/wrong owner = 404)", async () => {
    const owner = testUid("cred-owner");
    const other = testUid("cred-other");
    const app = makeApp();
    const created = await create(app, owner);
    const id = created.body.id as string;

    const wrong = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/credentials/${id}`,
      headers: authHeaders(other),
    });
    expect(wrong.statusCode).toBe(404);

    const ok = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/credentials/${id}`,
      headers: authHeaders(owner),
    });
    expect(ok.statusCode).toBe(204);

    const again = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/credentials/${id}`,
      headers: authHeaders(owner),
    });
    expect(again.statusCode).toBe(404);
  });

  it("another owner cannot read or patch the row", async () => {
    const owner = testUid("cred-owner2");
    const other = testUid("cred-other2");
    const app = makeApp();
    const created = await create(app, owner);
    const id = created.body.id as string;

    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/credentials",
      headers: authHeaders(other),
    });
    expect((list.json() as { items: unknown[] }).items).toHaveLength(0);

    const patch = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/credentials/${id}`,
      headers: authHeaders(other),
      payload: { label: "Hijacked" },
    });
    expect(patch.statusCode).toBe(404);
  });

  it("rejects a malformed site and a duplicate label", async () => {
    const uid = testUid("cred-validation");
    const app = makeApp();

    const bad = await create(app, uid, { site: "not a host" });
    expect(bad.statusCode).toBe(400);

    expect((await create(app, uid)).statusCode).toBe(201);
    const duplicate = await create(app, uid);
    expect(duplicate.statusCode).toBe(409);
    expect(duplicate.body.error).toMatchObject({ code: "label_taken" });
  });

  it("answers a loud 503 when the master key/crypto is not configured", async () => {
    const app = makeApp(true);
    const res = await create(app, testUid("cred-nocrypto"));
    expect(res.statusCode).toBe(503);
    expect(res.body.error).toMatchObject({ code: "unavailable" });
  });
});
