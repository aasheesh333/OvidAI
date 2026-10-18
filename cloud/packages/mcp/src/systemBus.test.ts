import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  APPROVAL_TIMEOUT_MS,
  createRedisSystemBus,
  type UserSystemBus,
} from "./systemBus.js";
import { sysInChannel, sysOutChannel } from "../../shared/src/system.js";

/**
 * Worker-side system bus (P5 Task 10) over REAL redis. A harness client
 * subscribes `sys:{uid}:out` (standing in for the gateway hub's per-uid
 * subscription) and replies on `sys:{uid}:in`. Gated on TEST_REDIS_URL.
 *
 * ioredis note: @ovid/mcp cannot DECLARE ioredis (the wave's lockfile is
 * frozen for parallel lanes), so the test loads the constructor through a
 * computed dynamic import from a sibling package's node_modules — the same
 * discipline as oauth/flow.ts's @ovid/db loader. The wave merger replaces
 * this with a plain `import Redis from "ioredis"` once the dependency is
 * declared.
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/** UUIDv7 shape: version nibble 7, variant 10xx (RFC 9562). */
const UUIDV7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const UID = "mcp-sysbus-user";

/** Loose structural stand-in for the ioredis client the harness needs. */
interface TestRedis {
  publish(channel: string, message: string): Promise<number>;
  subscribe(channel: string): Promise<number>;
  on(event: string, listener: (...args: never[]) => void): unknown;
  off(event: string, listener: (...args: never[]) => void): unknown;
  duplicate(): TestRedis;
  quit(): Promise<unknown>;
  disconnect(): void;
  pubsub(command: "NUMSUB", channel: string): Promise<unknown>;
}

const IOREDIS_CANDIDATES = [
  "../../../apps/gateway/node_modules/ioredis/built/index.js",
  "../../../events/node_modules/ioredis/built/index.js",
];

async function loadRedisCtor(): Promise<new (url: string) => TestRedis> {
  for (const spec of IOREDIS_CANDIDATES) {
    try {
      const mod = (await import(spec)) as { default?: unknown };
      const ctor = mod.default ?? mod;
      if (typeof ctor === "function") return ctor as new (url: string) => TestRedis;
    } catch {
      // try the next candidate
    }
  }
  throw new Error(
    "ioredis could not be loaded for the systemBus tests — run `pnpm install` at cloud/ first",
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond: () => boolean, what: string, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(10);
  }
}

async function waitForAsync(
  cond: () => Promise<boolean>,
  what: string,
  timeoutMs = 10_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await cond())) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(25);
  }
}

// Channel naming + the pinned default-deny window need no services.
describe("systemBus constants", () => {
  it("pins the cross-process channel naming (must match @ovid/shared's helpers)", () => {
    expect(sysOutChannel(UID)).toBe(`sys:${UID}:out`);
    expect(sysInChannel(UID)).toBe(`sys:${UID}:in`);
  });

  it("APPROVAL_TIMEOUT_MS is the spec §6.2 default-deny window", () => {
    expect(APPROVAL_TIMEOUT_MS).toBe(120_000);
  });
});

