import { createServer, type Server, type ServerResponse } from "node:http";
import * as fsp from "node:fs/promises";
import {
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { Redis } from "ioredis";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, users, type Db } from "@ovid/db";
import { createRedisEventLog, createRedisSystemBus, type EventLog } from "@ovid/events";
import {
  createAgentRunsWorker,
  createQueues,
  type QueueServices,
} from "@ovid/queue";
import {
  messageDtoSchema,
  pageSchema,
  ptyRegistryKey,
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
  createRedisPtyBridge,
  createTestVerifier,
  createTicketStore,
  type TicketStore,
} from "@ovid/gateway";
import {
  createAgentRunProcessor,
  createOpenAiTransport,
  createToolRegistry,
  startWorkerPtyBridge,
} from "@ovid/worker";
import {
  createCgroupManager,
  createNoopQuotaBackend,
  createSetuidLauncher,
  createSandboxManager,
  hostTestsAvailable,
  jailMechanismAvailable,
  loadSandboxConfig,
  REFUSAL_MESSAGE,
  resolveRootfs,
  type SandboxManager,
  type SandboxConfig,
} from "@ovid/sandbox";

/**
 * P2 Task 14 e2e — REAL-JAIL acceptance (plan Task 14, Step 2): the full
 * stack against REAL bwrap jails, REAL cgroups and the REAL rootfs, host-gated
 * (OVID_SANDBOX_HOST_TESTS=1 + root + a working bwrap mechanism + OVID_ROOTFS
 * pointing at an extracted rootfs — on the sandbox host, that must be a CURRENT
 * (r2) extract, not the stale /tmp/ovid-rootfs-test r1 one; DEPLOY.md §11).
 *
 * WIRING (Task 12 review F6 carry, binding): main() itself cannot boot
 * in-process — its shutdown path is signal-only and its connections live in a
 * closure — so this suite boots main.ts's EXACT dependency chain, in the
 * pinned Task-12 composition order, as its own in-process composition:
 *
 *   loadSandboxConfig → resolveRootfs (loud-fail) → createCgroupManager →
 *   cgroups.init() (leaf-first) → quota → launch-strategy switch →
 *   createSandboxManager({config, allocateUid: users.allocateSandboxUid(db,…),
 *   …}) → manager.recover() → startWorkerPtyBridge → createAgentRunProcessor(
 *   {…, sandbox: manager, tools: createToolRegistry()}) → createAgentRunsWorker
 *
 * …and the gateway through buildGateway with the gateway main()'s pty wiring
 * (pty: createRedisPtyBridge(redisQ) over the SAME redis the worker bridge
 * PSUBSCRIBEs). The ONLY stubs are the outermost boundaries, exactly as in
 * tools.test.ts: the SSE mock LiteLLM (scripted rounds) and the mint/key/auth
 * stubs. C1's legacy guard is therefore provably off here too — sandbox and
 * tools are both wired through the real chain.
 *
 * Scope guard (plan Global Constraints): throwaway `ovid-probe-e2e-{pid}`
 * cgroup base under /sys/fs/cgroup, mkdtemp workspaces root, noop-safe quota;
 * full cleanup in afterAll with an explicit no-leftovers assertion. The
 * process moves itself back out of the probe base right after init() so the
 * vitest tree never lives in the throwaway cgroup (manager.host.test.ts
 * pattern).
 *
 * Cross-suite redis lock (Task 13 C3 carry): this suite's worker bridge
 * PSUBSCRIBEs pty:ctl:* on the SHARED test redis, so it takes the same
 * `pty:test:suite-lock` as the worker ptyBridge and gateway wsPty suites —
 * renewed via PEXPIRE heartbeat (their TTL is never renewed; a real-jail run
 * comfortably outlives 10 s, which is why the renewal exists here).
 *
 * Flows (one `it` each):
 *   a. echo + file write through the real jail (spec §14 "working software"):
 *      run_shell writes /workspace/out.txt (host file owned by the SANDBOX
 *      uid) + write_file agent.txt + final text; events in the pinned order.
 *   b. WS terminal full chain: pty_open → input/echo → resize → stty size →
 *      DISCONNECT → reconnect + pty_attach(null) → snapshot repaint →
 *      pty_close → pty_exit (Review Focus #3 at integration level).
 *   c. blocked in the real jail: layer 1 (run_shell "bash -c 'gradle build'"
 *      → REFUSAL_MESSAGE tool result) AND layer 2 (pty "gradle" → the rootfs
 *      PATH shim's refusal copy in the terminal output).
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const ROOTFS = process.env.OVID_ROOTFS;

const WS_PATH = "/cloud/ws";
const CG_ROOT = "/sys/fs/cgroup";
/** Throwaway probe base — same naming discipline as the sandbox host suites. */
const BASE = `ovid-probe-e2e-${process.pid}`;

