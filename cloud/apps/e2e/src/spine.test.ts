import { createServer, type Server, type ServerResponse } from "node:http";
import { createServer as createTcpServer } from "node:net";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import {
  createAgentRunsWorker,
  createQueues,
  type QueueServices,
} from "@ovid/queue";
import {
  messageDtoSchema,
  pageSchema,
  sessionDtoSchema,
  wsServerMsg,
  type ApiError,
  type KeyProvider,
  type MintProvisioner,
  type SendMessageResponse,
  type SessionEvent,
  type WsServerMsg,
} from "@ovid/shared";
import {
  buildGateway,
  createTestVerifier,
  createTicketStore,
  type TicketStore,
} from "@ovid/gateway";
import { createAgentRunProcessor, createOpenAiTransport } from "@ovid/worker";

/**
 * The P0+P1 spine, end to end (Task 10): the REAL gateway (REST + WS) and the
 * REAL worker (BullMQ consumer + SSE transport) composed in one process over
 * REAL Postgres and REAL Redis, with only the outermost boundaries stubbed:
 *
 * - LiteLLM → a local http server speaking OpenAI-dialect SSE with per-test
 *   pacing hooks (chunk delays, a mid-run gate, early socket close).
 * - mint → MintProvisioner stub resolving {key:"test-key"}; KeyProvider stub
 *   returning "test-key" (the mock LiteLLM ignores key validity).
 * - auth → createTestVerifier(): `Authorization: Bearer test:<uid>`.
 *
 * Everything else is the shipped code path: buildGateway().listen(port 0),
 * createTicketStore(redis), createRedisEventLog(redis) created ONCE and shared
 * by gateway deps AND RunDeps (Task 8 carry-over: gateway and worker must hit
 * the same Redis instance or live fanout breaks), createQueues({url}) /
 * createAgentRunsWorker({url}, processor) in the mandatory OBJECT form.
 *
 * Pinned flows (one `it` each):
 *   a. happy path — REST send → 202; WS ordered live events; deltas ==
 *      assistant content; GET messages user→assistant; users/runs rows.
 *   b. mid-run reconnect (Review Focus #1) — abrupt disconnect behind a gate,
 *      resume with lastEventId: a LIVE leg (B subscribes while the gate holds;
 *      remaining events fan out live, exactly once, ground-truthed against
 *      events.readSince(null)) AND a REPLAY leg (after run_completed, C
 *      subscribes with the same cursor and must get the identical tail from
 *      the replay read alone — pins replay-from-non-null-cursor, which B's
 *      provably-empty replay cannot).
 *   c. degraded backend (Review Focus #5, two-part controller ruling) —
 *      queue add rejects → 503 unavailable + run row stays 'queued'; AND
 *      redis-q URL at a closed port → health 503 {db:true, redisQ:false}.
 *   d. per-user boundaries — B subscribe → forbidden frame; B GET session /
 *      messages → 404.
 *   e. single-active-run ordering (C1) — two rapid sends to ONE session with
 *      a gated first run: run2's run_started arrives strictly AFTER run1's
 *      run_completed, no interleaved deltas, final transcript order
 *      user1, user2, assistant1, assistant2.
 *
 * Heartbeat e2e is explicitly OUT of scope (Task 8 minor: pingIntervalMs seam
 * is not plumbed through buildGateway).
 *
 * Determinism: gates/deferreds, never timing guesses; bounded waits with
 * deadlines only for I/O settle. Shared dev services: no FLUSHDB — cleanup
 * DELetes only this suite's stream keys and obliterates only the pinned
 * agent-runs queue after the worker is closed.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** Contract path (hardcoded on purpose — same pin as ws.test.ts). */
const WS_PATH = "/cloud/ws";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond: () => boolean, what: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(10);
  }
}

async function waitForAsync(
  cond: () => Promise<boolean>,
  what: string,
  timeoutMs = 15_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await cond())) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(25);
  }
}

interface Deferred {
  promise: Promise<void>;
  resolve(): void;
}

