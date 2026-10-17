import { readdirSync, readFileSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Redis } from "ioredis";
import WebSocket, { type RawData } from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { createDb, migrate, sessions, users, type Db } from "@ovid/db";
import { createRedisEventLog, createRedisSystemBus, type EventLog } from "@ovid/events";
import type { QueueServices } from "@ovid/queue";
import {
  wsServerMsg,
  type KeyProvider,
  type MintProvisioner,
  type WsServerMsg,
} from "@ovid/shared";
import {
  buildGateway,
  createTestVerifier,
  createTicketStore,
  type TicketStore,
} from "@ovid/gateway";
import {
  TAKEOVER_REFUSAL,
  chromiumExecutableExists,
  createBrowserEngine,
  createLocalDiskBrowserStateStore,
  createStorageStatePersistence,
  decodeBrowserState,
  frameMagicFormat,
  type BrowserEngine,
  type BrowserEngineConfig,
} from "@ovid/browser";

// Relative-source imports per the accepted pattern (stateStore.test.ts /
// P7-T1): the fixture server (P6 Task 1) and the cross-suite browser lock
// (T13 precedent, T14's extraction) live in @ovid/browser's src/test —
// test-only code the package's exports map deliberately does not publish.
import { startTestPageServer, type TestPageServer } from "../../../packages/browser/src/test/testServer.js";
import { acquireBrowserSuiteLock } from "../../../packages/browser/src/test/suiteLock.js";

/**
 * The P6 browser-engine e2e (Task 15): the REAL gateway (REST + WS with the
 * Task-9 browser viewer channel) and the REAL Task-14 BrowserEngine — real
 * chromium, real pool, real registry, real screencast, real input injection,
 * real storageState persistence — composed in ONE process over the shared
 * dev Postgres + Redis. The engine plays the worker exactly as main.ts wires
 * it; only the outermost boundaries are stubbed, spine.test.ts-style:
 *
 * - auth → createTestVerifier(): `Authorization: Bearer test:<uid>`; the
 *   users rows for both uids are ensured explicitly (the sessions below are
 *   created through the @ovid/db repos, not the authenticated REST path).
 * - keys/mint → constant stubs (never exercised: no model calls happen).
 * - queues → a loud stub: NO agent run is ever enqueued in this suite (see
 *   leg a). The queue field is only a mandatory GatewayDeps shape here.
 *
 * Pinned flows (one `it` per leg, shared beforeAll rig):
 *   a. agent run browses — browser_open/browser_read at the executor seam.
 *      Run events are deliberately NOT involved: the P3 loop integration
 *      test lands with P3; this leg pins the dispatch's "agent run uses
 *      browser_open+read against a local test HTTP server".
 *   b. viewer attaches mid-"run" — browser_state {live:true} then ≥2 binary
 *      frames whose magic bytes match the state's frameFormat.
 *   c. viewer input — client JSON → gateway → redis → worker → Playwright →
 *      DOM (browser_find proves the DOM flipped).
 *   d. takeover — state flag, exact TAKEOVER_REFUSAL, release.
 *   e. storageState round-trip — releaseSession flush → openSession
 *      restores login_tok, AND the on-disk encrypted blob decodes with the
 *      test master key (at-rest encryption, not just in-memory).
 *   f. boundaries — a second uid's browser_attach is forbidden and that
 *      client receives ZERO binary frames for the whole suite.
 *
 * BINDING CARRIES folded in:
 * - I2 (T14 review): "no input before browser_state with screencast:true" is
 *   a GATEWAY-CLIENT requirement. The engine does NOT gate input on the
 *   one-per-lifetime webp probe (~3 s window — input sent during the probe
 *   lands on the probe's data: fixture and is lost). The harness below plays
 *   the gateway client and queues input until the screencast-true state.
 * - M5 (T14 review): shutdown is flush-before-drain (browser.close before
 *   worker.close). This suite has no drained jobs to fail; leg e + the
 *   teardown's engine.close() pin the flush-before-context-death half.
 *
 * Cross-suite browser lock (binding P6 ruling): this suite EMITS on
 * browser:* pub/sub channels through the real engine, so it takes
 * browser:test:suite-lock for its whole run (the T14 extraction, refreshed
 * while held — the chromium legs can outlive a short TTL).
 *
 * Determinism: bounded waits with deadlines only for I/O settle (frames,
 * redis round-trips, process exit); no fixed sleeps on the critical path.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** Contract path (hardcoded on purpose — same pin as spine.test.ts). */
