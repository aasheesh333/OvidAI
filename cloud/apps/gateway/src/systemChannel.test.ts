import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import Redis from "ioredis";
import {
  sysInChannel,
  sysOutChannel,
  type SystemEventEnvelope,
} from "@ovid/shared";
import { createSystemHub, type SystemHub } from "./systemChannel.js";

/**
 * Gateway system hub (P5 Task 10) over REAL redis. The hub owns ONE shared
 * `sys:{uid}:out` subscription per uid across that uid's attached sockets
 * (fan-out), publishes gateway-originated envelopes on the same channel, and
 * forwards client responses to the worker-bound `sys:{uid}:in` channel. An
 * external redis client stands in for the worker / the mcp system bus.
 * Gated on TEST_REDIS_URL.
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const UID_A = "syschan-user-a";
const UID_B = "syschan-user-b";

const envelope: SystemEventEnvelope = {
  id: "018f1e2a-7b1c-7abc-8def-0123456789ab",
  kind: "mcp_sampling_approval",
  requiresResponse: true,
  payload: { tool: "read_file", serverId: "srv-1" },
  ts: "2026-10-17T00:00:00.000Z",
};

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

describe.skipIf(!TEST_REDIS_URL)("gateway system hub (real redis)", () => {
  let redis: Redis;
  /** External client standing in for the worker / mcp system bus. */
  let hub: SystemHub | null = null;

  beforeAll(async () => {
    redis = new Redis(TEST_REDIS_URL!);
  }, 30_000);

  afterEach(async () => {
    const current = hub;
    hub = null;
    if (current !== null) await current.close().catch(() => {});
  });

  afterAll(async () => {
    await redis?.quit().catch(() => redis?.disconnect());
  });

  async function numsub(channel: string): Promise<number> {
    const res = (await redis.pubsub("NUMSUB", channel)) as unknown as [string, number];
    return Array.isArray(res) ? (res[1] ?? 0) : 0;
  }

  it("publishOut → the attached socket callback receives the envelope", async () => {
    hub = createSystemHub(redis);
    const received: SystemEventEnvelope[] = [];
    hub.attach(UID_A, (e) => received.push(e));
    await waitForAsync(async () => (await numsub(sysOutChannel(UID_A))) === 1, "subscription live");

    await hub.publishOut(UID_A, envelope);
    await waitFor(() => received.length === 1, "envelope delivered");
    expect(received[0]).toEqual(envelope);
  });

  it("two sockets same uid both receive (ONE shared subscription); other uids never do; garbage on the channel is skipped", async () => {
    hub = createSystemHub(redis);
    const a1: SystemEventEnvelope[] = [];
    const a2: SystemEventEnvelope[] = [];
    const b: SystemEventEnvelope[] = [];
    hub.attach(UID_A, (e) => a1.push(e));
    hub.attach(UID_A, (e) => a2.push(e));
    hub.attach(UID_B, (e) => b.push(e));
    await waitForAsync(
      async () =>
        (await numsub(sysOutChannel(UID_A))) === 1 && (await numsub(sysOutChannel(UID_B))) === 1,
      "both subscriptions live",
    );

    // Worker-side publish (raw redis — the production path of the mcp bus).
    await redis.publish(sysOutChannel(UID_A), JSON.stringify(envelope));
    await waitFor(() => a1.length === 1 && a2.length === 1, "fan-out to both sockets");
    expect(a1[0]).toEqual(envelope);
    expect(a2[0]).toEqual(envelope);

    // Garbage on the channel (invalid JSON, off-schema envelope) is skipped
    // without killing the subscription — the P1 listener discipline.
    await redis.publish(sysOutChannel(UID_A), "not-json");
    await redis.publish(
      sysOutChannel(UID_A),
      JSON.stringify({ id: "x", kind: "nope", requiresResponse: false, payload: {}, ts: "t" }),
    );
    await sleep(150);
    expect(a1).toEqual([envelope]); // unchanged: only the valid envelope arrived
    expect(a2).toEqual([envelope]);
    expect(b).toEqual([]); // uid isolation: B's sockets never saw A's event

    // Still ONE shared subscription across the two sockets (NUMSUB pinned).
    expect(await numsub(sysOutChannel(UID_A))).toBe(1);
  });

  it("respond publishes {id, payload} on sys:{uid}:in", async () => {
    hub = createSystemHub(redis);
    const seen: string[] = [];
    const observer = redis.duplicate();
    observer.on("error", () => {});
    observer.on("message", (ch, message) => {
      if (ch === sysInChannel(UID_A)) seen.push(message);
    });
    await observer.subscribe(sysInChannel(UID_A));
    try {
      await hub.respond(UID_A, "evt-1", { decision: "allow" });
      await waitFor(() => seen.length === 1, "response on sys:{uid}:in");
      expect(JSON.parse(seen[0]!)).toEqual({ id: "evt-1", payload: { decision: "allow" } });
    } finally {
      await observer.quit().catch(() => {});
    }
  });

  it("detach stops delivery and releases the subscription (count back to baseline)", async () => {
    hub = createSystemHub(redis);
    const received: SystemEventEnvelope[] = [];
    const detach = hub.attach(UID_A, (e) => received.push(e));
    await waitForAsync(async () => (await numsub(sysOutChannel(UID_A))) === 1, "subscription live");

    detach();
    await waitForAsync(async () => (await numsub(sysOutChannel(UID_A))) === 0, "subscription released");
    expect(await numsub(sysOutChannel(UID_B))).toBe(0); // baseline everywhere

    await redis.publish(sysOutChannel(UID_A), JSON.stringify(envelope));
    await sleep(150);
    expect(received).toEqual([]); // no delivery after the last detach
  });

  it("detaching ONE of two sockets keeps the subscription and delivery for the other", async () => {
    hub = createSystemHub(redis);
    const a1: SystemEventEnvelope[] = [];
    const a2: SystemEventEnvelope[] = [];
    const d1 = hub.attach(UID_A, (e) => a1.push(e));
    hub.attach(UID_A, (e) => a2.push(e));
    await waitForAsync(async () => (await numsub(sysOutChannel(UID_A))) === 1, "subscription live");

    d1();
    await sleep(150); // settle: the shared subscription must SURVIVE (a2 still attached)
    expect(await numsub(sysOutChannel(UID_A))).toBe(1);

    await redis.publish(sysOutChannel(UID_A), JSON.stringify(envelope));
    await waitFor(() => a2.length === 1, "a2 still receives");
    expect(a1).toEqual([]); // the detached socket never does
  });

  it("close() releases every subscription, is idempotent, and rejects further ops", async () => {
    hub = createSystemHub(redis);
    const a: SystemEventEnvelope[] = [];
    const b: SystemEventEnvelope[] = [];
    hub.attach(UID_A, (e) => a.push(e));
    hub.attach(UID_B, (e) => b.push(e));
    await waitForAsync(
      async () =>
        (await numsub(sysOutChannel(UID_A))) === 1 && (await numsub(sysOutChannel(UID_B))) === 1,
      "both subscriptions live",
    );

    await hub.close();
    await waitForAsync(
      async () =>
        (await numsub(sysOutChannel(UID_A))) === 0 && (await numsub(sysOutChannel(UID_B))) === 0,
      "subscriptions released on close",
    );
    expect(() => hub!.attach(UID_A, () => {})).toThrow();
    await expect(hub!.publishOut(UID_A, envelope)).rejects.toThrow();
    await expect(hub!.respond(UID_A, "x", {})).rejects.toThrow();
    await hub.close(); // idempotent — a second close must not throw
  });
});
