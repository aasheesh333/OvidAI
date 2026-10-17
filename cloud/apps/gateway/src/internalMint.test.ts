import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import {
  INTERNAL_MINT_PATH,
  MintInternalError,
  verifyInternalRequest,
  type InternalMintProvisioner,
} from "@ovid/shared";
import { createInternalMintProvisioner } from "./internalMint.js";
import { buildGateway } from "./app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "./test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "./test/stubs.js";

/**
 * P9 Task 9 — the gateway's server-to-server mint client.
 *
 * The gateway no longer forwards a client Firebase token: it signs
 * {uid} with OVID_INTERNAL_API_SECRET and calls mint's ADMIN listener. The
 * route keeps the P10 deadline and the existing relay contract:
 *   402/429 → the billing envelope verbatim; anything else → 409
 *   key_not_minted.
 */

const SECRET = "sk-internal-t9-gateway-secret-0123456789abcdef";

interface Captured {
  method: string;
  url: string;
  headers: IncomingMessage["headers"];
  body: string;
}

async function withMintServer(
  respond: () => { status: number; body: string },
  run: (ctx: { baseUrl: string; requests: Captured[] }) => Promise<void>,
): Promise<void> {
  const requests: Captured[] = [];
  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      requests.push({
        method: req.method!,
        url: req.url!,
        headers: req.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      });
      const r = respond();
      res.writeHead(r.status, { "content-type": "application/json" });
      res.end(r.body);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    await run({ baseUrl: `http://127.0.0.1:${port}`, requests });
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((err) => (err ? reject(err) : resolve())),
    );
  }
}

describe("createInternalMintProvisioner", () => {
  it("POSTs a signed {uid} to /internal/mint-key and returns the minted key", async () => {
    await withMintServer(
      () =>
        ({
          status: 200,
          body: JSON.stringify({ key: "sk-internal", tier: "free", baseUrl: "http://x" }),
        }) as const,
      async ({ baseUrl, requests }) => {
        const mint = createInternalMintProvisioner(`${baseUrl}/`, SECRET);
        await expect(mint.ensureKeyForUid("uid-1")).resolves.toEqual({
          key: "sk-internal",
          tier: "free",
          baseUrl: "http://x",
        });

        expect(requests).toHaveLength(1);
        const req = requests[0]!;
        expect(req.method).toBe("POST");
        expect(req.url).toBe(INTERNAL_MINT_PATH); // never "//internal…"
        expect(JSON.parse(req.body)).toEqual({ uid: "uid-1" });

        const timestamp = String(req.headers["x-ovid-timestamp"]);
        const signature = String(req.headers["x-ovid-signature"]);
        const ts = Number(Buffer.from(timestamp, "base64").toString("utf8"));
        expect(
          verifyInternalRequest(
            SECRET,
            "POST",
            INTERNAL_MINT_PATH,
            "uid-1",
            timestamp,
            signature,
            ts,
          ),
        ).toBe(true);
      },
    );
  });

  it("includes platform when supplied", async () => {
    await withMintServer(
      () => ({ status: 200, body: JSON.stringify({ key: "k", tier: "free", baseUrl: "" }) }),
      async ({ baseUrl, requests }) => {
        await createInternalMintProvisioner(baseUrl, SECRET).ensureKeyForUid("uid-web", {
          platform: "web",
        });
        expect(JSON.parse(requests[0]!.body)).toEqual({ uid: "uid-web", platform: "web" });
      },
    );
  });

  it("402 → MintInternalError carrying the status and parsed billing envelope", async () => {
    const body = { detail: "monthly free limit reached" };
    await withMintServer(
      () => ({ status: 402, body: JSON.stringify(body) }),
      async ({ baseUrl }) => {
        const err = await createInternalMintProvisioner(baseUrl, SECRET)
          .ensureKeyForUid("uid-2")
          .catch((e: unknown) => e);
        expect(err).toBeInstanceOf(MintInternalError);
        expect((err as MintInternalError).status).toBe(402);
        expect((err as MintInternalError).body).toEqual(body);
      },
    );
  });

  it("non-JSON error bodies are preserved verbatim", async () => {
    await withMintServer(
      () => ({ status: 500, body: "upstream exploded" }),
      async ({ baseUrl }) => {
        const err = await createInternalMintProvisioner(baseUrl, SECRET)
          .ensureKeyForUid("uid-3")
          .catch((e: unknown) => e);
        expect(err).toBeInstanceOf(MintInternalError);
        expect((err as MintInternalError).status).toBe(500);
        expect((err as MintInternalError).body).toBe("upstream exploded");
      },
    );
  });

  it("a 2xx without a string key → rejects (malformed mint contract)", async () => {
    await withMintServer(
      () => ({ status: 200, body: "{}" }),
      async ({ baseUrl }) => {
        await expect(
          createInternalMintProvisioner(baseUrl, SECRET).ensureKeyForUid("uid-4"),
        ).rejects.toThrow();
      },
    );
  });
});

describe.skipIf(!TEST_DATABASE_URL)("messages route relays the internal-mint contract", () => {
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

  function makeApp(mint: InternalMintProvisioner): FastifyInstance {
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint,
      events: noopEvents,
    });
    built.push(app);
    return app;
  }

  async function createSession(app: FastifyInstance, uid: string): Promise<string> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  }

  it("a 402 from mint is relayed verbatim and no message/run is written", async () => {
    const body = { detail: "monthly free limit reached" };
    const app = makeApp({
      async ensureKeyForUid() {
        throw new MintInternalError(402, body);
      },
    });
    const uid = testUid("internal-402");
    const sid = await createSession(app, uid);

    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages`,
      headers: authHeaders(uid),
      payload: { content: "hello" },
    });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual(body);

    const counts = (await db.$client.unsafe(
      "SELECT (SELECT count(*)::int FROM messages WHERE session_id = $1) AS messages," +
        " (SELECT count(*)::int FROM runs WHERE session_id = $1) AS runs",
      [sid],
    )) as Array<{ messages: number; runs: number }>;
    expect(counts[0]).toEqual({ messages: 0, runs: 0 });
  });

  it("a 500 from mint collapses to 409 key_not_minted (existing behavior kept)", async () => {
    const app = makeApp({
      async ensureKeyForUid() {
        throw new MintInternalError(500, { detail: "internal" });
      },
    });
    const uid = testUid("internal-500");
    const sid = await createSession(app, uid);

    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages`,
      headers: authHeaders(uid),
      payload: { content: "hello" },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("key_not_minted");
  });
});
