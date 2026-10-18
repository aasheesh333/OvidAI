import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import WebSocket, { WebSocketServer } from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, eventMirror, migrate, type Db } from "@ovid/db";
import {
  createRedisEventLog,
  createRedisSystemBus,
  type EventLog,
} from "@ovid/events";
import { createAgentRunsWorker, createQueues, type QueueServices } from "@ovid/queue";
import {
  buildGateway,
  createTestVerifier,
  createTicketStore,
  type TicketStore,
} from "@ovid/gateway";
import { createAgentRunProcessor, createOpenAiTransport } from "@ovid/worker";
import {
  sessionDtoSchema,
  type InternalMintProvisioner,
  type KeyProvider,
  type KeyResolver,
  type SessionEvent,
  type SessionEventType,
  type WsClientMsg,
  type WsServerMsg,
} from "@ovid/shared";
import { createLoadClient, runScenario, type LoadProfile, type LoadTarget } from "./index.js";
import { startMockLlmServer, type MockLlmServer } from "./mockServer.js";
import { SMOKE_THRESHOLDS, checkThresholds } from "./thresholds.js";

/**
 * Two tiers in this file:
 *
 * 1. UNIT (always runs): a hand-written mock gateway (HTTP + WS, in-process)
 *    plus the in-process mock LiteLLM. It pins the harness's own mechanics
 *    (ramp, cadence, reconnect+replay, drain, ground-truth diff) without any
 *    external service. It is NOT the plan's integration proof.
 * 2. INTEGRATION (skipped unless TEST_DATABASE_URL && TEST_REDIS_URL): the
 *    REAL `buildGateway` + REAL worker composed in one process over a real
 *    Redis event log, real BullMQ queues and real Postgres, exactly like
 *    `apps/e2e/src/spine.test.ts`. This is Task 4 Step 4's test: 10 users /
 *    20 s, `chunkDelayMs: 20`, real ticket/session/message/WS routes. It must
 *    run against an isolated database and Redis (the e2e suite's pattern).
 *
 * The mock gateway is the smallest composition that honours the wire
 * contract the harness consumes: `POST /auth/ticket`, `POST /sessions`,
 * `POST /sessions/:id/messages`, and `/cloud/ws` with
 * `{op:"subscribe", sessionId, lastEventId}`. Every server frame it emits is
 * constructed as `WsServerMsg`, and the client re-validates every frame
 * through the shared `wsServerMsg` schema — the same contract the real
 * gateway emits.
 *
 * The smoke profile is a scaled-down smoke10: the mechanics (ramp, cadence,
 * reconnect+replay, drain, ground-truth diff) are identical; only the
 * wall-clock budget is shorter so the suite stays fast. Task 5 runs the real
 * 10-user/2-minute profile against staging.
 */

/** Redis stream ids compare numerically on both parts. */
function compareSeq(a: string, b: string): number {
  const [aMs = 0, aIdx = 0] = a.split("-").map(Number);
  const [bMs = 0, bIdx = 0] = b.split("-").map(Number);
  if (aMs !== bMs) return aMs < bMs ? -1 : 1;
  if (aIdx !== bIdx) return aIdx < bIdx ? -1 : 1;
  return 0;
}

/** In-memory EventLog — the scenario's `readSince` ground truth. */
function createMemoryEventLog(): EventLog {
  const bySession = new Map<string, SessionEvent[]>();
  let ms = 0;
  let sub = 0;
  const nextSeq = (): string => {
    const now = Date.now();
    if (now > ms) {
      ms = now;
      sub = 0;
    }
    sub += 1;
    return `${ms}-${sub}`;
  };
  return {
    async append(sessionId, type, payload) {
      const event: SessionEvent = {
        sessionId,
        seq: nextSeq(),
        type,
        payload,
        ts: new Date().toISOString(),
      };
      const list = bySession.get(sessionId) ?? [];
      list.push(event);
      bySession.set(sessionId, list);
      return event;
    },
    async readSince(sessionId, lastSeq, limit) {
      if (limit <= 0) return [];
      const list = bySession.get(sessionId) ?? [];
      return list
        .filter((e) => lastSeq === null || compareSeq(e.seq, lastSeq) > 0)
        .slice(0, limit);
    },
    async subscribe() {
      throw new Error("in-memory EventLog subscribe is not used by the smoke test");
    },
  };
}

