import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { byokKeysRepo, users, type Db } from "@ovid/db";
import { createEnvelopeCrypto, byokRecordId } from "@ovid/escrow";
import { buildGateway } from "../app.js";
import { MAX_BYOK_KEYS_PER_USER } from "./byok.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
  stubSystemBus,
} from "../test/stubs.js";

// BYOK escrow routes (P9 Task 11) — real Postgres, Fastify inject. The crypto
// is the real @ovid/escrow envelope (no stub): the DB-never-holds-plaintext
// invariant and the recordId AAD binding are both asserted end to end.
// Probe fetch + DNS are injected through GatewayDeps.byok so no network I/O.

const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const UUIDV7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const API_KEY = "sk-live-SENTINEL-do-not-leak-0001";

interface FetchCall {
  url: string;
  init: RequestInit | undefined;
}

describe.skipIf(!TEST_DATABASE_URL)("gateway BYOK routes (real postgres)", () => {
  let db: Db;
  const built: FastifyInstance[] = [];

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  function makeApp(opts: {
    fetchImpl?: typeof fetch;
    lookupHost?: (host: string) => Promise<string[]>;
    noCrypto?: boolean;
  } = {}): FastifyInstance {
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues(),
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      ...(opts.noCrypto ? {} : { crypto: createEnvelopeCrypto(MASTER_KEY_HEX) }),
      byok: {
        ...(opts.fetchImpl ? { fetchImpl: opts.fetchImpl } : {}),
        ...(opts.lookupHost ? { lookupHost: opts.lookupHost } : {}),
      },
    });
    built.push(app);
    return app;
  }

  async function createKey(
    app: FastifyInstance,
    uid: string,
    payload: Record<string, unknown> = {},
  ): Promise<{ statusCode: number; body: Record<string, unknown> }> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/byok",
      headers: authHeaders(uid),
      payload: {
        providerId: "openai",
        endpoint: "https://api.example.com/v1",
        apiKey: API_KEY,
        label: "Work",
        ...payload,
      },
    });
    return { statusCode: res.statusCode, body: res.json() as Record<string, unknown> };
  }

  it("POST valid → 201 camelCase body and an encrypted DB row (no plaintext anywhere)", async () => {
    const uid = testUid("byok-post");
    const app = makeApp();
    const { statusCode, body } = await createKey(app, uid);

    expect(statusCode).toBe(201);
    expect(Object.keys(body).sort()).toEqual(
      ["createdAt", "endpoint", "id", "label", "providerId", "status"].sort(),
    );
    expect(body.id).toMatch(UUIDV7_RE);
    expect(body.providerId).toBe("openai");
    expect(body.endpoint).toBe("https://api.example.com/v1");
    expect(body.label).toBe("Work");
    expect(body.status).toBe("untested");
    expect(typeof body.createdAt).toBe("string");
    expect(JSON.stringify(body)).not.toContain(API_KEY);

    const row = await byokKeysRepo.get(db, body.id as string, uid);
    expect(row).not.toBeNull();
    expect(row!.ciphertext).not.toBe(API_KEY);
    // No text column may carry the plaintext.
    for (const value of Object.values(row!)) {
      if (typeof value === "string") expect(value).not.toContain(API_KEY);
    }
    // The envelope decrypts ONLY under this row's recordId (AAD binding).
    const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
    expect(
      crypto.decrypt(
        {
          wrappedDek: row!.wrappedDek,
          iv: row!.iv,
          ciphertext: row!.ciphertext,
          tag: row!.tag,
        },
        byokRecordId(row!.id),
      ),
    ).toBe(API_KEY);
    expect(() =>
      crypto.decrypt(
        {
          wrappedDek: row!.wrappedDek,
          iv: row!.iv,
          ciphertext: row!.ciphertext,
          tag: row!.tag,
        },
        byokRecordId("00000000-0000-7000-8000-000000000000"),
      ),
    ).toThrow();
  });

  it("POST http://evil → 400 endpoint_rejected and writes no row", async () => {
    const uid = testUid("byok-reject");
    const app = makeApp();
    const { statusCode, body } = await createKey(app, uid, {
      endpoint: "http://evil.example/v1",
    });
    expect(statusCode).toBe(400);
    expect((body.error as { code: string }).code).toBe("endpoint_rejected");
    expect(JSON.stringify(body)).not.toContain("evil.example");
    expect(await byokKeysRepo.list(db, uid)).toEqual([]);
  });

  it("POST non-string endpoint → 400 endpoint_rejected (canonicalizer owns the grammar)", async () => {
    const uid = testUid("byok-reject-type");
    const app = makeApp();
    const { statusCode, body } = await createKey(app, uid, { endpoint: 42 });
    expect(statusCode).toBe(400);
    expect((body.error as { code: string }).code).toBe("endpoint_rejected");
  });

  it("GET lists only the caller's rows and never projects ciphertext fields", async () => {
    const uid = testUid("byok-list");
    const other = testUid("byok-list-other");
    const app = makeApp();
    await createKey(app, uid);
    await createKey(app, uid, { providerId: "anthropic", label: null });
    await createKey(app, other, { providerId: "google" });

    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/byok",
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { items: Record<string, unknown>[] };
    expect(body.items.length).toBe(2);
    for (const item of body.items) {
      expect(Object.keys(item).sort()).toEqual(
        [
          "createdAt",
          "endpoint",
          "id",
          "label",
          "lastTestAt",
          "lastTestOk",
          "providerId",
          "status",
        ].sort(),
      );
      expect(item.lastTestAt).toBeNull();
      expect(item.lastTestOk).toBeNull();
    }
    expect(JSON.stringify(body)).not.toContain(API_KEY);
    expect(JSON.stringify(body)).not.toContain("wrappedDek");
    expect(JSON.stringify(body)).not.toContain("ciphertext");
    expect(body.items.map((i) => i.providerId).sort()).toEqual(["anthropic", "openai"]);
  });

  it("DELETE is owner-scoped: another user's id → 404, own → 204, then 404", async () => {
    const owner = testUid("byok-del-owner");
    const stranger = testUid("byok-del-stranger");
    const app = makeApp();
    const created = await createKey(app, owner);
    const id = created.body.id as string;

    const foreign = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/byok/${id}`,
      headers: authHeaders(stranger),
    });
    expect(foreign.statusCode).toBe(404);
    expect((foreign.json() as { error: { code: string } }).error.code).toBe("not_found");
    // Still there.
    expect(await byokKeysRepo.get(db, id, owner)).not.toBeNull();

    const own = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/byok/${id}`,
      headers: authHeaders(owner),
    });
    expect(own.statusCode).toBe(204);
    expect(await byokKeysRepo.get(db, id, owner)).toBeNull();

    const again = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/byok/${id}`,
      headers: authHeaders(owner),
    });
    expect(again.statusCode).toBe(404);
  });

  it("POST /:id/test probes GET <endpoint>/models with the key and persists the result", async () => {
    const uid = testUid("byok-test-ok");
    const calls: FetchCall[] = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), init });
      return new Response('{"data":[]}', { status: 200 });
    }) as typeof fetch;
    const app = makeApp({ fetchImpl, lookupHost: async () => ["93.184.216.34"] });

    const created = await createKey(app, uid);
    const id = created.body.id as string;
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/byok/${id}/test`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });

    expect(calls.length).toBe(1);
    expect(calls[0]!.url).toBe("https://api.example.com/v1/models");
    const headers = calls[0]!.init!.headers as Record<string, string>;
    expect(headers.authorization).toBe(`Bearer ${API_KEY}`);
    expect(JSON.stringify(res.body)).not.toContain(API_KEY);

    const row = await byokKeysRepo.get(db, id, uid);
    expect(row!.lastTestOk).toBe(true);
    expect(row!.lastTestAt).toBeInstanceOf(Date);
  });

  it("POST /:id/test maps a provider rejection to {ok:false, error} and persists false", async () => {
    const uid = testUid("byok-test-fail");
    const fetchImpl = (async () => new Response("nope", { status: 401 })) as typeof fetch;
    const app = makeApp({ fetchImpl, lookupHost: async () => ["93.184.216.34"] });
    const created = await createKey(app, uid);
    const id = created.body.id as string;

    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/byok/${id}/test`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: false, error: "HTTP 401" });
    const row = await byokKeysRepo.get(db, id, uid);
    expect(row!.lastTestOk).toBe(false);
    expect(row!.lastTestAt).toBeInstanceOf(Date);
  });

  it("SSRF: private/reserved/metadata targets → 400 endpoint_rejected with NO fetch", async () => {
    const uid = testUid("byok-ssrf");
    const calls: FetchCall[] = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), init });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    const targets: Array<{ endpoint: string; lookup?: string[]; label?: string }> = [
      { endpoint: "https://127.0.0.1/v1" },
      { endpoint: "https://10.1.2.3/v1" },
      { endpoint: "https://169.254.169.254/latest" },
      { endpoint: "https://api.example.com/v1", lookup: ["10.0.0.5"] },
      { endpoint: "https://api.example.com/v1", lookup: ["169.254.169.254"] },
      { endpoint: "https://api.example.com/v1", lookup: ["127.0.0.1"] },
      { endpoint: "https://api.example.com/v1", lookup: ["::1"] },
      // M2 (fix round 1): forms the route's former string-shape classifier
      // classified SAFE. Each must be rejected before any fetch.
      { endpoint: "https://[64:ff9b::7f00:1]/v1", label: "NAT64 literal" },
      { endpoint: "https://[2002:7f00:1::]/v1", label: "6to4 literal" },
      { endpoint: "https://[::127.0.0.1]/v1", label: "IPv4-compatible literal" },
      { endpoint: "https://[fec0::1]/v1", label: "site-local literal" },
      { endpoint: "https://[ff02::1]/v1", label: "multicast literal" },
      {
        endpoint: "https://api.example.com/v1",
        lookup: ["64:ff9b::7f00:1"],
        label: "NAT64 DNS answer",
      },
      {
        endpoint: "https://api.example.com/v1",
        lookup: ["2002:7f00:1::"],
        label: "6to4 DNS answer",
      },
      {
        endpoint: "https://api.example.com/v1",
        lookup: ["::7f00:1"],
        label: "IPv4-compatible DNS answer",
      },
      {
        endpoint: "https://api.example.com/v1",
        lookup: ["fec0::1"],
        label: "site-local DNS answer",
      },
      {
        endpoint: "https://api.example.com/v1",
        lookup: ["ff02::1"],
        label: "multicast DNS answer",
      },
    ];

    for (const target of targets) {
      const label = target.label ?? target.endpoint;
      const app = makeApp({
        fetchImpl,
        lookupHost: async () => target.lookup ?? [],
      });
      const created = await createKey(app, uid, { endpoint: target.endpoint });
      expect(created.statusCode, label).toBe(201);
      const id = created.body.id as string;
      const res = await app.inject({
        method: "POST",
        url: `/cloud/v1/byok/${id}/test`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode, label).toBe(400);
      expect((res.json() as { error: { code: string } }).error.code).toBe("endpoint_rejected");
    }
    expect(calls.length).toBe(0);
  });

  it("probe rejects ports other than 443/80", async () => {
    const uid = testUid("byok-port");
    const calls: FetchCall[] = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), init });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;
    const app = makeApp({ fetchImpl, lookupHost: async () => ["93.184.216.34"] });
    const created = await createKey(app, uid, {
      endpoint: "https://api.example.com:8443/v1",
    });
    expect(created.statusCode).toBe(201);
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/byok/${created.body.id as string}/test`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(400);
    expect((res.json() as { error: { code: string } }).error.code).toBe("endpoint_rejected");
    expect(calls.length).toBe(0);
  });

  it("L4: the target is validated before decryption (corrupt envelope + private target → 400)", async () => {
    // Without the ordering fix the corrupt envelope would throw first and the
    // route would answer 500/internal. endpoint_rejected proves the SSRF gate
    // ran before any plaintext materialized.
    const uid = testUid("byok-order");
    const app = makeApp({ lookupHost: async () => ["93.184.216.34"] });
    await users.ensure(db, uid, null);
    const row = await byokKeysRepo.create(db, {
      userId: uid,
      providerId: "openai",
      endpoint: "https://127.0.0.1/v1",
      wrappedDek: "00",
      iv: "00",
      ciphertext: "00",
      tag: "00",
    });

    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/byok/${row.id}/test`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(400);
    expect((res.json() as { error: { code: string } }).error.code).toBe("endpoint_rejected");
  });

  it("L5: an endpoint already ending in /models is not doubled", async () => {
    const uid = testUid("byok-models");
    const calls: FetchCall[] = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), init });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;
    const app = makeApp({ fetchImpl, lookupHost: async () => ["93.184.216.34"] });

    const created = await createKey(app, uid, {
      endpoint: "https://api.example.com/v1/models",
    });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/byok/${created.body.id as string}/test`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    expect(calls.length).toBe(1);
    expect(calls[0]!.url).toBe("https://api.example.com/v1/models");
  });

  it("L3: per-user BYOK row cap → 409 limit_reached with no extra row", async () => {
    const uid = testUid("byok-cap");
    const app = makeApp();
    await users.ensure(db, uid, null);
    for (let i = 0; i < MAX_BYOK_KEYS_PER_USER; i++) {
      await byokKeysRepo.create(db, {
        userId: uid,
        providerId: "openai",
        endpoint: `https://api${i}.example.com/v1`,
        wrappedDek: "00",
        iv: "00",
        ciphertext: "00",
        tag: "00",
      });
    }

    const { statusCode, body } = await createKey(app, uid);
    expect(statusCode).toBe(409);
    expect((body.error as { code: string }).code).toBe("limit_reached");
    expect((await byokKeysRepo.list(db, uid)).length).toBe(MAX_BYOK_KEYS_PER_USER);
  });

  it("crypto not wired → loud 503 (never stores unsealed keys)", async () => {
    const uid = testUid("byok-nocrypto");
    const app = makeApp({ noCrypto: true });
    const { statusCode, body } = await createKey(app, uid);
    expect(statusCode).toBe(503);
    expect((body.error as { code: string }).code).toBe("unavailable");
    expect(await byokKeysRepo.list(db, uid)).toEqual([]);
  });
});