describe.skipIf(!TEST_REDIS_URL)("mcp system bus (real redis)", () => {
  /** Harness observer: SUBSCRIBES sys:{uid}:out (subscriber-mode only). */
  let ctl: TestRedis;
  /** Harness publisher: replies on sys:{uid}:in + NUMSUB (a subscriber-mode
   *  connection cannot publish — hence the second client). */
  let pub: TestRedis;
  /** Publisher base the buses under test duplicate from. */
  let busRedis: TestRedis;
  /** Raw parsed envelopes observed on sys:{uid}:out, in arrival order. */
  const seen: Array<Record<string, unknown>> = [];
  let onEnvelope: ((env: Record<string, unknown>) => void) | null = null;
  const buses: UserSystemBus[] = [];

  beforeAll(async () => {
    const RedisCtor = await loadRedisCtor();
    ctl = new RedisCtor(TEST_REDIS_URL!);
    pub = new RedisCtor(TEST_REDIS_URL!);
    busRedis = new RedisCtor(TEST_REDIS_URL!);
    for (const c of [ctl, pub, busRedis]) c.on("error", () => {});
    ctl.on("message", ((ch: string, message: string) => {
      if (ch !== sysOutChannel(UID)) return;
      try {
        const env = JSON.parse(message) as Record<string, unknown>;
        seen.push(env);
        onEnvelope?.(env);
      } catch {
        // garbage on the channel: skip
      }
    }) as never);
    await ctl.subscribe(sysOutChannel(UID));
  }, 30_000);

  beforeEach(() => {
    seen.length = 0;
    onEnvelope = null;
  });

  afterAll(async () => {
    for (const bus of buses) await bus.close().catch(() => {});
    for (const c of [ctl, pub, busRedis]) await c?.quit().catch(() => {});
  });

  function makeBus(opts?: { idGen?: () => string }): UserSystemBus {
    const bus = createRedisSystemBus(busRedis, opts);
    buses.push(bus);
    return bus;
  }

  async function numsub(channel: string): Promise<number> {
    const res = (await pub.pubsub("NUMSUB", channel)) as unknown as [string, number];
    return Array.isArray(res) ? (res[1] ?? 0) : 0;
  }

  it("request round-trips the response by id (envelope: requiresResponse true, uuidv7 id, ts)", async () => {
    const bus = makeBus();
    const payload = { tool: "read_file", arguments: { path: "/etc/hosts" } };
    const pending = bus.request(UID, "mcp_sampling_approval", payload, { timeoutMs: 5_000 });

    await waitFor(() => seen.length >= 1, "request envelope published");
    const env = seen[0]!;
    expect(env.kind).toBe("mcp_sampling_approval");
    expect(env.requiresResponse).toBe(true);
    expect(env.payload).toEqual(payload);
    expect(typeof env.id).toBe("string");
    expect(env.id as string).toMatch(UUIDV7_RE);
    expect(typeof env.ts === "string" && !Number.isNaN(Date.parse(env.ts as string))).toBe(true);

    await pub.publish(sysInChannel(UID), JSON.stringify({ id: env.id, payload: { decision: "allow" } }));
    const res = await pending;
    expect(res).toEqual({ id: env.id, payload: { decision: "allow" } });

    // The per-request sys:{uid}:in subscription is gone once the reply lands.
    await waitForAsync(async () => (await numsub(sysInChannel(UID))) === 0, "in subscriber released");
  }, 15_000);

  it("timeout → null (caller treats null as deny); timeoutMs is honored", async () => {
    const bus = makeBus();
    const started = Date.now();
    const res = await bus.request(UID, "mcp_elicitation", { prompt: "Which file?" }, { timeoutMs: 50 });
    expect(res).toBeNull();
    expect(Date.now() - started).toBeLessThan(5_000);
    // The request itself was still published (the client could have answered).
    await waitFor(() => seen.length >= 1, "request envelope published");
    expect(seen[0]!.requiresResponse).toBe(true);
    await waitForAsync(async () => (await numsub(sysInChannel(UID))) === 0, "in subscriber released");
  }, 15_000);

  it("publish fills ts and defaults requiresResponse false; generates the id when absent (T9 structural callers); explicit fields survive", async () => {
    const bus = makeBus();
    // The T9 SystemEventPublisher callers pass NEITHER id nor requiresResponse
    // (kind/payload only) — the runtime is deliberately forgiving for them.
    await bus.publish(UID, {
      kind: "mcp_oauth_completed",
      payload: { serverId: "srv-9", ok: true },
    } as Parameters<UserSystemBus["publish"]>[1]);
    await waitFor(() => seen.length >= 1, "first publish observed");
    expect(seen.length).toBe(1);
    const env = seen[0]!;
    expect(env.kind).toBe("mcp_oauth_completed");
    expect(env.requiresResponse).toBe(false);
    expect(env.payload).toEqual({ serverId: "srv-9", ok: true });
    expect(env.id).toMatch(UUIDV7_RE);
    expect(typeof env.ts === "string" && !Number.isNaN(Date.parse(env.ts as string))).toBe(true);

    // Explicit id/requiresResponse/ts are forwarded verbatim.
    await bus.publish(UID, {
      id: "fixed-1",
      kind: "plugin_install_progress",
      requiresResponse: true,
      payload: { pct: 50 },
      ts: "2026-10-17T01:02:03.000Z",
    });
    await waitFor(() => seen.length >= 2, "second publish observed");
    expect(seen[1]).toEqual({
      id: "fixed-1",
      kind: "plugin_install_progress",
      requiresResponse: true,
      payload: { pct: 50 },
      ts: "2026-10-17T01:02:03.000Z",
    });
  }, 15_000);

  it("a mismatched id on sys:{uid}:in is ignored", async () => {
    const bus = makeBus({ idGen: () => "req-42" });
    const pending = bus.request(UID, "mcp_sampling_approval", { tool: "bash" }, { timeoutMs: 5_000 });
    await waitFor(() => seen.some((e) => e.id === "req-42"), "request published");

    // A reply for a DIFFERENT pending id arrives first: ignored.
    await pub.publish(sysInChannel(UID), JSON.stringify({ id: "req-other", payload: { decision: "deny" } }));
    await sleep(150); // give the wrong reply a chance to (wrongly) settle it
    // …then the matching one.
    await pub.publish(sysInChannel(UID), JSON.stringify({ id: "req-42", payload: { decision: "always" } }));

    const res = await pending;
    expect(res).toEqual({ id: "req-42", payload: { decision: "always" } });
  }, 15_000);

  it("close resolves pending requests as null (default-deny), releases connections, and rejects further ops", async () => {
    const bus = makeBus({ idGen: () => "req-close" });
    const pending = bus.request(UID, "plugin_grant_approval", { pluginId: "pl-1" }, { timeoutMs: 30_000 });
    await waitFor(() => seen.some((e) => e.id === "req-close"), "request published");
    await waitForAsync(async () => (await numsub(sysInChannel(UID))) >= 1, "in subscriber registered");

    await bus.close();
    expect(await pending).toBeNull(); // pending approvals DENY on shutdown
    await waitForAsync(async () => (await numsub(sysInChannel(UID))) === 0, "in subscriber released");

    // request() throws SYNCHRONOUSLY on a closed bus (assertOpen before the
    // promise); publish() rejects — both loud, never a silent no-op.
    expect(() => bus.request(UID, "mcp_elicitation", {}, { timeoutMs: 50 })).toThrow();
    await expect(
      bus.publish(UID, { id: "x", kind: "mcp_elicitation", requiresResponse: false, payload: {} }),
    ).rejects.toThrow();
    await bus.close(); // idempotent — a second close must not throw
  }, 20_000);
});