const WS_PATH = "/cloud/ws";

const TEST_MASTER_KEY = "e2e-browser-master-key";

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

async function waitForAsync(
  cond: () => Promise<boolean>,
  what: string,
  timeoutMs = 15_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await cond())) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(50);
  }
}

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

/**
 * Chromium processes DESCENDED FROM this vitest worker (test-spawned only).
 * Concurrent suites' chromium is not ours to assert about — the ancestry
 * filter makes the teardown pin precise.
 */
function chromiumDescendantsOf(rootPid: number): number[] {
  const ppidByPid = new Map<number, number>();
  const cmdByPid = new Map<number, string>();
  for (const ent of readdirSync("/proc")) {
    if (!/^\d+$/.test(ent)) continue;
    try {
      const stat = readFileSync(`/proc/${ent}/stat`, "utf8");
      const rest = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      ppidByPid.set(Number(ent), Number(rest[1]));
      cmdByPid.set(Number(ent), readFileSync(`/proc/${ent}/cmdline`, "utf8").replace(/\0/g, " "));
    } catch {
      /* process exited between readdir and read — ignore */
    }
  }
  const found: number[] = [];
  for (const [pid, cmd] of cmdByPid) {
    if (!/ms-playwright/.test(cmd) || !/chrom/i.test(cmd)) continue;
    const seen = new Set<number>();
    let cur: number | undefined = pid;
    while (cur !== undefined && cur > 1 && !seen.has(cur)) {
      seen.add(cur);
      if (cur === rootPid) {
        found.push(pid);
        break;
      }
      cur = ppidByPid.get(cur);
    }
  }
  return found;
}

