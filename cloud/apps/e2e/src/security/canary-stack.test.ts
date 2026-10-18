import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "@ovid/db";
import { createByokKeyProvider, createEnvelopeCrypto } from "@ovid/escrow";
import { createRedisEventLog, createRedisSystemBus, type EventLog } from "@ovid/events";
import {
  buildGateway,
  createInternalMintProvisioner,
  createTestVerifier,
  createTicketStore,
  type TicketStore,
} from "@ovid/gateway";
import { createAgentRunsWorker, createQueues, type QueueServices } from "@ovid/queue";
import { INTERNAL_MINT_PATH, verifyInternalRequest } from "@ovid/shared";
import {
  createAgentRunProcessor,
  createOpenAiTransport,
  createServerKeyResolver,
} from "@ovid/worker";

/**
 * P10 Task 10 fix — the canary sweep's in-process stack.
 *
 * This suite is NOT part of the ordinary e2e run: it is enabled only when the
 * canary CLI provisions isolated services and exports canary-bearing config
 * under the REAL names the shipped services read:
 *
 *   DATABASE_URL              (password = canary DB password)
 *   REDIS_Q_URL               (password = canary Redis password)
 *   OVID_MASTER_KEY           (64-hex canary)
 *   OVID_INTERNAL_API_SECRET  (canary; verified by the mock mint below)
 *   LITELLM_MASTER_KEY / OVID_LITELLM_MASTER_KEY (canary)
 *   OVID_CANARY_BYOK_KEY      (the plaintext uploaded through POST /byok)
 *
 * The composition is the SHIPPED one (buildGateway + createAgentRunProcessor
 * + createServerKeyResolver), with only the outermost model/mint HTTP
 * boundaries mocked locally. It drives one authenticated run to a terminal
 * event and one BYOK upload, then writes a proof file the CLI verifies. Any
 * canary appearing in the sweep's corpora is therefore a real leak from the
 * shipped path.
 *
 * Deliberately NOT covered: the sandboxed-tool path. This environment has no
 * bwrap/rootfs, so the legacy tool-less processor shape is used (the same
 * shape spine.test.ts uses). The CLI report says so explicitly.
 */

const ENABLED = process.env.OVID_CANARY_STACK === "1";
const DATABASE_URL = process.env.DATABASE_URL;
const REDIS_URL = process.env.REDIS_Q_URL;
const MASTER_KEY = process.env.OVID_MASTER_KEY;
const INTERNAL_SECRET = process.env.OVID_INTERNAL_API_SECRET;
const LITELLM_KEY =
  process.env.LITELLM_MASTER_KEY ?? process.env.OVID_LITELLM_MASTER_KEY;
const BYOK_KEY = process.env.OVID_CANARY_BYOK_KEY;
const PROOF_FILE = process.env.OVID_CANARY_PROOF_FILE;
const QUEUE_PREFIX =
  process.env.OVID_CANARY_QUEUE_PREFIX ?? `ovid-canary-${randomUUID()}`;

interface Proof {
  sessionId: string;
  uid: string;
  runId: string;
  byokId: string;
  terminalEvent: string;
  eventCount: number;
  mirrorRows: number;
  byokRows: number;
}

function required(name: string, value: string | undefined): string {
  if (value === undefined || value === "") {
    throw new Error(`canary-stack: ${name} is required when OVID_CANARY_STACK=1`);
  }
  return value;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(
  cond: () => boolean,
  what: string,
  timeoutMs = 30_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) throw new Error(`canary-stack: timed out waiting for ${what}`);
    await sleep(10);
  }
}

/** Local [OI]-dialect SSE endpoint; the shipped transport is unchanged. */
async function startSseMock(): Promise<{ baseUrl: string; close(): Promise<void> }> {
  const deltas = ["canary", " stack", " ok"];
  const server: Server = createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-store",
      });
      for (const delta of deltas) {
        res.write(
          `data: ${JSON.stringify({ choices: [{ delta: { content: delta }, finish_reason: null }] })}\n\n`,
        );
      }
      res.write(
        `data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] })}\n\n`,
      );
      res.end("data: [DONE]\n\n");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

/**
 * Local mint admin endpoint. It verifies the SAME HMAC the shipped
 * `createInternalMintProvisioner` signs with OVID_INTERNAL_API_SECRET, so the
 * mint secret is genuinely used by the composition rather than merely set in
 * the environment.
 */
