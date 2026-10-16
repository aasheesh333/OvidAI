import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  createDb,
  eventMirror,
  messages,
  migrate,
  runs,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import {
  AGENT_RUN_JOB_NAME,
  createAgentRunsWorker,
  createQueues,
  type AgentRunJob,
} from "@ovid/queue";
import type { KeyProvider, SessionEvent } from "@ovid/shared";
import {
  createOpenAiTransport,
  TerminalModelError,
  TransientModelError,
  type ChatMessage,
  type ModelTransport,
} from "./liteLlm.js";
import { createAgentRunProcessor, type RunDeps } from "./runProcessor.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

const stubKeys = (value: string | null): KeyProvider => ({
  getKeyForUser: async () => value,
});

// ---------------------------------------------------------------------------
// Scripted transport stub: each stream() call consumes the next script step.
// `deltas` on a failing step are delivered via onDelta BEFORE the throw —
// pins that a mid-stream failure still flushes its deltas in order.
// ---------------------------------------------------------------------------

type ScriptStep =
  | { kind: "ok"; deltas: string[]; finishReason?: string | null }
  | { kind: "transient"; message?: string; deltas?: string[] }
  | { kind: "terminal"; message: string };

interface TransportCall {
  baseUrl: string;
  apiKey: string;
  model: string;
  messages: ChatMessage[];
}

function stubTransport(script: ScriptStep[]): {
  transport: ModelTransport;
  calls: TransportCall[];
} {
  const calls: TransportCall[] = [];
  const transport: ModelTransport = {
    async stream(req, h) {
      calls.push({
        baseUrl: req.baseUrl,
        apiKey: req.apiKey,
        model: req.model,
        messages: req.messages,
      });
      const step = script[Math.min(calls.length - 1, script.length - 1)];
      if (step === undefined) throw new Error("stubTransport: empty script");
      if (step.kind === "transient") {
        for (const d of step.deltas ?? []) h.onDelta(d);
        throw new TransientModelError(step.message ?? "upstream unavailable");
      }
      if (step.kind === "terminal") throw new TerminalModelError(step.message);
      for (const d of step.deltas) h.onDelta(d);
      return { finishReason: step.finishReason ?? "stop" };
    },
  };
  return { transport, calls };
}