/** ws delivers Buffer | ArrayBuffer | Buffer[]; every text frame is UTF-8 JSON. */
function rawToString(data: RawData): string {
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  return data.toString("utf8");
}

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL || !chromiumExecutableExists())(
  "cloud browser e2e (real gateway + real engine + real chromium + real Postgres/Redis)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let tickets: TicketStore;
    let server: TestPageServer;
    let app: ReturnType<typeof buildGateway>;
    let baseUrl: string;
    let wsBase: string;
    let engine: BrowserEngine;
    let stateDir: string;
    let wsRoot: string;
    let releaseSuiteLock: (() => Promise<void>) | null = null;

    /** Every connection the engine's redis factory created (bridge-owned). */
    const engineConns: Redis[] = [];
    const engineLogs: Array<{ msg: string; err?: unknown }> = [];
    const sids: string[] = [];

    // The two principals (leg f's boundary needs a second uid).
    const uidA = uid("e2e-browser-a");
    const uidB = uid("e2e-browser-b");

    // Boundary stubs, spine.test.ts-style. No model calls happen; the queue
    // stub is LOUD so an accidental enqueue fails the test, not silently passes.
    const keys: KeyProvider = { getKeyForUser: async () => "test-key" };
    const mint: MintProvisioner = { ensureKey: async () => ({ key: "test-key" }) };
    const neverQueues = {
      agentRuns: {
        add: async () => {
          throw new Error("unexpected enqueue: no agent runs in the browser e2e suite");
        },
        client: Promise.resolve({ ping: async () => "PONG" }),
      },
    } as unknown as QueueServices;

    /** The owner viewer (legs b–d) and the would-be intruder (leg f). */
    let viewer: TestClient | null = null;
    let intruder: TestClient | null = null;
    /** Leg b's session: the one the viewer is attached to (legs c, d, f). */
    let sidViewer = "";

    interface TestClient {
      socket: WebSocket;
      /** Text frames, parsed THROUGH the shared schema (off-contract frames throw). */
      messages: WsServerMsg[];
      /** Binary frames (screencast image bytes, prefix already stripped by the gateway). */
      binary: Buffer[];
      send(msg: unknown): void;
      waitFor(cond: () => boolean, what: string, timeoutMs?: number): Promise<void>;
      close(): Promise<void>;
    }

    const clients: TestClient[] = [];

    async function connectWs(user: string): Promise<TestClient> {
      const res = await fetch(`${baseUrl}/cloud/v1/auth/ticket`, {
        method: "POST",
        headers: { authorization: `Bearer test:${user}` },
      });
      if (res.status !== 200) throw new Error(`ticket mint failed: ${res.status}`);
      const body = (await res.json()) as { ticket?: string };
      if (typeof body.ticket !== "string" || body.ticket === "") throw new Error("no ticket minted");

      const socket = new WebSocket(`${wsBase}?ticket=${encodeURIComponent(body.ticket)}`);
      const messages: WsServerMsg[] = [];
      const binary: Buffer[] = [];
      socket.on("message", (data: RawData, isBinary: boolean) => {
        if (isBinary) {
          binary.push(Buffer.from(data as Buffer));
          return;
        }
        messages.push(wsServerMsg(JSON.parse(rawToString(data))));
      });
      await new Promise<void>((resolve, reject) => {
        const onError = (err: Error): void => reject(err);
        socket.once("error", onError);
        socket.once("open", () => {
          socket.off("error", onError);
          resolve();
        });
      });
      socket.on("error", () => {}); // teardown noise never throws out of the loop

      const client: TestClient = {
        socket,
        messages,
        binary,
        send: (msg) => socket.send(JSON.stringify(msg)),
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

    /** Session rows through the @ovid/db repos (users ensured in beforeAll). */
    async function newSession(userId: string): Promise<string> {
      const row = await sessions.create(db, userId, null);
      sids.push(row.id);
      return row.id;
    }

    function tool(name: string) {
      const def = engine.tools.find((t) => t.name === name);
      if (def === undefined) throw new Error(`missing browser tool ${name}`);
      return def;
    }

    const ctx = (sessionId: string, userId = uidA) => ({ sessionId, userId });

    /** Every browser_state frame the client has received, in arrival order. */
    function browserStates(client: TestClient) {
      return client.messages.flatMap((m) => (m.op === "browser_state" ? [m.state] : []));
    }

    /** browser_find's leading match count (−1 when the content is not a count). */
    async function findCount(text: string, sessionId: string): Promise<number> {
      const res = await tool("browser_find").execute({ text }, ctx(sessionId));
      const m = /^(\d+) match/.exec(res.content);
      return m === null ? -1 : Number(m[1]);
    }

    // -------------------------------------------------------------------------
    // Rig
    // -------------------------------------------------------------------------

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redis = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);

      // The engine emits on browser:* pub/sub channels → take the cross-suite
      // browser lock FIRST (binding P6 ruling; T14's refreshed extraction).
      releaseSuiteLock = await acquireBrowserSuiteLock(redis);

      // Two principals for the leg-f boundary (the sessions are created via
      // the repos, so the users rows must pre-exist for the FK).
      await users.ensure(db, uidA, null);
      await users.ensure(db, uidB, null);

      server = await startTestPageServer();
      stateDir = await mkdtemp(join(tmpdir(), "ovid-browser-e2e-state-"));
      wsRoot = await mkdtemp(join(tmpdir(), "ovid-browser-e2e-ws-"));

      const cfg: BrowserEngineConfig = {
        maxLiveBrowsers: 4,
        tier1FallbackContexts: 2,
        // Real clock, comfortably above the suite duration: no idle eviction
        // may race the legs (leg e does its own explicit release/reopen).
        idleEvictMs: 600_000,
        maxTier1Processes: 8,
        tier1TimeoutMs: 20_000,
        maxActiveScreencasts: 3,
        screencastLoadMax: 6.0,
        screencast: { width: 1280, height: 800, quality: 60, everyNthFrame: 2, maxFramesInFlight: 2 },
        stateDir,
        lightpandaBin: null, // no tier-1 legs in this suite
        allowHosts: ["127.0.0.1", "localhost"], // the fixture server's host
        ownPublicIp: null,
        chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
      };

      // The worker's exact engine wiring (main.ts): persistence = local-disk
      // blob store under a tmp dir + the test master key.
      engine = await createBrowserEngine({
        cfg,
        redisFactory: () => {
          const r = new Redis(TEST_REDIS_URL!);
          engineConns.push(r);
          return r;
        },
        persistence: createStorageStatePersistence(
          createLocalDiskBrowserStateStore(stateDir),
          TEST_MASTER_KEY,
        ),
        workspaceDir: async () => wsRoot,
        log: (msg, err) => engineLogs.push({ msg, err }),
      });

      app = buildGateway({

        system: createRedisSystemBus(redis),
        db,
        queues: neverQueues,
        verifier: createTestVerifier(),
        tickets,
        keys,
        mint,
        events,
        // The Task-9 browser viewer channel, wired exactly like main.ts.
        browser: { redisFactory: () => new Redis(TEST_REDIS_URL!) },
      });
      await app.listen({ host: "127.0.0.1", port: 0 });
      const port = (app.server.address() as AddressInfo).port;
      baseUrl = `http://127.0.0.1:${port}`;
      wsBase = `ws://127.0.0.1:${port}${WS_PATH}`;
    }, 60_000);

    afterAll(async () => {
      // 1) Client sockets FIRST: each close makes the gateway publish
      //    viewer_leave and quit the attach's two dedicated redis connections.
      while (clients.length > 0) await clients.pop()!.close().catch(() => {});

      // 2) Peer-verified viewer_leave: the ENGINE saw the leave and stopped
      //    the cast (the observable on this side of the redis boundary).
      if (engine !== undefined) {
        await waitFor(
          () => engine.screencastCount() === 0,
          "screencast stops after viewer_leave",
          10_000,
        ).catch(() => {});
      }

      // 3) Engine close — flush BEFORE the contexts die (M5 carry's
      //    flush-before-drain half): every live session captures and persists
      //    storageState, then the browser process goes away.
      await engine?.close().catch(() => {});
      if (engine !== undefined) {
        expect(engine.pool.stats()).toEqual({
          browserAlive: false,
          live: 0,
          tier1: 0,
          queued: 0,
        });
        // Every connection the engine's redis factory created is quit.
        await waitForAsync(
          async () => engineConns.every((c) => c.status === "end"),
          "engine redis connections quit",
        );
      }

      // 4) No test-spawned chromium pid left alive (ancestry-filtered: a
      //    concurrent suite's chromium is not this suite's to assert about).
      await waitFor(
        () => chromiumDescendantsOf(process.pid).length === 0,
        "test-spawned chromium exited",
        10_000,
      );
      expect(chromiumDescendantsOf(process.pid)).toEqual([]);

      // 5) The intruder client received ZERO binary frames for the whole
      //    suite (Review Focus #1: the boundary must leak no pixels either).
      expect(intruder?.binary.length ?? 0).toBe(0);

      // 6) No leaked pub/sub channel for any session this suite opened
      //    (every browser ctl/input/state/frames + event live subscription
      //    owns a dedicated redis connection — bounded settle wait).
      const ours = new Set(
        sids.flatMap((id) => [
          `browser:${id}:ctl`,
          `browser:${id}:input`,
          `browser:${id}:state`,
          `browser:${id}:frames`,
          `sess:${id}:live`,
        ]),
      );
      await waitForAsync(async () => {
        const channels = (await redis.call("PUBSUB", "CHANNELS", "*")) as string[];
        return channels.every((c) => !ours.has(c));
      }, "suite pubsub channels torn down");

      // 7) The rest: gateway app, lock, fixture server, redis, db, tmpdirs.
      await app?.close();
      await releaseSuiteLock?.();
      await server?.close();
      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });
      await rm(stateDir, { recursive: true, force: true }).catch(() => {});
      await rm(wsRoot, { recursive: true, force: true }).catch(() => {});
    }, 60_000);

    // ---- Leg a: agent run browses -------------------------------------------

    it(
      "leg a — agent run browses: browser_open returns the fixture title + final URL, browser_read ≥600 chars of markdown (executor seam; run events NOT involved — the P3 loop integration test lands with P3)",
      async () => {
        const sessionId = await newSession(uidA);
        await engine.openSession(sessionId, uidA); // what P3's run start does

        const open = await tool("browser_open").execute({ url: server.url("/") }, ctx(sessionId));
        expect(open.content).toContain("Static article");
        expect(open.content).toContain(server.url("/"));
        expect(open.content.length).toBeGreaterThanOrEqual(600);

        const read = await tool("browser_read").execute({}, ctx(sessionId));
        expect(read.content.length).toBeGreaterThanOrEqual(600);
        expect(read.content).not.toMatch(/truncated \d+ chars/); // the plain article fits the cap whole
      },
      45_000,
    );

    // ---- Leg b: viewer attaches mid-"run" -----------------------------------

    it(
      "leg b — viewer attaches mid-run: browser_state {live:true, screencast:true} then ≥2 binary frames within 15 s whose magic bytes match the state's frameFormat",
      async () => {
        sidViewer = await newSession(uidA);
        // The "run" is underway: the agent's tab is live on the animated
        // fixture (damage every 100 ms — a static page emits zero frames).
        await engine.openSession(sidViewer, uidA);
        await tool("browser_open").execute({ url: server.url("/animated") }, ctx(sidViewer));

        // Owner viewer: ticket → subscribe (sanity) → browser_attach.
        viewer = await connectWs(uidA);
        viewer.send({ op: "subscribe", sessionId: sidViewer, lastEventId: null });
        await viewer.waitFor(
          () => viewer!.messages.some((m) => m.op === "subscribed"),
          "subscribed ack",
        );
        // No runs exist in this suite: the replay must have delivered zero
        // events after the ack.
        expect(viewer.messages.filter((m) => m.op === "event")).toEqual([]);

        // The leg-f intruder connects NOW and stays connected, so its
        // zero-binary-frames counter spans every frame-flowing leg.
        intruder = await connectWs(uidB);

        viewer.send({ op: "browser_attach", sessionId: sidViewer });
        // The first cast start runs the one-per-engine webp probe (~3 s);
        // the cast-start publish carries live:true + screencast:true.
        await viewer.waitFor(
          () => browserStates(viewer!).some((s) => s.live && s.screencast),
          "browser_state {live:true, screencast:true}",
          15_000,
        );
        await viewer.waitFor(
          () => viewer!.binary.length >= 2,
          "≥2 binary frames",
          15_000,
        );

        const state = browserStates(viewer).find((s) => s.live && s.screencast)!;
        expect(state.sessionId).toBe(sidViewer);
        expect(state.takeover).toBe(false);
        // Every binary frame's magic bytes must match the published format.
        for (const frame of viewer.binary) {
          expect(frameMagicFormat(frame)).toBe(state.frameFormat);
        }
      },
      45_000,
    );

    // ---- Leg c: input injection ----------------------------------------------

    it(
      "leg c — input injection: client JSON → gateway → redis → worker → Playwright → DOM; the harness (playing the gateway CLIENT) queues input until browser_state{screencast:true} (I2 binding: the ENGINE does not gate input on the ~3 s webp probe — input sent early lands on the probe's data: fixture and is lost)",
      async () => {
        // Leg b's session: viewer attached, cast live.
        await tool("browser_open").execute({ url: server.url("/click") }, ctx(sidViewer));

        // I2 CLIENT CONTRACT: no input before a browser_state with
        // screencast:true for the page we are about to tap. The probe already
        // ran in leg b, but the contract is the client's regardless — pin it
        // by waiting, never by assuming.
        await viewer!.waitFor(
          () =>
            browserStates(viewer!).some(
              (s) => s.screencast && s.url !== null && s.url.endsWith("/click"),
            ),
          "browser_state for /click with screencast on",
          15_000,
        );

        // #btn sits at left:20 top:20, 100x40 — (70, 40) is inside it.
        viewer!.send({
          op: "browser_input",
          sessionId: sidViewer,
          input: { type: "tap", x: 70, y: 40 },
        });

        // The DOM proof, through the agent's own tool on the same page.
        await waitForAsync(
          async () => (await findCount("CLICKED", sidViewer)) >= 1,
          "#out flips to CLICKED",
          15_000,
        );
      },
      45_000,
    );

    // ---- Leg d: takeover ------------------------------------------------------

    it(
      "leg d — takeover: enabled:true → state takeover:true; browser_click returns exactly TAKEOVER_REFUSAL; enabled:false → the tool works again",
      async () => {
        const states = () => browserStates(viewer!);

        // Reset #out so the post-release click is provable (leg c already
        // set it to CLICKED; a fresh click must be distinguishable).
        await tool("browser_evaluate").execute(
          { expression: "document.getElementById('out').textContent = 'PRE-TAKEOVER'" },
          ctx(sidViewer),
        );
        expect(await findCount("CLICKED", sidViewer)).toBe(0);

        viewer!.send({ op: "browser_takeover", sessionId: sidViewer, enabled: true });
        await viewer!.waitFor(
          () => states().some((s) => s.takeover),
          "state frame with takeover:true",
        );

        // Exactly the pinned refusal copy — before any browser work.
        const refused = await tool("browser_click").execute({ selector: "#btn" }, ctx(sidViewer));
        expect(refused.content).toBe(TAKEOVER_REFUSAL);

        viewer!.send({ op: "browser_takeover", sessionId: sidViewer, enabled: false });
        // The NEXT state after the takeover:true one must carry takeover:false
        // (a state frame published by the engine's ctl handler).
        await viewer!.waitFor(
          () => {
            const at = states().findIndex((s) => s.takeover);
            return at !== -1 && states().slice(at + 1).some((s) => !s.takeover);
          },
          "state frame with takeover:false after the takeover:true one",
        );

        const clicked = await tool("browser_click").execute({ selector: "#btn" }, ctx(sidViewer));
        expect(clicked.content).toBe("clicked #btn");
        await waitForAsync(
          async () => (await findCount("CLICKED", sidViewer)) >= 1,
          "#out flips back to CLICKED",
          15_000,
        );
      },
      45_000,
    );

    // ---- Leg e: storageState round-trip --------------------------------------

    it(
      "leg e — storageState login round-trips a context restart: releaseSession flushes, openSession restores login_tok=abc123, and the on-disk blob under users/{uid}/browser/main.zst decodes with the test master key (at-rest encryption)",
      async () => {
        const sessionId = await newSession(uidA);
        await engine.openSession(sessionId, uidA);
        await tool("browser_open").execute({ url: server.url("/setcookie") }, ctx(sessionId));

        // The pinned close path: capture → flush → context dies.
        await engine.releaseSession(sessionId);
        // …and the pinned open path: restore → acquire → register.
        await engine.openSession(sessionId, uidA);

        const cookie = await tool("browser_cookies").execute(
          { get: "login_tok" },
          ctx(sessionId),
        );
        expect(cookie.content).toBe("login_tok=abc123");

        // At-rest proof: the encrypted blob on disk decodes with the TEST
        // key (and not with a wrong one — AES-GCM auth, not just zstd).
        const blob = await readFile(join(stateDir, "users", uidA, "browser", "main.zst"));
        const decoded = decodeBrowserState(blob, TEST_MASTER_KEY);
        expect(decoded.cookies.some((c) => c.name === "login_tok" && c.value === "abc123")).toBe(
          true,
        );
        expect(() => decodeBrowserState(blob, "not-the-master-key")).toThrow();
      },
      45_000,
    );

    // ---- Leg f: boundaries ----------------------------------------------------

    it("leg f — boundaries: user B's browser_attach to A's session → {op:\"error\",code:\"forbidden\"}; the intruder received ZERO binary frames (tracked across the whole suite)", async () => {
      if (intruder === null) intruder = await connectWs(uidB); // defensive: leg b normally connects it
      if (sidViewer === "") throw new Error("leg f needs leg b's viewer session");

      // Attach to the session the cast is LIVE on — the strongest form of the
      // boundary pin: not a single pixel may cross it.
      intruder.send({ op: "browser_attach", sessionId: sidViewer });
      await intruder.waitFor(
        () => intruder!.messages.some((m) => m.op === "error"),
        "forbidden error frame",
      );
      await sleep(300); // settle: no (wrongly granted) state or frames may follow
      // The intruder sent exactly one frame ever (the attach) — the forbidden
      // error is its one and only reply, and the connection survives it.
      expect(intruder.messages).toEqual([
        {
          op: "error",
          code: "forbidden",
          message: expect.any(String),
          sessionId: sidViewer,
        },
      ]);
      // The whole-suite zero is asserted in afterAll (teardown order pins it
      // AFTER every frame-flowing leg has run); assert the local window here.
      expect(intruder.binary.length).toBe(0);
      expect(intruder.socket.readyState).toBe(WebSocket.OPEN);
    });
  },
);