async function startMintMock(
  secret: string,
  key: string,
): Promise<{ baseUrl: string; requests: number; close(): Promise<void> }> {
  const state = { requests: 0 };
  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      state.requests += 1;
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
          uid?: unknown;
        };
        const uid = typeof body.uid === "string" ? body.uid : "";
        const timestamp = req.headers["x-ovid-timestamp"];
        const signature = req.headers["x-ovid-signature"];
        const ok =
          typeof timestamp === "string" &&
          typeof signature === "string" &&
          verifyInternalRequest(
            secret,
            "POST",
            INTERNAL_MINT_PATH,
            uid,
            timestamp,
            signature,
            Math.floor(Date.now() / 1000),
          );
        if (!ok) {
          res.statusCode = 401;
          res.end(JSON.stringify({ error: "unauthorized" }));
          return;
        }
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ key, tier: "free", baseUrl: "" }));
      } catch {
        res.statusCode = 400;
        res.end("{}");
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    get requests() {
      return state.requests;
    },
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

describe.skipIf(!ENABLED)("canary in-process stack (isolated services)", () => {
  let db: Db;
  let redis: Redis;
  let events: EventLog;
  let tickets: TicketStore;
  let queues: QueueServices;
  let worker: ReturnType<typeof createAgentRunsWorker>;
  let app: ReturnType<typeof buildGateway>;
  let sse: Awaited<ReturnType<typeof startSseMock>>;
  let mint: Awaited<ReturnType<typeof startMintMock>>;
  let baseUrl: string;
  let wsBase: string;

  beforeAll(async () => {
    const databaseUrl = required("DATABASE_URL", DATABASE_URL);
    const redisUrl = required("REDIS_Q_URL", REDIS_URL);
    const masterKey = required("OVID_MASTER_KEY", MASTER_KEY);
    const internalSecret = required("OVID_INTERNAL_API_SECRET", INTERNAL_SECRET);
    const litellmKey = required("LITELLM_MASTER_KEY", LITELLM_KEY);

    // The isolated DB is owned by the canary role: this migrate() runs with
    // the canary password, proving the credential is real.
    await migrate(databaseUrl);
    db = createDb(databaseUrl);
    redis = new Redis(redisUrl);
    events = createRedisEventLog(redis);
    tickets = createTicketStore(redis);

    const connection = { url: redisUrl };
    queues = createQueues(connection, { prefix: QUEUE_PREFIX });

    sse = await startSseMock();
    mint = await startMintMock(internalSecret, litellmKey);

    // The SHIPPED worker key resolver: BYOK escrow + mint projection, with
    // the envelope crypto built from the canary OVID_MASTER_KEY.
    const keys = createServerKeyResolver({
      redisMint: redis,
      internalMint: { baseUrl: mint.baseUrl, secret: internalSecret },
      byok: createByokKeyProvider(db, createEnvelopeCrypto(masterKey), {
        log: () => {},
      }),
      litellmBaseUrl: sse.baseUrl,
      log: () => {},
    });

    const processor = createAgentRunProcessor({
      db,
      events,
      keys,
      transport: createOpenAiTransport(),
      litellmBaseUrl: sse.baseUrl,
      defaultModel: "canary-model",
    });
    worker = createAgentRunsWorker(connection, processor, {
      prefix: QUEUE_PREFIX,
    });

    app = buildGateway({
      system: createRedisSystemBus(redis),
      db,
      queues,
      verifier: createTestVerifier(),
      tickets,
      keys: { getKeyForUser: async () => litellmKey },
      mint: createInternalMintProvisioner(mint.baseUrl, internalSecret),
      events,
      crypto: createEnvelopeCrypto(masterKey),
    });
    await app.listen({ host: "127.0.0.1", port: 0 });
    const port = (app.server.address() as AddressInfo).port;
    baseUrl = `http://127.0.0.1:${port}`;
    wsBase = `ws://127.0.0.1:${port}/cloud/ws`;
  }, 60_000);

  afterAll(async () => {
    await worker?.close().catch(() => {});
    await app?.close().catch(() => {});
    if (queues) {
      await queues.agentRuns.obliterate({ force: true }).catch(() => {});
      await queues.agentRuns.close().catch(() => {});
    }
    await sse?.close().catch(() => {});
    await mint?.close().catch(() => {});
    redis?.disconnect();
    await db?.$client.end({ timeout: 5 }).catch(() => {});
  }, 60_000);

  async function api(
    method: string,
    path: string,
    opts: { uid?: string; body?: unknown } = {},
  ): Promise<{ status: number; body: unknown }> {
    const headers: Record<string, string> = {};
    if (opts.uid !== undefined) headers.authorization = `Bearer test:${opts.uid}`;
    if (opts.body !== undefined) headers["content-type"] = "application/json";
    const res = await fetch(`${baseUrl}${path}`, {
      method,
      headers,
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    });
    const text = await res.text();
    let body: unknown = null;
    if (text !== "") {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
    return { status: res.status, body };
  }

  it("drives an authenticated run and a BYOK upload under canary config", async () => {
    const uid = `canary-${randomUUID()}`;
    const byokPlaintext = required("OVID_CANARY_BYOK_KEY", BYOK_KEY);
    const litellmKey = required("LITELLM_MASTER_KEY", LITELLM_KEY);

    // The shipped resolver's mint projection path (step 2) reads this key.
    await redis.set(`user:${uid}:key`, litellmKey);

    const session = await api("POST", "/cloud/v1/sessions", { uid, body: {} });
    expect(session.status).toBe(201);
    const sessionId = (session.body as { id: string }).id;

    const ticketRes = await api("POST", "/cloud/v1/auth/ticket", { uid });
    expect(ticketRes.status).toBe(200);
    const ticket = (ticketRes.body as { ticket: string }).ticket;

    const socket = new WebSocket(`${wsBase}?ticket=${encodeURIComponent(ticket)}`);
    const frames: Array<Record<string, unknown>> = [];
    socket.on("message", (data) => {
      frames.push(JSON.parse(data.toString()) as Record<string, unknown>);
    });
    socket.on("error", () => {});
    await new Promise<void>((resolve, reject) => {
      socket.once("open", () => resolve());
      socket.once("error", reject);
    });
    socket.send(JSON.stringify({ op: "subscribe", sessionId, lastEventId: null }));
    await waitFor(
      () => frames.some((frame) => frame.op === "subscribed"),
      "subscribed ack",
    );

    const sent = await api("POST", `/cloud/v1/sessions/${sessionId}/messages`, {
      uid,
      body: { content: "canary stack run" },
    });
    expect(sent.status).toBe(202);
    const runId = (sent.body as { runId: string }).runId;

    await waitFor(
      () =>
        frames.some(
          (frame) =>
            frame.op === "event" &&
            (frame.event as { type?: string } | undefined)?.type === "run_completed",
        ),
      "run_completed on WS",
    );
    const wsEvents = frames
      .filter((frame) => frame.op === "event")
      .map((frame) => frame.event as { type: string });
    expect(wsEvents.map((event) => event.type)).toContain("run_started");
    expect(wsEvents.at(-1)?.type).toBe("run_completed");

    // The real run row reached a terminal state.
    const runRows = (await db.$client`
      SELECT status FROM runs WHERE id = ${runId}
    `) as Array<{ status: string }>;
    expect(runRows).toHaveLength(1);
    expect(runRows[0]!.status).toBe("completed");

    // BYOK upload through the REAL route, encrypted under the canary master key.
    const byokRes = await api("POST", "/cloud/v1/byok", {
      uid,
      body: {
        providerId: "openai",
        endpoint: "https://api.example.com/v1",
        apiKey: byokPlaintext,
        label: "canary-stack",
      },
    });
    expect(byokRes.status).toBe(201);
    const byokId = (byokRes.body as { id: string }).id;

    // P9 read path round-trips the canary exactly.
    const provider = createByokKeyProvider(
      db,
      createEnvelopeCrypto(required("OVID_MASTER_KEY", MASTER_KEY)),
      { log: () => {} },
    );
    const decrypted = await provider.getDecrypted(byokId, uid);
    expect(decrypted).not.toBeNull();
    expect(decrypted!.apiKey).toBe(byokPlaintext);

    const [mirror] = (await db.$client`
      SELECT count(*)::int AS n FROM session_event_mirror WHERE session_id = ${sessionId}
    `) as Array<{ n: number }>;
    expect(mirror!.n).toBeGreaterThan(0);

    const [byokRows] = (await db.$client`
      SELECT count(*)::int AS n FROM byok_keys
    `) as Array<{ n: number }>;

    const proof: Proof = {
      sessionId,
      uid,
      runId,
      byokId,
      terminalEvent: "run_completed",
      eventCount: wsEvents.length,
      mirrorRows: mirror!.n,
      byokRows: byokRows!.n,
    };
    writeFileSync(
      required("OVID_CANARY_PROOF_FILE", PROOF_FILE),
      JSON.stringify(proof),
      "utf8",
    );

    // The mint HMAC path really ran (the gateway provisions on every send).
    expect(mint.requests).toBeGreaterThanOrEqual(1);

    socket.close();
  }, 60_000);
});