function deferred(): Deferred {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

/**
 * Redis stream ids are "ms-i"; compare NUMERICALLY on both parts (same
 * algorithm as the gateway's ws.ts — not part of @ovid/gateway's public
 * surface, so the test keeps its own copy).
 */
function compareSeq(a: string, b: string): number {
  const [aMs = 0, aIdx = 0] = a.split("-").map(Number);
  const [bMs = 0, bIdx = 0] = b.split("-").map(Number);
  if (aMs !== bMs) return aMs < bMs ? -1 : 1;
  if (aIdx !== bIdx) return aIdx < bIdx ? -1 : 1;
  return 0;
}

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

// ---------------------------------------------------------------------------
// Mock LiteLLM: an http server speaking OpenAI-dialect SSE with per-test
// pacing hooks. arm() installs the script the NEXT request streams; the gate
// parks the response mid-stream until release() (a deferred — no sleeps).
// ---------------------------------------------------------------------------

interface SseScript {
  deltas: string[];
  /** Wait this long before writing each delta (default 0). */
  chunkDelayMs: number;
  /** After writing the Nth delta, hold the response open until released. */
  gateAfterDeltas: number | null;
  /** After writing the Nth delta, destroy the socket WITHOUT [DONE]. */
  closeSocketAfterDeltas: number | null;
}

interface SseArm {
  release(): void;
}

interface SseMock {
  baseUrl: string;
  arm(script: Partial<SseScript> & { deltas: string[] }): SseArm;
  /** Every model request seen: auth header + parsed JSON body. */
  requests: Array<{ authorization: string | undefined; body: unknown }>;
  close(): Promise<void>;
}

async function startSseMock(): Promise<SseMock> {
  let script: SseScript = {
    deltas: [],
    chunkDelayMs: 0,
    gateAfterDeltas: null,
    closeSocketAfterDeltas: null,
  };
  let gate: Deferred = deferred();
  const requests: SseMock["requests"] = [];

  async function stream(res: ServerResponse, s: SseScript, g: Deferred): Promise<void> {
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
    const writeData = (payload: string): void => {
      res.write(`data: ${payload}\n\n`);
    };
    for (let i = 0; i < s.deltas.length; i += 1) {
      if (s.chunkDelayMs > 0) await sleep(s.chunkDelayMs);
      if (res.destroyed || res.writableEnded) return; // client vanished mid-stream
      writeData(
        JSON.stringify({ choices: [{ delta: { content: s.deltas[i] }, finish_reason: null }] }),
      );
      const written = i + 1;
      if (s.closeSocketAfterDeltas === written) {
        res.socket?.destroy(); // truncated stream: the transport must surface it as transient
        return;
      }
      if (s.gateAfterDeltas === written) {
        await g.promise; // park mid-run until the test releases
        if (res.destroyed || res.writableEnded) return;
      }
    }
    writeData(JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] }));
    res.end("data: [DONE]\n\n");
  }

  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      requests.push({
        authorization: req.headers.authorization,
        body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
      });
      // Snapshot per request: a later arm() can never mutate an in-flight stream.
      void stream(res, { ...script }, gate);
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    arm(next) {
      script = {
        chunkDelayMs: 0,
        gateAfterDeltas: null,
        closeSocketAfterDeltas: null,
        ...next,
      };
      gate = deferred();
      const g = gate;
      return { release: () => g.resolve() };
    },
    requests,
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

