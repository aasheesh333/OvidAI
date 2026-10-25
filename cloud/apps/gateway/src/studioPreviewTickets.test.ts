import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";

import {
  PREVIEW_COOKIE_NAME,
  PREVIEW_COOKIE_TTL_SECONDS,
  PREVIEW_TICKET_TTL_SECONDS,
  createPreviewCookie,
  createPreviewExchange,
  createPreviewTicketStore,
  parsePreviewCookie,
  type PreviewBinding,
  type PreviewTicketRedis,
  type PreviewTicketStore,
} from "./studioPreviewTickets.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const KEY_PREFIX = `ovid:test:studio-preview:${randomUUID()}:`;
const NOW = new Date("2026-10-24T12:00:00.000Z");
const BINDING: PreviewBinding = {
  userId: "user-1",
  sessionId: "session-1",
  previewId: "preview-1",
  generation: 7,
};

const ticketKey = (ticket: string): string => `${KEY_PREFIX}ticket:${ticket}`;
const cookieKey = (cookieToken: string): string => `${KEY_PREFIX}cookie:${cookieToken}`;

async function deleteIsolatedKeys(redis: Redis): Promise<void> {
  let cursor = "0";
  do {
    const [next, keys] = await redis.scan(
      cursor,
      "MATCH",
      `${KEY_PREFIX}*`,
      "COUNT",
      100,
    );
    if (keys.length > 0) await redis.del(...keys);
    cursor = next;
  } while (cursor !== "0");
}

describe("pure preview cookie and exchange helpers", () => {
  it("serializes the exact host-only secure cookie without a Domain attribute", () => {
    const token = "c".repeat(43);
    expect(PREVIEW_COOKIE_NAME).toBe("__Host-ovid_preview");
    expect(createPreviewCookie(token)).toBe(
      `__Host-ovid_preview=${token}; Secure; HttpOnly; SameSite=Strict; Path=/`,
    );
    expect(createPreviewCookie(token)).not.toContain("Domain=");
  });

  it("accepts one valid preview cookie and rejects duplicates or malformed values", () => {
    const token = "aB0_-".repeat(8) + "aB0";
    expect(token).toHaveLength(43);
    expect(parsePreviewCookie(`theme=dark; __Host-ovid_preview=${token}`)).toBe(token);
    expect(parsePreviewCookie(`__Host-ovid_preview=${token}; __Host-ovid_preview=${token}`)).toBeNull();
    expect(parsePreviewCookie(`ovid_preview=${token}`)).toBeNull();
    expect(parsePreviewCookie("__Host-ovid_preview=not-a-grant")).toBeNull();
    expect(parsePreviewCookie(undefined)).toBeNull();
  });

  it("builds a 303 replace-history exchange whose final target contains no ticket", () => {
    const grant = {
      ...BINDING,
      cookieToken: "d".repeat(43),
      cookieExpiresAt: "2026-10-24T12:15:00.000Z",
    };
    const exchange = createPreviewExchange(grant);
    expect(exchange).toEqual({
      status: 303,
      location: "/preview/preview-1/",
      setCookie: `__Host-ovid_preview=${"d".repeat(43)}; Secure; HttpOnly; SameSite=Strict; Path=/`,
      cacheControl: "private, no-store",
      referrerPolicy: "no-referrer",
      history: "replace",
    });
    expect(exchange.location).not.toContain("ticket=");
    expect(exchange.location).not.toContain("?");
    expect(JSON.stringify(exchange)).not.toContain("one-use-ticket-secret");
  });
});

