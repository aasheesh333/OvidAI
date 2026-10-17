import { createServer, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "@ovid/db";
import { createRedisEventLog, createRedisSystemBus, type EventLog } from "@ovid/events";
import {
  createAgentRunsWorker,
  createQueues,
  type AgentRunJob,
  type QueueServices,
} from "@ovid/queue";
import {
  messageDtoSchema,
  nextIntervalSlot,
  pageSchema,
  sessionDtoSchema,
  wsServerMsg,
  type ApiError,
  type KeyProvider,
  type MintProvisioner,
  type ScheduleDto,
  type SystemEvent,
  type WsServerMsg,
} from "@ovid/shared";
import {
  buildGateway,
  createTestVerifier,
  createTicketStore,
  type TicketStore,
} from "@ovid/gateway";
import {
  createAgentRunProcessor,
  createFullAgentRunProcessor,
  createNotifier,
  createOpenAiTransport,
  createScheduleFireProcessor,
  fireScheduleOccurrence,
  KEY_NOT_MINTED_PUSH_BODY,
  runSchedulerTick,
  settleScheduleRuns,
  UNATTENDED_APPROVAL_TIMEOUT_MS,
  type FullRunDeps,
  type PushMessage,
  type PushSender,
  type SchedulerDeps,
  type SettleDeps,
} from "@ovid/worker";

/**
 * P4 Task 14 — the phase-level proof that a schedule fires UNATTENDED, runs,
 * and reports (spec P4 row: "unattended autonomous tasks run and report").
 *
 * Harness (copied wholesale from spine.test.ts): real gateway (REST + WS
 * system channel) and real worker pieces in one process over real Postgres and
 * real Redis; only the outermost boundaries are stubbed (LiteLLM → local SSE
 * mock, mint/key → stub, push → capturing stub).
 *
 * Determinism: the scheduler is driven by INJECTED clocks plus manual
 * `runSchedulerTick` / `settleScheduleRuns` calls — never `startSchedulerLoop`
 * wall time. The real agent-runs BullMQ worker is the only consumer; the
 * schedules mirror has NO worker here (flow D invokes its processor directly)
 * so delayed mirror jobs armed by ticks can never race a manual tick.
 *
 * Queue isolation (P1 fix-wave discipline): every queue/worker call passes the
 * suite-unique `OVID_TEST_QUEUE_PREFIX + "-e2e"` prefix; afterAll obliterates
 * ONLY the suite-prefixed `agent-runs` and `schedules` queues.
 *
 * Pinned flows:
 *   A. full unattended cycle + notification records (the anchor).
 *   B. key_not_minted (ledger Q5) → failed run + open-the-app push.
 *   C. missed-run simulation (skip / pause-beyond-grace / run-late).
 *   D. duplicate-fire prevention (Review Focus 1) + overlapping ticks
 *      (T10 carry b).
 *   E. retry ladder then pauseForReview.
 *   F. T10 carry (a): a scheduler-shaped job (job.data.schedule, no explicit
 *      `unattended`) is treated UNATTENDED — the default-deny policy applies.
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

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

// ---------------------------------------------------------------------------
// Mock LiteLLM: an http server speaking [OI]-dialect SSE (spine.test.ts copy).
// ---------------------------------------------------------------------------

interface SseScript {
  deltas: string[];
  chunkDelayMs: number;
  closeSocketAfterDeltas: number | null;
}

interface SseMock {
  baseUrl: string;
  arm(script: Partial<SseScript> & { deltas: string[] }): void;
  requests: Array<{ authorization: string | undefined; body: unknown }>;
  close(): Promise<void>;
}

async function startSseMock(): Promise<SseMock> {
  let script: SseScript = { deltas: [], chunkDelayMs: 0, closeSocketAfterDeltas: null };
  const requests: SseMock["requests"] = [];

  async function stream(res: ServerResponse, s: SseScript): Promise<void> {
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
    for (let i = 0; i < s.deltas.length; i += 1) {
      if (s.chunkDelayMs > 0) await sleep(s.chunkDelayMs);
      if (res.destroyed || res.writableEnded) return;
      res.write(
        `data: ${JSON.stringify({
          choices: [{ delta: { content: s.deltas[i] }, finish_reason: null }],
        })}\n\n`,
      );
      if (s.closeSocketAfterDeltas === i + 1) {
        res.socket?.destroy(); // truncated stream → the transport sees transient
        return;
      }
    }
    res.write(
      `data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] })}\n\n`,
    );
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
      void stream(res, { ...script });
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    arm(next) {
      script = { chunkDelayMs: 0, closeSocketAfterDeltas: null, ...next };
    },
    requests,
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

/**
 * A turn-based SSE mock for the full processor (T10 carry a): the Nth request
 * serves `turns[N-1]`, the last turn repeats. Each turn is a list of raw
 * OpenAI-dialect delta objects.
 */
interface TurnSse {
  url: string;
  readonly requests: number;
  close(): Promise<void>;
}

async function startTurnSse(
  turns: Array<Array<Record<string, unknown>>>,
): Promise<TurnSse> {
  const state = { requests: 0 };
  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      state.requests += 1;
      const turn = turns[Math.min(state.requests - 1, turns.length - 1)]!;
      res.writeHead(200, { "content-type": "text/event-stream" });
      for (const event of turn) res.write(`data: ${JSON.stringify(event)}\n\n`);
      res.end("data: [DONE]\n\n");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return {
    get requests() {
      return state.requests;
    },
    url,
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

const toolCallTurn = (
  id: string,
  name: string,
  args: Record<string, unknown>,
): Array<Record<string, unknown>> => [
  {
    choices: [
      {
        delta: {
          tool_calls: [{ index: 0, id, function: { name, arguments: JSON.stringify(args) } }],
        },
        finish_reason: null,
      },
    ],
  },
  { choices: [{ delta: {}, finish_reason: "tool_calls" }] },
];

const textTurn = (text: string): Array<Record<string, unknown>> => [
  { choices: [{ delta: { content: text }, finish_reason: null }] },
  { choices: [{ delta: {}, finish_reason: "stop" }] },
];

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "scheduler e2e (real gateway + real worker + real Postgres/Redis, injected clock)",
  () => {
    let db: Db;
    let redis: Redis;
    /** Dedicated throwaway database — see beforeAll. */
    let suiteDatabaseUrl: string;
    let suiteDbName: string;
    let adminDatabaseUrl: string;
    let events: EventLog;
    let system: ReturnType<typeof createRedisSystemBus>;
    let tickets: TicketStore;
    let queues: QueueServices;
    let worker: ReturnType<typeof createAgentRunsWorker>;
    let sse: SseMock;
    let app: ReturnType<typeof buildGateway>;
    let baseUrl: string;
    let wsBase: string;
    let notifier: ReturnType<typeof createNotifier>;
    let schedulerDeps: SchedulerDeps & SettleDeps;

    const clients: Array<{ close(): Promise<void> }> = [];
    const createdSids: string[] = [];
    const createdUids: string[] = [];
    const createdScheduleIds: string[] = [];
    const workerFailures: Array<{ jobId: string | undefined; message: string }> = [];
    const workerErrors: string[] = [];
    const sleeps: number[] = [];
    const pushes: PushMessage[] = [];
    /** Users whose KeyProvider lookup returns null (flow B). */
    const keylessUsers = new Set<string>();
    /** The suite's mutable scheduler clock — every tick/settle uses it. */
    let clockNow = new Date();

    const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
      ? `${process.env.OVID_TEST_QUEUE_PREFIX}-e2e`
      : "ovid-test-e2e";

    const keys: KeyProvider = {
      getKeyForUser: async (userId) => (keylessUsers.has(userId) ? null : "test-key"),
    };
    const mint: MintProvisioner = { ensureKey: async () => ({ key: "test-key" }) };
    const push: PushSender = {
      async send(msg) {
        pushes.push(msg);
        return { ok: true };
      },
    };

    beforeAll(async () => {
      // ISOLATION: `runSchedulerTick` scans EVERY pending schedule in the
      // database. The shared dev database carries leftovers from the other
      // suites (route/tool/unit fixtures that never cancel their rows), so a
      // real-clock tick there is neither exact nor deterministic. Give this
      // suite its own throwaway database (migrated fresh, dropped in
      // afterAll); Redis stays shared and is scoped by the queue prefix.
      const adminUrl = new URL(TEST_DATABASE_URL!);
      adminUrl.pathname = "/postgres";
      adminDatabaseUrl = adminUrl.toString();
      suiteDbName = `ovid_e2e_sched_${Date.now().toString(36)}_${process.pid}`.slice(0, 60);
      const admin = createDb(adminDatabaseUrl);
      try {
        await admin.$client.unsafe(`CREATE DATABASE "${suiteDbName}"`);
      } finally {
        await admin.$client.end({ timeout: 5 });
      }
      const suiteUrl = new URL(TEST_DATABASE_URL!);
      suiteUrl.pathname = `/${suiteDbName}`;
      suiteDatabaseUrl = suiteUrl.toString();

      await migrate(suiteDatabaseUrl);
      db = createDb(suiteDatabaseUrl);
      redis = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);
      // ONE bus instance, shared by the gateway's WS system channel and the
      // scheduler's publishes (same instance discipline as the spine's events).
      system = createRedisSystemBus(redis);

      // OBJECT form mandatory (Task 7 lesson): a bare URL string is spread
      // into garbage opts by withBlockingSafeRetries and hangs.
      const connection = { url: TEST_REDIS_URL! };
      queues = createQueues(connection, { prefix: QUEUE_PREFIX });

      sse = await startSseMock();
      // The documented legacy tool-less composition (same shape as
      // spine.test.ts): `sandbox`/`tools` are intentionally absent at runtime,
      // which selects the compat processor's v0 path. The cast only papers
      // over the interface's pre-P2 required fields.
      const processor = createAgentRunProcessor({
        db,
        events,
        keys,
        transport: createOpenAiTransport(),
        litellmBaseUrl: sse.baseUrl,
        defaultModel: "e2e-model",
        // Instant retry ladder: flow E's 3/9/27/60 s backoffs must not wait.
        sleep: async (ms: number) => {
          sleeps.push(ms);
        },
      } as unknown as Parameters<typeof createAgentRunProcessor>[0]);
      worker = createAgentRunsWorker(connection, processor, { prefix: QUEUE_PREFIX });
      worker.on("failed", (job, err) => {
        workerFailures.push({ jobId: job?.id, message: err.message });
      });
      worker.on("error", (err) => {
        workerErrors.push(err.message);
      });

      notifier = createNotifier({ db, push });
      schedulerDeps = {
        db,
        queues,
        system,
        events,
        notifier,
        clock: () => clockNow,
      };

      app = buildGateway({
        system,
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
      while (clients.length > 0) await clients.pop()!.close().catch(() => {});
      await worker?.close();

      // Apps after clients: closing the WS clients triggers the gateway's
      // per-socket teardown (each system subscription quits its dedicated
      // redis connection) before the HTTP server goes away.
      await app?.close();

      if (queues) {
        // Only THIS suite's prefixed queues. The schedules queue has no worker
        // here, so force is safe; close both or vitest never exits.
        await queues.agentRuns.obliterate({ force: true }).catch(() => {});
        await queues.agentRuns.close().catch(() => {});
        await queues.schedules.obliterate({ force: true }).catch(() => {});
        await queues.schedules.close().catch(() => {});
      }

      await sse?.close();

      // Cancelled rows are invisible to claimDue (status='pending' filter), so
      // re-runs of this file can never fire this suite's leftovers.
      for (const scheduleId of createdScheduleIds) {
        await db
          ?.$client.unsafe("UPDATE schedules SET status = 'cancelled' WHERE id = $1", [scheduleId])
          .catch(() => {});
      }
      for (const sessionId of createdSids) {
        await db
          ?.$client.unsafe(
            "UPDATE runs SET status = 'completed' WHERE session_id = $1 AND status IN ('queued','running')",
            [sessionId],
          )
          .catch(() => {});
      }
      if (createdSids.length > 0) {
        await redis
          ?.del(createdSids.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }

      // No leaked system-bus subscriber connections: every user channel this
      // suite opened must be gone from the shared dev redis (bounded settle
      // wait — gateway teardown runs unsubscribe()s asynchronously).
      const ours = new Set(createdUids.map((id) => `user:${id}:system`));
      await waitForAsync(async () => {
        const channels = (await redis.call("PUBSUB", "CHANNELS", "user:*:system")) as string[];
        return channels.every((c) => !ours.has(c));
      }, "suite system pubsub channels torn down");

      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });

      // Drop the throwaway database last (all suite connections are closed by
      // this point). FORCE reaps any stray pooled connection.
      if (suiteDbName !== undefined) {
        const admin = createDb(adminDatabaseUrl);
        try {
          await admin.$client.unsafe(`DROP DATABASE IF EXISTS "${suiteDbName}" WITH (FORCE)`);
        } finally {
          await admin.$client.end({ timeout: 5 });
        }
      }
    }, 60_000);

    // ---- HTTP + WS helpers -------------------------------------------------

    interface HttpResult {
      status: number;
      body: unknown;
    }

    async function api(
      method: string,
      path: string,
      opts: { uid?: string; body?: unknown } = {},
    ): Promise<HttpResult> {
      const headers: Record<string, string> = {};
      if (opts.uid !== undefined) headers.authorization = `Bearer test:${opts.uid}`;
      if (opts.body !== undefined) headers["content-type"] = "application/json";
      const res = await fetch(`${baseUrl}${path}`, {
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

    async function getTicket(user: string): Promise<string> {
      const res = await api("POST", "/cloud/v1/auth/ticket", { uid: user });
      expect(res.status).toBe(200);
      const ticket = (res.body as { ticket?: unknown }).ticket;
      if (typeof ticket !== "string" || ticket === "") throw new Error("no ticket minted");
      return ticket;
    }

    interface SystemClient {
      messages: WsServerMsg[];
      events(): SystemEvent[];
      waitFor(cond: () => boolean, what: string, timeoutMs?: number): Promise<void>;
      close(): Promise<void>;
    }

    async function connectSystem(user: string): Promise<SystemClient> {
      createdUids.push(user);
      const socket = new WebSocket(`${wsBase}?ticket=${encodeURIComponent(await getTicket(user))}`);
      const messages: WsServerMsg[] = [];
      socket.on("message", (data) => {
        messages.push(wsServerMsg(JSON.parse(data.toString())));
      });
      socket.on("error", () => {});
      await new Promise<void>((resolve, reject) => {
        const onError = (err: Error): void => reject(err);
        socket.once("error", onError);
        socket.once("open", () => {
          socket.off("error", onError);
          resolve();
        });
      });
      socket.send(JSON.stringify({ op: "subscribe_system" }));
      await waitFor(
        () => messages.some((m) => m.op === "system_subscribed"),
        "system_subscribed ack",
      );
      const client: SystemClient = {
        messages,
        events: () => messages.flatMap((m) => (m.op === "system" ? [m.event] : [])),
        waitFor: (cond, what, timeoutMs) => waitFor(cond, what, timeoutMs),
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

    async function createScheduleRest(
      user: string,
      body: {
        title: string;
        description: string;
        trigger: Record<string, unknown>;
        maxRetries?: number;
      },
    ): Promise<ScheduleDto> {
      const res = await api("POST", "/cloud/v1/schedules", { uid: user, body });
      expect(res.status).toBe(201);
      const dto = res.body as ScheduleDto;
      createdScheduleIds.push(dto.id);
      createdSids.push(dto.sessionId);
      return dto;
    }

    async function registerDevice(user: string, token: string): Promise<void> {
      const res = await api("POST", "/cloud/v1/devices", {
        uid: user,
        body: { token, platform: "android" },
      });
      expect(res.status).toBe(200);
    }

    function deviceToken(user: string): string {
      return `tok-${user}`;
    }

    function pushesFor(user: string): PushMessage[] {
      return pushes.filter((p) => p.token === deviceToken(user));
    }

    interface ScheduleRunRow {
      id: string;
      schedule_id: string;
      scheduled_for: string;
      run_id: string | null;
      status: string;
      attempt: number;
      ran_late: boolean;
      error: string | null;
      retry_at: string | null;
    }

    async function scheduleRunRows(scheduleId: string): Promise<ScheduleRunRow[]> {
      return (await db.$client.unsafe(
        "SELECT id, schedule_id, scheduled_for, run_id, status, attempt, ran_late, error, retry_at FROM schedule_runs WHERE schedule_id = $1 ORDER BY scheduled_for ASC, id ASC",
        [scheduleId],
      )) as unknown as ScheduleRunRow[];
    }

    async function runRow(runId: string): Promise<{ status: string; last_error: string | null } | null> {
      const rows = (await db.$client.unsafe("SELECT status, last_error FROM runs WHERE id = $1", [
        runId,
      ])) as Array<{ status: string; last_error: string | null }>;
      return rows[0] ?? null;
    }

    async function scheduleRow(
      scheduleId: string,
    ): Promise<{ status: string; paused_reason: string | null; next_run_at: string | null } | null> {
      const rows = (await db.$client.unsafe(
        "SELECT status, paused_reason, next_run_at FROM schedules WHERE id = $1",
        [scheduleId],
      )) as Array<{ status: string; paused_reason: string | null; next_run_at: string | null }>;
      return rows[0] ?? null;
    }

    async function pauseSchedule(scheduleId: string): Promise<void> {
      await db.$client.unsafe("UPDATE schedules SET status = 'paused' WHERE id = $1", [scheduleId]);
    }

    async function agentJobsFor(sessionId: string): Promise<AgentRunJob[]> {
      const jobs = await queues.agentRuns.getJobs([
        "waiting",
        "active",
        "completed",
        "failed",
        "delayed",
        "prioritized",
        "waiting-children",
      ]);
      return jobs
        .map((job) => job.data)
        .filter((data): data is AgentRunJob => data !== undefined && data.sessionId === sessionId);
    }

    async function notificationRows(
      userId: string,
    ): Promise<Array<{ kind: string; status: string; route: string; channel: string; body: string }>> {
      return (await db.$client.unsafe(
        "SELECT kind, status, route, channel, body FROM notifications WHERE user_id = $1 ORDER BY created_at ASC",
        [userId],
      )) as unknown as Array<{
        kind: string;
        status: string;
        route: string;
        channel: string;
        body: string;
      }>;
    }

    async function sessionMessages(user: string, sessionId: string) {
      const res = await api("GET", `/cloud/v1/sessions/${sessionId}/messages`, { uid: user });
      expect(res.status).toBe(200);
      return [...pageSchema(messageDtoSchema).parse(res.body).items].reverse();
    }

    async function waitForRunStatus(runId: string, status: string, what: string): Promise<void> {
      await waitForAsync(async () => (await runRow(runId))?.status === status, what, 25_000);
    }

    // ---- Flow A: full unattended cycle + notification records --------------

    it("flow A — REST every-300 schedule → device → tick → real worker run → settle: prompt format, transcript, ledger, notification, push, ordered WS system events", async () => {
      const user = uid("e2e-sched-a");
      createdUids.push(user);
      const token = deviceToken(user);
      const sys = await connectSystem(user);
      await registerDevice(user, token);

      // Subscribe BEFORE creation so schedule_created is observed live.
      const dto = await createScheduleRest(user, {
        title: "Morning report",
        description: "check things",
        trigger: { kind: "every", seconds: 300 },
      });
      const due = new Date(dto.nextRunAt!);

      sse.arm({ deltas: ["Report ready"] });
      const realNow = Date.now();
      clockNow = new Date(realNow + 301_000);
      const report = await runSchedulerTick(schedulerDeps);
      expect(report).toEqual({
        fired: 1,
        retried: 0,
        skipped: 0,
        paused: 0,
        deferred: 0,
        duplicates: 0,
      });

      // The REAL agent-runs worker executes the scheduler-enqueued job.
      const ledger = await scheduleRunRows(dto.id);
      expect(ledger).toHaveLength(1);
      expect(ledger[0]!.run_id).not.toBeNull();
      await waitForRunStatus(ledger[0]!.run_id!, "completed", "flow A run completed");

      const settled = await settleScheduleRuns(schedulerDeps);
      expect(settled).toBe(1);

      // Prompt format pin: the scheduler appended EXACTLY schedulePrompt().
      const prompt = "[schedule: Morning report] check things";
      const lastRequest = sse.requests.at(-1);
      const modelBody = lastRequest?.body as {
        messages: Array<{ role: string; content: string }>;
      };
      expect(modelBody.messages.at(-1)).toEqual({ role: "user", content: prompt });

      // Transcript via REST: user prompt then the assistant answer.
      const transcript = await sessionMessages(user, dto.sessionId);
      expect(transcript.map((m) => m.role)).toEqual(["user", "assistant"]);
      expect(transcript.map((m) => m.content)).toEqual([prompt, "Report ready"]);

      // Ledger + schedule advance.
      const finalLedger = await scheduleRunRows(dto.id);
      expect(finalLedger).toHaveLength(1);
      expect(finalLedger[0]).toMatchObject({
        status: "succeeded",
        ran_late: false,
        attempt: 1,
      });
      expect(new Date(finalLedger[0]!.scheduled_for).toISOString()).toBe(due.toISOString());
      const after = await scheduleRow(dto.id);
      expect(after).not.toBeNull();
      expect(after!.status).toBe("pending");
      // `every` stays anchored at the occurrence: next = due + 300 s.
      expect(new Date(after!.next_run_at!).toISOString()).toBe(
        new Date(due.getTime() + 300_000).toISOString(),
      );

      // Notification inbox record (Review Focus 5 record pin) + captured push.
      const notes = await notificationRows(user);
      expect(notes).toHaveLength(1);
      expect(notes[0]).toMatchObject({
        kind: "scheduleSucceeded",
        status: "sent",
        route: `/schedule/${dto.sessionId}`,
        channel: "scheduler_results",
      });
      const sentPushes = pushesFor(user);
      expect(sentPushes).toHaveLength(1);
      expect(sentPushes[0]!.data.kind).toBe("scheduleSucceeded");
      expect(sentPushes[0]!.androidChannelId).toBe("ovid_scheduler_results.chime.v1");

      // WS system events, in order, all for this schedule.
      await sys.waitFor(
        () =>
          sys
            .events()
            .filter((e) => e.scheduleId === dto.id)
            .some((e) => e.type === "schedule_run_succeeded"),
        "flow A schedule_run_succeeded",
        20_000,
      );
      const evs = sys.events().filter((e) => e.scheduleId === dto.id);
      expect(evs.map((e) => e.type)).toEqual([
        "schedule_created",
        "schedule_run_started",
        "schedule_run_succeeded",
      ]);
      expect(evs[1]!.payload).toMatchObject({
        scheduleRunId: finalLedger[0]!.id,
        runId: finalLedger[0]!.run_id,
        ranLate: false,
        attempt: 1,
      });
      expect(evs[2]!.payload).toMatchObject({
        scheduleRunId: finalLedger[0]!.id,
        summary: "Report ready",
        scheduleCompleted: false,
      });

      // Flow A's session is the ground-truth replay stream (cross-flow check).
      const replayed = await events.readSince(dto.sessionId, null, 500);
      expect(replayed.map((e) => e.type)).toEqual([
        "run_started",
        "message_delta",
        "message_completed",
        "run_completed",
        "system_note",
      ]);
      expect(replayed.at(-1)!.payload).toMatchObject({
        scheduleId: dto.id,
        scheduleRunId: finalLedger[0]!.id,
        status: "succeeded",
      });

      // Keep flow A's recurring schedule out of later (future-clock) scans.
      await pauseSchedule(dto.id);
    }, 40_000);

    // ---- Flow B: key_not_minted (ledger Q5) --------------------------------

    it("flow B — KeyProvider null: run fails key_not_minted → schedule failed, pinned open-the-app push, WS failed{willRetry:false}, system transcript message", async () => {
      const user = uid("e2e-sched-b");
      createdUids.push(user);
      keylessUsers.add(user);
      const token = deviceToken(user);
      const sys = await connectSystem(user);
      await registerDevice(user, token);

      const at = new Date(Date.now() + 2_000).toISOString();
      const dto = await createScheduleRest(user, {
        title: "Needs a key",
        description: "do the thing",
        trigger: { kind: "at", at },
      });
      expect(dto.nextRunAt).toBe(new Date(at).toISOString());

      clockNow = new Date(new Date(at).getTime() + 1_000);
      const report = await runSchedulerTick(schedulerDeps);
      expect(report.fired).toBe(1);

      const ledger = await scheduleRunRows(dto.id);
      expect(ledger).toHaveLength(1);
      await waitForRunStatus(ledger[0]!.run_id!, "failed", "flow B run failed");
      expect((await runRow(ledger[0]!.run_id!))!.last_error).toBe("key_not_minted");

      const settled = await settleScheduleRuns(schedulerDeps);
      expect(settled).toBe(1);

      const finalLedger = await scheduleRunRows(dto.id);
      expect(finalLedger).toHaveLength(1);
      expect(finalLedger[0]).toMatchObject({ status: "failed", error: "key_not_minted" });
      const after = await scheduleRow(dto.id);
      expect(after).toMatchObject({ status: "failed", next_run_at: null });

      const sentPushes = pushesFor(user);
      expect(sentPushes).toHaveLength(1);
      expect(sentPushes[0]!.notification.body).toBe(KEY_NOT_MINTED_PUSH_BODY);
      expect(sentPushes[0]!.data.kind).toBe("scheduleFailed");

      await sys.waitFor(
        () => sys.events().some((e) => e.type === "schedule_run_failed"),
        "flow B schedule_run_failed",
      );
      const failed = sys.events().find((e) => e.type === "schedule_run_failed")!;
      expect(failed.payload).toMatchObject({ code: "key_not_minted", willRetry: false });

      const transcript = await sessionMessages(user, dto.sessionId);
      const systemMessage = transcript.find((m) => m.role === "system");
      expect(systemMessage?.content).toBe("Scheduled task failed: key_not_minted");
    }, 30_000);

    // ---- Flow C: missed-run simulation ------------------------------------

    it("flow C — missed-run policy: recurring beyond grace → skipped + schedule_updated{skipped_missed}; one-off beyond 24 h → paused missed_beyond_grace; one-off within grace → fired ranLate", async () => {
      // -- C1: recurring `every 300` fires on time, then misses beyond grace.
      const user3 = uid("e2e-sched-c1");
      createdUids.push(user3);
      const sys3 = await connectSystem(user3);
      const dto3 = await createScheduleRest(user3, {
        title: "Recurring",
        description: "recurring work",
        trigger: { kind: "every", seconds: 300 },
      });
      const due1 = new Date(dto3.nextRunAt!);

      sse.arm({ deltas: ["first"] });
      clockNow = new Date(due1.getTime());
      expect((await runSchedulerTick(schedulerDeps)).fired).toBe(1);
      const firstLedger = await scheduleRunRows(dto3.id);
      await waitForRunStatus(firstLedger[0]!.run_id!, "completed", "flow C first run completed");
      expect(await settleScheduleRuns(schedulerDeps)).toBe(1);

      const nextDue = new Date(due1.getTime() + 300_000);
      const jobsBefore = (await agentJobsFor(dto3.sessionId)).length;
      const missedNow = new Date(nextDue.getTime() + 7 * 3_600_000);
      clockNow = missedNow;
      const skipReport = await runSchedulerTick(schedulerDeps);
      expect(skipReport).toMatchObject({ fired: 0, skipped: 1, paused: 0, retried: 0 });

      const ledgerAfterSkip = await scheduleRunRows(dto3.id);
      expect(ledgerAfterSkip).toHaveLength(2);
      expect(ledgerAfterSkip[1]).toMatchObject({ status: "skipped", run_id: null });
      expect(new Date(ledgerAfterSkip[1]!.scheduled_for).toISOString()).toBe(
        nextDue.toISOString(),
      );
      const afterSkip = await scheduleRow(dto3.id);
      const expectedNext = nextIntervalSlot(nextDue, 300, missedNow);
      expect(new Date(afterSkip!.next_run_at!).toISOString()).toBe(
        expectedNext.toISOString(),
      );
      // ZERO new agent-runs adds for a skipped occurrence.
      expect((await agentJobsFor(dto3.sessionId)).length).toBe(jobsBefore);

      await sys3.waitFor(
        () =>
          sys3
            .events()
            .some(
              (e) => e.type === "schedule_updated" && e.payload.reason === "skipped_missed",
            ),
        "flow C schedule_updated skipped_missed",
      );
      // Keep C1 out of the later future-clock scans.
      await pauseSchedule(dto3.id);

      // -- C2: one-off 25 h late → paused for review, never fired.
      const user4 = uid("e2e-sched-c2");
      createdUids.push(user4);
      const t1 = new Date(Date.now() + 3_600_000);
      const dto4 = await createScheduleRest(user4, {
        title: "Stale one-off",
        description: "stale",
        trigger: { kind: "at", at: t1.toISOString() },
      });
      const sys4 = await connectSystem(user4);
      clockNow = new Date(t1.getTime() + 25 * 3_600_000);
      const pauseReport = await runSchedulerTick(schedulerDeps);
      expect(pauseReport).toMatchObject({ fired: 0, paused: 1, skipped: 0 });
      expect(await scheduleRow(dto4.id)).toMatchObject({
        status: "paused",
        paused_reason: "missed_beyond_grace",
      });
      await sys4.waitFor(
        () => sys4.events().some((e) => e.type === "schedule_run_paused"),
        "flow C schedule_run_paused",
      );
      expect(sys4.events().find((e) => e.type === "schedule_run_paused")!.payload).toMatchObject({
        reason: "missed_beyond_grace",
      });

      // -- C3: one-off 3 h late (within 24 h grace) → runs late, ranLate true.
      const user5 = uid("e2e-sched-c3");
      createdUids.push(user5);
      const t2 = new Date(Date.now() + 2 * 3_600_000);
      const dto5 = await createScheduleRest(user5, {
        title: "Late one-off",
        description: "late work",
        trigger: { kind: "at", at: t2.toISOString() },
      });
      sse.arm({ deltas: ["late result"] });
      clockNow = new Date(t2.getTime() + 3 * 3_600_000);
      const lateReport = await runSchedulerTick(schedulerDeps);
      expect(lateReport.fired).toBe(1);
      const lateLedger = await scheduleRunRows(dto5.id);
      expect(lateLedger).toHaveLength(1);
      expect(lateLedger[0]!.ran_late).toBe(true);
      await waitForRunStatus(lateLedger[0]!.run_id!, "completed", "flow C late run completed");
      expect(await settleScheduleRuns(schedulerDeps)).toBe(1);
      expect((await scheduleRow(dto5.id))!.status).toBe("completed");
    }, 40_000);

    // ---- Flow D: duplicate-fire prevention (Review Focus 1) ----------------

    it("flow D — concurrent fireScheduleOccurrence ×2 + mirror processor → exactly one fired, one schedule_run, one run, one agent-runs job; two overlapping ticks → one fire (T10 carry b)", async () => {
      const user = uid("e2e-sched-d");
      createdUids.push(user);
      const dto = await createScheduleRest(user, {
        title: "Once only",
        description: "single occurrence",
        trigger: { kind: "every", seconds: 300 },
      });
      const due = new Date(dto.nextRunAt!);
      sse.arm({ deltas: ["once"] });

      clockNow = new Date(due.getTime());
      const fireProcessor = createScheduleFireProcessor(schedulerDeps);
      const outcomes = await Promise.all([
        fireScheduleOccurrence(schedulerDeps, dto.id, { expectedScheduledFor: due }),
        fireScheduleOccurrence(schedulerDeps, dto.id, { expectedScheduledFor: due }),
        fireProcessor({ data: { scheduleId: dto.id, scheduledFor: due.toISOString() } }),
      ]);
      expect(outcomes.filter((o) => o === "fired")).toHaveLength(1);

      const ledger = await scheduleRunRows(dto.id);
      expect(ledger).toHaveLength(1);
      await waitForRunStatus(ledger[0]!.run_id!, "completed", "flow D run completed");
      expect(await settleScheduleRuns(schedulerDeps)).toBe(1);

      const runRows = (await db.$client.unsafe("SELECT id FROM runs WHERE session_id = $1", [
        dto.sessionId,
      ])) as Array<{ id: string }>;
      expect(runRows).toHaveLength(1);
      const jobs = await agentJobsFor(dto.sessionId);
      expect(jobs).toHaveLength(1);
      expect(jobs[0]!.schedule).toMatchObject({
        scheduleId: dto.id,
        scheduleRunId: ledger[0]!.id,
      });
      await pauseSchedule(dto.id);

      // T10 carry (b): two OVERLAPPING ticks must never double-fire.
      const user2 = uid("e2e-sched-d2");
      createdUids.push(user2);
      const dto2 = await createScheduleRest(user2, {
        title: "Overlapping ticks",
        description: "tick race",
        trigger: { kind: "every", seconds: 300 },
      });
      const due2 = new Date(dto2.nextRunAt!);
      sse.arm({ deltas: ["tick"] });
      clockNow = new Date(due2.getTime());
      const [tickA, tickB] = await Promise.all([
        runSchedulerTick(schedulerDeps),
        runSchedulerTick(schedulerDeps),
      ]);
      expect(tickA.fired + tickB.fired).toBe(1);
      expect(tickA.duplicates + tickB.duplicates).toBe(0); // the row lock wins first

      const ledger2 = await scheduleRunRows(dto2.id);
      expect(ledger2).toHaveLength(1);
      await waitForRunStatus(ledger2[0]!.run_id!, "completed", "flow D overlapping-tick run completed");
      expect(await settleScheduleRuns(schedulerDeps)).toBe(1);
      const runRows2 = (await db.$client.unsafe("SELECT id FROM runs WHERE session_id = $1", [
        dto2.sessionId,
      ])) as Array<{ id: string }>;
      expect(runRows2).toHaveLength(1);
      expect(await agentJobsFor(dto2.sessionId)).toHaveLength(1);
      await pauseSchedule(dto2.id);
    }, 40_000);

    // ---- Flow E: retry ladder then pauseForReview --------------------------

    it("flow E — every-300 maxRetries 1: transient failure → retry_scheduled attempt 2 at T+30 s (no push); tick retries; second failure → failed + paused retries_exhausted, ONE push, ordered WS events", async () => {
      const user = uid("e2e-sched-e");
      createdUids.push(user);
      const sys = await connectSystem(user);
      await registerDevice(user, deviceToken(user));

      const dto = await createScheduleRest(user, {
        title: "Flaky",
        description: "retry me",
        trigger: { kind: "every", seconds: 300 },
        maxRetries: 1,
      });
      const due = new Date(dto.nextRunAt!);

      // Always transient: every model request dies after one delta.
      sse.arm({ deltas: ["partial"], closeSocketAfterDeltas: 1 });
      const T = new Date(due.getTime());
      clockNow = T;
      expect((await runSchedulerTick(schedulerDeps)).fired).toBe(1);

      const firstLedger = await scheduleRunRows(dto.id);
      expect(firstLedger).toHaveLength(1);
      const firstRunId = firstLedger[0]!.run_id!;
      await waitForRunStatus(firstRunId, "failed", "flow E first run failed");
      expect((await runRow(firstRunId))!.last_error).toBe("model_transient_exhausted");

      expect(await settleScheduleRuns(schedulerDeps)).toBe(1);
      const retryRow = (await scheduleRunRows(dto.id))[0]!;
      expect(retryRow).toMatchObject({
        id: firstLedger[0]!.id,
        status: "retry_scheduled",
        attempt: 2,
        run_id: firstRunId,
      });
      expect(new Date(retryRow.retry_at!).toISOString()).toBe(
        new Date(T.getTime() + 30_000).toISOString(),
      );
      // Dart parity: intermediate retries notify nobody.
      expect(await notificationRows(user)).toHaveLength(0);
      expect(pushesFor(user)).toHaveLength(0);

      // Tick at T+31 s: the retry occurrence fires as a NEW run, same ledger id.
      clockNow = new Date(T.getTime() + 31_000);
      const retryReport = await runSchedulerTick(schedulerDeps);
      expect(retryReport.retried).toBe(1);
      const secondLedger = (await scheduleRunRows(dto.id))[0]!;
      expect(secondLedger.id).toBe(firstLedger[0]!.id);
      expect(secondLedger.run_id).not.toBe(firstRunId);
      await waitForRunStatus(secondLedger.run_id!, "failed", "flow E retry run failed");

      expect(await settleScheduleRuns(schedulerDeps)).toBe(1);
      const finalLedger = (await scheduleRunRows(dto.id))[0]!;
      expect(finalLedger).toMatchObject({
        status: "failed",
        attempt: 2,
        error: "model_transient_exhausted",
      });
      expect(await scheduleRow(dto.id)).toMatchObject({
        status: "paused",
        paused_reason: "retries_exhausted",
      });

      await sys.waitFor(
        () => sys.events().some((e) => e.type === "schedule_run_paused"),
        "flow E schedule_run_paused",
      );
      const evs = sys.events().filter((e) => e.scheduleId === dto.id);
      expect(evs.map((e) => e.type)).toEqual([
        "schedule_created",
        "schedule_run_started",
        "schedule_run_failed", // willRetry: true (no push)
        "schedule_run_failed", // willRetry: false
        "schedule_run_paused",
      ]);
      expect(evs[2]!.payload).toMatchObject({
        willRetry: true,
        retryAt: new Date(retryRow.retry_at!).toISOString(),
      });
      expect(evs[3]!.payload).toMatchObject({ willRetry: false, code: "model_transient_exhausted" });
      expect(evs[4]!.payload).toMatchObject({ reason: "retries_exhausted" });

      // Exactly ONE terminal push/notification (never the intermediate retry).
      const notes = await notificationRows(user);
      expect(notes).toHaveLength(1);
      expect(notes[0]!.kind).toBe("scheduleFailed");
      expect(pushesFor(user)).toHaveLength(1);
      expect(pushesFor(user)[0]!.data.kind).toBe("scheduleFailed");
    }, 40_000);

    // ---- Flow F: T10 carry (a) — scheduler job is UNATTENDED ---------------

    it("flow F (T10 carry a) — a scheduler-shaped job (job.data.schedule, no explicit unattended flag) is UNATTENDED: default-deny policy applies and auto-denials are ledgered", async () => {
      // The pinned default-deny window is the spec §6.2 120 s.
      expect(UNATTENDED_APPROVAL_TIMEOUT_MS).toBe(120_000);

      const user = uid("e2e-sched-f");
      createdUids.push(user);
      const at = new Date(Date.now() + 3_600_000);
      const dto = await createScheduleRest(user, {
        title: "Approval needed",
        description: "run a shell command",
        trigger: { kind: "at", at: at.toISOString() },
      });

      // Capture the EXACT job the scheduler enqueues (no consumer here).
      const captured: AgentRunJob[] = [];
      const fakeQueues = {
        agentRuns: {
          add: async (_name: string, data: AgentRunJob) => {
            captured.push(data);
            return { id: data.runId };
          },
        },
        schedules: { add: async () => ({}) },
      } as unknown as QueueServices;

      clockNow = new Date(at.getTime() + 1_000);
      const outcome = await fireScheduleOccurrence(
        { db, queues: fakeQueues, system, clock: () => clockNow },
        dto.id,
        { expectedScheduledFor: at },
      );
      expect(outcome).toBe("fired");
      expect(captured).toHaveLength(1);
      const job = captured[0]!;
      expect(job.schedule).toMatchObject({ scheduleId: dto.id });
      // The enqueue payload does NOT carry `unattended` — derivation is the
      // processor's job (job.data.schedule !== undefined).
      expect(job.unattended).toBeUndefined();

      // The run_shell tool requires approval. A 250 ms timeout keeps the test
      // fast; the DENIAL REASON is the pin that the run was classified
      // unattended ("unattended_timeout", never plain "timeout").
      const execs: string[] = [];
      const fakeSandbox = {
        async exec(_userId: string, o: { cmd: string }) {
          execs.push(o.cmd);
          return { exitCode: 0, stdout: "", stderr: "" };
        },
        async killCall() {},
        async readFile() {
          return "";
        },
        async writeFile() {},
        async exists() {
          return false;
        },
        async listDir() {
          return [];
        },
        async jobStart() {
          return { jobId: "job-1" };
        },
        async jobOutput() {
          return { output: "", running: false, exitCode: 0 };
        },
        async jobList() {
          return [];
        },
        async jobKill() {},
      } as unknown as FullRunDeps["sandbox"];

      const hookCalls: string[] = [];
      const turnSse = await startTurnSse([
        // A destructive command trips the shell approval pre-pass (a safe
        // command such as `echo` is auto-allowed and never asks).
        toolCallTurn("call_sched_1", "run_shell", {
          command: "rm -rf /tmp/ovid-unattended",
        }),
        textTurn("denied, continuing"),
      ]);
      const processor = createFullAgentRunProcessor({
        db,
        events,
        keys: { getKeyForUser: async () => "test-key" },
        redisQ: redis,
        sandbox: fakeSandbox,
        github: null,
        litellmBaseUrl: turnSse.url,
        defaultModel: "e2e-model",
        anthropicBaseUrl: "https://anthropic.invalid",
        approvalTimeoutMs: 250,
        sleep: async () => {},
        unattendedApprovalHook: {
          async isUnattendedRun() {
            return true;
          },
          async onApprovalRequested(runId, req) {
            hookCalls.push(`requested:${runId}:${req.toolName}`);
          },
          async onApprovalAutoDenied(runId, req) {
            hookCalls.push(`denied:${runId}:${req.toolName}`);
          },
        },
      });

      try {
        await processor({ data: job });
      } finally {
        await processor.close();
        await turnSse.close();
      }

      const evts = await events.readSince(dto.sessionId, null, 500);
      expect(evts.some((e) => e.type === "approval_requested")).toBe(true);
      const resolved = evts.find((e) => e.type === "approval_resolved")!;
      expect(resolved.payload).toMatchObject({
        decision: "deny",
        reason: "unattended_timeout",
      });
      expect(evts.find((e) => e.type === "tool_completed")?.payload).toMatchObject({
        isError: true,
      });
      // Denied BEFORE dispatch: the sandbox never saw the command.
      expect(execs).toEqual([]);
      // The run-scoped unattended hook fired for both sides of the seam.
      expect(hookCalls).toEqual([
        `requested:${job.runId}:run_shell`,
        `denied:${job.runId}:run_shell`,
      ]);
      // spec §8: the run finishes normally after the denial.
      expect((await runRow(job.runId))!.status).toBe("completed");

      // Close the occurrence out so the ledger is terminal on re-runs.
      clockNow = new Date(at.getTime() + 2_000);
      expect(await settleScheduleRuns(schedulerDeps)).toBe(1);
      expect((await scheduleRow(dto.id))!.status).toBe("completed");
    }, 40_000);

    // ---- Cross-flow invariants --------------------------------------------

    it("cross-flow invariants — no failed/errored worker jobs", () => {
      expect(workerFailures).toEqual([]);
      expect(workerErrors).toEqual([]);
    });
  },
);
