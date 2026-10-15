import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import { createHttpMintProvisioner, createMintRedisKeyProvider, MintHttpError } from "./keys.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

interface CapturedRequest {
  method: string;
  url: string;
  headers: IncomingMessage["headers"];
  body: string;
}

interface MintCtx {
  baseUrl: string;
  requests: CapturedRequest[];
}

/** Local mint stand-in on 127.0.0.1:0 capturing every request verbatim. */
async function withMintServer(
  respond: () => { status: number; body: string; contentType?: string },
  run: (ctx: MintCtx) => Promise<void>,
): Promise<void> {
  const requests: CapturedRequest[] = [];
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
      res.writeHead(r.status, { "content-type": r.contentType ?? "application/json" });
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

describe("createHttpMintProvisioner", () => {
  it("POSTs {base}/mint forwarding Authorization + X-Firebase-AppCheck verbatim with an empty JSON body", async () => {
    await withMintServer(
      () => ({ status: 200, body: JSON.stringify({ key: "sk-mint-1" }) }),
      async ({ baseUrl, requests }) => {
        const mint = createHttpMintProvisioner(baseUrl);
        await expect(mint.ensureKey("id-token-1", "app-check-1")).resolves.toEqual({
          key: "sk-mint-1",
        });
        expect(requests).toHaveLength(1);
        const req = requests[0]!;
        expect(req.method).toBe("POST");
        expect(req.url).toBe("/mint");
        expect(req.headers.authorization).toBe("Bearer id-token-1");
        expect(req.headers["x-firebase-appcheck"]).toBe("app-check-1");
        expect(req.headers["content-type"]).toBe("application/json");
        expect(req.body).toBe("{}");
      },
    );
  });

  it("omits X-Firebase-AppCheck when appCheck is null and tolerates a trailing slash on the base URL", async () => {
    await withMintServer(
      () => ({ status: 200, body: JSON.stringify({ key: "k" }) }),
      async ({ baseUrl, requests }) => {
        const mint = createHttpMintProvisioner(`${baseUrl}/`);
        await expect(mint.ensureKey("tok", null)).resolves.toEqual({ key: "k" });
        expect(requests[0]!.url).toBe("/mint"); // never "//mint"
        expect("x-firebase-appcheck" in requests[0]!.headers).toBe(false);
      },
    );
  });

  it("non-2xx → MintHttpError carrying the status and parsed body for 402/429 passthrough", async () => {
    const paymentBody = { error: { code: "payment_required", message: "buy credits" } };
    await withMintServer(
      () => ({ status: 402, body: JSON.stringify(paymentBody) }),
      async ({ baseUrl }) => {
        const mint = createHttpMintProvisioner(baseUrl);
        const err = await mint.ensureKey("tok", "ac").catch((e: unknown) => e);
        expect(err).toBeInstanceOf(MintHttpError);
        expect((err as MintHttpError).status).toBe(402);
        expect((err as MintHttpError).body).toEqual(paymentBody);
      },
    );
    await withMintServer(
      () => ({ status: 429, body: JSON.stringify({ error: { code: "rate_limited" } }) }),
      async ({ baseUrl }) => {
        const err = await createHttpMintProvisioner(baseUrl)
          .ensureKey("tok", null)
          .catch((e: unknown) => e);
        expect((err as MintHttpError).status).toBe(429);
      },
    );
    await withMintServer(
      () => ({ status: 500, body: "upstream exploded" }),
      async ({ baseUrl }) => {
        const err = await createHttpMintProvisioner(baseUrl)
          .ensureKey("tok", null)
          .catch((e: unknown) => e);
        expect(err).toBeInstanceOf(MintHttpError);
        expect((err as MintHttpError).status).toBe(500);
        expect((err as MintHttpError).body).toBe("upstream exploded"); // non-JSON preserved as text
      },
    );
  });

  it("2xx without a string key → rejects (malformed mint contract)", async () => {
    await withMintServer(() => ({ status: 200, body: "{}" }), async ({ baseUrl }) => {
      await expect(createHttpMintProvisioner(baseUrl).ensureKey("tok", null)).rejects.toThrow();
    });
  });
});

describe.skipIf(!TEST_REDIS_URL)("createMintRedisKeyProvider (real redis)", () => {
  let redis: Redis;
  const written: string[] = [];

  beforeAll(() => {
    // The provider does a plain GET — REDIS_MINT_URL carries the db selector
    // in production; against the dev redis we simply use db0 and clean up.
    redis = new Redis(TEST_REDIS_URL!);
  });

  afterAll(async () => {
    if (written.length > 0) await redis.del(written);
    redis.disconnect();
  });

  it("reads GET user:{uid}:key and returns null for missing users", async () => {
    const provider = createMintRedisKeyProvider(redis);
    const uid = `mint-key-test-${Date.now()}`;
    const key = `user:${uid}:key`;
    written.push(key);
    await redis.set(key, "sk-live-1");

    await expect(provider.getKeyForUser(uid)).resolves.toBe("sk-live-1");
    await expect(provider.getKeyForUser(`missing-${Date.now()}`)).resolves.toBeNull();
  });
});