/** Module-level config ONLY for the skipIf gate (bwrap probe + rootfs set). */
const gateCfg: SandboxConfig = {
  ...loadSandboxConfig({}),
  rootfsPath: ROOTFS ?? "/tmp/ovid-rootfs-test",
  cgroupRoot: CG_ROOT,
  cgroupBase: BASE,
  launch: "setuid",
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond: () => boolean, what: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
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
// cgroup host helpers (manager.host.test.ts pattern)
// ---------------------------------------------------------------------------

function readProcSelfCgroup(): string {
  const line = readFileSync("/proc/self/cgroup", "utf8")
    .trim()
    .split("\n")
    .find((l) => l.startsWith("0::"));
  if (!line) throw new Error("not a cgroups v2 host: no 0:: line in /proc/self/cgroup");
  return line.slice(3);
}
const ORIGINAL_CGROUP = readProcSelfCgroup();

function moveSelfTo(cgroupPath: string): void {
  writeFileSync(join(CG_ROOT, cgroupPath, "cgroup.procs"), String(process.pid));
}

/** Depth-first kill+remove of a probe cgroup subtree (cgroupfs: rmdir only). */
async function removeCgroupTree(path: string): Promise<void> {
  await fsp.writeFile(join(path, "cgroup.kill"), "1").catch(() => {}); // already-gone leaves
  let entries;
  try {
    entries = await fsp.readdir(path, { withFileTypes: true });
  } catch {
    return; // already gone
  }
  for (const e of entries) {
    if (e.isDirectory()) await removeCgroupTree(join(path, e.name));
  }
  await fsp.rmdir(path).catch(() => {});
}

// ---------------------------------------------------------------------------
// Mock LiteLLM: identical round-queue contract as tools.test.ts (self-contained
// suites are this package's convention — spine.test.ts duplicates its harness
// the same way).
// ---------------------------------------------------------------------------

interface ToolCallSpec {
  name: string;
  arguments: string;
  id: string;
}

interface Round {
  deltas?: string[];
  toolCalls?: ToolCallSpec[];
}

interface SseMock {
  baseUrl: string;
  arm(rounds: Round[]): void;
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
// Cross-suite pty lock (Task 13 C3 carry) — TTL renewed by a heartbeat so a
// real-jail run (slow jail spawns) cannot silently outlive the 10 s TTL.
// ---------------------------------------------------------------------------

const SUITE_LOCK_KEY = "pty:test:suite-lock";
const SUITE_LOCK_TTL_MS = 10_000;

async function acquireSuiteLock(redis: Redis): Promise<() => Promise<void>> {
  const token = randomUUID();
  const deadline = Date.now() + 8_000;
  for (;;) {
    const ok = await redis.set(SUITE_LOCK_KEY, token, "PX", SUITE_LOCK_TTL_MS, "NX");
    if (ok === "OK") break;
    if (Date.now() > deadline) throw new Error("pty suite lock not free within 8s");
    await sleep(50);
  }
  const heartbeat = setInterval(() => {
    void redis.pexpire(SUITE_LOCK_KEY, SUITE_LOCK_TTL_MS).catch(() => {});
  }, 3_000);
  heartbeat.unref?.();
  let released = false;
  return async () => {
    if (released) return;
    released = true;
    clearInterval(heartbeat);
    await redis
      .eval(
        "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
        1,
        SUITE_LOCK_KEY,
        token,
      )
      .catch(() => {});
  };
}

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

describe.skipIf(
  !TEST_DATABASE_URL ||
    !TEST_REDIS_URL ||
    !hostTestsAvailable() ||
    !jailMechanismAvailable(gateCfg) ||
    !ROOTFS,
)(
  "cloud e2e — real jail (real sandbox chain + real gateway/worker, host-gated)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let tickets: TicketStore;
    let queues: QueueServices;
    let worker: ReturnType<typeof createAgentRunsWorker>;
    let sse: SseMock;
    let app: ReturnType<typeof buildGateway>;
    let baseUrl: string;
    let wsBase: string;
    let manager: SandboxManager;
    let wsRoot: string;
    let stopPtyBridge: () => Promise<void>;
    let releaseSuiteLock: () => Promise<void>;

    const clients: Array<TestClient> = [];
    const createdSids: string[] = [];
    const openedPtyIds: string[] = [];
    const workerFailures: Array<{ jobId: string | undefined; message: string }> = [];
    const workerErrors: string[] = [];
    const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
      ? `${process.env.OVID_TEST_QUEUE_PREFIX}-e2e-rj`
      : "ovid-test-e2e-rj";

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

      // The worker bridge PSUBSCRIBEs pty:ctl:* on the shared test redis —
      // the cross-suite lock must be held BEFORE it starts (C3 carry).
      releaseSuiteLock = await acquireSuiteLock(redis);

      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);
      const connection = { url: TEST_REDIS_URL! };
      queues = createQueues(connection, { prefix: QUEUE_PREFIX });
      sse = await startSseMock();

      // ---- main.ts's EXACT Task-12 composition order (F6 carry) -----------
      // Every step is the real thing: throwaway probe cgroup base, mkdtemp
      // workspaces root, noop-safe quota (this tree is not an XFS prjquota
      // volume — same as the manager host suite), real setuid launcher +
      // real rootfs, and the REAL uid allocator over the real users table.
      wsRoot = mkdtempSync(join(tmpdir(), "ovid-e2e-rj-ws-"));
      const sandboxConfig: SandboxConfig = {
        ...gateCfg,
        workspacesRoot: wsRoot,
      };
      const rootfs = await resolveRootfs(sandboxConfig.rootfsPath);
      const cgroups = createCgroupManager(sandboxConfig);
      await cgroups.init(); // leaf-first bootstrap (no-internal-process rule)
      // init() parked this process in the probe base's worker leaf; move it
      // back out so the vitest tree does not live in the throwaway cgroup.
      moveSelfTo(ORIGINAL_CGROUP);
      const quota = createNoopQuotaBackend();
      const launcher = createSetuidLauncher(sandboxConfig);
      manager = createSandboxManager({
        config: sandboxConfig,
        allocateUid: (userId) => users.allocateSandboxUid(db, userId),
        cgroups,
        quota,
        launcher,
        rootfs,
      });
      await manager.recover();

      // P2 Task 13 wiring: the pty bridge starts AFTER recovery (same order
      // as main.ts) and stops BEFORE manager.close() in afterAll.
      stopPtyBridge = await startWorkerPtyBridge({ sandbox: manager, redis });

      const processor = createAgentRunProcessor({
        db,
        events,
        keys,
        transport: createOpenAiTransport(),
        litellmBaseUrl: sse.baseUrl,
        defaultModel: "e2e-model",
        sandbox: manager,
        tools: createToolRegistry(),
      });
      worker = createAgentRunsWorker(connection, processor, { prefix: QUEUE_PREFIX });
      worker.on("failed", (job, err) => {
        workerFailures.push({ jobId: job?.id, message: err.message });
      });
      worker.on("error", (err) => {
        workerErrors.push(err.message);
      });

      // Gateway main()'s pty wiring: the Redis pty bridge over the SAME redis
      // the worker bridge PSUBSCRIBEs.
      app = buildGateway({
        system: createRedisSystemBus(redis),
        db,
        queues,
        verifier: createTestVerifier(),
        tickets,
        keys,
        mint,
        events,
        pty: createRedisPtyBridge(redis),
      });
      await app.listen({ host: "127.0.0.1", port: 0 });
      const port = (app.server.address() as AddressInfo).port;
      baseUrl = `http://127.0.0.1:${port}`;
      wsBase = `ws://127.0.0.1:${port}${WS_PATH}`;
    }, 120_000);

    afterAll(async () => {
      // main.ts's shutdown order (Task 12/13 pins): clients → pty bridge →
      // manager (kills every live pty leaf; each onExit publishes exit +
      // HDELs its registry key) → worker drain → gateway → queues → mock.
      while (clients.length > 0) {
        const c = clients.pop()!;
        try {
          c.terminate();
        } catch {
          /* already dead */
        }
      }
      await stopPtyBridge?.().catch(() => {});
      await manager?.close().catch(() => {});
      await worker?.close();
      await app?.close();
      if (queues) {
        await queues.agentRuns.obliterate({ force: true }).catch(() => {});
        await queues.agentRuns.close().catch(() => {});
      }
      await sse?.close();

      // Probe cgroups: nothing named ovid-probe-* may remain (explicit
      // no-leftovers assertion, manager.host.test.ts discipline).
      const problems: string[] = [];
      try {
        moveSelfTo(ORIGINAL_CGROUP);
      } catch (e) {
        problems.push(`restore placement: ${String(e)}`);
      }
      try {
        await removeCgroupTree(join(CG_ROOT, BASE));
      } catch (e) {
        problems.push(`cleanup ${BASE}: ${String(e)}`);
      }
      for (const entry of readdirSync(CG_ROOT)) {
        if (!entry.startsWith("ovid-probe-")) continue;
        try {
          await removeCgroupTree(join(CG_ROOT, entry));
        } catch (e) {
          problems.push(`sweep ${entry}: ${String(e)}`);
        }
      }
      const leftovers = readdirSync(CG_ROOT).filter((e) => e.startsWith("ovid-probe-"));
      if (leftovers.length > 0) problems.push(`leftover probe cgroups: ${leftovers.join(", ")}`);

      if (wsRoot !== undefined) {
        try {
          rmSync(wsRoot, { recursive: true, force: true });
        } catch (e) {
          problems.push(`rm workspaces: ${String(e)}`);
        }
      }
      if (createdSids.length > 0) {
        await redis
          ?.del(createdSids.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }
      for (const ptyId of openedPtyIds) {
        await redis?.del(ptyRegistryKey(ptyId)).catch(() => {});
      }
      // Release the cross-suite lock BEFORE quitting the connection so a
      // waiting suite can start immediately.
      await releaseSuiteLock?.();
      if (problems.length > 0) throw new Error(`realjail cleanup failed:\n- ${problems.join("\n- ")}`);
      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });
    }, 120_000);

    // ---- HTTP + WS helpers ---------------------------------------------------

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
      messages: WsServerMsg[];
      send(msg: unknown): void;
      events(): SessionEvent[];
      waitFor(cond: () => boolean, what: string, timeoutMs?: number): Promise<void>;
      terminate(): void;
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

    async function openSubscribedClient(user: string, sessionId: string): Promise<TestClient> {
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

    const typesOf = (evts: SessionEvent[]): string[] => evts.map((e) => e.type);

    /** First frame of `op` (thrown if absent) — narrows the WsServerMsg union. */
    function frameOf<T extends WsServerMsg["op"]>(c: TestClient, op: T): Extract<WsServerMsg, { op: T }> {
      const m = c.messages.find((x): x is Extract<WsServerMsg, { op: T }> => x.op === op);
      if (m === undefined) throw new Error(`expected a ${op} frame, saw none`);
      return m;
    }

    /** Reassembled pty output for `ptyId` (arrival order — snapshot then live). */
    const ptyText = (c: TestClient, ptyId: string): string =>
      c.messages
        .filter((m) => m.op === "pty_output" && m.ptyId === ptyId)
        .map((m) => Buffer.from((m as { data: string }).data, "base64").toString("utf8"))
        .join("");

    const waitForPtyText = (
      c: TestClient,
      ptyId: string,
      substr: string,
      what: string,
      timeoutMs = 60_000,
    ): Promise<void> =>
      waitFor(() => ptyText(c, ptyId).includes(substr), `${what} (looking for "${substr}")`, timeoutMs);

    const b64 = (s: string): string => Buffer.from(s, "utf8").toString("base64");

    // ---- Flow a: echo + file write through the real jail --------------------

    it(
      "flow a — run_shell writes /workspace/out.txt (host file owned by the sandbox uid) and write_file writes agent.txt; events in the pinned order; run completes",
      async () => {
        const user = uid("e2e-rj-a");
        sse.arm([
          {
            toolCalls: [
              {
                id: "call-echo",
                name: "run_shell",
                arguments: JSON.stringify({
                  command: "echo hello > /workspace/out.txt && cat /workspace/out.txt",
                }),
              },
            ],
          },
          {
            toolCalls: [
              {
                id: "call-agentfile",
                name: "write_file",
                arguments: JSON.stringify({ path: "agent.txt", content: "written-by-agent" }),
              },
            ],
          },
          { deltas: ["done"] },
        ]);

        const sessionId = await createSession(user);
        const client = await openSubscribedClient(user, sessionId);
        const sent = await sendMessage(user, sessionId, "write things");

        await client.waitFor(
          () => client.events().some((e) => e.type === "run_completed"),
          "run_completed on WS",
          90_000,
        );
        await sleep(200);

        const evts = client.events();
        expect(typesOf(evts)).toEqual([
          "run_started",
          "tool_started",
          "tool_completed",
          "tool_started",
          "tool_completed",
          "message_delta",
          "message_completed",
          "run_completed",
        ]);
        // The jailed echo really ran: its stdout came back through the tool
        // result (the REAL jail's exec, not a canned one).
        const shellResult = evts.find(
          (e) => e.type === "tool_completed" && e.payload.name === "run_shell",
        )!;
        expect(shellResult.payload.isError).toBe(false);
        expect(shellResult.payload.content as string).toContain("hello");
        expect(shellResult.payload.content as string).toContain("[exit 0]");

        // Host-side proof: {workspacesRoot}/{uid}/workspace/out.txt exists,
        // owned BY THE SANDBOX UID (the jail wrote it as that uid), and the
        // host-side write_file wrote agent.txt next to it.
        const handle = manager.get(user);
        expect(handle).toBeDefined();
        const outPath = join(wsRoot, String(handle!.uid), "workspace", "out.txt");
        const st = statSync(outPath);
        expect(st.isFile()).toBe(true);
        expect(st.uid).toBe(handle!.uid);
        expect(readFileSync(outPath, "utf8")).toBe("hello\n");
        expect(
          readFileSync(join(wsRoot, String(handle!.uid), "workspace", "agent.txt"), "utf8"),
        ).toBe("written-by-agent");

        expect(await runRow(sent.runId)).toEqual({ status: "completed", attempts: 1 });

        // REST history: user prompt + the final assistant text.
        const pageRes = await api("GET", `/cloud/v1/sessions/${sessionId}/messages`, {
          uid: user,
        });
        const page = pageSchema(messageDtoSchema).parse(pageRes.body);
        const chronological = [...page.items].reverse();
        expect(chronological.map((m) => m.content)).toEqual([
          "write things",
          "done",
        ]);

        expect(workerFailures).toEqual([]);
        expect(workerErrors).toEqual([]);
        await client.close();
      },
      150_000,
    );

    // ---- Flow b: WS terminal full chain (disconnect/reconnect/repaint) -------

    it(
      "flow b — pty_open → echo → resize → stty size → disconnect → reconnect + pty_attach(null) repaints the snapshot → pty_close → pty_exit",
      async () => {
        const user = uid("e2e-rj-b");
        const sessionId = await createSession(user); // ensures the users row (pty open attaches the sandbox)
        const token = `ptytest-${randomUUID().slice(0, 8)}`;

        const client = await connectWs(user);
        client.send({ op: "pty_open", sessionId, cols: 100, rows: 30 });
        await client.waitFor(
          () => client.messages.some((m) => m.op === "pty_opened"),
          "pty_opened",
          60_000,
        );
        const opened = frameOf(client, "pty_opened");
        const ptyId = opened.ptyId;
        openedPtyIds.push(ptyId);
        expect(opened.sessionId).toBe(sessionId);

        // Type a command; the tty echoes it and bash runs it.
        client.send({ op: "pty_input", ptyId, data: b64(`echo ${token}\n`) });
        await waitForPtyText(client, ptyId, token, "echo output visible", 60_000);

        // Resize takes effect inside the jail: stty size reports rows cols.
        client.send({ op: "pty_resize", ptyId, cols: 120, rows: 40 });
        client.send({ op: "pty_input", ptyId, data: b64("stty size\n") });
        await waitForPtyText(client, ptyId, "40 120", "stty size after resize", 60_000);

        // Abrupt disconnect (no close handshake). The PTY SURVIVES — only the
        // gateway's pty:out subscription detaches.
        client.terminate();
        await sleep(300); // let the gateway tear the socket down

        // Reconnect with a FRESH single-use ticket and re-attach from offset
        // null: pty_attached + the ring SNAPSHOT must repaint the earlier
        // output (Review Focus #3 at integration level).
        const client2 = await connectWs(user);
        client2.send({ op: "pty_attach", ptyId, lastOffset: null });
        await client2.waitFor(
          () => client2.messages.some((m) => m.op === "pty_attached" && m.ptyId === ptyId),
          "pty_attached after reconnect",
          30_000,
        );
        const attached = frameOf(client2, "pty_attached");
        expect(attached.ptyId).toBe(ptyId);
        expect(attached.truncated).toBe(false);
        await waitForPtyText(client2, ptyId, token, "snapshot repaint contains the echo", 30_000);
        await waitForPtyText(client2, ptyId, "40 120", "snapshot repaint contains stty size", 30_000);

        // Explicit close kills the pty: the exit event reaches the client.
        client2.send({ op: "pty_close", ptyId });
        await client2.waitFor(
          () => client2.messages.some((m) => m.op === "pty_exit" && m.ptyId === ptyId),
          "pty_exit after close",
          60_000,
        );
        const exitFrame = frameOf(client2, "pty_exit");
        expect(exitFrame.ptyId).toBe(ptyId);

        expect(workerFailures).toEqual([]);
        expect(workerErrors).toEqual([]);
        await client2.close();
      },
      240_000,
    );

    // ---- Flow c: blocked in the real jail (layers 1 and 2) -------------------

    it(
      "flow c — run_shell 'bash -c gradle build' → layer-1 REFUSAL_MESSAGE tool result + one system_note; pty 'gradle' → layer-2 shim refusal copy in the terminal output",
      async () => {
        // -- Layer 1: the client-side policy refuses before any jail spawn.
        const user = uid("e2e-rj-c");
        sse.arm([
          {
            toolCalls: [
              {
                id: "call-gradle",
                name: "run_shell",
                arguments: JSON.stringify({ command: "bash -c 'gradle build'" }),
              },
            ],
          },
          { deltas: ["ok"] },
        ]);
        const sessionId = await createSession(user);
        const client = await openSubscribedClient(user, sessionId);
        const sent = await sendMessage(user, sessionId, "try to build");

        await client.waitFor(
          () => client.events().some((e) => e.type === "run_completed"),
          "run_completed on WS",
          90_000,
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
        const notes = evts.filter((e) => e.type === "system_note");
        expect(notes).toHaveLength(1);
        expect(notes[0]!.payload).toMatchObject({
          code: "command_blocked",
          command: "bash -c 'gradle build'",
        });
        const completed = evts.find((e) => e.type === "tool_completed")!;
        expect(completed.payload.isError).toBe(true);
        expect(completed.payload.content).toBe(REFUSAL_MESSAGE);
        expect(await runRow(sent.runId)).toEqual({ status: "completed", attempts: 1 });
        await client.close();

        // -- Layer 2: the rootfs PATH shim refuses INSIDE a real pty.
        const ptySessionId = await createSession(user);
        const term = await connectWs(user);
        term.send({ op: "pty_open", sessionId: ptySessionId, cols: 100, rows: 30 });
        await term.waitFor(
          () => term.messages.some((m) => m.op === "pty_opened"),
          "pty_opened",
          60_000,
        );
        const ptyId = frameOf(term, "pty_opened").ptyId;
        openedPtyIds.push(ptyId);
        term.send({ op: "pty_input", ptyId, data: b64("gradle\n") });
        await waitForPtyText(
          term,
          ptyId,
          "Heavy native compilation",
          "layer-2 shim refusal copy in pty output",
          60_000,
        );
        term.send({ op: "pty_close", ptyId });
        await term.waitFor(
          () => term.messages.some((m) => m.op === "pty_exit" && m.ptyId === ptyId),
          "pty_exit after close",
          60_000,
        );

        expect(workerFailures).toEqual([]);
        expect(workerErrors).toEqual([]);
        await term.close();
      },
      240_000,
    );
  },
);