// ---------------------------------------------------------------------------
// Real Postgres + real Redis (event log). skipIf on BOTH env vars per brief.
// Data isolation: every test seeds a fresh user/session/run (uuidv7 ids), and
// the redis stream keys this file creates are DELeted in afterAll (shared dev
// redis — no FLUSHDB, other suites' keys untouched).
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "createAgentRunProcessor (real Postgres + real Redis event log)",
  () => {
    let db: Db;
    let redisQ: Redis;
    let events: EventLog;
    let sleeps: number[] = [];
    const createdSessions: string[] = [];

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redisQ = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redisQ);
    });

    beforeEach(() => {
      sleeps = [];
    });

    afterAll(async () => {
      // Only keys THIS file created (one event stream per seeded session).
      if (createdSessions.length > 0) {
        await redisQ
          .del(...createdSessions.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }
      redisQ?.disconnect();
      await db?.$client.end({ timeout: 5 });
    });

    interface Seeded {
      uid: string;
      sessionId: string;
      runId: string;
      prompt: string;
      promptMessageId: string;
    }

    /**
     * Seeds the exact state the gateway leaves behind at enqueue time
     * (messages.test.ts ordering pin): user → session → history → the user
     * prompt message row → queued run row pointing at it.
     */
    async function seedRun(
      opts: {
        prompt?: string;
        history?: Array<{ role: "user" | "assistant" | "system" | "tool"; content: string }>;
      } = {},
    ): Promise<Seeded> {
      const userUid = uid("w9u");
      await users.ensure(db, userUid, `${userUid}@stub.test`);
      const session = await sessions.create(db, userUid);
      createdSessions.push(session.id);
      for (const m of opts.history ?? []) {
        await messages.append(db, { sessionId: session.id, role: m.role, content: m.content });
      }
      const prompt = opts.prompt ?? `prompt-${session.id.slice(-8)}`;
      const promptMessage = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: prompt,
      });
      const run = await runs.create(db, {
        sessionId: session.id,
        promptMessageId: promptMessage.id,
      });
      return {
        uid: userUid,
        sessionId: session.id,
        runId: run.id,
        prompt,
        promptMessageId: promptMessage.id,
      };
    }

    async function runRow(
      runId: string,
    ): Promise<{ status: string; attempts: number; lastError: string | null }> {
      const rows = await db.$client.unsafe(
        "SELECT status, attempts, last_error FROM runs WHERE id = $1",
        [runId],
      );
      const row = rows[0] as { status: string; attempts: number; last_error: string | null };
      return { status: row.status, attempts: row.attempts, lastError: row.last_error };
    }

    const jobOf = (s: Seeded): { data: AgentRunJob } => ({
      data: { runId: s.runId, sessionId: s.sessionId, userId: s.uid, prompt: s.prompt },
    });

    function makeDeps(transport: ModelTransport, overrides: Partial<RunDeps> = {}): RunDeps {
      return {
        db,
        events,
        keys: stubKeys("sk-worker-test"),
        transport,
        litellmBaseUrl: "http://litellm.invalid",
        defaultModel: "ovid-default-model",
        sleep: async (ms) => {
          sleeps.push(ms);
        },
        ...overrides,
      };
    }

    const readEvents = (sessionId: string): Promise<SessionEvent[]> =>
      events.readSince(sessionId, null, 200);
    const readMirror = (sessionId: string): Promise<SessionEvent[]> =>
      eventMirror.readSince(db, sessionId, null, 200);
    const types = (evts: SessionEvent[]): string[] => evts.map((e) => e.type);
    const assistantRows = async (sessionId: string) =>
      (await messages.page(db, sessionId, { limit: 200 })).rows.filter(
        (r) => r.role === "assistant",
      );

    it("happy path: run_started → message_delta×3 → message_completed → run_completed, assistant persisted, run completed", async () => {
      const seeded = await seedRun();
      const { transport, calls } = stubTransport([
        { kind: "ok", deltas: ["Hello", ", ", "world"] },
      ]);

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "message_delta",
        "message_delta",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(evts[0]!.payload).toEqual({ runId: seeded.runId });
      expect(evts[1]!.payload).toEqual({ runId: seeded.runId, text: "Hello" });
      expect(evts[2]!.payload).toEqual({ runId: seeded.runId, text: ", " });
      expect(evts[3]!.payload).toEqual({ runId: seeded.runId, text: "world" });

      // assistant message persisted with the concatenated deltas
      const assistants = await assistantRows(seeded.sessionId);
      expect(assistants).toHaveLength(1);
      expect(assistants[0]!.content).toBe("Hello, world");
      expect(evts[4]!.payload).toEqual({
        messageId: assistants[0]!.id,
        content: "Hello, world",
      });
      expect(evts[5]!.payload).toEqual({ runId: seeded.runId });

      // EVERY appended event is mirrored, field-for-field (sessionId, seq, type, payload, ts)
      expect(await readMirror(seeded.sessionId)).toEqual(evts);

      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed", attempts: 1 });

      // The gateway persisted the prompt BEFORE enqueueing, so the loaded
      // history already ends with it — exactly once, no second user message.
      expect(calls).toHaveLength(1);
      expect(calls[0]!.messages).toEqual([{ role: "user", content: seeded.prompt }]);
      expect(calls[0]!.baseUrl).toBe("http://litellm.invalid");
      expect(calls[0]!.apiKey).toBe("sk-worker-test");
      expect(calls[0]!.model).toBe("ovid-default-model");
      const page = await messages.page(db, seeded.sessionId, { limit: 10 });
      expect(page.rows.filter((r) => r.role === "user")).toHaveLength(1);
    });

    it("transient ×2 then success → exactly 2 run_started_retry (3000 then 9000), sleeps [3000, 9000], completes on attempt 3", async () => {
      const seeded = await seedRun();
      const { transport, calls } = stubTransport([
        { kind: "transient" },
        { kind: "transient" },
        { kind: "ok", deltas: ["recovered"] },
      ]);

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "run_started_retry",
        "run_started_retry",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      const retries = evts.filter((e) => e.type === "run_started_retry");
      expect(retries).toHaveLength(2);
      expect(retries[0]!.payload).toEqual({ attempt: 2, nextBackoffMs: 3000 });
      expect(retries[1]!.payload).toEqual({ attempt: 3, nextBackoffMs: 9000 });
      expect(sleeps).toEqual([3000, 9000]);
      expect(calls).toHaveLength(3);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed", attempts: 3 });
      const assistants = await assistantRows(seeded.sessionId);
      expect(assistants.map((r) => r.content)).toEqual(["recovered"]);
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
    });

    it("deltas emitted before a mid-stream transient failure stay ordered ahead of the retry event", async () => {
      const seeded = await seedRun();
      const { transport } = stubTransport([
        { kind: "transient", deltas: ["par", "tial"] },
        { kind: "ok", deltas: [" done"] },
      ]);

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "message_delta",
        "message_delta",
        "run_started_retry",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(evts[1]!.payload).toEqual({ runId: seeded.runId, text: "par" });
      expect(evts[2]!.payload).toEqual({ runId: seeded.runId, text: "tial" });
      // the persisted assistant message is the SUCCESSFUL attempt's text only
      const assistants = await assistantRows(seeded.sessionId);
      expect(assistants.map((r) => r.content)).toEqual([" done"]);
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
    });

    it("5 transients → run_failed(model_transient_exhausted), status failed, attempts 5, sleeps [3000, 9000, 27000, 60000]", async () => {
      const seeded = await seedRun();
      const { transport, calls } = stubTransport(
        Array.from({ length: 5 }, () => ({ kind: "transient" as const, message: "upstream 500" })),
      );

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "run_started_retry",
        "run_started_retry",
        "run_started_retry",
        "run_started_retry",
        "run_failed",
      ]);
      expect(evts.slice(1, 5).map((e) => e.payload)).toEqual([
        { attempt: 2, nextBackoffMs: 3000 },
        { attempt: 3, nextBackoffMs: 9000 },
        { attempt: 4, nextBackoffMs: 27000 },
        { attempt: 5, nextBackoffMs: 60000 },
      ]);
      expect(evts[5]!.payload).toEqual({ code: "model_transient_exhausted" });
      expect(sleeps).toEqual([3000, 9000, 27000, 60000]);
      expect(calls).toHaveLength(5);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "failed", attempts: 5 });
      expect(await assistantRows(seeded.sessionId)).toEqual([]);
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
    });

    it("terminal model error → immediate run_failed(model_terminal), status failed, attempts 1, no sleep, no retry", async () => {
      const seeded = await seedRun();
      const { transport, calls } = stubTransport([
        { kind: "terminal", message: "400 unknown model 'gpt-x'" },
      ]);

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual(["run_started", "run_failed"]);
      expect(evts[1]!.payload).toEqual({
        code: "model_terminal",
        message: "400 unknown model 'gpt-x'",
      });
      expect(sleeps).toEqual([]);
      expect(calls).toHaveLength(1);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "failed", attempts: 1 });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
    });

    it("missing key → run_failed(key_not_minted), status failed, transport NEVER called, no run_started", async () => {
      const seeded = await seedRun();
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      await createAgentRunProcessor(makeDeps(transport, { keys: stubKeys(null) }))(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toEqual({ code: "key_not_minted" });
      expect(calls).toHaveLength(0);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "failed", attempts: 0 });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
    });

    it("duplicate delivery (run already claimed/running) → silent return, ZERO events appended", async () => {
      const seeded = await seedRun();
      expect(await runs.claimNext(db, seeded.runId)).toBe(true); // another worker owns it now
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      expect(await readEvents(seeded.sessionId)).toEqual([]);
      expect(await readMirror(seeded.sessionId)).toEqual([]);
      expect(calls).toHaveLength(0);
      expect(sleeps).toEqual([]);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "running", attempts: 0 });
    });

    it("history reaches the transport oldest-first, ends with the prompt, tool rows skipped defensively", async () => {
      const seeded = await seedRun({
        prompt: "the-new-prompt",
        history: [
          { role: "user", content: "u1" },
          { role: "assistant", content: "a1" },
          { role: "system", content: "sys" },
          { role: "tool", content: "tool-result-cannot-occur-in-v0" },
          { role: "user", content: "u2" },
        ],
      });
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["ok"] }]);

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      expect(calls).toHaveLength(1);
      expect(calls[0]!.messages).toEqual([
        { role: "user", content: "u1" },
        { role: "assistant", content: "a1" },
        { role: "system", content: "sys" },
        { role: "user", content: "u2" },
        { role: "user", content: "the-new-prompt" }, // prompt appears EXACTLY once, last
      ]);
    });

    it("with 105 stored messages only the newest 100 are sent, oldest-first", async () => {
      const seeded = await seedRun({
        prompt: "m-104",
        history: Array.from({ length: 104 }, (_, i) => ({
          role: "user" as const,
          content: `m-${i}`,
        })),
      });
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["ok"] }]);

      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      expect(calls).toHaveLength(1);
      const sent = calls[0]!.messages;
      expect(sent).toHaveLength(100);
      expect(sent[0]).toEqual({ role: "user", content: "m-5" }); // oldest of the newest 100
      expect(sent[99]).toEqual({ role: "user", content: "m-104" }); // the prompt, last
      expect(sent.map((m) => m.content)).toEqual(
        Array.from({ length: 100 }, (_, i) => `m-${i + 5}`),
      );
    });

    // -------------------------------------------------------------------------
    // Integration-ish: the processor behind a REAL BullMQ worker + REAL queues
    // ({url} connection-object form pinned by Task 7) consuming a job added via
    // the real Queue, against the mock SSE LiteLLM through the REAL transport.
    // De-risks Task 10's e2e wiring.
    // -------------------------------------------------------------------------

    describe("integration: real BullMQ worker + real Queue + real SSE transport", () => {
      let server: Server | undefined;
      let queues: ReturnType<typeof createQueues> | undefined;
      let worker: ReturnType<typeof createAgentRunsWorker> | undefined;
      let lastModelRequest: { authorization: string | undefined; body: unknown } | undefined;

      afterAll(async () => {
        await worker?.close();
        worker = undefined;
        if (queues) {
          // BullMQ keeps blocking connections open — obliterate our queue keys
          // and close, or vitest hangs (same discipline as queues.test.ts).
          await queues.agentRuns.obliterate({ force: true });
          await queues.agentRuns.close();
          queues = undefined;
        }
        if (server) {
          const s = server;
          server = undefined;
          s.closeAllConnections();
          await new Promise<void>((resolve) => s.close(() => resolve()));
        }
      });

      async function startSseMock(pieces: string[]): Promise<string> {
        server = createServer((req, res) => {
          const chunks: Buffer[] = [];
          req.on("data", (c: Buffer) => chunks.push(c));
          req.on("end", () => {
            lastModelRequest = {
              authorization: req.headers.authorization,
              body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
            };
            res.writeHead(200, { "content-type": "text/event-stream" });
            for (const piece of pieces) {
              res.write(
                `data: ${JSON.stringify({
                  choices: [{ delta: { content: piece }, finish_reason: null }],
                })}\n\n`,
              );
            }
            res.write(
              `data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] })}\n\n`,
            );
            res.end("data: [DONE]\n\n");
          });
        });
        await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
        return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
      }

      it("job added via Queue({url}) → worker → SSE stream → ordered events in redis + mirror, run completed", async () => {
        const litellmBaseUrl = await startSseMock(["Integration ", "reply ", "works."]);
        const seeded = await seedRun({ prompt: "integration prompt" });
        const processor = createAgentRunProcessor(
          makeDeps(createOpenAiTransport(), { litellmBaseUrl }),
        );

        // Task 7 lesson, pinned: factories take an OPTIONS OBJECT { url }.
        const connection = { url: TEST_REDIS_URL! };
        queues = createQueues(connection);
        await queues.agentRuns.obliterate({ force: true }); // deterministic counts
        worker = createAgentRunsWorker(connection, processor);

        const settled = new Promise<void>((resolve, reject) => {
          const timer = setTimeout(
            () => reject(new Error("timed out waiting for the worker to settle the job")),
            15_000,
          );
          worker!.once("completed", () => {
            clearTimeout(timer);
            resolve();
          });
          worker!.once("failed", (_job, err) => {
            clearTimeout(timer);
            reject(err);
          });
        });

        await queues.agentRuns.add(
          AGENT_RUN_JOB_NAME,
          {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: seeded.prompt,
          },
          { jobId: seeded.runId, priority: 1 },
        );
        await settled;

        const evts = await readEvents(seeded.sessionId);
        expect(types(evts)).toEqual([
          "run_started",
          "message_delta",
          "message_delta",
          "message_delta",
          "message_completed",
          "run_completed",
        ]);
        expect(evts.map((e) => e.payload).slice(1, 4)).toEqual([
          { runId: seeded.runId, text: "Integration " },
          { runId: seeded.runId, text: "reply " },
          { runId: seeded.runId, text: "works." },
        ]);
        const assistants = await assistantRows(seeded.sessionId);
        expect(assistants.map((r) => r.content)).toEqual(["Integration reply works."]);
        expect(evts[4]!.payload).toEqual({
          messageId: assistants[0]!.id,
          content: "Integration reply works.",
        });
        expect(await readMirror(seeded.sessionId)).toEqual(evts);
        expect(await runRow(seeded.runId)).toMatchObject({ status: "completed", attempts: 1 });

        // the real transport carried the worker's key + history (prompt last)
        expect(lastModelRequest?.authorization).toBe("Bearer sk-worker-test");
        const body = lastModelRequest?.body as { model: string; stream: boolean; messages: ChatMessage[] };
        expect(body.model).toBe("ovid-default-model");
        expect(body.stream).toBe(true);
        expect(body.messages.at(-1)).toEqual({ role: "user", content: "integration prompt" });
      });
    });
  },
);
