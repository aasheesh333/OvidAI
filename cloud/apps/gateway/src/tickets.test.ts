import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import { createTicketStore, TICKET_TTL_SECONDS, type TicketStore } from "./tickets.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const ticketKey = (ticket: string): string => `ws:ticket:${ticket}`;

describe.skipIf(!TEST_REDIS_URL)("ticketStore against real redis", () => {
  let redis: Redis;
  let store: TicketStore;
  // Every ticket this suite mints, so afterAll can delete exactly the keys
  // it created (shared dev redis — FLUSHDB is forbidden; consumed tickets
  // are already gone, DEL on a missing key is a no-op).
  const minted: string[] = [];

  async function mint(uid: string): Promise<string> {
    const ticket = await store.mint(uid);
    minted.push(ticket);
    return ticket;
  }

  beforeAll(() => {
    redis = new Redis(TEST_REDIS_URL!);
    store = createTicketStore(redis);
  });

  afterAll(async () => {
    if (minted.length > 0) {
      await redis.del(minted.map(ticketKey));
    }
    redis.disconnect();
  });

  it("mint → verify round-trips the uid", async () => {
    const ticket = await mint("user-roundtrip");
    // ≥32 bytes of entropy, base64url alphabet (32 bytes → 43 chars, no padding).
    expect(ticket).toMatch(/^[A-Za-z0-9_-]{43,}$/);
    await expect(store.verify(ticket)).resolves.toEqual({
      uid: "user-roundtrip",
    });
  });

  it("a ticket is single-use: second verify → null", async () => {
    const ticket = await mint("user-single");
    await expect(store.verify(ticket)).resolves.toEqual({ uid: "user-single" });
    await expect(store.verify(ticket)).resolves.toBeNull();
    // Key is gone from redis, not just masked by the store.
    expect(await redis.exists(ticketKey(ticket))).toBe(0);
  });

  it("verify of an unknown ticket → null", async () => {
    await expect(
      store.verify("not-a-ticket-anyone-ever-minted"),
    ).resolves.toBeNull();
  });

  it("mint stores the uid under ws:ticket:{t} with a TTL of at most 60s", async () => {
    const ticket = await mint("user-ttl");
    expect(await redis.get(ticketKey(ticket))).toBe("user-ttl");
    const pttl = await redis.pttl(ticketKey(ticket));
    expect(pttl).toBeGreaterThan(0);
    expect(pttl).toBeLessThanOrEqual(TICKET_TTL_SECONDS * 1000);
    expect(pttl).toBeLessThanOrEqual(60_000);
  });

  it("concurrent verify of the same ticket resolves exactly one winner", async () => {
    const ticket = await mint("user-race");
    const results = await Promise.all([
      store.verify(ticket),
      store.verify(ticket),
    ]);
    const winners = results.filter((r) => r !== null);
    const losers = results.filter((r) => r === null);
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(winners[0]).toEqual({ uid: "user-race" });
  });

  it("minted tickets are unique", async () => {
    const a = await mint("user-uniq");
    const b = await mint("user-uniq");
    expect(a).not.toBe(b);
  });
});
