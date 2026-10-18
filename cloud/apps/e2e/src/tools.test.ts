import { createServer, type Server, type ServerResponse } from "node:http";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "@ovid/db";
import { createRedisEventLog, createRedisSystemBus, type EventLog } from "@ovid/events";
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
  type KeyProvider,
  type KeyResolver,
  type InternalMintProvisioner,
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
import {
  createAgentRunProcessor,
  createOpenAiTransport,
  createToolRegistry,
  SYSTEM_PROMPT_V1,
} from "@ovid/worker";
import {
  REFUSAL_MESSAGE,
  SandboxAdmissionError,
  type ExecRequest,
  type ExecResult,
  type JobRegistry,
  type PtyHandlers,
  type PtyRequest,
  type PtySession,
  type SandboxHandle,
  type SandboxManager,
  type SpawnedProcess,
} from "@ovid/sandbox";

/**
 * P2 Task 14 e2e — the agent TOOL loop, stubbed at the sandbox seam (plan
 * Task 14, Step 1). Same harness shape as the P1 spine (spine.test.ts): the
 * REAL gateway (REST + WS) and the REAL worker (BullMQ consumer + SSE
 * transport + tool registry + run processor) composed in one process over
 * REAL Postgres and REAL Redis, with only the outermost boundaries stubbed:
 *
 * - LiteLLM → a local http server speaking [OI]-dialect SSE, scripted as a
 *   QUEUE OF ROUNDS: each model request consumes the next round (either
 *   `tool_calls` fragments or content deltas). The real transport's
 *   index-merge aggregator reassembles the fragments, so the tool loop sees
 *   exactly the calls the test scripted.
 * - sandbox → FakeSandboxManager: `attach` returns a handle whose
 *   workspaceDir is a REAL mkdtemp (the host-side file tools really write
 *   there) and whose `exec` records every command and returns a canned
 *   {exitCode:0, stdout:"hi\n"} result. Blocked commands never reach it
 *   (layer 1 refuses client-side — pinned by flow b).
 * - mint/keys/auth → the spine's stubs (createTestVerifier, constant key).
 *
 * WIRING NOTE (Task 12 review F6 carry, binding): the worker here is wired
 * through main.ts's EXACT RunDeps composition — `sandbox` AND
 * `tools: createToolRegistry()` both present — so the processor's C1 legacy
 * guard is provably OFF and cannot mask a wiring regression (flow a also
 * pins the system prompt + tools array in the actual model request). main()
 * itself cannot boot in-process for this suite: it hard-boots the REAL
 * sandbox chain (rootfs + cgroups + root) that the stub replaces, and its
 * shutdown path is signal-only. The FULL real chain (config → rootfs →
 * cgroups → quota → launcher → manager → recover → pty bridge → processor)
 * is booted in realjail.test.ts on the sandbox host.
 *
 * Pinned flows (one `it` each):
 *   a. tool run — two tool rounds then text; exact WS event order
 *      run_started, tool_started, tool_completed ×2, message_delta+,
 *      message_completed, run_completed; notes.md really written; GET
 *      messages user + final text; model request carried system prompt +
 *      tools + role:"tool" result rows.
 *   b. blocked command — REFUSAL_MESSAGE verbatim as the tool result,
 *      exactly one system_note{command_blocked}, fake exec NEVER invoked.
 *   c. sandbox unavailable — attach rejects SandboxAdmissionError →
 *      run_failed{sandbox_unavailable} (no run_started — documented M4
 *      ordering), run row failed, job COMPLETES, and a second run with the
 *      working fake proceeds (queue not stuck).
 *   d. file confinement — read_file "../../etc/passwd" → isError tool
 *      result with the pinned "confined:" prefix; workspace untouched.
 *
 * Determinism and cleanup discipline follow spine.test.ts exactly (no
 * FLUSHDB; DEL only this suite's stream keys; obliterate only this suite's
 * pinned queue prefix after the worker is closed).
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** Contract path (hardcoded on purpose — same pin as spine.test.ts). */
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
// Mock LiteLLM: [OI]-dialect SSE scripted as a round queue. Each incoming
// model request consumes the next round; a round is either tool_calls (one
// delta fragment per call, complete — the transport's index-merge aggregator
// passes complete fragments through verbatim) or content deltas.
// ---------------------------------------------------------------------------

