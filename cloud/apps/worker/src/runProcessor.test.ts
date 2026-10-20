import { mkdtempSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  accountSettings,
  createDb,
  createPrivateMemoryStore,
  customPresets,
  attachments,
  eventMirror,
  messages,
  migrate,
  newId,
  projectsRepo,
  runs,
  sessionState,
  sessions,
  users,
  userPreferences,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import {
  AGENT_RUN_JOB_NAME,
  createAgentRunsWorker,
  createQueues,
  type AgentRunJob,
} from "@ovid/queue";
import {
  REFUSAL_MESSAGE,
  SandboxAdmissionError,
  SandboxCapacityError,
  type ExecRequest,
  type ExecResult,
  type SandboxHandle,
  type SandboxManager,
} from "@ovid/sandbox";
import type { SandboxPort } from "@ovid/agent-core";
import type { KeyResolver, SessionEvent } from "@ovid/shared";
import { createToolRegistry } from "./tools/registry.js";
import type { ToolRegistry } from "./tools/registry.js";
import {
  createImageTools,
  parseImageCapabilities,
  type ImageTooling,
} from "./tools/imageTools.js";
import { SYSTEM_PROMPT_V1, TOOL_EVENT_CONTENT_CAP } from "./tools/systemPrompt.js";
import type { ModelToolSpec } from "./tools/types.js";
import type { AgentTool } from "./tools/types.js";
import {
  createOpenAiTransport,
  TerminalModelError,
  TransientModelError,
  type ChatMessage,
  type ModelTransport,
  type ToolCall,
} from "./liteLlm.js";
import { createSandboxPort } from "./sandboxAdapter.js";
import { createAgentRunProcessor, type RunDeps } from "./runProcessor.js";
import { createFullAgentRunProcessor, type FullRunDeps } from "./runProcessor.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

const stubKeys = (value: string | null): KeyResolver => ({
  resolveForRun: async () =>
    value === null ? null : { kind: "litellm", key: value, baseUrl: "" },
});

// ---------------------------------------------------------------------------
// Scripted transport stub: each stream() call consumes the next script step.
// `deltas` on a failing step are delivered via onDelta BEFORE the throw —
// pins that a mid-stream failure still flushes its deltas in order.
// ---------------------------------------------------------------------------

type ScriptStep =
  | { kind: "ok"; deltas: string[]; finishReason?: string | null; toolCalls?: ToolCall[] }
  | { kind: "transient"; message?: string; deltas?: string[] }
  | { kind: "terminal"; message: string };

interface TransportCall {
  baseUrl: string;
  apiKey: string;
  model: string;
  messages: ChatMessage[];
  tools?: ModelToolSpec[];
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
        // SNAPSHOT: the processor passes its live (growing) array on tool
        // rounds — capturing the reference would show every call the final
        // state.
        messages: [...req.messages],
        tools: req.tools,
      });
      const step = script[Math.min(calls.length - 1, script.length - 1)];
      if (step === undefined) throw new Error("stubTransport: empty script");
      if (step.kind === "transient") {
        for (const d of step.deltas ?? []) h.onDelta(d);
        throw new TransientModelError(step.message ?? "upstream unavailable");
      }
      if (step.kind === "terminal") throw new TerminalModelError(step.message);
      for (const d of step.deltas) h.onDelta(d);
      return { finishReason: step.finishReason ?? "stop", toolCalls: step.toolCalls ?? [] };
    },
  };
  return { transport, calls };
}

// ---------------------------------------------------------------------------
// Stub SandboxManager (P2 Task 12): a fake handle whose workspaceDir is a REAL
// mkdtemp — the host-side file tools hit the real filesystem; exec records
// requests and returns a canned ExecResult; attach can be scripted to reject.
// ---------------------------------------------------------------------------

interface FakeSandbox {
  manager: SandboxManager;
  handle: SandboxHandle;
  /** Every exec request the fake handle received (blocked commands must leave this empty). */
  execs: ExecRequest[];
  /** Every attach(userId, opts) call — pins the tier pass-through. */
  attachCalls: Array<{ userId: string; tier?: "free" | "pro" }>;
  workspaceDir: string;
}

function makeFakeSandbox(opts: { execResult?: Partial<ExecResult>; attachError?: Error } = {}): FakeSandbox {
  const execs: ExecRequest[] = [];
  const attachCalls: FakeSandbox["attachCalls"] = [];
  const workspaceDir = mkdtempSync(join(tmpdir(), "ovid-w12-ws-"));
  const execResult: ExecResult = {
    exitCode: 0,
    stdout: "",
    stderr: "",
    timedOut: false,
    truncated: false,
    blocked: false,
    refusal: null,
    ...opts.execResult,
  };
  const handle = {
    userId: "fake",
    uid: 200_001,
    workspaceDir,
    homeDir: join(workspaceDir, "..", ".home"),
    jailWorkspaceDir: "/workspace",
    exec: async (req: ExecRequest) => {
      execs.push(req);
      return execResult;
    },
  } as unknown as SandboxHandle;
  const manager = {
    attach: async (userId: string, sbxOpts?: { tier?: "free" | "pro" }) => {
      attachCalls.push({ userId, tier: sbxOpts?.tier });
      if (opts.attachError !== undefined) throw opts.attachError;
      return handle;
    },
    get: () => undefined,
    destroy: async () => {},
    list: () => [],
    activeCount: () => 0,
    workspaceDir: async () => workspaceDir,
    recover: async () => {},
    close: async () => {},
  } as unknown as SandboxManager;
  return { manager, handle, execs, attachCalls, workspaceDir };
}