interface MockGateway {
  baseUrl: string;
  wsBase: string;
  eventLog: EventLog;
  close(): Promise<void>;
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  const text = Buffer.concat(chunks).toString("utf8");
  return text === "" ? {} : JSON.parse(text);
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function sendWs(socket: WebSocket, msg: WsServerMsg): void {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg));
}

/**
 * Minimal gateway: enough of the P1 contract for the load client. It appends
 * each event to the shared EventLog (the ground truth) and fans it out to
 * subscribers; `subscribe` replays strictly after `lastEventId`.
 */
async function startMockGateway(mockLlmUrl: string): Promise<MockGateway> {
  const eventLog = createMemoryEventLog();
  const tickets = new Map<string, string>();
  const subscribers = new Map<string, Set<WebSocket>>();
  const locks = new Map<string, Promise<unknown>>();
  let ticketSeq = 0;
  let runSeq = 0;
  let messageSeq = 0;

  /** Serializes append+broadcast against replay+register per session. */
  function withLock<T>(sessionId: string, fn: () => Promise<T>): Promise<T> {
    const prev = locks.get(sessionId) ?? Promise.resolve();
    const next = prev.then(fn, fn);
    locks.set(
      sessionId,
      next.catch(() => {}),
    );
    return next;
  }

  async function emit(
    sessionId: string,
    type: SessionEventType,
    payload: Record<string, unknown>,
  ): Promise<SessionEvent> {
    return withLock(sessionId, async () => {
      const event = await eventLog.append(sessionId, type, payload);
      for (const socket of subscribers.get(sessionId) ?? []) {
        sendWs(socket, { op: "event", event });
      }
      return event;
    });
  }

  async function executeRun(
    sessionId: string,
    runId: string,
    content: string,
  ): Promise<void> {
    await emit(sessionId, "run_started", { runId });
    let full = "";
    try {
      const response = await fetch(`${mockLlmUrl}/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          model: "mock-model",
          stream: true,
          messages: [{ role: "user", content }],
        }),
      });
      if (!response.ok || response.body === null) {
        throw new Error(`mock LLM responded ${response.status}`);
      }
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let boundary = buffer.indexOf("\n\n");
        while (boundary >= 0) {
          const frame = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          for (const line of frame.split("\n")) {
            if (!line.startsWith("data: ")) continue;
            const data = line.slice("data: ".length).trim();
            if (data === "[DONE]") continue;
            const parsed = JSON.parse(data) as {
              choices?: Array<{ delta?: { content?: string } }>;
            };
            const text = parsed.choices?.[0]?.delta?.content;
            if (typeof text === "string" && text !== "") {
              full += text;
              await emit(sessionId, "message_delta", { text });
            }
          }
          boundary = buffer.indexOf("\n\n");
        }
      }
      messageSeq += 1;
      await emit(sessionId, "message_completed", {
        messageId: `msg-${messageSeq}`,
        content: full,
      });
      await emit(sessionId, "run_completed", { runId });
    } catch (err) {
      await emit(sessionId, "run_failed", {
        runId,
        code: "mock_error",
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }

  const server = createServer((req, res) => {
    void (async () => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      const path = url.pathname;

      if (req.method === "POST" && path === "/cloud/v1/auth/ticket") {
        const authorization = req.headers.authorization ?? "";
        const uid = authorization.startsWith("Bearer test:")
          ? authorization.slice("Bearer test:".length)
          : "";
        if (uid === "") {
          sendJson(res, 401, { error: { code: "unauthenticated", message: "test auth only" } });
          return;
        }
        ticketSeq += 1;
        const ticket = `ticket-${ticketSeq}`;
        tickets.set(ticket, uid);
        sendJson(res, 200, { ticket });
        return;
      }

      if (req.method === "POST" && path === "/cloud/v1/sessions") {
        await readJson(req);
        const now = new Date().toISOString();
        const session = {
          id: `sess-${++ticketSeq}-${Date.now().toString(36)}`,
          title: null,
          mode: "safe" as const,
          createdAt: now,
          updatedAt: now,
        };
        sendJson(res, 201, sessionDtoSchema.parse(session));
        return;
      }

      const messageMatch = /^\/cloud\/v1\/sessions\/([^/]+)\/messages$/.exec(path);
      if (req.method === "POST" && messageMatch !== null) {
        const sessionId = decodeURIComponent(messageMatch[1]!);
        const body = (await readJson(req)) as { content?: unknown };
        const content = typeof body.content === "string" ? body.content : "";
        runSeq += 1;
        messageSeq += 1;
        const runId = `run-${runSeq}`;
        sendJson(res, 202, {
          runId,
          userMessageId: `msg-${messageSeq}`,
          status: "queued",
        });
        void executeRun(sessionId, runId, content);
        return;
      }

      sendJson(res, 404, { error: { code: "not_found", message: "Route not found." } });
    })().catch((err: unknown) => {
      sendJson(res, 500, {
        error: { code: "internal", message: err instanceof Error ? err.message : String(err) },
      });
    });
  });

  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname !== "/cloud/ws") {
      socket.destroy();
      return;
    }
    const ticket = url.searchParams.get("ticket") ?? "";
    const uid = tickets.get(ticket);
    if (uid === undefined) {
      socket.destroy();
      return;
    }
    tickets.delete(ticket); // single-use
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.on("message", (data) => {
        let msg: WsClientMsg;
        try {
          msg = JSON.parse(data.toString()) as WsClientMsg;
        } catch {
          sendWs(ws, { op: "error", code: "bad_message", message: "unparseable frame" });
          return;
        }
        if (msg.op === "subscribe") {
          sendWs(ws, { op: "subscribed", sessionId: msg.sessionId });
          void withLock(msg.sessionId, async () => {
            const replay = await eventLog.readSince(
              msg.sessionId,
              msg.lastEventId ?? null,
              100_000,
            );
            for (const event of replay) sendWs(ws, { op: "event", event });
            let set = subscribers.get(msg.sessionId);
            if (set === undefined) {
              set = new Set();
              subscribers.set(msg.sessionId, set);
            }
            set.add(ws);
          });
          ws.on("close", () => {
            subscribers.get(msg.sessionId)?.delete(ws);
          });
          return;
        }
        if (msg.op === "ping") {
          sendWs(ws, { op: "pong" });
          return;
        }
        if (msg.op === "browser_attach") {
          sendWs(ws, {
            op: "error",
            code: "unavailable",
            message: "browser channel not composed in the smoke gateway",
            sessionId: msg.sessionId,
          });
          return;
        }
        sendWs(ws, {
          op: "error",
          code: "bad_message",
          message: `unsupported op in smoke gateway: ${msg.op}`,
        });
      });
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    wsBase: `ws://127.0.0.1:${port}/cloud/ws`,
    eventLog,
    async close() {
      for (const set of subscribers.values()) {
        for (const socket of set) socket.terminate();
      }
      wss.close();
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

describe("load harness (unit: self-contained mock gateway)", () => {
  let sse: MockLlmServer;
  let gateway: MockGateway;

  beforeAll(async () => {
    sse = await startMockLlmServer({
      deltas: ["Hello", " from", " the mock"],
      chunkDelayMs: 5,
    });
    gateway = await startMockGateway(sse.baseUrl);
  });

  afterAll(async () => {
    await gateway?.close();
    await sse?.close();
  });

  it("mock LiteLLM serves the P9 admin stubs alongside chat SSE", async () => {
    const generated = await fetch(`${sse.baseUrl}/key/generate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key_alias: "staging-user" }),
    });
    expect(generated.status).toBe(200);
    const body = (await generated.json()) as { key?: unknown; token?: unknown };
    expect(typeof body.key).toBe("string");
    expect(body.key as string).toMatch(/^sk-mock-/);
    expect(body.token).toBe("mock");

    const info = await fetch(`${sse.baseUrl}/key/info?key=${encodeURIComponent(body.key as string)}`);
    expect(info.status).toBe(200);
    const updated = await fetch(`${sse.baseUrl}/key/update`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: body.key }),
    });
    expect(updated.status).toBe(200);
  });

  it("arm() parks a stream mid-flight until release(), then completes", async () => {
    const handle = sse.arm({
      deltas: ["first", "second"],
      chunkDelayMs: 0,
      gateAfterDeltas: 1,
    });
    const response = await fetch(`${sse.baseUrl}/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ stream: true }),
    });
    expect(response.status).toBe(200);
    const reader = response.body!.getReader();
    const decoder = new TextDecoder();
    let text = "";
    const deadline = Date.now() + 2_000;
    while (!text.includes("first") && Date.now() < deadline) {
      const { done, value } = await reader.read();
      if (done) break;
      text += decoder.decode(value, { stream: true });
    }
    expect(text).toContain("first");
    expect(text).not.toContain("second"); // parked by the deferred gate

    handle.release();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      text += decoder.decode(value, { stream: true });
    }
    expect(text).toContain("second");
    expect(text).toContain("[DONE]");
  });

  it("emits a REAL provider tool_calls delta once per [sandbox] run (GAP B)", async () => {
    sse.arm({ deltas: ["done"], chunkDelayMs: 0 });

    const request = async (messages: unknown[]): Promise<string> => {
      const response = await fetch(`${sse.baseUrl}/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ stream: true, messages }),
      });
      expect(response.status).toBe(200);
      return response.text();
    };

    const firstText = await request([{ role: "user", content: "[sandbox] load run 1" }]);
    const firstFrame = firstText
      .split("\n")
      .find((line) => line.startsWith("data: ") && !line.includes("[DONE]"));
    expect(firstFrame).toBeDefined();
    const chunk = JSON.parse(firstFrame!.slice("data: ".length)) as {
      choices: Array<{
        delta: {
          tool_calls?: Array<{
            index: number;
            id: string;
            type: string;
            function: { name: string; arguments: string };
          }>;
        };
        finish_reason: string | null;
      }>;
    };
    const call = chunk.choices[0]!.delta.tool_calls?.[0];
    expect(call).toMatchObject({
      index: 0,
      id: "call_load_sandbox",
      type: "function",
      function: { name: "run_shell" },
    });
    // The arguments are the real provider JSON string the worker parses.
    expect(JSON.parse(call!.function.arguments)).toEqual({ command: "echo load-ok" });
    expect(firstText).toContain('"finish_reason":"tool_calls"');
    expect(firstText).toContain("[DONE]");

    // The continuation round carries the assistant tool_calls + tool result
    // after the last user message: the mock must stream content, not loop.
    const secondText = await request([
      { role: "user", content: "[sandbox] load run 1" },
      {
        role: "assistant",
        content: "",
        tool_calls: [
          {
            id: "call_load_sandbox",
            type: "function",
            function: { name: "run_shell", arguments: '{"command":"echo load-ok"}' },
          },
        ],
      },
      { role: "tool", tool_call_id: "call_load_sandbox", content: "load-ok" },
    ]);
    expect(secondText).not.toContain('"tool_calls"');
    expect(secondText).toContain('"finish_reason":"stop"');
    expect(secondText).toContain("done");

    // A non-sandbox run (no marker) never gets a tool call.
    const plainText = await request([{ role: "user", content: "plain load run" }]);
    expect(plainText).not.toContain('"tool_calls"');
    expect(plainText).toContain('"finish_reason":"stop"');
  });

  it("HTTP control surface holds only gateMarker requests until release (spike hold seam)", async () => {
    const armed = await fetch(`${sse.baseUrl}/_control/arm`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        deltas: ["parked", "released"],
        chunkDelayMs: 0,
        gateAfterDeltas: 1,
        gateMarker: "[spike]",
      }),
    });
    expect(armed.status).toBe(200);
    const { gateId } = (await armed.json()) as { gateId: string };
    expect(gateId).toMatch(/^gate-/);

    const chat = (content: string): Promise<Response> =>
      fetch(`${sse.baseUrl}/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ stream: true, messages: [{ role: "user", content }] }),
      });

    const gated = await chat("[spike] held run");
    expect(gated.status).toBe(200);
    const reader = gated.body!.getReader();
    const decoder = new TextDecoder();
    let text = "";
    const deadline = Date.now() + 2_000;
    while (!text.includes("parked") && Date.now() < deadline) {
      const { done, value } = await reader.read();
      if (done) break;
      text += decoder.decode(value, { stream: true });
    }
    expect(text).toContain("parked");
    expect(text).not.toContain("released"); // parked after the first delta

    const status = (await (
      await fetch(`${sse.baseUrl}/_control/status`)
    ).json()) as { gateId: string | null; heldRequests: number };
    expect(status.gateId).toBe(gateId);
    expect(status.heldRequests).toBeGreaterThan(0);

    // The marker scopes the gate: a steady-state request is NOT held.
    const plain = await chat("plain run");
    expect(await plain.text()).toContain("[DONE]");

    const released = await fetch(`${sse.baseUrl}/_control/release`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ gateId }),
    });
    expect(released.status).toBe(200);
    expect(((await released.json()) as { released: boolean }).released).toBe(true);

    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      text += decoder.decode(value, { stream: true });
    }
    expect(text).toContain("released");
    expect(text).toContain("[DONE]");

    // Restore the default script for the scenario tests below.
    sse.arm({ deltas: ["Hello", " from", " the mock"], chunkDelayMs: 5 });
  });

  it("smoke run: zero loss/duplicates vs readSince ground truth, harness under the latency floor", async () => {
    // Restore the default script after the gate test above.
    sse.arm({ deltas: ["Hello", " from", " the mock"], chunkDelayMs: 5 });
    const profile: LoadProfile = {
      users: 6,
      durationMs: 3_000,
      rampMs: 200,
      runsPerUserEveryMs: 400,
      sandboxDutyCycle: 0,
      browserUsers: 0,
      schedules: 0,
      reconnectEveryMs: 1_000,
    };
    const target: LoadTarget = {
      baseUrl: gateway.baseUrl,
      wsBase: gateway.wsBase,
      redisQUrl: "",
      databaseUrl: "",
      mockLlmUrl: sse.baseUrl,
      queuePrefix: "bull:load-smoke",
      eventLog: gateway.eventLog,
    };

    const report = await runScenario(profile, target);

    expect(report.users).toBe(profile.users);
    expect(report.runsStarted).toBeGreaterThan(0);
    expect(report.runsFailed).toBe(0);
    expect(report.runsCompleted).toBe(report.runsStarted);
    expect(report.integrity).toEqual({
      lostEvents: 0,
      duplicateEvents: 0,
      gapsVsMirror: 0,
    });
    expect(report.eventDelivery.samples).toBeGreaterThan(0);
    expect(report.eventDelivery.p95Ms).toBeLessThanOrEqual(250);
    expect(report.replay.reconnects).toBeGreaterThan(0);
    // Review Focus #2: the harness itself is not the bottleneck.
    expect(report.harness.latencyFloorP95Ms).toBeLessThanOrEqual(50);
    expect(report.harness.maxPendingFrames).toBeLessThanOrEqual(32);
    expect(checkThresholds(report, SMOKE_THRESHOLDS, profile)).toEqual([]);
    expect(sse.requestsSeen()).toBeGreaterThan(0);

    // Every frame the client accepted was schema-valid: a second client can
    // still talk to the same mock gateway after the scenario tore down.
    const probe = await createLoadClient({
      baseUrl: gateway.baseUrl,
      wsBase: gateway.wsBase,
      uid: "probe-user",
      authMode: "test",
    });
    const sid = await probe.createSession();
    await probe.subscribe(sid, null);
    await probe.sendMessage(sid, "probe");
    await probe.close();
  });
});