interface ToolCallSpec {
  name: string;
  /** Raw JSON arguments string, exactly as the wire would carry them. */
  arguments: string;
  /** Wire id for the call (the processor echoes it in tool_started/tool_completed). */
  id: string;
}

interface Round {
  deltas?: string[];
  toolCalls?: ToolCallSpec[];
  chunkDelayMs?: number;
}

interface SseMock {
  baseUrl: string;
  /** Installs the round queue the NEXT requests consume, in order. */
  arm(rounds: Round[]): void;
  /** Every model request seen: parsed JSON body. */
  requests: Array<{ body: unknown }>;
  close(): Promise<void>;
}

async function startSseMock(): Promise<SseMock> {
  let queue: Round[] = [];
  const requests: SseMock["requests"] = [];

  async function stream(res: ServerResponse, round: Round): Promise<void> {
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
    const writeData = (payload: string): void => {
      res.write(`data: ${payload}\n\n`);
    };
    for (const delta of round.deltas ?? []) {
      if (round.chunkDelayMs) await sleep(round.chunkDelayMs);
      if (res.destroyed || res.writableEnded) return;
      writeData(JSON.stringify({ choices: [{ delta: { content: delta }, finish_reason: null }] }));
    }
    for (const call of round.toolCalls ?? []) {
      writeData(
        JSON.stringify({
          choices: [
            {
              delta: {
                tool_calls: [
                  {
                    index: 0,
                    id: call.id,
                    type: "function",
                    function: { name: call.name, arguments: call.arguments },
                  },
                ],
              },
              finish_reason: null,
            },
          ],
        }),
      );
    }
    writeData(JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] }));
    res.end("data: [DONE]\n\n");
  }

  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      requests.push({ body: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
      // No scripted round left = a wiring bug (the model was called more
      // often than the test pinned). Fail the request LOUDLY as a terminal
      // model error so the run terminalizes instead of hanging.
      const round = queue.shift();
      if (round === undefined) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: "e2e mock: no scripted round left" } }));
        return;
      }
      void stream(res, round);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    arm(rounds) {
      queue = [...rounds];
    },
    requests,
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

// ---------------------------------------------------------------------------
// FakeSandboxManager: the sandbox seam stub. attach() hands out handles over
// REAL mkdtemp workspace dirs (the host-side file tools really read/write
// them); exec() records every command and returns the canned success result.
// ---------------------------------------------------------------------------

const CANNED_EXEC: ExecResult = {
  exitCode: 0,
  stdout: "hi\n",
  stderr: "",
  timedOut: false,
  truncated: false,
  blocked: false,
  refusal: null,
};

interface FakeSandbox {
  manager: SandboxManager;
  /** Every exec the run_shell tool performed, in order. */
  execs: Array<{ command: string; timeoutMs: number | undefined }>;
  /** Every attach (userId + tier label), in order. */
  attachCalls: Array<{ userId: string; tier: string | undefined }>;
  /** Make the NEXT attach reject with this error (consumed once). */
  failNextAttachWith(err: Error): void;
  /** userId → the handle's workspace dir (host side). */
  workspaceByUser: Map<string, string>;
  /** Destroyed userIds, in order. */
  destroyed: string[];
}