const rmWs = (dir: string): void => {
  rmSync(dir, { recursive: true, force: true });
};

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
      const row = rows[0] as unknown as {
        status: string;
        attempts: number;
        last_error: string | null;
      };
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

    it("stalled SSE stream → idle deadline aborts and retries as transient (first ladder rung 3000)", async () => {
      // P10 Task 2. A real [OI] SSE server writes ONE delta then holds the
      // response open. With RunDeps.streamIdleTimeoutMs the transport must be
      // aborted, classified transient, and retried on the 3 s ladder rung;
      // the second attempt (fresh idle arm) completes normally.
      const seeded = await seedRun();
      let requests = 0;
      let firstRequestAborted = false;
      const server = createServer((req, res) => {
        req.on("data", () => {});
        req.on("end", () => {
          requests += 1;
          res.writeHead(200, { "content-type": "text/event-stream" });
          if (requests === 1) {
            res.write(
              `data: ${JSON.stringify({
                choices: [{ delta: { content: "partial" }, finish_reason: null }],
              })}\n\n`,
            );
            res.on("close", () => {
              firstRequestAborted = true;
            });
            return; // hold forever: only the idle watchdog can end this
          }
          res.write(
            `data: ${JSON.stringify({
              choices: [{ delta: { content: "recovered" }, finish_reason: null }],
            })}\n\n`,
          );
          res.write(
            `data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] })}\n\n`,
          );
          res.end("data: [DONE]\n\n");
        });
      });
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      const litellmBaseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

      try {
        await createAgentRunProcessor(
          makeDeps(createOpenAiTransport(), {
            litellmBaseUrl,
            streamIdleTimeoutMs: 100,
          }),
        )(jobOf(seeded));

        // The server saw the aborted first response (the abort reached the
        // underlying fetch/socket, not just the processor's promise).
        const abortDeadline = Date.now() + 1_000;
        while (!firstRequestAborted && Date.now() < abortDeadline) {
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
        expect(firstRequestAborted).toBe(true);
        expect(requests).toBe(2);
      } finally {
        server.closeAllConnections();
        await new Promise<void>((resolve) => server.close(() => resolve()));
      }

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "message_delta",
        "run_started_retry",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(evts[2]!.payload).toEqual({ attempt: 2, nextBackoffMs: 3000 });
      expect(sleeps).toEqual([3000]);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed", attempts: 2 });
      const assistants = await assistantRows(seeded.sessionId);
      expect(assistants.map((r) => r.content)).toEqual(["recovered"]);
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
    }, 15_000);

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
      // Hygiene: don't leave a stranded 'running' row behind — that is exactly
      // the pathology the stale-run sweeper (staleRuns.ts) exists to fix.
      await runs.finish(db, seeded.runId, "failed", "test cleanup");
    });

    // -------------------------------------------------------------------------
    // C1: single active run per session. The processor must not claim a run
    // while an older active run of the SAME session exists (worker concurrency
    // 8 would otherwise interleave two runs' deltas in one transcript).
    // -------------------------------------------------------------------------

    /** Two runs of ONE session: `older` claimed by "another worker", `newer` enqueued. */
    async function seedTwoRuns(): Promise<{
      uid: string;
      sessionId: string;
      older: string;
      newer: string;
    }> {
      const userUid = uid("w9u");
      await users.ensure(db, userUid, `${userUid}@stub.test`);
      const session = await sessions.create(db, userUid);
      createdSessions.push(session.id);
      const promptMessage = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "p",
      });
      const first = await runs.create(db, {
        sessionId: session.id,
        promptMessageId: promptMessage.id,
      });
      const second = await runs.create(db, {
        sessionId: session.id,
        promptMessageId: promptMessage.id,
      });
      expect(await runs.claimNext(db, first.id)).toBe(true); // another worker owns it
      return { uid: userUid, sessionId: session.id, older: first.id, newer: second.id };
    }

    it("C1: newer run waits for the older active run, then starts strictly after its run_completed", async () => {
      const two = await seedTwoRuns();
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["after wait"] }]);
      // The injected sleep plays the older run's processor: on run2's first
      // poll-wait it emits run_completed (event FIRST) and flips the row —
      // exactly the terminal sequence the real processor now guarantees.
      const deps = makeDeps(transport, {
        sleep: async (ms) => {
          sleeps.push(ms);
          if (sleeps.length === 1) {
            const event = await events.append(two.sessionId, "run_completed", {
              runId: two.older,
            });
            await eventMirror.put(db, event);
            await runs.finish(db, two.older, "completed");
          }
        },
      });

      await createAgentRunProcessor(deps)({
        data: { runId: two.newer, sessionId: two.sessionId, userId: two.uid, prompt: "p" },
      });

      expect(sleeps).toEqual([250]); // one poll interval, then the older run was gone
      expect(calls).toHaveLength(1); // the model call happened exactly once, after the wait
      const evts = await readEvents(two.sessionId);
      expect(types(evts)).toEqual([
        "run_completed", // the OLDER run's terminal event…
        "run_started", // …strictly before run2's run_started (the C1 ordering pin)
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(evts[1]!.payload).toEqual({ runId: two.newer });
      expect(evts[4]!.payload).toEqual({ runId: two.newer });
      expect(await readMirror(two.sessionId)).toEqual(evts);
      expect(await runRow(two.newer)).toMatchObject({ status: "completed", attempts: 1 });
      expect(await runRow(two.older)).toMatchObject({ status: "completed" });
    });

    it("C1: older run still active at the wait cap → run_failed(run_queue_wait_timeout), run terminalized from 'queued', model never called", async () => {
      const two = await seedTwoRuns();
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      await createAgentRunProcessor(makeDeps(transport, { runQueueWaitMs: 0 }))({
        data: { runId: two.newer, sessionId: two.sessionId, userId: two.uid, prompt: "p" },
      });

      const evts = await readEvents(two.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toEqual({ code: "run_queue_wait_timeout" });
      expect(await readMirror(two.sessionId)).toEqual(evts);
      expect(calls).toHaveLength(0); // the model call is never started
      expect(sleeps).toEqual([]); // cap 0 → immediate refusal, no poll wait
      expect(await runRow(two.newer)).toMatchObject({
        status: "failed",
        attempts: 0,
        lastError: "run_queue_wait_timeout",
      });
      // The OLDER run is untouched — the refusal only concerns the wait-capped run.
      expect(await runRow(two.older)).toMatchObject({ status: "running" });
      // Hygiene: don't leave the seeded 'running' row stranded.
      await runs.finish(db, two.older, "failed", "test cleanup");
    });

    it("C1: the waiter terminalized externally mid-wait (stale-run sweeper) → exits on the NEXT tick, no duplicate terminal, model never called", async () => {
      const two = await seedTwoRuns();
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      // The injected sleep plays the queued-zombie sweeper: on run2's first
      // poll-wait it terminalizes the WAITER itself — claim-then-emit, the
      // sweeper's exact sequence (finish first, then append+mirror). The
      // older run stays 'running', so ONLY the per-tick self check can end
      // this wait; without it the job holds its slot the full 10-minute cap.
      const deps = makeDeps(transport, {
        sleep: async (ms) => {
          sleeps.push(ms);
          if (sleeps.length === 1) {
            if (await runs.finish(db, two.newer, "failed", "run_queue_wait_timeout")) {
              const event = await events.append(two.sessionId, "run_failed", {
                runId: two.newer,
                code: "run_queue_wait_timeout",
              });
              await eventMirror.put(db, event);
            }
          }
        },
      });

      await createAgentRunProcessor(deps)({
        data: { runId: two.newer, sessionId: two.sessionId, userId: two.uid, prompt: "p" },
      });

      expect(sleeps).toEqual([250]); // ONE poll interval: the next tick saw the terminal row
      expect(calls).toHaveLength(0); // the model call is never started
      // The sweeper's event ONLY — the waiter must not emit a second terminal.
      const evts = await readEvents(two.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toEqual({ runId: two.newer, code: "run_queue_wait_timeout" });
      expect(await readMirror(two.sessionId)).toEqual(evts);
      expect(await runRow(two.newer)).toMatchObject({
        status: "failed",
        attempts: 0,
        lastError: "run_queue_wait_timeout",
      });
      expect(await runRow(two.older)).toMatchObject({ status: "running" });
      // Hygiene: don't leave the seeded 'running' row stranded.
      await runs.finish(db, two.older, "failed", "test cleanup");
    });

    it("C1: cancelRequested while waiting (the gateway's 'cancelling' verdict) → the waiter terminalizes cancelled on the next tick, model never called", async () => {
      const two = await seedTwoRuns();
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      // The gateway set the flag but could NOT remove the BullMQ job (this
      // worker holds it, waiting) — terminalization is delegated to the
      // worker's flag check, which before this fix only ran mid-stream,
      // AFTER the claim that never comes. The wait loop must take the same
      // path a mid-stream cancel takes.
      const deps = makeDeps(transport, {
        sleep: async (ms) => {
          sleeps.push(ms);
          if (sleeps.length === 1) {
            await runs.requestCancel(db, two.newer, two.uid);
          }
        },
      });

      await createAgentRunProcessor(deps)({
        data: { runId: two.newer, sessionId: two.sessionId, userId: two.uid, prompt: "p" },
      });

      expect(sleeps).toEqual([250]); // ONE poll interval, then the flag was seen
      expect(calls).toHaveLength(0);
      const evts = await readEvents(two.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toEqual({ code: "cancelled", message: "Stopped by user." });
      expect(await readMirror(two.sessionId)).toEqual(evts);
      expect(await runRow(two.newer)).toMatchObject({
        status: "cancelled",
        attempts: 0,
        lastError: "Stopped by user.",
      });
      expect(await runRow(two.older)).toMatchObject({ status: "running" });
      // Hygiene: don't leave the seeded 'running' row stranded.
      await runs.finish(db, two.older, "failed", "test cleanup");
    });

    // -------------------------------------------------------------------------
    // P8 Task 1: cooperative cancel. The gateway sets runs.cancel_requested;
    // the processor polls it between streamed delta batches (throttled to one
    // check per second) and terminalizes the run as 'cancelled' with the
    // EXISTING run_failed event type.
    // -------------------------------------------------------------------------

    it("cancelRequested flips mid-stream → processor stops, run_failed{cancelled} appended+mirrored, run cancelled, no assistant message", async () => {
      const seeded = await seedRun();
      const transport: ModelTransport = {
        async stream(_req, h) {
          h.onDelta("first ");
          // Let the cancel check run once while the flag is still false
          // (cancelCheckIntervalMs: 0 → every delta batch gets a check).
          await new Promise((r) => setTimeout(r, 25));
          await runs.requestCancel(db, seeded.runId, seeded.uid);
          h.onDelta("second");
          // The check after this batch sees the flag and aborts.
          await new Promise((r) => setTimeout(r, 25));
          return { finishReason: "stop", toolCalls: [] };
        },
      };

      await createAgentRunProcessor(
        makeDeps(transport, { cancelCheckIntervalMs: 0 }),
      )(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "message_delta",
        "message_delta",
        "run_failed",
      ]);
      expect(evts[3]!.payload).toEqual({ code: "cancelled", message: "Stopped by user." });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      expect(await runRow(seeded.runId)).toMatchObject({
        status: "cancelled",
        // The v0 path's own terminalizeCancelled (worker, not the engine
        // loop) still writes the prose message.
        lastError: "Stopped by user.",
      });
      // Cancelled mid-stream: the partial assistant text is NEVER persisted.
      expect(await assistantRows(seeded.sessionId)).toEqual([]);
    });

    it("cancel checks are throttled to one per second: a flip inside the window is caught by the next windowed check", async () => {
      const seeded = await seedRun();
      const transport: ModelTransport = {
        async stream(_req, h) {
          h.onDelta("a");
          await new Promise((r) => setTimeout(r, 25)); // window-1 check: flag false
          await runs.requestCancel(db, seeded.runId, seeded.uid);
          h.onDelta("b"); // inside the 1 s window → this check is SKIPPED
          await new Promise((r) => setTimeout(r, 1_050)); // window elapses
          h.onDelta("c");
          await new Promise((r) => setTimeout(r, 25)); // window-2 check: sees the flag
          return { finishReason: "stop", toolCalls: [] };
        },
      };

      // Default cancelCheckIntervalMs (1000) — no override.
      await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "message_delta",
        "message_delta",
        "message_delta",
        "run_failed",
      ]);
      expect(evts[4]!.payload).toEqual({ code: "cancelled", message: "Stopped by user." });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "cancelled" });
      expect(await assistantRows(seeded.sessionId)).toEqual([]);
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
    // P2 Task 12: the v1 tool-call loop. Stub transport scripting rounds +
    // the stub SandboxManager above (file tools hit the REAL tmpdir workspace).
    // -------------------------------------------------------------------------

    it("v1 happy tool run: run_shell round → write_file round → text round; exact event order; round-2 messages carry role:tool; file written; tier passed to attach", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox({ execResult: { stdout: "hi\n" } });
      const runShellArgs = JSON.stringify({ command: "echo hi > out.txt" });
      const writeFileArgs = JSON.stringify({ path: "notes.md", content: "# x" });
      const { transport, calls } = stubTransport([
        { kind: "ok", deltas: [], toolCalls: [{ id: "call_1", name: "run_shell", arguments: runShellArgs }] },
        { kind: "ok", deltas: [], toolCalls: [{ id: "call_2", name: "write_file", arguments: writeFileArgs }] },
        { kind: "ok", deltas: ["done"] },
      ]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry() }),
      )({
        data: { runId: seeded.runId, sessionId: seeded.sessionId, userId: seeded.uid, prompt: seeded.prompt, tier: "free" },
      });

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "tool_started",
        "tool_completed",
        "tool_started",
        "tool_completed",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(evts[1]!.payload).toEqual({
        runId: seeded.runId,
        callId: "call_1",
        name: "run_shell",
        input: { command: "echo hi > out.txt" },
      });
      expect(evts[2]!.payload).toEqual({
        runId: seeded.runId,
        callId: "call_1",
        name: "run_shell",
        isError: false,
        content: "hi\n\n[exit 0]",
        truncated: false,
      });
      expect(evts[4]!.payload).toMatchObject({
        name: "write_file",
        isError: false,
        content: "wrote 3 bytes",
      });

      // tier passed through to attach
      expect(sbx.attachCalls).toEqual([{ userId: seeded.uid, tier: "free" }]);

      // the model context: system prompt first, history, assistant tool_calls,
      // then the role:"tool" result message
      expect(calls).toHaveLength(3);
      expect(calls[0]!.messages[0]).toEqual({ role: "system", content: SYSTEM_PROMPT_V1 });
      expect(calls[1]!.messages).toEqual([
        { role: "system", content: SYSTEM_PROMPT_V1 },
        { role: "user", content: seeded.prompt },
        {
          role: "assistant",
          content: "",
          toolCalls: [{ id: "call_1", name: "run_shell", arguments: runShellArgs }],
        },
        { role: "tool", toolCallId: "call_1", content: "hi\n\n[exit 0]" },
      ]);
      expect(calls[2]!.messages.slice(-2)).toEqual([
        {
          role: "assistant",
          content: "",
          toolCalls: [{ id: "call_2", name: "write_file", arguments: writeFileArgs }],
        },
        { role: "tool", toolCallId: "call_2", content: "wrote 3 bytes" },
      ]);
      // tools are sent on every round (sorted specs)
      expect(calls[0]!.tools?.map((t) => t.function.name)).toEqual([
        "edit_file", "glob_files", "grep_files", "read_file", "run_shell", "write_file",
      ]);

      // run_shell hit the fake exec once, with the clamped DEFAULT timeout
      expect(sbx.execs).toHaveLength(1);
      expect(sbx.execs[0]).toMatchObject({ command: "echo hi > out.txt", timeoutMs: 120_000 });

      // write_file wrote into the REAL tmpdir workspace (host-side, no jail)
      expect(await readFile(join(sbx.workspaceDir, "notes.md"), "utf8")).toBe("# x");

      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed", attempts: 3 });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      const assistants = await assistantRows(seeded.sessionId);
      expect(assistants.map((r) => r.content)).toEqual(["done"]);
      rmWs(sbx.workspaceDir);
    });

    it("v1 blocked command: run_shell 'gradle build' → tool_completed isError content === REFUSAL_MESSAGE, exactly one system_note, exec NEVER invoked", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const { transport } = stubTransport([
        {
          kind: "ok",
          deltas: [],
          toolCalls: [{ id: "call_b", name: "run_shell", arguments: JSON.stringify({ command: "gradle build" }) }],
        },
        { kind: "ok", deltas: ["alright then"] },
      ]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry() }),
      )(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "tool_started",
        "system_note",
        "tool_completed",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      const completed = evts.find((e) => e.type === "tool_completed")!;
      expect(completed.payload).toEqual({
        runId: seeded.runId,
        callId: "call_b",
        name: "run_shell",
        isError: true,
        content: REFUSAL_MESSAGE,
        truncated: false,
      });
      const notes = evts.filter((e) => e.type === "system_note");
      expect(notes).toHaveLength(1);
      expect(notes[0]!.payload).toEqual({
        code: "command_blocked",
        message: REFUSAL_MESSAGE,
        command: "gradle build",
      });
      // Zero side effects: the layer-1 policy short-circuits BEFORE exec.
      expect(sbx.execs).toEqual([]);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      rmWs(sbx.workspaceDir);
    });

    it("v1 attach rejects SandboxAdmissionError → run_failed {code:sandbox_unavailable}, run failed, job completes (no throw), model never called", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox({ attachError: new SandboxAdmissionError("gate full") });
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry() }),
      )(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toEqual({ code: "sandbox_unavailable", message: "gate full" });
      expect(await runRow(seeded.runId)).toMatchObject({
        status: "failed",
        attempts: 0,
        lastError: "sandbox_unavailable",
      });
      expect(calls).toHaveLength(0);
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      rmWs(sbx.workspaceDir);
    });

    it("v1 attach rejects SandboxCapacityError → the same sandbox_unavailable failure (no throw)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox({
        attachError: new SandboxCapacityError("disk_pressure"),
      });
      const { transport } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry() }),
      )(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toMatchObject({ code: "sandbox_unavailable" });
      expect(await runRow(seeded.runId)).toMatchObject({ status: "failed" });
      rmWs(sbx.workspaceDir);
    });

    it("v1 transport always returning a tool call → tool_rounds_exhausted after exactly 50 rounds, unknown_tool result each round", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const loop: ToolCall = { id: "call_loop", name: "loop_tool", arguments: "{}" };
      const { transport, calls } = stubTransport([
        { kind: "ok", deltas: [], toolCalls: [loop] },
      ]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry() }),
      )(jobOf(seeded));

      expect(calls).toHaveLength(50); // rounds 1..50, then the exhaustion failure
      const evts = await readEvents(seeded.sessionId);
      const failed = evts.find((e) => e.type === "run_failed")!;
      expect(failed.payload).toEqual({ code: "tool_rounds_exhausted" });
      expect(await runRow(seeded.runId)).toMatchObject({ status: "failed", attempts: 50 });
      const completions = evts.filter((e) => e.type === "tool_completed");
      expect(completions).toHaveLength(50);
      expect(completions[0]!.payload).toMatchObject({
        name: "loop_tool",
        isError: true,
        content: "unknown_tool: loop_tool",
      });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      rmWs(sbx.workspaceDir);
    });

    it("v1 tool result > 8 KiB → tool_completed payload capped with truncated:true; the in-run role:tool message keeps the full content; timeoutMs clamps to 600000", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox({ execResult: { stdout: "y".repeat(9_000) } });
      const { transport, calls } = stubTransport([
        {
          kind: "ok",
          deltas: [],
          toolCalls: [
            { id: "call_big", name: "run_shell", arguments: JSON.stringify({ command: "cat big.log", timeoutMs: 999_999 }) },
          ],
        },
        { kind: "ok", deltas: ["done"] },
      ]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry() }),
      )(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      const completed = evts.find((e) => e.type === "tool_completed")!;
      expect(completed.payload.content).toHaveLength(TOOL_EVENT_CONTENT_CAP);
      expect(completed.payload.truncated).toBe(true);
      expect(completed.payload.isError).toBe(false);

      // the model-facing tool message is NOT the event cap — it carries the
      // full (32 KiB-capped) tool result
      const toolMsg = calls[1]!.messages.find((m) => m.role === "tool")!;
      expect(toolMsg.toolCallId).toBe("call_big");
      expect(toolMsg.content).toBe(`${"y".repeat(9_000)}\n[exit 0]`);

      // the timeout was clamped to the 600 s max
      expect(sbx.execs[0]).toMatchObject({ command: "cat big.log", timeoutMs: 600_000 });
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      rmWs(sbx.workspaceDir);
    });

    // -------------------------------------------------------------------------
    // P8 Task 3: attachment materialization. The job payload carries
    // attachmentIds; the processor resolves them against the session's
    // attachment rows and downloads each R2 object (storage seam) into
    // uploads/{sanitizedName} inside the sandbox workspace BEFORE the first
    // provider call.
    // -------------------------------------------------------------------------

    /** Seeds an attachment row for the session and returns it. */
    async function seedAttachment(
      sessionId: string,
      userId: string,
      name: string,
    ): Promise<{ id: string; r2Key: string; name: string }> {
      const id = newId();
      const r2Key = `users/${userId}/sessions/${sessionId}/uploads/${id}`;
      await attachments.create(db, { id, sessionId, userId, name, size: 16, r2Key });
      return { id, r2Key, name };
    }

    it("job attachmentIds → one storage download per id into uploads/<sanitizedName> before streaming, then a normal completed run", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      // A NON-image name on purpose: this case pins materialization and
      // sanitization. Image attachments are gated by the vision check, which
      // has its own tests below.
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "photo 1.txt");
      const a2 = await seedAttachment(seeded.sessionId, seeded.uid, "../evil.txt");

      const downloads: string[] = [];
      const storage = {
        async getBuffer(key: string): Promise<Buffer | null> {
          downloads.push(key);
          return Buffer.from(`content-of-${key}`, "utf8");
        },
      };
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["done"] }]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry(), storage }),
      )({
        data: {
          runId: seeded.runId,
          sessionId: seeded.sessionId,
          userId: seeded.uid,
          prompt: seeded.prompt,
          attachmentIds: [a1.id, a2.id],
        },
      });

      // Exactly one download per id, in payload order, with the exact r2 keys.
      expect(downloads).toEqual([a1.r2Key, a2.r2Key]);

      // Both files landed in the sandbox workspace under uploads/ with the
      // sanitized single-segment names (the raw name is stored, the path is safe).
      const uploads = join(sbx.workspaceDir, "uploads");
      expect(await readFile(join(uploads, "photo_1.txt"), "utf8")).toBe(
        `content-of-${a1.r2Key}`,
      );
      expect(await readFile(join(uploads, "_evil.txt"), "utf8")).toBe(
        `content-of-${a2.r2Key}`,
      );

      // The model call happened exactly once — after materialization — and the
      // run completed normally (materialization emits no events).
      expect(calls).toHaveLength(1);
      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      rmWs(sbx.workspaceDir);
    });

    // ---- Vision gate (owner directive 2026-10-18) ----------------------
    // An image attachment goes to the model as an image. A model that cannot
    // see it must be refused BEFORE any bytes move, with copy the user can act
    // on and a push so a backgrounded app still learns.
    it("image attachment + a non-vision model → run_failed{model_no_vision}, no download, push sent", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "shot.png");

      const downloads: string[] = [];
      const storage = {
        async getBuffer(key: string): Promise<Buffer | null> {
          downloads.push(key);
          return Buffer.from("png-bytes", "utf8");
        },
      };
      const pushes: Array<{ code: string; message: string; userId: string }> = [];
      const notifier = {
        async notifyAgentFailed(a: {
          userId: string;
          sessionId: string;
          sessionTitle: string;
          code: string;
          message: string;
        }): Promise<void> {
          pushes.push({ code: a.code, message: a.message, userId: a.userId });
        },
      };
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      await createAgentRunProcessor(
        makeDeps(transport, {
          sandbox: sbx.manager,
          tools: createToolRegistry(),
          storage,
          notifier,
        }),
      )({
        data: {
          runId: seeded.runId,
          sessionId: seeded.sessionId,
          userId: seeded.uid,
          prompt: "what is in this picture?",
          attachmentIds: [a1.id],
        },
      } as never);

      // Nothing was downloaded and the provider was never called.
      expect(downloads).toEqual([]);
      expect(calls).toHaveLength(0);

      const evts = await readEvents(seeded.sessionId);
      const failure = evts.find((e) => e.type === "run_failed");
      expect(failure?.payload).toMatchObject({
        code: "model_no_vision",
        model: "ovid-default-model",
        basis: "unknown",
        imageCount: 1,
      });
      expect(String(failure?.payload.message)).toContain("does not support vision/image inputs");
      expect(await runRow(seeded.runId)).toMatchObject({ status: "failed" });

      // The push carries the same actionable copy.
      expect(pushes).toHaveLength(1);
      expect(pushes[0]).toMatchObject({ code: "model_no_vision", userId: seeded.uid });
      expect(pushes[0]!.message).toContain("switch to a vision-capable model");
      rmWs(sbx.workspaceDir);
    });

    it("image attachment + a catalog-confirmed vision model → the run proceeds", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "shot.png");

      const downloads: string[] = [];
      const storage = {
        async getBuffer(key: string): Promise<Buffer | null> {
          downloads.push(key);
          return Buffer.from("png-bytes", "utf8");
        },
      };
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["a photo"] }]);

      await createAgentRunProcessor(
        makeDeps(transport, {
          sandbox: sbx.manager,
          tools: createToolRegistry(),
          storage,
          // The operator's catalog vouches for the fleet default.
          modelCatalog: async () => [
            { model_name: "ovid-default-model", model_info: { supports_vision: true } },
          ],
        }),
      )({
        data: {
          runId: seeded.runId,
          sessionId: seeded.sessionId,
          userId: seeded.uid,
          prompt: "what is in this picture?",
          attachmentIds: [a1.id],
        },
      } as never);

      expect(downloads).toEqual([a1.r2Key]);
      expect(calls).toHaveLength(1);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      rmWs(sbx.workspaceDir);
    });

    it("missing R2 object (storage returns null) → run_failed{attachment_unavailable}, model never called, job completes", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "gone.txt");
      const storage = {
        async getBuffer(): Promise<Buffer | null> {
          return null; // object absent — the upload never completed
        },
      };
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools: createToolRegistry(), storage }),
      )({
        data: {
          runId: seeded.runId,
          sessionId: seeded.sessionId,
          userId: seeded.uid,
          prompt: seeded.prompt,
          attachmentIds: [a1.id],
        },
      });

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toMatchObject({ code: "attachment_unavailable" });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      expect(calls).toHaveLength(0);
      expect(await runRow(seeded.runId)).toMatchObject({
        status: "failed",
        attempts: 0,
        lastError: "attachment_unavailable",
      });
      rmWs(sbx.workspaceDir);
    });

    it("attachment id with no db row (or no storage wired) → the same attachment_unavailable terminal failure", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      // No row for this id — the gateway validated at enqueue time, so this is
      // the defensive path; it must still be loud, never a silent skip.
      await createAgentRunProcessor(
        makeDeps(transport, {
          sandbox: sbx.manager,
          tools: createToolRegistry(),
          storage: { async getBuffer() { return Buffer.from("x"); } },
        }),
      )({
        data: {
          runId: seeded.runId,
          sessionId: seeded.sessionId,
          userId: seeded.uid,
          prompt: seeded.prompt,
          attachmentIds: [newId()],
        },
      });

      let evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toMatchObject({ code: "attachment_unavailable" });
      expect(calls).toHaveLength(0);
      await runs.finish(db, seeded.runId, "failed", "test cleanup"); // hygiene: already failed, keep row terminal

      // And with attachments requested but NO storage seam wired: same loud
      // failure (misconfiguration must never be a silent no-op).
      const seeded2 = await seedRun();
      const sbx2 = makeFakeSandbox();
      const a1 = await seedAttachment(seeded2.sessionId, seeded2.uid, "x.txt");
      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx2.manager, tools: createToolRegistry() }),
      )({
        data: {
          runId: seeded2.runId,
          sessionId: seeded2.sessionId,
          userId: seeded2.uid,
          prompt: seeded2.prompt,
          attachmentIds: [a1.id],
        },
      });
      evts = await readEvents(seeded2.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toMatchObject({ code: "attachment_unavailable" });
      expect(calls).toHaveLength(0);
      expect(await runRow(seeded2.runId)).toMatchObject({ status: "failed" });
      rmWs(sbx.workspaceDir);
      rmWs(sbx2.workspaceDir);
    });

    it("v0 tool-less path (no sandbox wired) with attachmentIds → loud run_failed{attachment_unavailable}, model never called (never-silent invariant)", async () => {
      const seeded = await seedRun();
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "x.txt");
      const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

      // Pre-P2 composition: NO sandbox/tools — the legacy v0 loop. Attachments
      // need a workspace, so this must fail loudly, never silently drop them.
      await createAgentRunProcessor(makeDeps(transport))({
        data: {
          runId: seeded.runId,
          sessionId: seeded.sessionId,
          userId: seeded.uid,
          prompt: seeded.prompt,
          attachmentIds: [a1.id],
        },
      });

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual(["run_failed"]);
      expect(evts[0]!.payload).toMatchObject({ code: "attachment_unavailable" });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      expect(calls).toHaveLength(0);
      expect(await runRow(seeded.runId)).toMatchObject({
        status: "failed",
        lastError: "attachment_unavailable",
      });
    });

    // -------------------------------------------------------------------------
    // Integration-ish: the processor behind a REAL BullMQ worker + REAL queues
    // ({url} connection-object form pinned by Task 7) consuming a job added via
    // the real Queue, against the mock SSE LiteLLM through the REAL transport.
    // De-risks Task 10's e2e wiring.
    // -------------------------------------------------------------------------

    describe("integration: real BullMQ worker + real Queue + real SSE transport", () => {
      // Suite-unique BullMQ prefix: parallel suites share the dev redis, so
      // this suite's obliterate calls can only ever wipe its OWN keys.
      const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
        ? `${process.env.OVID_TEST_QUEUE_PREFIX}-worker`
        : "ovid-test-worker";
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
        queues = createQueues(connection, { prefix: QUEUE_PREFIX });
        await queues.agentRuns.obliterate({ force: true }); // deterministic counts (our keys only)
        worker = createAgentRunsWorker(connection, processor, { prefix: QUEUE_PREFIX });

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

    // -----------------------------------------------------------------------
    // P3 Task 16 — the engine behind the P2-compat contract.
    //
    // The compat path swaps P2's interim loop for the agent-core engine but
    // keeps P2's wire contract EXACTLY (see the appended cases): payload keys
    // are normalized by the worker's compat sink (args stripped from
    // tool_started, ok stripped from tool_completed, model_transient_exhausted
    // carries no message, run_cancelled is the P2 run_failed/cancelled pair).
    // -----------------------------------------------------------------------

    it("P3 compat: a fake P2 registry joins through agentToolAdapter — exact P2 payloads, role:tool row, system prompt V1", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const seen: Array<{ input: unknown; callKey: string | undefined }> = [];
      const fake: AgentTool = {
        name: "fake_echo",
        description: "Echo the text back.",
        parameters: {
          type: "object",
          properties: { text: { type: "string" } },
          required: ["text"],
        },
        async execute(input, ctx) {
          seen.push({ input, callKey: ctx.callKey });
          return { content: `echo:${(input as { text: string }).text}`, isError: false };
        },
      };
      // A hand-built P2 registry (the seam Task 9 adapts), NOT createToolRegistry:
      // the point is that any landed P2 roster joins the canonical seam.
      const tools: ToolRegistry = {
        tools: [fake],
        get: (name) => (name === "fake_echo" ? fake : undefined),
        specs: () => [
          {
            type: "function" as const,
            function: {
              name: fake.name,
              description: fake.description,
              parameters: fake.parameters,
            },
          },
        ],
      };
      const { transport, calls } = stubTransport([
        {
          kind: "ok",
          deltas: [],
          toolCalls: [{ id: "c1", name: "fake_echo", arguments: JSON.stringify({ text: "hi" }) }],
        },
        { kind: "ok", deltas: ["done"] },
      ]);

      await createAgentRunProcessor(
        makeDeps(transport, { sandbox: sbx.manager, tools }),
      )(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "tool_started",
        "tool_completed",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      // EXACT P2 spellings: no `args`, no `ok` (the compat sink strips them).
      expect(evts[1]!.payload).toEqual({
        runId: seeded.runId,
        callId: "c1",
        name: "fake_echo",
        input: { text: "hi" },
      });
      expect(evts[2]!.payload).toEqual({
        runId: seeded.runId,
        callId: "c1",
        name: "fake_echo",
        isError: false,
        content: "echo:hi",
        truncated: false,
      });

      // The adapted tool received the canonical ctx callKey.
      expect(seen).toEqual([{ input: { text: "hi" }, callKey: `${seeded.runId}:c1` }]);

      // The system row is P2's SYSTEM_PROMPT_V1, byte-for-byte; the tool row
      // joins the next request.
      expect(calls).toHaveLength(2);
      expect(calls[0]!.messages[0]).toEqual({ role: "system", content: SYSTEM_PROMPT_V1 });
      expect(calls[1]!.messages).toContainEqual({
        role: "tool",
        toolCallId: "c1",
        content: "echo:hi",
      });
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed", attempts: 2 });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      rmWs(sbx.workspaceDir);
    });

    it("P3 compat: run_cancelled maps onto P2's run_failed {code:cancelled} with the event sequence unchanged", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox();
      const transport: ModelTransport = {
        async stream(_req, h) {
          h.onDelta("first ");
          await new Promise((r) => setTimeout(r, 25));
          await runs.requestCancel(db, seeded.runId, seeded.uid);
          h.onDelta("second");
          await new Promise((r) => setTimeout(r, 25));
          return { finishReason: "stop", toolCalls: [] };
        },
      };

      await createAgentRunProcessor(
        makeDeps(transport, {
          sandbox: sbx.manager,
          tools: createToolRegistry(),
          cancelCheckIntervalMs: 0,
        }),
      )(jobOf(seeded));

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "message_delta",
        "message_delta",
        "run_failed",
      ]);
      expect(evts[3]!.payload).toEqual({ code: "cancelled", message: "Stopped by user." });
      expect(await runRow(seeded.runId)).toMatchObject({
        status: "cancelled",
        // Canonical code, not prose (see the compat-path cancel test).
        lastError: "cancelled",
      });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
      rmWs(sbx.workspaceDir);
    });

    it("P3 compat: cancel-then-next-run — the cancelled run's terminal event precedes the successor's run_started", async () => {
      // Two runs of ONE session, neither pre-claimed: run1 is processed by
      // this test (cancel requested before it streams), run2 waits behind it
      // in the C1 gate. The cancelled run's terminal event MUST land before
      // run2's run_started (T16 review I1 — event-first, P8-T1 contract).
      const userUid = uid("w9u");
      await users.ensure(db, userUid, `${userUid}@stub.test`);
      const session = await sessions.create(db, userUid);
      createdSessions.push(session.id);
      const promptMessage = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "p",
      });
      const run1 = await runs.create(db, { sessionId: session.id, promptMessageId: promptMessage.id });

      const sbx = makeFakeSandbox();
      const realSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
      let modelStarted = false;
      const t1: ModelTransport = {
        async stream(_req, h) {
          modelStarted = true;
          h.onDelta("first");
          // Stay in the model call past run1's drain points (the steering
          // drain would otherwise MERGE the queued run2 into run1), then
          // emit another delta so the cancel poll runs.
          await new Promise((r) => setTimeout(r, 300));
          h.onDelta("second");
          await new Promise((r) => setTimeout(r, 50));
          return { finishReason: "stop", toolCalls: [] };
        },
      };
      const t2 = stubTransport([{ kind: "ok", deltas: ["second run"] }]);

      const deps1 = makeDeps(t1, {
        sandbox: sbx.manager,
        tools: createToolRegistry(),
        cancelCheckIntervalMs: 0,
        sleep: realSleep,
      });
      const deps2 = makeDeps(t2.transport, {
        sandbox: sbx.manager,
        tools: createToolRegistry(),
        sleep: realSleep,
      });

      const p1 = createAgentRunProcessor(deps1)({
        data: { runId: run1.id, sessionId: session.id, userId: userUid, prompt: "p" },
      });
      // Wait until run1 is INSIDE its model call (its loop has passed the
      // steering drain), then enqueue run2's processor so it waits in the
      // C1 gate rather than being merged.
      const deadline = Date.now() + 5_000;
      for (;;) {
        if (modelStarted) break;
        if (Date.now() > deadline) throw new Error("run1 never called the model");
        await realSleep(10);
      }
      // The row is created only AFTER run1 is inside its model call: a queued
      // row existing at run1's first steering drain would be MERGED into
      // run1 (that is the steering contract), leaving no successor to order.
      const prompt2 = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "p2",
      });
      const run2 = await runs.create(db, {
        sessionId: session.id,
        promptMessageId: prompt2.id,
      });
      const p2 = createAgentRunProcessor(deps2)({
        data: { runId: run2.id, sessionId: session.id, userId: userUid, prompt: "p" },
      });
      await realSleep(50);
      // Cancel run1 mid-model-call; the next delta's poll sees it.
      await runs.requestCancel(db, run1.id, userUid);
      await Promise.all([p1, p2]);

      const evts = await readEvents(session.id);
      const cancelIdx = evts.findIndex(
        (e) => e.type === "run_failed" && e.payload.code === "cancelled",
      );
      const successorIdx = evts.findIndex(
        (e) => e.type === "run_started" && e.payload.runId === run2.id,
      );
      expect(cancelIdx).toBeGreaterThanOrEqual(0);
      expect(successorIdx).toBeGreaterThan(cancelIdx);
      expect(await runRow(run1.id)).toMatchObject({ status: "cancelled" });
      expect(await runRow(run2.id)).toMatchObject({ status: "completed" });
      rmWs(sbx.workspaceDir);
    });

    // -----------------------------------------------------------------------
    // P3 Task 16 — the full processor (createFullAgentRunProcessor).
    //
    // Real agent-core engine over: the REAL openai SSE transport against a
    // local mock, a fake SandboxPort, the Postgres state store and the real
    // redis approval bridge (closed by processor.close()).
    // -----------------------------------------------------------------------

    /** A fake SandboxPort recording exec requests (callKey included). */
    function makeFakePort(
      execResult: { exitCode: number; stdout: string; stderr: string } = {
        exitCode: 0,
        stdout: "",
        stderr: "",
      },
      files: Record<string, string> = {},
    ): { port: SandboxPort; execs: Array<{ cmd: string; callKey?: string }> } {
      const execs: Array<{ cmd: string; callKey?: string }> = [];
      const port: SandboxPort = {
        async exec(_userId, o) {
          execs.push({ cmd: o.cmd, callKey: o.callKey });
          return execResult;
        },
        async killCall() {},
        async readFile(_userId, path) {
          return files[path] ?? "";
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
      };
      return { port, execs };
    }

    /**
     * A local [OI]-dialect SSE mock: the Nth POST serves turns[N-1] (the last
     * turn repeats). Every turn ends with `data: [DONE]`. The recorded model
     * pins which route the run actually took (the vision gate predicts it).
     */
    async function startTurnSse(
      turns: Array<Array<Record<string, unknown>>>,
    ): Promise<{
      url: string;
      requests: Array<{
        messages: ChatMessage[];
        tools?: unknown;
        model?: string;
        max_tokens?: number;
      }>;
      close: () => Promise<void>;
    }> {
      const requests: Array<{
        messages: ChatMessage[];
        tools?: unknown;
        model?: string;
        max_tokens?: number;
      }> = [];
      const server = createServer((req, res) => {
        const chunks: Buffer[] = [];
        req.on("data", (c: Buffer) => chunks.push(c));
        req.on("end", () => {
          const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
            messages: ChatMessage[];
            tools?: unknown;
            model?: string;
            max_tokens?: number;
          };
          requests.push({
            messages: body.messages,
            tools: body.tools,
            model: body.model,
            max_tokens: body.max_tokens,
          });
          const turn = turns[Math.min(requests.length - 1, turns.length - 1)]!;
          res.writeHead(200, { "content-type": "text/event-stream" });
          for (const event of turn) res.write(`data: ${JSON.stringify(event)}\n\n`);
          res.end("data: [DONE]\n\n");
        });
      });
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
      return {
        url,
        requests,
        close: async () => {
          server.closeAllConnections();
          await new Promise<void>((resolve) => server.close(() => resolve()));
        },
      };
    }

    function makeFullDeps(
      litellmBaseUrl: string,
      port: SandboxPort,
      overrides: Partial<FullRunDeps> = {},
    ): FullRunDeps {
      return {
        db,
        events,
        keys: stubKeys("sk-full-test"),
        redisQ,
        sandbox: port,
        github: null,
        litellmBaseUrl,
        defaultModel: "full-default-model",
        anthropicBaseUrl: "https://anthropic.invalid",
        // NO egress override: the tests exercise the production provider
        // egress, whose operator-origin allowlist admits the loopback SSE
        // mock (T16 review C1). User-supplied URLs stay fully guarded.
        sleep: async (ms) => {
          sleeps.push(ms);
        },
        ...overrides,
      };
    }

    const toolCallTurn = (id: string, name: string, args: Record<string, unknown>): Array<Record<string, unknown>> => [
      {
        choices: [
          {
            delta: {
              tool_calls: [
                {
                  index: 0,
                  id,
                  function: { name, arguments: JSON.stringify(args) },
                },
              ],
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

    it("full processor: run_shell round → sandbox.exec got the command + callKey → final text turn completes", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort({ exitCode: 0, stdout: "hi\n", stderr: "" });
      const sse = await startTurnSse([
        toolCallTurn("call_1", "run_shell", { command: "echo hi" }),
        textTurn("done"),
      ]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toEqual([
        "run_started",
        "tool_started",
        "tool_completed",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      // P3 spellings ride alongside P2's through this task.
      expect(evts[1]!.payload).toMatchObject({
        runId: seeded.runId,
        callId: "call_1",
        name: "run_shell",
        input: { command: "echo hi" },
        args: { command: "echo hi" },
      });
      expect(evts[2]!.payload).toMatchObject({
        runId: seeded.runId,
        callId: "call_1",
        name: "run_shell",
        isError: false,
        ok: true,
        content: "hi\n\n[exit 0]",
        truncated: false,
      });
      // The dispatch threaded the canonical callKey down to the sandbox.
      expect(sbx.execs).toEqual([{ cmd: "echo hi", callKey: `${seeded.runId}:call_1` }]);
      // A real system prompt went out on the wire.
      expect(sse.requests[0]!.messages[0]!.role).toBe("system");
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      expect(await readMirror(seeded.sessionId)).toEqual(evts);
    });

    it("full processor: every model call's usage lands in run_usage (Wave 3 ledger)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort({ exitCode: 0, stdout: "hi\n", stderr: "" });
      const usage = (prompt: number, completion: number, cached: number) => ({
        choices: [],
        usage: {
          prompt_tokens: prompt,
          completion_tokens: completion,
          total_tokens: prompt + completion,
          prompt_tokens_details: { cached_tokens: cached },
        },
      });
      const sse = await startTurnSse([
        [...toolCallTurn("call_1", "run_shell", { command: "echo hi" }), usage(1200, 40, 1000)],
        [...textTurn("done"), usage(1300, 5, 1200)],
      ]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      const rows = (await db.$client`
        SELECT user_id, session_id, run_id, model, input_tokens, output_tokens, cache_read_tokens
          FROM run_usage WHERE run_id = ${seeded.runId} ORDER BY created_at, id
      `) as Array<Record<string, unknown>>;
      expect(rows).toEqual([
        {
          user_id: seeded.uid,
          session_id: seeded.sessionId,
          run_id: seeded.runId,
          model: "full-default-model",
          input_tokens: 1200,
          output_tokens: 40,
          cache_read_tokens: 1000,
        },
        {
          user_id: seeded.uid,
          session_id: seeded.sessionId,
          run_id: seeded.runId,
          model: "full-default-model",
          input_tokens: 1300,
          output_tokens: 5,
          cache_read_tokens: 1200,
        },
      ]);
    });

    it("full processor: the five subagent tools are registered (fix I-1)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const sse = await startTurnSse([textTurn("done")]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }

      const advertised = (
        sse.requests[0]!.tools as Array<{ function: { name: string } }>
      ).map((t) => t.function.name);
      for (const name of [
        "dispatch_agent",
        "send_message",
        "list_agents",
        "interrupt_agent",
        "report",
      ]) {
        expect(advertised).toContain(name);
      }
    });

    it("full processor: image tools are registered when the image seam is wired (W8)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const sse = await startTurnSse([textTurn("done")]);
      const capabilities = parseImageCapabilities({
        catalog_hash: "a".repeat(32),
        models: [
          {
            slug: "ovid-image:img-one",
            operations: { generate: {}, edit: {} },
            sizes: ["1024x1024"],
            input: { max_images: 1 },
          },
        ],
      });
      const images: ImageTooling = {
        capabilities: async () => capabilities,
        createTools: (o) =>
          createImageTools({
            call: async () => ({ ok: true, body: {} }),
            capabilities: o.capabilities,
            publishArtifact: async (input) => ({
              id: "art-test",
              url: "https://r2.invalid/art-test",
              expiresAt: "2026-10-20T16:00:00.000Z",
              sizeBytes: input.content.length,
              contentType: input.contentType,
            }),
          }),
      };
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, sbx.port, { images }),
      );
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }

      const advertised = (
        sse.requests[0]!.tools as Array<{ function: { name: string } }>
      ).map((t) => t.function.name);
      expect(advertised).toContain("generate_image");
      expect(advertised).toContain("edit_image");
      // The description carries the discovered card, not a private model id.
      const generate = (
        sse.requests[0]!.tools as Array<{
          function: { name: string; description: string };
        }>
      ).find((t) => t.function.name === "generate_image");
      expect(generate?.function.description).toContain("ovid-image:img-one");
    });

    it("full processor: dispatch_agent runs a real child loop and returns its report (fix I-1)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const sse = await startTurnSse([
        toolCallTurn("call_d", "dispatch_agent", { prompt: "child task" }),
        textTurn("child answer"),
        textTurn("parent done"),
      ]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toContain("subagent_started");
      expect(types(evts)).toContain("subagent_completed");
      const completed = evts.find(
        (e) => e.type === "tool_completed" && e.payload.name === "dispatch_agent",
      )!;
      expect(completed.payload).toMatchObject({ ok: true, content: "child answer" });
      // The child is a real session with its own persisted transcript.
      const started = evts.find((e) => e.type === "subagent_started")!;
      const childSessionId = String(started.payload.childSessionId);
      const childRows = await messages.page(db, childSessionId, { limit: 10 });
      expect(childRows.rows.some((r) => r.role === "assistant" && r.content === "child answer")).toBe(true);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
    });

    it("full processor: a prompt hook is model-evaluated and can block (fix I-6)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort(undefined, {
        ".dsh/hooks.json": JSON.stringify([
          {
            event: "UserPromptSubmit",
            type: "prompt",
            prompt: "Never allow the word banana.",
            id: "h1",
          },
        ]),
      });
      const sse = await startTurnSse([textTurn("block: banana is forbidden")]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }

      const evts = await readEvents(seeded.sessionId);
      const failed = evts.find((e) => e.type === "run_failed")!;
      expect(failed.payload).toMatchObject({ code: "hook_blocked" });
      expect(String(failed.payload.message)).toContain("banana");
      // The evaluator is a QUIET one-shot call: exactly one model request
      // (the rule), no transcript deltas, and the main run never starts.
      expect(sse.requests).toHaveLength(1);
      expect(JSON.stringify(sse.requests[0]!.messages)).toContain(
        "Never allow the word banana.",
      );
      expect(evts.some((e) => e.type === "message_delta")).toBe(false);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "failed" });
    });

    it("full processor: unattended approval timeout → approval_resolved{unattended_timeout}, DENIED tool result, run CONTINUES", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const sse = await startTurnSse([
        toolCallTurn("call_d", "run_shell", { command: "rm -rf /tmp/ovid-unattended" }),
        textTurn("understood"),
      ]);
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, sbx.port, { approvalTimeoutMs: 500 }),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: seeded.prompt,
            unattended: true,
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }

      const evts = await readEvents(seeded.sessionId);
      expect(types(evts)).toContain("approval_requested");
      const resolved = evts.find((e) => e.type === "approval_resolved")!;
      expect(resolved.payload).toMatchObject({
        approvalId: expect.any(String),
        decision: "deny",
        reason: "unattended_timeout",
      });
      const completed = evts.find((e) => e.type === "tool_completed")!;
      expect(completed.payload).toMatchObject({ isError: true, content: "DENIED by user" });
      // Denied BEFORE dispatch: the sandbox never saw the command.
      expect(sbx.execs).toEqual([]);
      // spec §8: reported, never crashed — the run finishes normally.
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
    });

    /**
     * P4-T10 carry: the run-scoped approval hook. `onApprovalRequested` must
     * fire BEFORE the timeout clock (the push) and `onApprovalAutoDenied` when
     * that clock fires, so the schedule occurrence's `auto_denied` ledger is
     * populated. Attended runs must invoke neither.
     */
    function recordingUnattendedHook(): {
      hook: NonNullable<FullRunDeps["unattendedApprovalHook"]>;
      calls: string[];
    } {
      const calls: string[] = [];
      return {
        calls,
        hook: {
          async isUnattendedRun() {
            return true;
          },
          async onApprovalRequested(runId, req) {
            calls.push(`requested:${runId}:${req.toolName}`);
          },
          async onApprovalAutoDenied(runId, req) {
            calls.push(`denied:${runId}:${req.toolName}`);
          },
        },
      };
    }

    it("full processor: an unattended timeout invokes the hook's push then auto-denied ledger (P4 carry)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const sse = await startTurnSse([
        toolCallTurn("call_p", "run_shell", { command: "rm -rf /tmp/ovid-p4-seam" }),
        textTurn("understood"),
      ]);
      const { hook, calls } = recordingUnattendedHook();
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, sbx.port, {
          approvalTimeoutMs: 150,
          unattendedApprovalHook: hook,
        }),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: seeded.prompt,
            unattended: true,
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }

      expect(calls).toEqual([
        `requested:${seeded.runId}:run_shell`,
        `denied:${seeded.runId}:run_shell`,
      ]);
      const evts = await readEvents(seeded.sessionId);
      expect(evts.find((e) => e.type === "approval_resolved")!.payload).toMatchObject({
        decision: "deny",
        reason: "unattended_timeout",
      });
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
    });

    it("full processor: an ATTENDED timeout does not invoke the unattended hook (P4 carry)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const sse = await startTurnSse([
        toolCallTurn("call_p", "run_shell", { command: "rm -rf /tmp/ovid-p4-attended" }),
        textTurn("understood"),
      ]);
      const { hook, calls } = recordingUnattendedHook();
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, sbx.port, {
          approvalTimeoutMs: 150,
          unattendedApprovalHook: hook,
        }),
      );
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }

      expect(calls).toEqual([]);
      const evts = await readEvents(seeded.sessionId);
      expect(evts.find((e) => e.type === "approval_resolved")!.payload).toMatchObject({
        decision: "deny",
        reason: "timeout",
      });
    });

    it("full processor: UNATTENDED mode:'safe' (a safe schedule) — write_file denied outright, no approval card", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const sse = await startTurnSse([
        toolCallTurn("call_w", "write_file", { path: "x.txt", content: "x" }),
        textTurn("ok"),
      ]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: seeded.prompt,
            mode: "safe",
            unattended: true,
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }

      const evts = await readEvents(seeded.sessionId);
      const completed = evts.find((e) => e.type === "tool_completed")!;
      expect(completed.payload).toMatchObject({ name: "write_file", isError: true });
      expect(String(completed.payload.content)).toContain("READ-ONLY MODE");
      expect(evts.some((e) => e.type === "approval_requested")).toBe(false);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
    });

    // Wave 1a (CH-001): the Read-Only chip "asks for permission before every
    // shell, browser, or write action" — on the production processor.
    for (const call of [
      { name: "write_file", args: { path: "x.txt", content: "x" } },
      { name: "run_shell", args: { command: "ls" } },
    ]) {
      it(`full processor: attended mode:'safe' asks before ${call.name}; a denial dispatches nothing`, async () => {
        const seeded = await seedRun();
        const sbx = makeFakePort({ exitCode: 0, stdout: "listing\n", stderr: "" });
        const sse = await startTurnSse([toolCallTurn("call_s", call.name, call.args), textTurn("ok")]);
        const processor = createFullAgentRunProcessor(
          makeFullDeps(sse.url, sbx.port, { approvalTimeoutMs: 150 }),
        );
        try {
          await processor({
            data: {
              runId: seeded.runId,
              sessionId: seeded.sessionId,
              userId: seeded.uid,
              prompt: seeded.prompt,
              mode: "safe",
            },
          });
        } finally {
          await processor.close();
          await sse.close();
        }

        const evts = await readEvents(seeded.sessionId);
        const requested = evts.find((e) => e.type === "approval_requested");
        expect(requested?.payload).toMatchObject({ tool: call.name });
        const completed = evts.find((e) => e.type === "tool_completed")!;
        expect(completed.payload).toMatchObject({ name: call.name, isError: true, content: "DENIED by user" });
        expect(sbx.execs).toEqual([]);
        expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      });
    }

    it("full processor: mode:'auto' writes with no approval card", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      const handleSbx = makeFakeSandbox();
      const sse = await startTurnSse([
        toolCallTurn("call_w", "write_file", { path: "x.txt", content: "x" }),
        textTurn("ok"),
      ]);
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, sbx.port, {
          approvalTimeoutMs: 150,
          sandboxHandleFor: async () => handleSbx.handle,
        }),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: seeded.prompt,
            mode: "auto",
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }

      const evts = await readEvents(seeded.sessionId);
      expect(evts.some((e) => e.type === "approval_requested")).toBe(false);
      const completed = evts.find((e) => e.type === "tool_completed")!;
      expect(completed.payload).toMatchObject({ name: "write_file" });
      expect(completed.payload.isError, String(completed.payload.content)).not.toBe(true);
    });

    // Wave 1a (CH-007): the model the user picked is the model the run uses.
    it("full processor: the session's model pin (set by the send body) is the model on the provider wire", async () => {
      const seeded = await seedRun();
      await sessionState.patch(db, seeded.sessionId, { modelPin: "glm-5.3-picked" });
      const sbx = makeFakePort();
      const sse = await startTurnSse([textTurn("hi")]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }
      expect(sse.requests[0]!.model).toBe("glm-5.3-picked");
    });

    // ---- Wave 1a (owner rule R1): session isolation -----------------------

    const wireText = (req: { messages: ChatMessage[] }): string => JSON.stringify(req.messages);
    const toolNames = (req: { tools?: unknown }): string[] =>
      ((req.tools ?? []) as Array<{ function?: { name?: string } }>).map((t) => t.function?.name ?? "");

    it("R1: by default session_search cannot read another session's messages; with Share session memory it can", async () => {
      const marker = `zebracode${Date.now().toString(36)}`;
      const seeded = await seedRun();
      const otherSession = await sessions.create(db, seeded.uid, "Other chat");
      createdSessions.push(otherSession.id);
      await messages.append(db, { sessionId: otherSession.id, role: "user", content: `the secret is ${marker}` });

      const runSearch = async (s: Seeded): Promise<string> => {
        const sbx = makeFakePort();
        const sse = await startTurnSse([
          toolCallTurn("call_q", "session_search", { query: marker }),
          textTurn("ok"),
        ]);
        const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
        try {
          await processor(jobOf(s));
        } finally {
          await processor.close();
          await sse.close();
        }
        const evts = await readEvents(s.sessionId);
        const done = evts.filter((e) => e.type === "tool_completed").pop()!;
        return String(done.payload.content);
      };

      const isolated = await runSearch(seeded);
      expect(isolated).not.toContain(marker);
      expect(isolated).not.toContain(otherSession.id);

      await userPreferences.patch(db, seeded.uid, { shareSessionMemory: true });
      const prompt2 = await messages.append(db, { sessionId: seeded.sessionId, role: "user", content: "again" });
      const run2 = await runs.create(db, { sessionId: seeded.sessionId, promptMessageId: prompt2.id });
      const shared = await runSearch({ ...seeded, runId: run2.id, prompt: "again", promptMessageId: prompt2.id });
      expect(shared).toContain(otherSession.id);
    });

    it("Wave 4 (SE-004): a BYOK default routes every model call to the user's key — Ovid's LiteLLM sees nothing", async () => {
      const seeded = await seedRun();
      const keyId = newId();
      await accountSettings.patch(db, seeded.uid, { byokDefault: { keyId, model: "gpt-4.1-mini" } });
      const seen: Array<string | null | undefined> = [];
      const keys: KeyResolver = {
        async resolveForRun(_uid, ctx) {
          seen.push(ctx.byokKeyId);
          // The escrow cannot decrypt this key → the run must FAIL, never
          // fall back onto Ovid's metered LiteLLM key.
          return ctx.byokKeyId ? null : { kind: "litellm", key: "sk-ovid", baseUrl: "" };
        },
      };
      const sbx = makeFakePort();
      const sse = await startTurnSse([textTurn("ok")]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port, { keys }));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }
      expect(seen.length).toBeGreaterThan(0);
      expect(seen.every((id) => id === keyId)).toBe(true);
      expect(sse.requests).toHaveLength(0);
      const evts = await readEvents(seeded.sessionId);
      expect(evts.some((e) => e.type === "run_failed" && e.payload.code === "key_not_minted")).toBe(true);
    });

    it("Wave 4 (SE-007): a custom preset applied to the session pins its temperature and drops denied tools from the request", async () => {
      const seeded = await seedRun();
      await customPresets.upsert(db, seeded.uid, {
        id: "custom-no-shell",
        label: "No shell",
        description: "",
        deniedTools: ["run_shell", "run_code"],
        model: null,
        temperature: 0.2,
      });
      await sessionState.patch(db, seeded.sessionId, { presetId: "custom-no-shell" });
      const sbx = makeFakePort();
      const sse = await startTurnSse([textTurn("ok")]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }
      const req = sse.requests[0] as unknown as { tools?: Array<{ function: { name: string } }> };
      const names = (req.tools ?? []).map((t) => t.function.name);
      expect(names.length).toBeGreaterThan(0);
      expect(names).not.toContain("run_shell");
      expect(names).not.toContain("run_code");
      expect(names).toContain("web_search");
    });

    it("R1: no sessionRefs → no other session's text reaches the model; sessionRefs → included for that run only", async () => {
      const marker = `okapi${Date.now().toString(36)}`;
      const seeded = await seedRun();
      const otherSession = await sessions.create(db, seeded.uid, "Trip plan");
      createdSessions.push(otherSession.id);
      await messages.append(db, { sessionId: otherSession.id, role: "user", content: `we chose ${marker}` });
      await messages.append(db, { sessionId: otherSession.id, role: "assistant", content: "noted" });

      const runOnce = async (job: { data: AgentRunJob }) => {
        const sbx = makeFakePort();
        const sse = await startTurnSse([textTurn("ok")]);
        const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
        try {
          await processor(job);
        } finally {
          await processor.close();
          await sse.close();
        }
        return sse.requests[0]!;
      };

      const plain = await runOnce(jobOf(seeded));
      expect(wireText(plain)).not.toContain(marker);

      const p2 = await messages.append(db, { sessionId: seeded.sessionId, role: "user", content: "use @[Trip plan]" });
      const r2 = await runs.create(db, { sessionId: seeded.sessionId, promptMessageId: p2.id });
      const tagged = await runOnce({
        data: {
          runId: r2.id,
          sessionId: seeded.sessionId,
          userId: seeded.uid,
          prompt: "use @[Trip plan]",
          sessionRefs: [otherSession.id],
        },
      });
      expect(wireText(tagged)).toContain(marker);
      expect(wireText(tagged)).toContain("Trip plan");

      const p3 = await messages.append(db, { sessionId: seeded.sessionId, role: "user", content: "and now?" });
      const r3 = await runs.create(db, { sessionId: seeded.sessionId, promptMessageId: p3.id });
      const after = await runOnce({
        data: { runId: r3.id, sessionId: seeded.sessionId, userId: seeded.uid, prompt: "and now?" },
      });
      expect(wireText(after)).not.toContain(marker);
    });

    it("R1: a sessionRef to another user's session is ignored by the worker", async () => {
      const marker = `lynx${Date.now().toString(36)}`;
      const seeded = await seedRun();
      const stranger = uid("w1a-stranger");
      await users.ensure(db, stranger, null);
      const foreign = await sessions.create(db, stranger, "Foreign");
      createdSessions.push(foreign.id);
      await messages.append(db, { sessionId: foreign.id, role: "user", content: marker });
      const sbx = makeFakePort();
      const sse = await startTurnSse([textTurn("ok")]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor({ data: { ...jobOf(seeded).data, sessionRefs: [foreign.id] } });
      } finally {
        await processor.close();
        await sse.close();
      }
      expect(wireText(sse.requests[0]!)).not.toContain(marker);
    });

    it("W1: project memory reaches only Main Agent runs in that project", async () => {
      const markerA = `projA${Date.now().toString(36)}`;
      const markerB = `projB${Date.now().toString(36)}`;
      const owner = await seedRun();
      const projectA = (await projectsRepo.create(db, owner.uid, "Alpha"))!;
      const projectB = (await projectsRepo.create(db, owner.uid, "Beta"))!;
      const store = createPrivateMemoryStore(db);
      await store.save(owner.uid, { projectId: projectA.id }, "MEMORY.md", markerA);
      await store.save(owner.uid, { projectId: projectB.id }, "MEMORY.md", markerB);
      await projectsRepo.moveSession(db, owner.uid, owner.sessionId, projectA.id);

      const runJob = async (data: AgentRunJob) => {
        const sbx = makeFakePort();
        const sse = await startTurnSse([textTurn("ok")]);
        const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
        try {
          await processor({ data });
        } finally {
          await processor.close();
          await sse.close();
        }
        return sse.requests[0]!;
      };
      const runNew = async (sessionId: string, userId: string) => {
        const prompt = await messages.append(db, { sessionId, role: "user", content: "hi" });
        const run = await runs.create(db, { sessionId, promptMessageId: prompt.id });
        return runJob({ runId: run.id, sessionId, userId, prompt: "hi" });
      };

      // Project A's session sees A, never B. (This also drains the run row
      // seedRun queued for the same session.)
      const aReq = await runJob(jobOf(owner).data);
      expect(wireText(aReq)).toContain(markerA);
      expect(wireText(aReq)).not.toContain(markerB);

      // A standalone chat of the SAME user sees neither project.
      const standalone = await sessions.create(db, owner.uid, "Standalone");
      createdSessions.push(standalone.id);
      const plainReq = await runNew(standalone.id, owner.uid);
      expect(wireText(plainReq)).not.toContain(markerA);
      expect(wireText(plainReq)).not.toContain(markerB);

      // A chat in project B sees B, never A.
      const bSession = await sessions.create(db, owner.uid, "Beta chat");
      createdSessions.push(bSession.id);
      await projectsRepo.moveSession(db, owner.uid, bSession.id, projectB.id);
      const bReq = await runNew(bSession.id, owner.uid);
      expect(wireText(bReq)).toContain(markerB);
      expect(wireText(bReq)).not.toContain(markerA);
    }, 60_000);

    it("W1 follow-up: @project refs inject only the tagged project's memory for that run", async () => {
      const markerA = `refA${Date.now().toString(36)}`;
      const markerB = `refB${Date.now().toString(36)}`;
      const owner = await seedRun();
      const projectA = (await projectsRepo.create(db, owner.uid, "Tag A"))!;
      const projectB = (await projectsRepo.create(db, owner.uid, "Tag B"))!;
      const emptyProject = (await projectsRepo.create(db, owner.uid, "Empty"))!;
      const stranger = uid("w1b-stranger");
      await users.ensure(db, stranger, null);
      const foreignProject = (await projectsRepo.create(db, stranger, "Foreign"))!;
      const store = createPrivateMemoryStore(db);
      await store.save(owner.uid, { projectId: projectA.id }, "MEMORY.md", markerA);
      await store.save(owner.uid, { projectId: projectB.id }, "MEMORY.md", markerB);

      const runJob = async (data: AgentRunJob) => {
        const sbx = makeFakePort();
        const sse = await startTurnSse([textTurn("ok")]);
        const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
        try {
          await processor({ data });
        } finally {
          await processor.close();
          await sse.close();
        }
        return sse.requests[0]!;
      };
      const runWith = async (projectRefs?: string[]) => {
        const prompt = await messages.append(db, { sessionId: owner.sessionId, role: "user", content: "tagged" });
        const run = await runs.create(db, { sessionId: owner.sessionId, promptMessageId: prompt.id });
        return runJob({
          runId: run.id,
          sessionId: owner.sessionId,
          userId: owner.uid,
          prompt: "tagged",
          ...(projectRefs !== undefined ? { projectRefs } : {}),
        });
      };

      // Drain the run seedRun queued (no refs → neither project).
      const plain = await runJob(jobOf(owner).data);
      expect(wireText(plain)).not.toContain(markerA);
      expect(wireText(plain)).not.toContain(markerB);

      // Only the tagged project's memory reaches the model.
      const taggedA = await runWith([projectA.id]);
      expect(wireText(taggedA)).toContain(markerA);
      expect(wireText(taggedA)).not.toContain(markerB);
      expect(wireText(taggedA)).toContain("Tag A");

      // A project with no memory contributes nothing and does not error.
      const empty = await runWith([emptyProject.id]);
      expect(wireText(empty)).not.toContain(markerA);
      expect(wireText(empty)).not.toContain(markerB);

      // A foreign project id contributes nothing (defence in depth; the
      // gateway already refuses the whole send).
      const foreign = await runWith([foreignProject.id]);
      expect(wireText(foreign)).not.toContain(markerA);
      expect(wireText(foreign)).not.toContain(markerB);

      // Refs do not persist: the next untagged turn sees neither project.
      const after = await runWith();
      expect(wireText(after)).not.toContain(markerA);
      expect(wireText(after)).not.toContain(markerB);
    }, 60_000);

    it("R1: child loops inherit Memory OFF and isolated search, without parent or other chat history injection", async () => {
      const seeded = await seedRun();
      const marker = `childsecret${Date.now().toString(36)}`;
      const parentMarker = `parentsecret${Date.now().toString(36)}`;
      const other = await sessions.create(db, seeded.uid, "Other private chat");
      createdSessions.push(other.id);
      await messages.append(db, { sessionId: other.id, role: "user", content: `childlookup ${marker}` });
      await messages.append(db, { sessionId: seeded.sessionId, role: "assistant", content: parentMarker });
      await userPreferences.patch(db, seeded.uid, { memoryEnabled: false, shareSessionMemory: false });
      const sbx = makeFakePort();
      const sse = await startTurnSse([
        toolCallTurn("call_child", "dispatch_agent", { prompt: "Search only your own task history" }),
        toolCallTurn("call_search", "session_search", { query: "childlookup" }),
        textTurn("child done"),
        textTurn("parent done"),
      ]);
      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }
      expect(sse.requests).toHaveLength(4);
      for (const childRequest of sse.requests.slice(1, 3)) {
        expect(toolNames(childRequest).filter((n) => n.startsWith("memory_"))).toEqual([]);
        expect(wireText(childRequest)).not.toContain(marker);
        expect(wireText(childRequest)).not.toContain(parentMarker);
      }
      const started = (await readEvents(seeded.sessionId)).find((e) => e.type === "subagent_started")!;
      expect(started).toBeDefined();
      const childEvents = await readEvents(String(started.payload.childSessionId));
      const search = childEvents.find((e) => e.type === "tool_completed" && e.payload.name === "session_search")!;
      expect(search).toBeDefined();
      expect(String(search.payload.content)).not.toContain(marker);
      expect(String(search.payload.content)).not.toContain(other.id);
    });

    it("SE-005: Memory OFF removes every memory_* tool from the model's tool list", async () => {
      const seeded = await seedRun();
      const run = async (job: { data: AgentRunJob }) => {
        const sbx = makeFakePort();
        const sse = await startTurnSse([textTurn("ok")]);
        const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
        try {
          await processor(job);
        } finally {
          await processor.close();
          await sse.close();
        }
        return toolNames(sse.requests[0]!);
      };
      const on = await run(jobOf(seeded));
      expect(on.some((n) => n.startsWith("memory_"))).toBe(true);

      await userPreferences.patch(db, seeded.uid, { memoryEnabled: false });
      const p2 = await messages.append(db, { sessionId: seeded.sessionId, role: "user", content: "again" });
      const r2 = await runs.create(db, { sessionId: seeded.sessionId, promptMessageId: p2.id });
      const off = await run({ data: { runId: r2.id, sessionId: seeded.sessionId, userId: seeded.uid, prompt: "again" } });
      expect(off.filter((n) => n.startsWith("memory_"))).toEqual([]);
    });

    it("full processor: provider egress admits the configured loopback LiteLLM origin, while a USER URL to it is still blocked", async () => {
      const seeded = await seedRun();
      const sbx = makeFakePort();
      // The mock's turns are built AFTER listen (they embed its own URL).
      const turns: Array<Array<Record<string, unknown>>> = [];
      const sse = await startTurnSse(turns);
      turns.push(
        // The model asks to fetch the EXACT provider origin. The provider
        // egress allowlists it for model calls; the TOOL egress must not.
        toolCallTurn("call_f", "fetch_url", { url: `${sse.url}/secret` }),
        textTurn("done"),
      );

      const processor = createFullAgentRunProcessor(makeFullDeps(sse.url, sbx.port));
      try {
        await processor(jobOf(seeded));
      } finally {
        await processor.close();
        await sse.close();
      }

      // The model call itself SUCCEEDED through the default provider egress
      // (the C1 regression: it used to throw SsrfBlockedError on loopback).
      expect(sse.requests).toHaveLength(2);
      const completed = (await readEvents(seeded.sessionId)).find(
        (e) => e.type === "tool_completed",
      )!;
      expect(completed.payload).toMatchObject({ name: "fetch_url" });
      expect(String(completed.payload.content)).toContain("fetch failed:");
      expect(String(completed.payload.content)).toMatch(/not allowed|non-public|loopback/);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
    });

    it("full processor: job tier drives the sandbox port and handle (free → free, else pro)", async () => {
      const seeded = await seedRun();
      const sbx = makeFakeSandbox({ execResult: { stdout: "hi\n" } });
      const tierCalls: string[] = [];
      const handleTiers: string[] = [];
      const sse = await startTurnSse([
        toolCallTurn("call_t", "run_shell", { command: "echo hi" }),
        textTurn("done"),
      ]);
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, createSandboxPort(sbx.manager, { tier: "free" }), {
          sandboxForTier: (tier) => {
            tierCalls.push(tier);
            return createSandboxPort(sbx.manager, { tier });
          },
          sandboxHandleFor: async (_uid, tier) => {
            handleTiers.push(tier);
            return sbx.handle;
          },
        }),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: seeded.prompt,
            tier: "free",
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }
      expect(tierCalls).toEqual(["free"]);
      expect(handleTiers).toEqual(["free"]);
      // Every attach on the run's port/handle used the job tier (the port
      // attaches lazily per call — skills discovery, hook source, tools).
      expect(sbx.attachCalls.length).toBeGreaterThan(0);
      expect(sbx.attachCalls.every((c) => c.tier === "free")).toBe(true);
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      rmWs(sbx.workspaceDir);
    });

    // -------------------------------------------------------------------------
    // Vision gate, full path (owner directive 2026-10-18). The compat path's
    // gate (see the model_no_vision tests above) must hold on the PRODUCTION
    // processor too: promptImages ride the engine run out to the provider
    // wire, and a model that cannot see is refused before any bytes move.
    // -------------------------------------------------------------------------

    it("full processor: image attachment + a vision model pin → promptImages reach the engine run as an image_url content part", async () => {
      const seeded = await seedRun();
      // The /model pin selects a documented vision family while the fleet
      // default ("full-default-model") is unknown → text-only. This pins the
      // gate's effective-model resolution: it predicts the model the engine's
      // routeFor will actually route to (the pin), not the fleet default.
      await sessionState.patch(db, seeded.sessionId, { modelPin: "gpt-4o" });
      const handleSbx = makeFakeSandbox();
      const port = makeFakePort();
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "shot.png");

      const downloads: string[] = [];
      const storage = {
        async getBuffer(key: string): Promise<Buffer | null> {
          downloads.push(key);
          return Buffer.from("png-bytes", "utf8");
        },
      };
      const sse = await startTurnSse([textTurn("a photo")]);
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, port.port, {
          storage,
          sandboxHandleFor: async () => handleSbx.handle,
        }),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: "what is in this picture?",
            attachmentIds: [a1.id],
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }

      // Materialized once into uploads/ alongside the prompt copy, and the
      // run completed normally on the pinned model.
      expect(downloads).toEqual([a1.r2Key]);
      expect(
        await readFile(join(handleSbx.workspaceDir, "uploads", "shot.png"), "utf8"),
      ).toBe("png-bytes");
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });

      // promptImages reached the engine's run: the turn went out on the wire
      // as [OI] multimodal content parts — text first, then the data URL —
      // riding exactly the model the gate predicted.
      expect(sse.requests).toHaveLength(1);
      expect(sse.requests[0]!.model).toBe("gpt-4o");
      const msgs = sse.requests[0]!.messages;
      const last = msgs[msgs.length - 1]!;
      expect(last.role).toBe("user");
      const parts = last.content as unknown as Array<Record<string, unknown>>;
      expect(parts[0]).toMatchObject({ type: "text", text: "what is in this picture?" });
      expect(parts[1]).toMatchObject({
        type: "image_url",
        image_url: {
          url: `data:image/png;base64,${Buffer.from("png-bytes", "utf8").toString("base64")}`,
        },
      });
      rmWs(handleSbx.workspaceDir);
    });

    it("full processor: job maxOutputTokens reaches the provider wire as max_tokens; absent → no max_tokens key", async () => {
      // With the cap: the gateway-validated pick (Settings "Max output
      // tokens") rides the job payload → engine run → AgentRequest.maxTokens
      // → the openai transport's request body.
      const seeded = await seedRun();
      const port = makeFakePort();
      const sse = await startTurnSse([textTurn("done")]);
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, port.port),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: seeded.prompt,
            maxOutputTokens: 2048,
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }
      expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      expect(sse.requests).toHaveLength(1);
      expect(sse.requests[0]!.max_tokens).toBe(2048);

      // Without the cap (auto): the key never lands on the wire — the
      // provider's own default applies, byte-for-byte the pre-feature body.
      const seeded2 = await seedRun();
      const port2 = makeFakePort();
      const sse2 = await startTurnSse([textTurn("done")]);
      const processor2 = createFullAgentRunProcessor(
        makeFullDeps(sse2.url, port2.port),
      );
      try {
        await processor2(jobOf(seeded2));
      } finally {
        await processor2.close();
        await sse2.close();
      }
      expect(await runRow(seeded2.runId)).toMatchObject({ status: "completed" });
      expect(sse2.requests).toHaveLength(1);
      expect(sse2.requests[0]!.max_tokens).toBeUndefined();
    });

    it("full processor: image attachment + a text-only model → run_failed{model_no_vision}, no attach, no download, no provider call, push sent", async () => {
      const seeded = await seedRun();
      // No model pin: the fleet default is the effective model, and it is
      // unknown to the catalog and the family list → refused (basis unknown).
      const handleSbx = makeFakeSandbox();
      const port = makeFakePort();
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "shot.png");

      const downloads: string[] = [];
      const storage = {
        async getBuffer(key: string): Promise<Buffer | null> {
          downloads.push(key);
          return Buffer.from("png-bytes", "utf8");
        },
      };
      const handleCalls: string[] = [];
      const pushes: Array<{ code: string; message: string; userId: string }> = [];
      const notifier = {
        async notifyAgentFailed(a: {
          userId: string;
          sessionId: string;
          sessionTitle: string;
          code: string;
          message: string;
        }): Promise<void> {
          pushes.push({ code: a.code, message: a.message, userId: a.userId });
        },
      };
      const sse = await startTurnSse([textTurn("never")]);
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, port.port, {
          storage,
          notifier,
          sandboxHandleFor: async (_uid, tier) => {
            handleCalls.push(tier);
            return handleSbx.handle;
          },
        }),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: "what is in this picture?",
            attachmentIds: [a1.id],
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }

      // The refusal fired BEFORE any bytes moved: no sandbox handle, no
      // storage download, and the engine's run never started (zero provider
      // requests — the SSE mock was never hit).
      expect(handleCalls).toEqual([]);
      expect(downloads).toEqual([]);
      expect(sse.requests).toEqual([]);

      const evts = await readEvents(seeded.sessionId);
      const failure = evts.find((e) => e.type === "run_failed");
      expect(failure?.payload).toMatchObject({
        code: "model_no_vision",
        model: "full-default-model",
        basis: "unknown",
        imageCount: 1,
      });
      expect(String(failure?.payload.message)).toContain("does not support vision/image inputs");
      expect(await runRow(seeded.runId)).toMatchObject({
        status: "failed",
        lastError: "model_no_vision",
      });

      // The push carries the same actionable copy.
      expect(pushes).toHaveLength(1);
      expect(pushes[0]).toMatchObject({ code: "model_no_vision", userId: seeded.uid });
      expect(pushes[0]!.message).toContain("switch to a vision-capable model");
      rmWs(handleSbx.workspaceDir);
    });

    it("full processor: the gate names the ROUTED model — a pinned text-only family is refused by name, not as the fleet default", async () => {
      const seeded = await seedRun();
      // The /model pin selects a documented TEXT-ONLY family
      // (TEXT_ONLY_OVERRIDES in modelCapabilities.ts). The fleet default is
      // likewise text-only, so only the model NAME in the refusal
      // distinguishes "the gate resolved the pin" from "the gate assumed the
      // default" — the audit's latent gap (a).
      await sessionState.patch(db, seeded.sessionId, { modelPin: "deepseek-chat" });
      const handleSbx = makeFakeSandbox();
      const port = makeFakePort();
      const a1 = await seedAttachment(seeded.sessionId, seeded.uid, "shot.png");

      const storage = {
        async getBuffer(): Promise<Buffer | null> {
          return Buffer.from("png-bytes", "utf8");
        },
      };
      const sse = await startTurnSse([textTurn("never")]);
      const processor = createFullAgentRunProcessor(
        makeFullDeps(sse.url, port.port, {
          storage,
          sandboxHandleFor: async () => handleSbx.handle,
        }),
      );
      try {
        await processor({
          data: {
            runId: seeded.runId,
            sessionId: seeded.sessionId,
            userId: seeded.uid,
            prompt: "what is in this picture?",
            attachmentIds: [a1.id],
          },
        });
      } finally {
        await processor.close();
        await sse.close();
      }

      expect(sse.requests).toEqual([]);
      const evts = await readEvents(seeded.sessionId);
      const failure = evts.find((e) => e.type === "run_failed");
      expect(failure?.payload).toMatchObject({
        code: "model_no_vision",
        model: "deepseek-chat",
        basis: "family",
        imageCount: 1,
      });
      expect(await runRow(seeded.runId)).toMatchObject({
        status: "failed",
        lastError: "model_no_vision",
      });
      rmWs(handleSbx.workspaceDir);
    });

    // -------------------------------------------------------------------------
    // Task 11: ensureWarm run hook (workspace hydration before tools run)
    // -------------------------------------------------------------------------

    describe("ensureWarm hook", () => {
      it("ensureWarm resolves → the run proceeds unchanged", async () => {
        const seeded = await seedRun();
        const { transport, calls } = stubTransport([
          { kind: "ok", deltas: ["hydrated ", "run"] },
        ]);
        let callsToEnsureWarm = 0;

        await createAgentRunProcessor(
          makeDeps(transport, {
            ensureWarm: async (sessionId, userId) => {
              callsToEnsureWarm += 1;
              expect(sessionId).toBe(seeded.sessionId);
              expect(userId).toBe(seeded.uid);
            },
          }),
        )(jobOf(seeded));

        expect(callsToEnsureWarm).toBe(1);
        expect(calls).toHaveLength(1);
        const evts = await readEvents(seeded.sessionId);
        expect(types(evts)).toContain("run_completed");
        expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      });

      it("ensureWarm rejects → one run_failed{hydrate_failed}, run failed, transport NEVER called", async () => {
        const seeded = await seedRun();
        const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["never"] }]);

        await createAgentRunProcessor(
          makeDeps(transport, {
            ensureWarm: async () => {
              throw new Error("workspace did not hydrate");
            },
          }),
        )(jobOf(seeded));

        const evts = await readEvents(seeded.sessionId);
        expect(types(evts)).toEqual(["run_failed"]);
        expect(evts[0]!.payload).toMatchObject({
          runId: seeded.runId,
          code: "hydrate_failed",
          message: "workspace did not hydrate",
        });
        expect(await readMirror(seeded.sessionId)).toEqual(evts);
        expect(calls).toHaveLength(0);
        expect(await runRow(seeded.runId)).toMatchObject({
          status: "failed",
          lastError: "hydrate_failed",
        });
      });

      it("ensureWarm undefined → v0 behavior identical (backward-compat pin)", async () => {
        const seeded = await seedRun();
        const { transport, calls } = stubTransport([{ kind: "ok", deltas: ["same as v0"] }]);

        await createAgentRunProcessor(makeDeps(transport))(jobOf(seeded));

        expect(calls).toHaveLength(1);
        const evts = await readEvents(seeded.sessionId);
        expect(types(evts)).toEqual([
          "run_started",
          "message_delta",
          "message_completed",
          "run_completed",
        ]);
        expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      });

      it("activity.bump is called after the claim and after the run finishes", async () => {
        const seeded = await seedRun();
        const { transport } = stubTransport([{ kind: "ok", deltas: ["ok"] }]);
        let bumps = 0;
        const tracker = {
          async bump(): Promise<void> {
            bumps += 1;
          },
          async read(): Promise<number | null> {
            return null;
          },
          async readMany(): Promise<Map<string, number>> {
            return new Map();
          },
        };

        await createAgentRunProcessor(
          makeDeps(transport, { activity: tracker }),
        )(jobOf(seeded));

        expect(bumps).toBe(2);
        expect(await runRow(seeded.runId)).toMatchObject({ status: "completed" });
      });
    });
  },
);