/** A local port that is guaranteed to be CLOSED when the caller uses it. */
async function reserveThenReleasePort(): Promise<number> {
  const srv = createTcpServer();
  await new Promise<void>((resolve) => srv.listen(0, "127.0.0.1", resolve));
  const port = (srv.address() as AddressInfo).port;
  await new Promise<void>((resolve) => srv.close(() => resolve()));
  return port;
}

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "cloud spine e2e (real gateway + real worker + real Postgres/Redis)",
  () => {
    let db: Db;
    let redis: Redis;
    /** Created ONCE, shared by gateway deps and RunDeps (Task 8 carry-over). */
    let events: EventLog;
    let tickets: TicketStore;
    let queues: QueueServices;
    let worker: ReturnType<typeof createAgentRunsWorker>;
    let sse: SseMock;
    let app: ReturnType<typeof buildGateway>;
    let baseUrl: string;
    let wsBase: string;

    const clients: Array<TestClient> = [];
    const extraApps: Array<ReturnType<typeof buildGateway>> = [];
    const extraQueues: QueueServices[] = [];
    const createdSids: string[] = [];
    const workerFailures: Array<{ jobId: string | undefined; message: string }> = [];
    const workerErrors: string[] = [];
    const sleeps: number[] = [];
    /** Released defensively in afterAll so worker.close() can never hang. */
    let activeGate: SseArm | null = null;
    /**
     * Suite-unique BullMQ prefix: parallel suites share the dev redis, so
     * this suite's obliterate call can only ever wipe its OWN queue keys.
     */
    const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
      ? `${process.env.OVID_TEST_QUEUE_PREFIX}-e2e`
      : "ovid-test-e2e";

    // Mint/key stubs per the binding decision: the mock LiteLLM ignores key
    // validity, so a constant "test-key" is enough end to end.
    const keys: KeyProvider = { getKeyForUser: async () => "test-key" };
    const mint: MintProvisioner = { ensureKey: async () => ({ key: "test-key" }) };

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redis = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);

      // OBJECT form mandatory — a bare URL string is spread into garbage opts
      // by withBlockingSafeRetries and hangs (Task 7 lesson, Task 9 carry-over).
      const connection = { url: TEST_REDIS_URL! };
      queues = createQueues(connection, { prefix: QUEUE_PREFIX });

      sse = await startSseMock();
      const processor = createAgentRunProcessor({
        db,
        events,
        keys,
        transport: createOpenAiTransport(),
        litellmBaseUrl: sse.baseUrl,
        defaultModel: "e2e-model",
        sleep: async (ms) => {
          sleeps.push(ms);
          await sleep(ms); // REALLY wait: the C1 same-session wait loop polls on this
        },
      });
      worker = createAgentRunsWorker(connection, processor, { prefix: QUEUE_PREFIX });
      worker.on("failed", (job, err) => {
        workerFailures.push({ jobId: job?.id, message: err.message });
      });
      worker.on("error", (err) => {
        workerErrors.push(err.message);
      });

      app = buildGateway({
        db,
        queues,
        verifier: createTestVerifier(),
        tickets,
        keys,
        mint,
        events,
      });
      await app.listen({ host: "127.0.0.1", port: 0 });
      const port = (app.server.address() as AddressInfo).port;
      baseUrl = `http://127.0.0.1:${port}`;
      wsBase = `ws://127.0.0.1:${port}${WS_PATH}`;
    }, 60_000);

    afterAll(async () => {
      // Release any still-held gate FIRST: worker.close() waits for active
      // jobs, and a parked SSE response would hang it forever.
      activeGate?.release();
      activeGate = null;

      while (clients.length > 0) await clients.pop()!.close().catch(() => {});
      await worker?.close();

      // Apps after clients: closing the WS clients triggers the gateway's
      // per-socket teardown (each subscription quits its dedicated redis
      // pub/sub connection) before the HTTP servers go away.
      await app?.close();
      while (extraApps.length > 0) await extraApps.pop()!.close().catch(() => {});

      if (queues) {
        // Same discipline as queues.test.ts / runProcessor.test.ts: obliterate
        // the pinned queue keys (worker is closed, so force is safe) and close
        // the blocking connections, or vitest never exits.
        await queues.agentRuns.obliterate({ force: true }).catch(() => {});
        await queues.agentRuns.close().catch(() => {});
      }
      while (extraQueues.length > 0) {
        await extraQueues.pop()!.agentRuns.close().catch(() => {});
      }

      await sse?.close();

      // Clean only what this suite created: one event stream per session.
      // Ticket keys are single-use (consumed by verify) and TTL'd anyway.
      if (createdSids.length > 0) {
        await redis
          ?.del(createdSids.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }

      // No leaked subscriber connections: every session channel this suite
      // opened must be gone from the shared dev redis (bounded settle wait —
      // gateway teardown runs unsubscribe()s asynchronously). A leak here
      // fails the suite: every subscription owns a dedicated redis connection.
      const ours = new Set(createdSids.map((id) => `sess:${id}:live`));
      await waitForAsync(async () => {
        // redis.call keeps this future-proof against ioredis's pubsub overload
        // set (its typings don't expose CHANNELS-with-pattern cleanly).
        const channels = (await redis.call("PUBSUB", "CHANNELS", "sess:*")) as string[];
        return channels.every((c) => !ours.has(c));
      }, "suite pubsub channels torn down");

      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });
    }, 60_000);

    // ---- HTTP + WS helpers -------------------------------------------------

    interface HttpResult {
      status: number;
      body: unknown;
    }

    async function api(
      base: string,
      method: string,
      path: string,
      opts: { uid?: string; body?: unknown } = {},
    ): Promise<HttpResult> {
      const headers: Record<string, string> = {};
      if (opts.uid !== undefined) headers.authorization = `Bearer test:${opts.uid}`;
      if (opts.body !== undefined) headers["content-type"] = "application/json";
      const res = await fetch(`${base}${path}`, {
        method,
        headers,
        body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
      });
      const text = await res.text();
      let body: unknown;
      try {
        body = text === "" ? null : JSON.parse(text);
      } catch {
        body = text;
      }
      return { status: res.status, body };
    }

    interface TestClient {
      socket: WebSocket;
      /** Every server frame, parsed THROUGH the shared schema (off-contract frames throw). */
      messages: WsServerMsg[];
      send(msg: unknown): void;
      events(): SessionEvent[];
      waitFor(cond: () => boolean, what: string, timeoutMs?: number): Promise<void>;
      /** Abrupt teardown — no close handshake (the mid-run disconnect of flow b). */
      terminate(): void;
      close(): Promise<void>;
    }

    async function connectWs(base: string, ticket: string): Promise<TestClient> {
      const socket = new WebSocket(`${base}?ticket=${encodeURIComponent(ticket)}`);
      const messages: WsServerMsg[] = [];
      socket.on("message", (data) => {
        messages.push(wsServerMsg(JSON.parse(data.toString())));
      });
      await new Promise<void>((resolve, reject) => {
        const onError = (err: Error): void => reject(err);
        socket.once("error", onError);
        socket.once("open", () => {
          socket.off("error", onError);
          resolve();
        });
      });
      // Abrupt terminations (flow b) emit 'error' — always keep a sink attached.
      socket.on("error", () => {});

      const client: TestClient = {
        socket,
        messages,
        send: (msg) => socket.send(JSON.stringify(msg)),
        events: () => messages.flatMap((m) => (m.op === "event" ? [m.event] : [])),
        waitFor: (cond, what, timeoutMs) => waitFor(cond, what, timeoutMs),
        terminate: () => socket.terminate(),
        close: () =>
          new Promise<void>((resolve) => {
            if (socket.readyState === WebSocket.CLOSED) {
              resolve();
              return;
            }
            socket.once("close", () => resolve());
            socket.close();
          }),
      };
      clients.push(client);
      return client;
    }

    async function createSession(user: string, base = baseUrl): Promise<string> {
      const res = await api(base, "POST", "/cloud/v1/sessions", { uid: user, body: {} });
      expect(res.status).toBe(201);
      const session = sessionDtoSchema.parse(res.body);
      createdSids.push(session.id);
      return session.id;
    }

    async function getTicket(user: string, base = baseUrl): Promise<string> {
      const res = await api(base, "POST", "/cloud/v1/auth/ticket", { uid: user });
      expect(res.status).toBe(200);
      const ticket = (res.body as { ticket?: unknown }).ticket;
      if (typeof ticket !== "string" || ticket === "") throw new Error("no ticket minted");
      return ticket;
    }

    /** Connect + subscribe + assert the `subscribed` ack arrived first. */
    async function openSubscribedClient(
      user: string,
      sessionId: string,
      lastEventId: string | null,
      base = wsBase,
    ): Promise<TestClient> {
      const client = await connectWs(base, await getTicket(user));
      client.send({ op: "subscribe", sessionId, lastEventId });
      await client.waitFor(() => client.messages.length >= 1, "subscribed ack");
      expect(client.messages[0]).toEqual({ op: "subscribed", sessionId });
      return client;
    }

    async function sendMessage(
      user: string,
      sessionId: string,
      content: string,
      base = baseUrl,
    ): Promise<SendMessageResponse> {
      const res = await api(base, "POST", `/cloud/v1/sessions/${sessionId}/messages`, {
        uid: user,
        body: { content },
      });
      expect(res.status).toBe(202);
      const body = res.body as SendMessageResponse;
      expect(body.status).toBe("queued");
      expect(typeof body.runId).toBe("string");
      expect(typeof body.userMessageId).toBe("string");
      return body;
    }

    async function runRow(runId: string): Promise<{ status: string; attempts: number }> {
      const rows = await db.$client.unsafe(
        "SELECT status, attempts FROM runs WHERE id = $1",
        [runId],
      );
      const row = rows[0] as unknown as { status: string; attempts: number } | undefined;
      if (row === undefined) throw new Error(`run row missing: ${runId}`);
      return { status: row.status, attempts: row.attempts };
    }

    function armSse(script: Partial<SseScript> & { deltas: string[] }): SseArm {
      const handle = sse.arm(script);
      activeGate = handle;
      return handle;
    }

    const typesOf = (evts: SessionEvent[]): string[] => evts.map((e) => e.type);
    const deltaTexts = (evts: SessionEvent[]): string[] =>
      evts.filter((e) => e.type === "message_delta").map((e) => e.payload.text as string);

    function expectSeqsStrictlyMonotonic(seqs: string[]): void {
      for (let i = 1; i < seqs.length; i += 1) {
        expect(compareSeq(seqs[i]!, seqs[i - 1]!)).toBe(1);
      }
    }

    // ---- Flow a: happy path ------------------------------------------------

    it("flow a — REST send → 202; WS delivers run_started → deltas → message_completed → run_completed in order; deltas == assistant content; GET messages user→assistant; users + run rows", async () => {
      const user = uid("e2e-a");
      // Small per-chunk delay: the run is still streaming while the client
      // mints its ticket and subscribes, so the frames below arrive through
      // the live path (the assertions hold for replay too — dedupe guarantees
      // the exact order either way).
      armSse({ deltas: ["Hello", ", ", "spine!"], chunkDelayMs: 120 });

      const sessionId = await createSession(user);
      const sent = await sendMessage(user, sessionId, "say hello");
      const client = await openSubscribedClient(user, sessionId, null);

      await client.waitFor(
        () => client.events().some((e) => e.type === "run_completed"),
        "run_completed on WS",
        25_000,
      );
      await sleep(200); // settle window: give any (wrongly) duplicated frame a chance to arrive

      const evts = client.events();
      expect(typesOf(evts)).toEqual([
        "run_started",
        "message_delta",
        "message_delta",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      // subscribed ack + the 6 events — no stray frames of any other op
      expect(client.messages.length).toBe(7);
      expect(evts.every((e) => e.sessionId === sessionId)).toBe(true);
      expectSeqsStrictlyMonotonic(evts.map((e) => e.seq));
      expect(evts[0]!.payload).toEqual({ runId: sent.runId });
      expect(deltaTexts(evts)).toEqual(["Hello", ", ", "spine!"]);
      const fullText = deltaTexts(evts).join("");
      expect(fullText).toBe("Hello, spine!");
      expect(evts[4]!.payload).toEqual({
        messageId: expect.any(String),
        content: fullText, // deltas concatenate to the assistant content
      });
      expect(evts[5]!.payload).toEqual({ runId: sent.runId });
      const assistantMessageId = (evts[4]!.payload as { messageId: string }).messageId;

      // REST history: the page is newest-first, so chronologically the user
      // message comes first and the assistant reply second.
      const pageRes = await api(baseUrl, "GET", `/cloud/v1/sessions/${sessionId}/messages`, {
        uid: user,
      });
      expect(pageRes.status).toBe(200);
      const page = pageSchema(messageDtoSchema).parse(pageRes.body);
      const chronological = [...page.items].reverse();
      expect(chronological.map((m) => m.role)).toEqual(["user", "assistant"]);
      expect(chronological[0]!.id).toBe(sent.userMessageId);
      expect(chronological[0]!.content).toBe("say hello");
      expect(chronological[1]!.id).toBe(assistantMessageId);
      expect(chronological[1]!.content).toBe(fullText);

      // users row ensured by the authenticated request path (tier drives queue priority)
      const userRows = await db.$client.unsafe("SELECT uid, tier FROM users WHERE uid = $1", [
        user,
      ]);
      expect(userRows.length).toBe(1);
      expect((userRows[0] as unknown as { tier: string }).tier).toBe("free");

      // run row completed
      expect(await runRow(sent.runId)).toEqual({ status: "completed", attempts: 1 });

      // the real transport carried the stub key, model and prompt to "LiteLLM"
      const modelReq = sse.requests.at(-1);
      expect(modelReq?.authorization).toBe("Bearer test-key");
      const body = modelReq?.body as { model: string; stream: boolean; messages: Array<{ role: string; content: string }> };
      expect(body.model).toBe("e2e-model");
      expect(body.stream).toBe(true);
      expect(body.messages.at(-1)).toEqual({ role: "user", content: "say hello" });

      expect(workerFailures).toEqual([]);
      expect(workerErrors).toEqual([]);
      // Happy path: no transient-failure backoff sleeps may have happened.
      expect(sleeps).toEqual([]);
      await client.close();
    });

    // ---- Flow b: mid-run reconnect (Review Focus #1) -----------------------

    it("flow b — abrupt disconnect mid-run, resume with lastEventId: remaining events arrive exactly once (live leg) and replay-from-cursor returns the same tail post-completion (replay leg), monotonic, no gaps vs readSince ground truth", async () => {
      const user = uid("e2e-b");
      const pieces = ["alpha ", "beta ", "gamma ", "delta"];
      // The gate parks the SSE response after 2 deltas: the run is provably
      // mid-stream (no completion events can exist) until release().
      const gate = armSse({ deltas: pieces, chunkDelayMs: 30, gateAfterDeltas: 2 });

      const sessionId = await createSession(user);
      const clientA = await openSubscribedClient(user, sessionId, null);
      const sent = await sendMessage(user, sessionId, "tell me a story");

      // Client A sees run_started + the two pre-gate deltas — and NOTHING
      // more while the gate holds (the stream contains exactly these three).
      await clientA.waitFor(() => clientA.events().length >= 3, "run_started + 2 deltas on A");
      const aEvents = clientA.events();
      expect(typesOf(aEvents)).toEqual(["run_started", "message_delta", "message_delta"]);
      expect(clientA.messages.length).toBe(4); // ack + 3 events, nothing past the gate
      expect(deltaTexts(aEvents)).toEqual(["alpha ", "beta "]);
      const lastEventId = aEvents[2]!.seq;

      // Abrupt teardown (no close handshake) — the thin client's network drop.
      clientA.terminate();

      // Client B resumes from A's last seq WHILE the run is still gated, so
      // the replay is empty (asserted) and everything after comes LIVE.
      const clientB = await openSubscribedClient(user, sessionId, lastEventId);
      expect(clientB.events()).toEqual([]); // nothing after lastEventId exists yet

      gate.release();

      await clientB.waitFor(
        () => clientB.events().some((e) => e.type === "run_completed"),
        "run_completed on B",
        25_000,
      );
      await sleep(200); // settle window for wrongly duplicated frames

      const bEvents = clientB.events();
      expect(typesOf(bEvents)).toEqual([
        "message_delta",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(clientB.messages.length).toBe(5); // ack + 4 events, exactly once each
      expect(bEvents.map((e) => e.payload).slice(0, 2)).toEqual([
        { runId: sent.runId, text: "gamma " },
        { runId: sent.runId, text: "delta" },
      ]);
      expect(bEvents[2]!.payload).toEqual({
        messageId: expect.any(String),
        content: "alpha beta gamma delta",
      });
      expect(bEvents[3]!.payload).toEqual({ runId: sent.runId });

      // Ground truth: the FULL stream, read back from redis.
      const full = await events.readSince(sessionId, null, 500);
      expect(typesOf(full)).toEqual([
        "run_started",
        "message_delta",
        "message_delta",
        "message_delta",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      // A's prefix + B's suffix == the full stream, event for event:
      // no duplicates, no gaps, no reordering across the reconnect.
      expect([...aEvents, ...bEvents]).toEqual(full);
      const seqs = [...aEvents, ...bEvents].map((e) => e.seq);
      expect(new Set(seqs).size).toBe(seqs.length); // exactly once
      expectSeqsStrictlyMonotonic(seqs); // monotonic across BOTH lives

      expect(await runRow(sent.runId)).toEqual({ status: "completed", attempts: 1 });
      expect(workerFailures).toEqual([]);
      // Happy path: no transient-failure backoff sleeps may have happened.
      expect(sleeps).toEqual([]);

      // ---- Post-completion resume leg (fix round 1, reviewer Important #1) ----
      // The run is FINISHED: nothing more will ever be appended or published,
      // so every frame client C receives must come from the REPLAY read with a
      // non-null cursor. B's leg cannot exercise that path (its replay was
      // provably empty; its events arrived live) — a gateway regression that
      // skips or botches replay-from-cursor is invisible there and fatal here.
      const clientC = await openSubscribedClient(user, sessionId, lastEventId);
      await clientC.waitFor(() => clientC.events().length >= 4, "C replays the remaining 4 events");
      await sleep(200); // settle: C must receive NO frame beyond the replay
      const cEvents = clientC.events();
      expect(typesOf(cEvents)).toEqual([
        "message_delta",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(clientC.messages.length).toBe(5); // ack + the 4 replayed events, nothing else
      // Exactly the events after A's cursor, deep-equal against the ground truth…
      expect(cEvents).toEqual(full.slice(3));
      // …and identical to what B received live: replay and live fanout converge.
      expect(cEvents).toEqual(bEvents);
      expectSeqsStrictlyMonotonic(cEvents.map((e) => e.seq));

      await clientB.close();
      await clientC.close();
    });

    // ---- Flow c: degraded backend (Review Focus #5, two-part ruling) -------

    it("flow c — queue add rejects → 503 unavailable + run row stays 'queued'; redis-q at a closed port → health 503 degraded {db:true, redisQ:false}", async () => {
      // -- Part 1: enqueue failure is loud (503) and leaves a reconcilable row.
      const deadQueues = {
        agentRuns: {
          add: async () => {
            throw new Error("redis-q unreachable (simulated)");
          },
          client: Promise.resolve({ ping: async () => "PONG" }),
        },
      } as unknown as QueueServices;
      const brokenApp = buildGateway({
        db,
        queues: deadQueues,
        verifier: createTestVerifier(),
        tickets,
        keys,
        mint,
        events,
      });
      extraApps.push(brokenApp);
      await brokenApp.listen({ host: "127.0.0.1", port: 0 });
      const brokenBase = `http://127.0.0.1:${(brokenApp.server.address() as AddressInfo).port}`;

      const userC1 = uid("e2e-c1");
      const sidC1 = await createSession(userC1, brokenBase);
      const res = await api(
        brokenBase,
        "POST",
        `/cloud/v1/sessions/${sidC1}/messages`,
        { uid: userC1, body: { content: "will not enqueue" } },
      );
      expect(res.status).toBe(503);
      expect((res.body as ApiError).error.code).toBe("unavailable");

      // Documented ruling: the user message row persists and the run row is
      // LEFT 'queued' for an operator/reconciler — not deleted.
      const runRows = (await db.$client.unsafe(
        "SELECT id, status FROM runs WHERE session_id = $1",
        [sidC1],
      )) as Array<{ id: string; status: string }>;
      expect(runRows.length).toBe(1);
      expect(runRows[0]!.status).toBe("queued");
      const msgRows = (await db.$client.unsafe(
        "SELECT role FROM messages WHERE session_id = $1",
        [sidC1],
      )) as Array<{ role: string }>;
      expect(msgRows.map((m) => m.role)).toEqual(["user"]);
      // Nothing was ever processed: zero events for the session.
      expect(await events.readSince(sidC1, null, 10)).toEqual([]);

      await brokenApp.close();

      // -- Part 2: health reflects a dead redis-q (URL at a closed port).
      // Control first: the healthy gateway reports ok.
      const okRes = await api(baseUrl, "GET", "/cloud/v1/health");
      expect(okRes.status).toBe(200);
      expect(okRes.body).toEqual({ status: "ok", checks: { db: true, redisQ: true } });

      const deadPort = await reserveThenReleasePort();
      const deadRealQueues = createQueues(
        {
          url: `redis://127.0.0.1:${deadPort}`,
          // Bounded retries: once ioredis stops retrying it flushes queued
          // commands with errors, so the probe's ping() rejects fast instead of
          // leaning solely on the 1 s probe timeout — and no reconnect timer
          // outlives the test.
          retryStrategy: (times: number) => (times >= 3 ? null : 50),
        },
        { prefix: QUEUE_PREFIX },
      );
      extraQueues.push(deadRealQueues);
      deadRealQueues.agentRuns.on("error", () => {}); // expected ECONNREFUSED noise
      const degradedApp = buildGateway({
        db,
        queues: deadRealQueues,
        verifier: createTestVerifier(),
        tickets,
        keys,
        mint,
        events,
      });
      extraApps.push(degradedApp);
      await degradedApp.listen({ host: "127.0.0.1", port: 0 });
      const degradedBase = `http://127.0.0.1:${(degradedApp.server.address() as AddressInfo).port}`;

      // Public route: no auth headers.
      const healthRes = await api(degradedBase, "GET", "/cloud/v1/health");
      expect(healthRes.status).toBe(503);
      expect(healthRes.body).toEqual({
        status: "degraded",
        checks: { db: true, redisQ: false },
      });

      await degradedApp.close();
      await deadRealQueues.agentRuns.close();
    });

    // ---- Flow d: per-user access boundaries --------------------------------

    it("flow d — user B: WS subscribe to A's session → forbidden frame (no ack, socket survives); GET session + GET messages → 404", async () => {
      const userA = uid("e2e-d-a");
      const userB = uid("e2e-d-b");
      const sessionId = await createSession(userA);

      // REST: wrong-owner reads are 404 not_found — never 403, no existence leaks.
      const getRes = await api(baseUrl, "GET", `/cloud/v1/sessions/${sessionId}`, {
        uid: userB,
      });
      expect(getRes.status).toBe(404);
      expect((getRes.body as ApiError).error.code).toBe("not_found");

      const msgsRes = await api(baseUrl, "GET", `/cloud/v1/sessions/${sessionId}/messages`, {
        uid: userB,
      });
      expect(msgsRes.status).toBe(404);
      expect((msgsRes.body as ApiError).error.code).toBe("not_found");

      // Same boundary on the write path (ownership checked before anything else).
      const sendRes = await api(
        baseUrl,
        "POST",
        `/cloud/v1/sessions/${sessionId}/messages`,
        { uid: userB, body: { content: "intruder" } },
      );
      expect(sendRes.status).toBe(404);
      expect((sendRes.body as ApiError).error.code).toBe("not_found");

      // WS: B subscribes to A's session with a VALID ticket for B.
      const clientB = await connectWs(wsBase, await getTicket(userB));
      clientB.send({ op: "subscribe", sessionId, lastEventId: null });
      await clientB.waitFor(() => clientB.messages.length >= 1, "forbidden error frame");
      await sleep(150); // settle: no (wrongly granted) subscribed ack may follow
      expect(clientB.messages).toEqual([
        {
          op: "error",
          code: "forbidden",
          message: expect.any(String),
          sessionId,
        },
      ]);
      expect(clientB.events()).toEqual([]);
      // The rejection kills the subscription, not the connection.
      expect(clientB.socket.readyState).toBe(WebSocket.OPEN);

      await clientB.close();
    });

    // ---- Flow e: single-active-run ordering (C1) ---------------------------

    it("flow e — two rapid sends to one session: run2's run_started strictly AFTER run1's run_completed; no interleaved deltas; transcript user1,user2,assistant1,assistant2", async () => {
      const user = uid("e2e-e");
      // The gate parks run1's stream after 1 delta: run1 is provably mid-run
      // (no completion events can exist) while run2 is enqueued.
      const gate = armSse({ deltas: ["first ", "reply"], chunkDelayMs: 30, gateAfterDeltas: 1 });

      const sessionId = await createSession(user);
      const client = await openSubscribedClient(user, sessionId, null);
      const sent1 = await sendMessage(user, sessionId, "message one");

      // Run1 is mid-stream: run_started + the pre-gate delta, nothing more.
      await client.waitFor(
        () => client.events().length >= 2,
        "run1 run_started + first delta",
      );
      expect(typesOf(client.events())).toEqual(["run_started", "message_delta"]);

      // Second rapid send WHILE run1 is parked at the gate. Worker concurrency
      // is 8, so run2's job is picked up immediately — the C1 wait loop must
      // hold it: nothing of run2's may appear on the wire yet.
      const sent2 = await sendMessage(user, sessionId, "message two");
      await sleep(400); // settle window: any (wrongly) started run2 event lands here
      expect(
        client.events().filter((e) => e.payload.runId === sent2.runId),
      ).toEqual([]);
      expect((await runRow(sent2.runId)).status).toBe("queued"); // waiting, not running

      gate.release();

      await client.waitFor(
        () =>
          client.events().filter((e) => e.type === "run_completed").length === 2,
        "both runs completed",
        25_000,
      );
      await sleep(300); // settle window: no frame may arrive after the tail

      const evts = client.events();
      // The C1 ordering pin: run2's run_started STRICTLY after run1's
      // run_completed — both in arrival order and by stream seq.
      const completed1 = evts.findIndex(
        (e) => e.type === "run_completed" && e.payload.runId === sent1.runId,
      );
      const started2 = evts.findIndex(
        (e) => e.type === "run_started" && e.payload.runId === sent2.runId,
      );
      expect(completed1).toBeGreaterThanOrEqual(0);
      expect(started2).toBeGreaterThan(completed1);
      expect(compareSeq(evts[started2]!.seq, evts[completed1]!.seq)).toBe(1);
      expectSeqsStrictlyMonotonic(evts.map((e) => e.seq));

      // No interleaving: run1's deltas form one contiguous block, run2's
      // another, and run2's block starts only after run1's run_completed.
      const deltaRunIds = evts
        .filter((e) => e.type === "message_delta")
        .map((e) => e.payload.runId);
      expect(deltaRunIds).toEqual([sent1.runId, sent1.runId, sent2.runId, sent2.runId]);
      // run1's LAST delta precedes run2's run_started: nothing of run2's
      // stream can precede its own start.
      const lastRun1Delta = evts.reduce(
        (acc, e, i) => (e.type === "message_delta" && e.payload.runId === sent1.runId ? i : acc),
        -1,
      );
      expect(lastRun1Delta).toBeLessThan(started2);

      // run2's model call saw the serialized context: user1, user2,
      // assistant1 — the prompt of run2 ("message two") exactly once, last.
      const run2Request = sse.requests.at(-1);
      const run2Body = run2Request?.body as {
        messages: Array<{ role: string; content: string }>;
      };
      expect(run2Body.messages).toEqual([
        { role: "user", content: "message one" },
        { role: "user", content: "message two" },
        { role: "assistant", content: "first reply" },
      ]);

      // Final transcript: user1, user2, assistant1, assistant2 (page is
      // newest-first; chronological is the reverse).
      const pageRes = await api(baseUrl, "GET", `/cloud/v1/sessions/${sessionId}/messages`, {
        uid: user,
      });
      expect(pageRes.status).toBe(200);
      const page = pageSchema(messageDtoSchema).parse(pageRes.body);
      const chronological = [...page.items].reverse();
      expect(chronological.map((m) => m.role)).toEqual([
        "user",
        "user",
        "assistant",
        "assistant",
      ]);
      expect(chronological.map((m) => m.content)).toEqual([
        "message one",
        "message two",
        "first reply",
        "first reply",
      ]);
      expect(chronological[0]!.id).toBe(sent1.userMessageId);
      expect(chronological[1]!.id).toBe(sent2.userMessageId);

      // Both run rows completed, one model attempt each, no job failures.
      expect(await runRow(sent1.runId)).toEqual({ status: "completed", attempts: 1 });
      expect(await runRow(sent2.runId)).toEqual({ status: "completed", attempts: 1 });
      expect(workerFailures).toEqual([]);
      expect(workerErrors).toEqual([]);
      // No transient-failure backoff sleeps: the ONLY sleeps are C1 poll
      // intervals (250 ms) while run2 waited behind the gated run1.
      expect(sleeps.length).toBeGreaterThan(0);
      expect(sleeps.filter((s) => s !== 250)).toEqual([]);

      await client.close();
    }, 30_000);
  },
);