describe.skipIf(!TEST_REDIS_URL)("PreviewTicketStore against isolated real Redis", () => {
  let redisA: Redis;
  let redisB: Redis;
  let storeA: PreviewTicketStore;
  let storeB: PreviewTicketStore;

  beforeAll(() => {
    redisA = new Redis(TEST_REDIS_URL!);
    redisB = new Redis(TEST_REDIS_URL!);
    storeA = createPreviewTicketStore(redisA, {
      keyPrefix: KEY_PREFIX,
      now: () => NOW,
    });
    storeB = createPreviewTicketStore(redisB, {
      keyPrefix: KEY_PREFIX,
      now: () => NOW,
    });
  });

  afterAll(async () => {
    await deleteIsolatedKeys(redisA);
    redisA.disconnect();
    redisB.disconnect();
  });

  it("mints independent 32-byte grants with exact 60 s and 15 min Redis TTLs", async () => {
    const minted = await storeA.mint(BINDING);
    expect(minted).toEqual({
      ...BINDING,
      ticket: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      cookieToken: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      ticketExpiresAt: "2026-10-24T12:01:00.000Z",
      cookieExpiresAt: "2026-10-24T12:15:00.000Z",
    });
    expect(minted.cookieToken).not.toBe(minted.ticket);
    expect(PREVIEW_TICKET_TTL_SECONDS).toBe(60);
    expect(PREVIEW_COOKIE_TTL_SECONDS).toBe(15 * 60);

    const ticketTtl = await redisA.pttl(ticketKey(minted.ticket));
    const cookieTtl = await redisA.pttl(cookieKey(minted.cookieToken));
    expect(ticketTtl).toBeGreaterThan(0);
    expect(ticketTtl).toBeLessThanOrEqual(60_000);
    expect(cookieTtl).toBeGreaterThan(60_000);
    expect(cookieTtl).toBeLessThanOrEqual(15 * 60_000);
  });

  it("consumes into the matching cookie grant and denies replay", async () => {
    const minted = await storeA.mint(BINDING);
    await expect(storeB.consume(minted.ticket, BINDING)).resolves.toEqual({
      ...BINDING,
      cookieToken: minted.cookieToken,
      cookieExpiresAt: minted.cookieExpiresAt,
    });
    await expect(storeA.consume(minted.ticket, BINDING)).resolves.toBeNull();
    expect(await redisA.exists(ticketKey(minted.ticket))).toBe(0);
  });

  it("has exactly one winner across concurrent consumers", async () => {
    const minted = await storeA.mint(BINDING);
    const replies = await Promise.all(
      Array.from({ length: 32 }, (_, index) =>
        (index % 2 === 0 ? storeA : storeB).consume(minted.ticket, BINDING),
      ),
    );
    expect(replies.filter((reply) => reply !== null)).toHaveLength(1);
    expect(replies.filter((reply) => reply === null)).toHaveLength(31);
  });

  it.each([
    ["user", { ...BINDING, userId: "another-user" }],
    ["session", { ...BINDING, sessionId: "another-session" }],
    ["preview", { ...BINDING, previewId: "another-preview" }],
    ["generation", { ...BINDING, generation: BINDING.generation + 1 }],
  ])("denies a wrong %s binding and cannot be replayed with the right one", async (_field, expected) => {
    const minted = await storeA.mint(BINDING);
    await expect(storeA.consume(minted.ticket, expected)).resolves.toBeNull();
    await expect(storeA.consume(minted.ticket, BINDING)).resolves.toBeNull();
  });

  it("denies an expired ticket", async () => {
    const minted = await storeA.mint(BINDING);
    await redisA.pexpire(ticketKey(minted.ticket), 1);
    await new Promise((resolve) => setTimeout(resolve, 20));
    await expect(storeA.consume(minted.ticket, BINDING)).resolves.toBeNull();
  });

  it("fails closed for unknown, malformed, and corrupt grants", async () => {
    const corruptTicket = "x".repeat(43);
    await redisA.set(ticketKey(corruptTicket), "{not-json", "EX", 60);
    await expect(storeA.consume("missing", BINDING)).resolves.toBeNull();
    await expect(storeA.consume(corruptTicket, BINDING)).resolves.toBeNull();
  });

  it("verifies a cookie against every binding field without consuming it", async () => {
    const minted = await storeA.mint(BINDING);
    await expect(storeA.verifyCookie(minted.cookieToken, BINDING)).resolves.toEqual(BINDING);
    await expect(storeA.verifyCookie(minted.cookieToken, BINDING)).resolves.toEqual(BINDING);
    for (const wrong of [
      { ...BINDING, userId: "another-user" },
      { ...BINDING, sessionId: "another-session" },
      { ...BINDING, previewId: "another-preview" },
      { ...BINDING, generation: BINDING.generation + 1 },
    ]) {
      await expect(storeA.verifyCookie(minted.cookieToken, wrong)).resolves.toBeNull();
    }
  });

  // UNEXECUTED deterministic replacement under HEAVY-COMMANDS-PAUSED (2026-10-25).
  it("never silently slides the cookie grant or refreshes its Redis TTL", async () => {
    const mutations: string[] = [];
    const observedRedis: PreviewTicketRedis = {
      async set(key, value, expiryMode, seconds) {
        mutations.push("SET");
        return redisA.set(key, value, expiryMode, seconds);
      },
      async get(key) {
        return redisA.get(key);
      },
      async call(command, key) {
        mutations.push(command);
        return redisA.call(command, key);
      },
    };
    let clock = new Date(NOW);
    const observedStore = createPreviewTicketStore(observedRedis, {
      keyPrefix: KEY_PREFIX,
      now: () => clock,
    });
    const minted = await observedStore.mint(BINDING);
    const key = cookieKey(minted.cookieToken);
    const storedBefore = await redisA.get(key);
    const pttlBefore = await redisA.pttl(key);
    mutations.length = 0;

    // Verification later in the grant's lifetime must not rewrite its absolute
    // expiry. Equal adjacent PTTL readings are valid; TTL may only decrease.
    clock = new Date(NOW.getTime() + 14 * 60_000);
    await expect(observedStore.verifyCookie(minted.cookieToken, BINDING)).resolves.toEqual(BINDING);
    const storedAfter = await redisA.get(key);
    const pttlAfter = await redisA.pttl(key);
    expect(pttlBefore).toBeGreaterThan(0);
    expect(pttlAfter).toBeGreaterThan(0);
    expect(pttlAfter).toBeLessThanOrEqual(pttlBefore);
    expect(storedAfter).toBe(storedBefore);
    expect(JSON.parse(storedAfter!).cookieExpiresAt).toBe(minted.cookieExpiresAt);
    expect(mutations).toEqual([]);
  });

  it("denies an expired cookie grant", async () => {
    const minted = await storeA.mint(BINDING);
    await redisA.pexpire(cookieKey(minted.cookieToken), 1);
    await new Promise((resolve) => setTimeout(resolve, 20));
    await expect(storeA.verifyCookie(minted.cookieToken, BINDING)).resolves.toBeNull();
  });
});