function createFakeSandbox(): FakeSandbox {
  const execs: FakeSandbox["execs"] = [];
  const attachCalls: FakeSandbox["attachCalls"] = [];
  const destroyed: string[] = [];
  const workspaceByUser = new Map<string, string>();
  const handles = new Map<string, SandboxHandle>();
  const scratchDirs: string[] = [];
  let nextFail: Error | null = null;
  let uidSeq = 200_500; // inside the sandbox uid block shape; never touches the host

  const manager: SandboxManager = {
    async attach(userId, opts) {
      attachCalls.push({ userId, tier: opts?.tier });
      if (nextFail !== null) {
        const err = nextFail;
        nextFail = null;
        throw err;
      }
      const existing = handles.get(userId);
      if (existing !== undefined) return existing;
      const workspaceDir = await mkdtemp(join(tmpdir(), "ovid-e2e-fake-ws-"));
      scratchDirs.push(workspaceDir);
      workspaceByUser.set(userId, workspaceDir);
      const sandboxUid = (uidSeq += 1);
      const handle: SandboxHandle = {
        userId,
        uid: sandboxUid,
        workspaceDir,
        homeDir: join(workspaceDir, "..", ".home"),
        jailWorkspaceDir: "/workspace",
        exec: async (req: ExecRequest) => {
          execs.push({ command: req.command ?? "", timeoutMs: req.timeoutMs });
          return { ...CANNED_EXEC };
        },
        createPty: async (_req: PtyRequest, _h: PtyHandlers): Promise<PtySession> => {
          throw new Error("fake sandbox: no pty support (realjail.test.ts covers pty)");
        },
        getPty: () => undefined,
        get jobs(): JobRegistry {
          throw new Error("fake sandbox: no job registry");
        },
        spawnProcess: async (_req: {
          argv: string[];
          cwd?: string;
          env?: Record<string, string>;
        }): Promise<SpawnedProcess> => {
          throw new Error("fake sandbox: no spawnProcess");
        },
        destroy: async () => {
          destroyed.push(userId);
          handles.delete(userId);
        },
      };
      handles.set(userId, handle);
      return handle;
    },
    get: (userId) => handles.get(userId),
    destroy: async (userId) => {
      destroyed.push(userId);
      handles.delete(userId);
    },
    list: () => [...handles.values()].map((h) => ({
      userId: h.userId,
      uid: h.uid,
      createdAt: new Date().toISOString(),
    })),
    activeCount: () => handles.size,
    workspaceDir: async (userId) => {
      const ws = workspaceByUser.get(userId);
      if (ws === undefined) throw new Error(`fake sandbox: unknown user ${userId}`);
      return ws;
    },
    recover: async () => {},
    close: async () => {
      handles.clear();
      for (const dir of scratchDirs.splice(0)) {
        await rm(dir, { recursive: true, force: true }).catch(() => {});
      }
    },
  };

  return {
    manager,
    execs,
    attachCalls,
    destroyed,
    workspaceByUser,
    failNextAttachWith: (err) => {
      nextFail = err;
    },
  };
}

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "cloud e2e — agent tool loop (real gateway + real worker, stubbed sandbox)",
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
    let fake: FakeSandbox;

    const clients: Array<TestClient> = [];
    const createdSids: string[] = [];
    const workerFailures: Array<{ jobId: string | undefined; message: string }> = [];
    const workerErrors: string[] = [];
    const sleeps: number[] = [];
    const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
      ? `${process.env.OVID_TEST_QUEUE_PREFIX}-e2e-tools`
      : "ovid-test-e2e-tools";

    // Mint/key stubs per the spine's binding decision: the mock LiteLLM
    // ignores key validity, so a constant "test-key" is enough end to end.
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
      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);

      // OBJECT form mandatory (Task 7 lesson, Task 9 carry-over).
      const connection = { url: TEST_REDIS_URL! };
      queues = createQueues(connection, { prefix: QUEUE_PREFIX });

      sse = await startSseMock();
      fake = createFakeSandbox();
      // main.ts's RunDeps composition (Task 12 wiring), with ONLY the
      // SandboxManager seam stubbed: sandbox + tools BOTH wired → the C1
      // legacy guard is provably off (F6 carry).
      const processor = createAgentRunProcessor({
        db,
        events,
        keys,
        transport: createOpenAiTransport(),
        litellmBaseUrl: sse.baseUrl,
        defaultModel: "e2e-model",
        sandbox: fake.manager,
        tools: createToolRegistry(),
        sleep: async (ms) => {
          sleeps.push(ms);
          await sleep(ms);
        },
      });
      worker = createAgentRunsWorker(connection, processor, { prefix: QUEUE_PREFIX });
      worker.on("failed", (job, err) => {
        workerFailures.push({ jobId: job?.id, message: err.message });
      });
      worker.on("error", (err) => {
        workerErrors.push(err.message);
      });

      // No pty bridge here (GatewayDeps.pty optional): the tool flows never
      // send pty frames; the terminal chain is realjail.test.ts's scope.
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
      wsBase = `ws://127.0.0.1:${port}${WS_PATH}`;
    }, 60_000);

    afterAll(async () => {
      while (clients.length > 0) await clients.pop()!.close().catch(() => {});
      await worker?.close();
      await app?.close();
      if (queues) {
        await queues.agentRuns.obliterate({ force: true }).catch(() => {});
        await queues.agentRuns.close().catch(() => {});
      }
      await sse?.close();
      if (createdSids.length > 0) {
        await redis
          ?.del(createdSids.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }
      // No leaked subscriber connections (same leak check as the spine).
      const ours = new Set(createdSids.map((id) => `sess:${id}:live`));
      await waitForAsync(async () => {
        const channels = (await redis.call("PUBSUB", "CHANNELS", "sess:*")) as string[];
        return channels.every((c) => !ours.has(c));
      }, "suite pubsub channels torn down");
      await fake?.manager.close().catch(() => {});
      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });
    }, 60_000);

    // ---- HTTP + WS helpers (spine.test.ts shape) ---------------------------

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
      close(): Promise<void>;
    }

    async function connectWs(user: string): Promise<TestClient> {
      const ticketRes = await api("POST", "/cloud/v1/auth/ticket", { uid: user });
      if (ticketRes.status !== 200) throw new Error("no ticket minted");
      const ticket = (ticketRes.body as { ticket?: unknown }).ticket;
      if (typeof ticket !== "string" || ticket === "") throw new Error("no ticket minted");
      const socket = new WebSocket(`${wsBase}?ticket=${encodeURIComponent(ticket)}`);
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
      socket.on("error", () => {}); // always keep a sink attached
      const client: TestClient = {
        socket,
        messages,
        send: (msg) => socket.send(JSON.stringify(msg)),
        events: () => messages.flatMap((m) => (m.op === "event" ? [m.event] : [])),
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

    async function openSubscribedClient(
      user: string,
      sessionId: string,
    ): Promise<TestClient> {
      const client = await connectWs(user);
      client.send({ op: "subscribe", sessionId, lastEventId: null });
      await client.waitFor(() => client.messages.length >= 1, "subscribed ack");
      expect(client.messages[0]).toEqual({ op: "subscribed", sessionId });
      return client;
    }

    async function createSession(user: string): Promise<string> {
      const res = await api("POST", "/cloud/v1/sessions", { uid: user, body: {} });
      expect(res.status).toBe(201);
      const session = sessionDtoSchema.parse(res.body);
      createdSids.push(session.id);
      return session.id;
    }

    async function sendMessage(
      user: string,
      sessionId: string,
      content: string,
    ): Promise<SendMessageResponse> {
      const res = await api("POST", `/cloud/v1/sessions/${sessionId}/messages`, {
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

    /**
     * Poll for a TERMINAL row. The processor emits the terminal event BEFORE
     * flipping the row (pinned ordering, runProcessor.ts: "Terminal event
     * BEFORE the status flip"), so a client that reacts to run_completed can
     * legitimately observe the row still `running`. Asserting the row
     * immediately after the event is a race, not a stronger check.
     */
    async function terminalRunRow(
      runId: string,
      timeoutMs = 10_000,
    ): Promise<{ status: string; attempts: number }> {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const row = await runRow(runId);
        if (row.status !== "running") return row;
        if (Date.now() >= deadline) return row;
        await sleep(25);
      }
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

    const typesOf = (evts: SessionEvent[]): string[] => evts.map((e) => e.type);
    const deltaTexts = (evts: SessionEvent[]): string[] =>
      evts.filter((e) => e.type === "message_delta").map((e) => e.payload.text as string);

    // ---- Flow a: tool run ---------------------------------------------------

    it("flow a — two tool rounds then text: exact event order run_started, tool_started, tool_completed ×2, message_delta+, message_completed, run_completed; notes.md written in the fake workspace; model request carried system prompt + tools + role:tool results", async () => {
      const user = uid("e2e-ta");
      sse.arm([
        {
          toolCalls: [
            {
              id: "call-runshell",
              name: "run_shell",
              arguments: JSON.stringify({ command: "echo hi > out.txt" }),
            },
          ],
        },
        {
          toolCalls: [
            {
              id: "call-writefile",
              name: "write_file",
              arguments: JSON.stringify({ path: "notes.md", content: "# x" }),
            },
          ],
        },
        { deltas: ["do", "ne"] },
      ]);

      const sessionId = await createSession(user);
      const client = await openSubscribedClient(user, sessionId);
      const sent = await sendMessage(user, sessionId, "use your tools");

      await client.waitFor(
        () => client.events().some((e) => e.type === "run_completed"),
        "run_completed on WS",
        25_000,
      );
      await sleep(200); // settle window: any (wrongly) duplicated frame lands here

      const evts = client.events();
      expect(typesOf(evts)).toEqual([
        "run_started",
        "tool_started",
        "tool_completed",
        "tool_started",
        "tool_completed",
        "message_delta",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(evts.every((e) => e.sessionId === sessionId)).toBe(true);
      expect(evts[0]!.payload).toEqual({ runId: sent.runId });

      // run_shell round: started before completed, exact input and result.
      expect(evts[1]!.payload).toEqual({
        runId: sent.runId,
        callId: "call-runshell",
        name: "run_shell",
        input: { command: "echo hi > out.txt" },
      });
      expect(evts[2]!.payload).toEqual({
        runId: sent.runId,
        callId: "call-runshell",
        name: "run_shell",
        isError: false,
        content: "hi\n\n[exit 0]",
        truncated: false,
      });
      // write_file round: the host-side tool really wrote into the handle's
      // mkdtemp workspace.
      expect(evts[3]!.payload).toEqual({
        runId: sent.runId,
        callId: "call-writefile",
        name: "write_file",
        input: { path: "notes.md", content: "# x" },
      });
      expect(evts[4]!.payload).toEqual({
        runId: sent.runId,
        callId: "call-writefile",
        name: "write_file",
        isError: false,
        content: "wrote 3 bytes",
        truncated: false,
      });

      // Final text round.
      expect(deltaTexts(evts)).toEqual(["do", "ne"]);
      expect(evts[5]!.payload).toEqual({ runId: sent.runId, text: "do" });
      expect(evts[7]!.payload).toEqual({ messageId: expect.any(String), content: "done" });
      expect(evts[8]!.payload).toEqual({ runId: sent.runId });

      // The fake sandbox really served the round: one recorded exec with the
      // exact command; the workspace really holds notes.md.
      expect(fake.execs).toEqual([{ command: "echo hi > out.txt", timeoutMs: 120_000 }]);
      const wsDir = fake.workspaceByUser.get(user);
      expect(wsDir).toBeDefined();
      expect(await readFile(join(wsDir!, "notes.md"), "utf8")).toBe("# x");

      // REST history: user prompt + the final assistant text only (tool
      // rounds never persist assistant rows).
      const pageRes = await api("GET", `/cloud/v1/sessions/${sessionId}/messages`, {
        uid: user,
      });
      expect(pageRes.status).toBe(200);
      const page = pageSchema(messageDtoSchema).parse(pageRes.body);
      const chronological = [...page.items].reverse();
      expect(chronological.map((m) => m.role)).toEqual(["user", "assistant"]);
      expect(chronological[0]!.content).toBe("use your tools");
      expect(chronological[1]!.content).toBe("done");

      // attempts counts MODEL CALLS (bumpAttempt per attempt), and the tool
      // loop makes one call per round: 3 rounds here.
      expect(await terminalRunRow(sent.runId)).toEqual({ status: "completed", attempts: 3 });

      // The LAST model request (round 3) proves the wired v1 loop end to end:
      // pinned system prompt first, the six-roster tools param, and both tool
      // results as role:"tool" rows between the assistant tool_calls turns.
      // If the C1 legacy guard ever masked a wiring regression, the system
      // row and the tools param would be absent (Task 12 review F6 carry).
      const body = sse.requests.at(-1)!.body as {
        model: string;
        stream: boolean;
        tools: Array<{ function: { name: string } }>;
        messages: Array<{ role: string; tool_call_id?: string }>;
      };
      expect(body.model).toBe("e2e-model");
      expect(body.stream).toBe(true);
      expect(body.tools.map((t) => t.function.name)).toEqual([
        "edit_file",
        "glob_files",
        "grep_files",
        "read_file",
        "run_shell",
        "write_file",
      ]);
      expect(body.messages[0]).toEqual({ role: "system", content: SYSTEM_PROMPT_V1 });
      expect(body.messages.map((m) => m.role)).toEqual([
        "system",
        "user",
        "assistant",
        "tool",
        "assistant",
        "tool",
      ]);
      const toolRows = body.messages.filter((m) => m.role === "tool");
      expect(toolRows.map((m) => m.tool_call_id)).toEqual([
        "call-runshell",
        "call-writefile",
      ]);

      expect(workerFailures).toEqual([]);
      expect(workerErrors).toEqual([]);
      expect(sleeps).toEqual([]); // happy path: no backoff, no C1 wait
      await client.close();
    });

    // ---- Flow b: blocked command (layer 1) ----------------------------------

    it("flow b — ./gradlew assembleDebug: tool_completed.content === REFUSAL_MESSAGE verbatim, isError, exactly one system_note{command_blocked}, fake exec never invoked; the run still finishes", async () => {
      const user = uid("e2e-tb");
      const execsBefore = fake.execs.length;
      sse.arm([
        {
          toolCalls: [
            {
              id: "call-blocked",
              name: "run_shell",
              arguments: JSON.stringify({ command: "./gradlew assembleDebug" }),
            },
          ],
        },
        { deltas: ["ok"] },
      ]);

      const sessionId = await createSession(user);
      const client = await openSubscribedClient(user, sessionId);
      const sent = await sendMessage(user, sessionId, "build it");

      await client.waitFor(
        () => client.events().some((e) => e.type === "run_completed"),
        "run_completed on WS",
        25_000,
      );
      await sleep(200);

      const evts = client.events();
      expect(typesOf(evts)).toEqual([
        "run_started",
        "tool_started",
        "system_note",
        "tool_completed",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      // The pinned refusal: exactly one system_note, verbatim copy, and the
      // tool result carries the same copy as an error.
      const notes = evts.filter((e) => e.type === "system_note");
      expect(notes).toHaveLength(1);
      expect(notes[0]!.payload).toEqual({
        code: "command_blocked",
        message: REFUSAL_MESSAGE,
        command: "./gradlew assembleDebug",
      });
      const completed = evts.find((e) => e.type === "tool_completed")!;
      expect(completed.payload).toEqual({
        runId: sent.runId,
        callId: "call-blocked",
        name: "run_shell",
        isError: true,
        content: REFUSAL_MESSAGE,
        truncated: false,
      });

      // Layer 1 refused client-side: ZERO side effects — the fake sandbox's
      // exec was never invoked (no jail spawn in production either).
      expect(fake.execs.length).toBe(execsBefore);

      // The refusal is a tool RESULT: the model saw it, answered, and the
      // run completed normally (2 model calls: the tool round + the text).
      expect(await terminalRunRow(sent.runId)).toEqual({ status: "completed", attempts: 2 });
      expect(workerFailures).toEqual([]);
      expect(workerErrors).toEqual([]);
      await client.close();
    });

    // ---- Flow c: sandbox unavailable (queue not stuck) ----------------------

    it("flow c — attach rejects SandboxAdmissionError → run_failed{sandbox_unavailable} (no run_started), run row failed, job completes, and a second run with the working fake proceeds", async () => {
      const user = uid("e2e-tc");
      const admissionMessage =
        "sandbox admission timed out after 60000 ms (24 sandboxes active)";
      fake.failNextAttachWith(new SandboxAdmissionError(admissionMessage));

      const sessionId = await createSession(user);
      const client = await openSubscribedClient(user, sessionId);
      const sent1 = await sendMessage(user, sessionId, "first run hits a full sandbox gate");

      await client.waitFor(
        () => client.events().some((e) => e.type === "run_failed"),
        "run_failed on WS",
        25_000,
      );
      await sleep(200);

      // Documented ordering (Task 12 review M4): the attach happens BEFORE
      // run_started is emitted, so the failure is a BARE run_failed.
      const evts1 = client.events();
      expect(typesOf(evts1)).toEqual(["run_failed"]);
      expect(evts1[0]!.payload).toEqual({
        code: "sandbox_unavailable",
        message: admissionMessage,
      });
      // The model was never called: no deltas, no completion, and the run row
      // is terminal-failed with zero model attempts.
      expect(await terminalRunRow(sent1.runId)).toEqual({ status: "failed", attempts: 0 });

      // Queue not stuck: the job COMPLETED (no BullMQ failure) and a second
      // run through the now-working fake proceeds end to end.
      expect(workerFailures).toEqual([]);
      const eventsBeforeRun2 = client.events().length;
      sse.arm([{ deltas: ["recovered"] }]);
      const sent2 = await sendMessage(user, sessionId, "second run works");
      await client.waitFor(
        () =>
          client
            .events()
            .some((e) => e.type === "run_completed" && e.payload.runId === sent2.runId),
        "second run completed",
        25_000,
      );
      expect(await terminalRunRow(sent2.runId)).toEqual({ status: "completed", attempts: 1 });
      // message_completed carries no runId — slice by position, not filter.
      const evts2 = client.events().slice(eventsBeforeRun2);
      expect(typesOf(evts2)).toEqual([
        "run_started",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      expect(workerFailures).toEqual([]);
      expect(workerErrors).toEqual([]);
      await client.close();
    });

    // ---- Flow d: file confinement (host-side file tools) ---------------------

    it("flow d — read_file ../../etc/passwd: isError tool result with the pinned confined: prefix; workspace untouched; exec never invoked", async () => {
      const user = uid("e2e-td");
      const execsBefore = fake.execs.length;
      sse.arm([
        {
          toolCalls: [
            {
              id: "call-escape",
              name: "read_file",
              arguments: JSON.stringify({ path: "../../etc/passwd" }),
            },
          ],
        },
        { deltas: ["done"] },
      ]);

      const sessionId = await createSession(user);
      const client = await openSubscribedClient(user, sessionId);
      const sent = await sendMessage(user, sessionId, "read outside");

      await client.waitFor(
        () => client.events().some((e) => e.type === "run_completed"),
        "run_completed on WS",
        25_000,
      );
      await sleep(200);

      const evts = client.events();
      expect(typesOf(evts)).toEqual([
        "run_started",
        "tool_started",
        "tool_completed",
        "message_delta",
        "message_completed",
        "run_completed",
      ]);
      const completed = evts.find((e) => e.type === "tool_completed")!;
      // The pinned prefix (Task 12): "confined: <path> is outside the workspace".
      expect(completed.payload.isError).toBe(true);
      expect(completed.payload.content).toBe(
        "confined: ../../etc/passwd is outside the workspace",
      );

      // The escape never touched the filesystem: the workspace is empty and
      // no jail exec happened (read_file is host-side only).
      const wsDir = fake.workspaceByUser.get(user);
      expect(wsDir).toBeDefined();
      expect(await readdir(wsDir!)).toEqual([]);
      expect(fake.execs.length).toBe(execsBefore);

      // The refusal is a tool result: the model recovered and finished
      // (2 model calls: the tool round + the text).
      expect(await terminalRunRow(sent.runId)).toEqual({ status: "completed", attempts: 2 });
      expect(workerFailures).toEqual([]);
      expect(workerErrors).toEqual([]);
      await client.close();
    });
  },
);
