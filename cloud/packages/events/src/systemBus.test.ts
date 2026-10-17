import { afterAll, beforeAll, describe, expect, it } from "vitest";
import Redis from "ioredis";
import type { SystemEvent } from "@ovid/shared";
import { createRedisSystemBus } from "./systemBus.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

// Unique user ids per test run (shared dev redis — a fixed uid would leak
// deliveries between runs and between parallel suites).
let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

const systemChannel = (u: string): string => `user:${u}:system`;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) {
      throw new Error("waitFor: condition not met before timeout");
    }
    await sleep(25);
  }
}

function scheduleEvent(scheduleId: string): SystemEvent {
  return {
    type: "schedule_created",
    scheduleId,
    ts: new Date().toISOString(),
    payload: { title: "ping" },
  };
}

describe.skipIf(!TEST_REDIS_URL)("systemBus against real redis", () => {
  let redis: Redis;

  beforeAll(() => {
    redis = new Redis(TEST_REDIS_URL!);
  });

  afterAll(async () => {
    await redis.quit();
  });

  it("publish delivers the event to that uid's subscriber; other uids see nothing", async () => {
    const bus = createRedisSystemBus(redis);
    const uA = uid("user");
    const uB = uid("user");
    const gotA: SystemEvent[] = [];
    const gotB: SystemEvent[] = [];
    const e = scheduleEvent("sched-1");

    const unsubA = await bus.subscribe(uA, (ev) => gotA.push(ev));
    const unsubB = await bus.subscribe(uB, (ev) => gotB.push(ev));
    try {
      await bus.publish(uA, e);
      await waitFor(() => gotA.length === 1);
      expect(gotA).toEqual([e]); // full envelope round-trips through the channel

      // channel isolation: uid B's subscriber must see none of A's events
      await sleep(100);
      expect(gotB).toEqual([]);
    } finally {
      await unsubA();
      await unsubB();
    }
  });

  it("garbage on the channel is skipped; later valid events still arrive", async () => {
    const bus = createRedisSystemBus(redis);
    const u = uid("user");
    const got: SystemEvent[] = [];

    const unsub = await bus.subscribe(u, (ev) => got.push(ev));
    try {
      // Raw garbage straight onto the channel (bypasses publish's JSON).
      await redis.publish(systemChannel(u), "{oops");
      await redis.publish(systemChannel(u), "");
      await redis.publish(systemChannel(u), '["truncated"');
      // Valid JSON that is NOT a SystemEvent fails the schema gate → skipped.
      await redis.publish(
        systemChannel(u),
        JSON.stringify({
          type: "not_a_schedule_kind",
          scheduleId: "s",
          ts: new Date().toISOString(),
          payload: {},
        }),
      );
      await sleep(150);
      expect(got).toEqual([]); // nothing delivered, listener still alive

      const e = scheduleEvent("sched-2");
      await bus.publish(u, e);
      await waitFor(() => got.length === 1);
      expect(got).toEqual([e]);
    } finally {
      await unsub();
    }
  });

  it("an onEvent that throws on one event still receives the next", async () => {
    const bus = createRedisSystemBus(redis);
    const u = uid("user");
    const got: SystemEvent[] = [];

    const unsub = await bus.subscribe(u, (ev) => {
      got.push(ev);
      if (got.length === 1) throw new Error("consumer boom");
    });
    try {
      await bus.publish(u, scheduleEvent("sched-3"));
      await waitFor(() => got.length === 1);

      // The throwing consumer must not have knocked out the listener:
      const e2 = scheduleEvent("sched-4");
      await bus.publish(u, e2);
      await waitFor(() => got.length === 2);
      expect(got[1]).toEqual(e2);
    } finally {
      await unsub();
    }
  });

  it("unsubscribe stops delivery and drains the channel (connection quit)", async () => {
    const bus = createRedisSystemBus(redis);
    const u = uid("user");
    const got: SystemEvent[] = [];

    const unsub = await bus.subscribe(u, (ev) => got.push(ev));

    // While subscribed, redis lists the channel as active. The pattern is the
    // EXACT channel name (uids contain no glob metacharacters): the shared dev
    // redis may hold OTHER suites' user:* subscriptions, so a `user:*` query
    // would flake — the e2e "drains" assertion made suite-local.
    const during = (await redis.call(
      "PUBSUB",
      "CHANNELS",
      systemChannel(u),
    )) as string[];
    expect(during).toContain(systemChannel(u));

    const first = scheduleEvent("sched-5");
    await bus.publish(u, first);
    await waitFor(() => got.length === 1);

    await unsub();
    await bus.publish(u, scheduleEvent("sched-6"));
    await sleep(200); // give any stray delivery time to arrive
    expect(got).toEqual([first]); // nothing delivered after unsubscribe

    // The subscription is really gone: quit() ended the connection, so the
    // channel no longer has a subscriber.
    const after = (await redis.call(
      "PUBSUB",
      "CHANNELS",
      systemChannel(u),
    )) as string[];
    expect(after).toEqual([]);

    await unsub(); // idempotent: second call must not throw
  });
});