// ---------------------------------------------------------------------------
// Integration tier (Task 4 Step 4): the REAL gateway + worker in one process,
// exactly like apps/e2e/src/spine.test.ts. Runs only when isolated services
// are supplied — never against the shared dev DB or the live stack.
// ---------------------------------------------------------------------------

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "load harness integration (real gateway + worker + Postgres/Redis)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let tickets: TicketStore;
    let queues: QueueServices;
    let worker: ReturnType<typeof createAgentRunsWorker>;
    let sse: MockLlmServer;
    let app: ReturnType<typeof buildGateway>;
    let baseUrl: string;
    let wsBase: string;

    /**
     * Suite-unique BullMQ prefix: the runner's Redis may be shared with other
     * suites, so this suite can only ever obliterate its OWN queue keys.
     */
    const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
      ? `${process.env.OVID_TEST_QUEUE_PREFIX}-load`
      : `ovid-load-test-${process.pid}-${Date.now()}`;
    /** Session ids observed through the scenario's mirror read (cleanup). */
    const seenSessions = new Set<string>();

    // The mock LiteLLM ignores key validity, so a constant key is enough.
    const keys: KeyProvider & KeyResolver = {
      getKeyForUser: async () => "test-key",
      resolveForRun: async () => ({ kind: "litellm", key: "test-key", baseUrl: "" }),
    };
    const mint: InternalMintProvisioner = {
      ensureKeyForUid: async () => ({ key: "test-key", tier: "free", baseUrl: "" }),
    };

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redis = new Redis(TEST_REDIS_URL!);
      // Created ONCE and shared by gateway deps AND RunDeps: live fanout only
      // works when both sides hit the same Redis instance (spine.test.ts).
      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);

      // OBJECT form mandatory (spine.test.ts / Task 7 lesson).
      const connection = { url: TEST_REDIS_URL! };
      queues = createQueues(connection, { prefix: QUEUE_PREFIX });

      sse = await startMockLlmServer({
        deltas: ["Hello", " from", " the real composition"],
        chunkDelayMs: 20,
      });
      const processor = createAgentRunProcessor({
        db,
        events,
        keys,
        transport: createOpenAiTransport(),
        litellmBaseUrl: sse.baseUrl,
        defaultModel: "load-test-model",
      });
      worker = createAgentRunsWorker(connection, processor, { prefix: QUEUE_PREFIX });

      app = buildGateway({
        system: createRedisSystemBus(redis),
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
      wsBase = `ws://127.0.0.1:${port}/cloud/ws`;
    }, 60_000);

    afterAll(async () => {
      // The scenario releases its spike gate before returning; close the
      // worker first so BullMQ's blocking connections stop fetching.
      await worker?.close();
      await app?.close();
      if (queues) {
        await queues.agentRuns.obliterate({ force: true }).catch(() => {});
        await queues.agentRuns.close().catch(() => {});
      }
      await sse?.close();
      if (seenSessions.size > 0) {
        // Only this suite's streams (the runner supplied an isolated Redis).
        await redis
          ?.del([...seenSessions].map((id) => `sess:${id}:events`))
          .catch(() => {});
      }
      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });
    }, 60_000);

    it(
      "10 users / 20 s: zero loss/dups vs the real event log, floor held, spike held",
      async () => {
        /**
         * Read the REAL Postgres mirror, settling until it has caught up with
         * the REAL Redis stream. The worker appends then mirrors; the live
         * frame can reach the client a beat before `eventMirror.put` commits.
         * A persistent gap still fails the scenario's `gapsVsMirror` check.
         */
        const mirrorRead = async (sessionId: string): Promise<string[]> => {
          seenSessions.add(sessionId);
          let seqs: string[] = [];
          for (let attempt = 0; attempt < 80; attempt += 1) {
            seqs = (await eventMirror.readSince(db, sessionId, null, 100_000)).map(
              (event) => event.seq,
            );
            const truth = (await events.readSince(sessionId, null, 100_000)).length;
            if (seqs.length >= truth) return seqs;
            await new Promise((resolve) => setTimeout(resolve, 25));
          }
          return seqs;
        };

        const profile: LoadProfile = {
          users: 10,
          durationMs: 20_000,
          rampMs: 1_000,
          runsPerUserEveryMs: 4_000,
          sandboxDutyCycle: 0, // this composition has no sandbox/tool roster
          browserUsers: 0,
          schedules: 1, // I5: created under the session owner's uid
          reconnectEveryMs: 10_000,
          // I4: a small held burst proves the scenario's mock control seam.
          spike: { atMs: 8_000, extraConcurrentRuns: 5, durationMs: 1_000 },
        };
        const target: LoadTarget = {
          baseUrl,
          wsBase,
          redisQUrl: "",
          databaseUrl: "",
          mockLlmUrl: sse.baseUrl,
          queuePrefix: QUEUE_PREFIX,
          eventLog: events,
          mirrorRead,
        };

        const report = await runScenario(profile, target);

        // Plan Step 4 assertions (unchanged).
        expect(report.users).toBe(profile.users);
        expect(report.integrity).toEqual({
          lostEvents: 0,
          duplicateEvents: 0,
          gapsVsMirror: 0,
        });
        expect(report.runsCompleted).toBe(report.runsStarted);
        expect(report.eventDelivery.p95Ms).toBeLessThanOrEqual(250);
        expect(report.harness.latencyFloorP95Ms).toBeLessThanOrEqual(50);
        expect(report.harness.maxPendingFrames).toBeLessThanOrEqual(32);

        // Positive data: the run cannot pass with nothing running.
        expect(report.runsStarted).toBeGreaterThan(0);
        expect(report.eventDelivery.samples).toBeGreaterThan(0);
        expect(report.runsFailed).toBe(0);
        expect(report.harness.invalidFrames).toBe(0);
        expect(sse.requestsSeen()).toBeGreaterThan(0);

        // I5: the schedule was created under the session-owning uid. A wrong
        // identity 404s and leaves created=0 (the old silent PASS).
        expect(report.scheduleRuns.created).toBe(1);
        expect(report.notes ?? []).not.toEqual(
          expect.arrayContaining([expect.stringContaining("schedule tier: NOT EXERCISED")]),
        );

        // I4: the spike fired AND was actually held by the mock gate.
        expect(report.admission.spikeRuns).toBeGreaterThan(0);
        expect(report.admission.spikeHeldRequests).toBeGreaterThan(0);
        expect(report.admission.spikeDrainMs).toBeGreaterThanOrEqual(0);

        // One compact evidence line (kept in the test output so a Task 5
        // operator can see the values behind the assertions).
        console.log(
          `load integration: runsStarted=${report.runsStarted} ` +
            `runsCompleted=${report.runsCompleted} ` +
            `delivery.p95=${report.eventDelivery.p95Ms}ms ` +
            `samples=${report.eventDelivery.samples} ` +
            `integrity=${JSON.stringify(report.integrity)} ` +
            `floor.p95=${report.harness.latencyFloorP95Ms}ms ` +
            `pending=${report.harness.maxPendingFrames} ` +
            `schedules.created=${report.scheduleRuns.created} ` +
            `spike.runs=${report.admission.spikeRuns} ` +
            `spike.held=${report.admission.spikeHeldRequests} ` +
            `spike.drainMs=${report.admission.spikeDrainMs}`,
        );
      },
      120_000,
    );
  },
);
