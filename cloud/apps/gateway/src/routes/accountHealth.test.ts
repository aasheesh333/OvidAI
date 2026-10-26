import { describe, expect, it, vi } from "vitest";
import { PgDialect } from "drizzle-orm/pg-core";
import type { Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

// GET /cloud/v1/account/health — the Account Health screen's one aggregate.
//
// The screen's whole job is to be true. The server knows the storage ledger,
// the recorded token usage, the ban flag and the deletion row; it does NOT
// know the mint's remaining allowance (that lives in LiteLLM/mint, not in the
// gateway's database). A field the gateway cannot answer is `null` — `0`
// would claim a fact ("nothing left") the server cannot support.

const GIB = 1024 ** 3;
const NOW = new Date("2026-10-19T12:00:00.000Z");

interface FakeOptions {
  tier?: string;
  tierExpiresAt?: Date | null;
  bannedAt?: Date | null;
  bannedReason?: string | null;
  usedBytes?: number;
  today?: Record<string, number | string>;
  month?: Record<string, number | string>;
  deletion?: { uid: string; state: string; deleteAfter: number; record: Record<string, unknown> } | null;
}

const EMPTY_TOTALS = {
  runs: 0,
  model_calls: 0,
  input_tokens: 0,
  output_tokens: 0,
  cache_read_tokens: 0,
  cache_write_tokens: 0,
};

/** A db stub covering exactly the four reads the route performs. */
function fakeDb(opts: FakeOptions = {}) {
  const queries: Array<{ text: string; params: unknown[] }> = [];
  const usageRows = [
    { ...EMPTY_TOTALS, ...(opts.today ?? {}) },
    { ...EMPTY_TOTALS, ...(opts.month ?? {}) },
  ];

  // postgres.js's Sql is a tagged template; runUsage.totals and the vault
  // usage aggregate both call it. The SQL text tells them apart.
  const client = (strings: TemplateStringsArray, ...params: unknown[]): Promise<unknown[]> => {
    const text = strings.join("?");
    queries.push({ text, params });
    if (text.includes("workspace_objects")) {
      return Promise.resolve([{ used_bytes: opts.usedBytes ?? 0 }]);
    }
    return Promise.resolve([usageRows.shift() ?? EMPTY_TOTALS]);
  };

  let lockingUser = false;
  const selectChain = {
    from: () => selectChain,
    where: () => selectChain,
    for: () => {
      lockingUser = true;
      return selectChain;
    },
    limit: async () => {
      if (lockingUser) return [userRow];
      return opts.deletion ? [opts.deletion] : [];
    },
  };

  const userRow = {
    uid: "",
    email: null,
    tier: opts.tier ?? "free",
    tierExpiresAt: opts.tierExpiresAt ?? null,
    bannedAt: opts.bannedAt ?? null,
    bannedReason: opts.bannedReason ?? null,
  };

  const insertChain = {
    values: () => insertChain,
    onConflictDoUpdate: () => insertChain,
    returning: async () => [userRow],
  };

  // The storage read reconciles through drizzle's tx.execute, so record that
  // SQL too (a raw $client-only recorder would miss the workspace_objects
  // scoping query entirely).
  const dialect = new PgDialect();
  const db = {
    $client: client,
    select: () => {
      lockingUser = false;
      return selectChain;
    },
    insert: () => insertChain,
    transaction: async (callback: (tx: unknown) => Promise<unknown>) => callback({
      select: () => {
        lockingUser = false;
        return selectChain;
      },
      execute: async (query: Parameters<PgDialect["sqlToQuery"]>[0]) => {
        const built = dialect.sqlToQuery(query);
        queries.push({ text: built.sql, params: [...built.params] });
        return [{ used_bytes: opts.usedBytes ?? 0, reserved_bytes: 0 }];
      },
    }),
  } as unknown as Db;

  return { db, queries };
}

async function read(opts: FakeOptions = {}, url = "/cloud/v1/account/health", uid = "u1") {
  const { db, queries } = fakeDb(opts);
  const app = buildGateway({
    db,
    queues: stubQueues().queues,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
    system: stubSystemBus(),
    clock: () => NOW,
  });
  const response = await app.inject({
    method: "GET",
    url,
    headers: authHeaders(uid),
  });
  return { status: response.statusCode, body: response.json(), queries };
}

describe("GET /cloud/v1/account/health", () => {
  it("reports storage against the plan quota and the usage it can prove", async () => {
    const { status, body } = await read({
      tier: "pro",
      usedBytes: 5 * GIB,
      today: { runs: 2, model_calls: 3, input_tokens: 1000, output_tokens: 200 },
      month: { runs: 9, model_calls: 12, input_tokens: 8000, output_tokens: 900 },
    });

    expect(status).toBe(200);
    expect(body.plan).toMatchObject({
      tier: "pro",
      id: "pro",
      name: "Ovid Pro",
      expiresAt: null,
      limits: {
        storageBytes: 75 * GIB,
        customConnectors: 20,
        projectFiles: 250,
        manualModels: true,
        autoMultiplier: 20,
        uploads: { count: 80, windowHours: 3 },
      },
    });
    expect(body.storage).toEqual({
      usedBytes: 5 * GIB,
      quotaBytes: 75 * GIB,
      remainingBytes: 70 * GIB,
    });
    expect(body.usage.today.used).toEqual({
      runs: 2,
      modelCalls: 3,
      inputTokens: 1000,
      outputTokens: 200,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      costUsd: null,
    });
    expect(body.usage.month.used.inputTokens).toBe(8000);
    // Token caps are the plan's, and the remaining number is the one the
    // send route enforces — real arithmetic, not null.
    expect(body.usage.today.tokensUsed).toBe(1200);
    expect(body.usage.today.tokenCap).toBe(1_000_000_000); // Pro = 20× Free
    expect(body.usage.today.tokensRemaining).toBe(1_000_000_000 - 1200);
    expect(body.usage.month.tokensUsed).toBe(8900);
    expect(body.usage.month.tokenCap).toBe(30_000_000_000);
    expect(body.usage.month.tokensRemaining).toBe(30_000_000_000 - 8900);
    // The remaining allowance is mint/LiteLLM state; the gateway cannot read
    // it, so it is null — not 0.
    expect(body.usage.today.remainingUsd).toBeNull();
    expect(body.usage.month.remainingUsd).toBeNull();
    expect(body.standing).toEqual({
      banned: false,
      bannedAt: null,
      bannedReason: null,
      multiIpFlags: null,
      deletion: null,
    });
  });

  it("never reports a negative remainder when the account is over quota", async () => {
    const { body } = await read({ tier: "free", usedBytes: 10 * GIB });
    expect(body.storage.quotaBytes).toBe(3 * GIB);
    expect(body.storage.remainingBytes).toBe(0);
  });

  it("recorded zero token counts stay zero while unmeasured cost stays null", async () => {
    // The token ledger was read and had nothing in it. Its measured USD sum
    // is still unknown, so the additive cost field is null rather than zero.
    const { body } = await read({});
    expect(body.usage.today.used).toEqual({
      runs: 0,
      modelCalls: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      costUsd: null,
    });
    expect(body.storage.usedBytes).toBe(0);
  });

  // UNEXECUTED regression while HEAVY-COMMANDS-PAUSED.md is active. Exact DTO
  // assertions keep measured cost, measured zero, and unknown cost distinct.
  it("projects exact measured USD and recorded zero while unknown cost stays null", async () => {
    const measured = await read({
      today: { cost_usd: "0.0000000001" },
      month: { cost_usd: "0.0000000000" },
    });
    expect(measured.body.usage.today.used).toEqual({
      runs: 0,
      modelCalls: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      costUsd: "0.0000000001",
    });
    expect(measured.body.usage.month.used).toEqual({
      runs: 0,
      modelCalls: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      costUsd: "0.0000000000",
    });

    const unknown = await read({});
    expect(unknown.body.usage.today.used.costUsd).toBeNull();
    expect(unknown.body.usage.month.used.costUsd).toBeNull();
  });

  it("reports the Free token caps and counts input + output only", async () => {
    const { body } = await read({
      tier: "free",
      today: {
        input_tokens: 30_000_000,
        output_tokens: 1_000_000,
        cache_read_tokens: 200_000_000,
        cache_write_tokens: 5_000_000,
      },
      month: { input_tokens: 1_400_000_000, output_tokens: 50_000_000 },
    });

    expect(body.usage.today.tokensUsed).toBe(31_000_000);
    expect(body.usage.today.tokenCap).toBe(50_000_000);
    expect(body.usage.today.tokensRemaining).toBe(19_000_000);
    // Cache tokens are reported separately in `used` and never counted twice.
    expect(body.usage.today.used.cacheReadTokens).toBe(200_000_000);
    expect(body.usage.month.tokensUsed).toBe(1_450_000_000);
    expect(body.usage.month.tokenCap).toBe(1_500_000_000);
    expect(body.usage.month.tokensRemaining).toBe(50_000_000);
  });

  it("clamps an exhausted token window to zero remaining, never negative", async () => {
    const { body } = await read({
      tier: "free",
      today: { input_tokens: 60_000_000, output_tokens: 0 },
    });
    expect(body.usage.today.tokensRemaining).toBe(0);
  });

  it("resolves the token cap for a legacy stored tier", async () => {
    const { body } = await read({ tier: "7x" });
    expect(body.usage.today.tokenCap).toBe(250_000_000);
    expect(body.usage.month.tokenCap).toBe(7_500_000_000);
  });

  it("a banned account with a pending deletion says so", async () => {
    const bannedAt = new Date("2026-10-01T08:30:00.000Z");
    const { body } = await read({
      bannedAt,
      bannedReason: "auto",
      deletion: {
        uid: "u1",
        state: "pending",
        deleteAfter: 1_790_000_000,
        record: { request_id: "r1" },
      },
    });

    expect(body.standing).toEqual({
      banned: true,
      bannedAt: bannedAt.toISOString(),
      bannedReason: "auto",
      multiIpFlags: null,
      deletion: {
        state: "pending",
        pending: true,
        deleteAfter: new Date(1_790_000_000_000).toISOString(),
      },
    });
  });

  it("a cancelled deletion is a row but no longer pending", async () => {
    const { body } = await read({
      deletion: { uid: "u1", state: "cancelled", deleteAfter: 1_790_000_000, record: {} },
    });
    expect(body.standing.deletion).toEqual({
      state: "cancelled",
      pending: false,
      deleteAfter: new Date(1_790_000_000_000).toISOString(),
    });
  });

  it("resolves a legacy stored tier to the plan it means", async () => {
    const { body } = await read({ tier: "7x" });
    expect(body.plan).toMatchObject({
      tier: "7x",
      id: "plus",
      name: "Ovid Plus",
      limits: { storageBytes: 15 * GIB },
    });
  });

  it("only reads the caller's rows, ignoring a uid in the query string", async () => {
    const { queries } = await read({ usedBytes: 1 }, "/cloud/v1/account/health?uid=someone-else");
    expect(queries.length).toBeGreaterThanOrEqual(3);
    for (const q of queries) {
      expect(q.params).toContain("u1");
      expect(q.params).not.toContain("someone-else");
    }
    const storage = queries.find((q) => q.text.includes("workspace_objects"));
    expect(storage?.text).toContain("user_id");
  });

  it("buckets today at the caller's UTC offset", async () => {
    // 2026-10-19T12:00Z is 2026-10-20 00:30 at +12:30, so "today" starts at
    // 2026-10-19T11:30Z and "this month" at 2026-10-01T00:00+12:30.
    const { status, body, queries } = await read(
      {},
      "/cloud/v1/account/health?utcOffsetMinutes=750",
    );
    expect(status).toBe(200);
    const usage = queries.filter((q) => q.text.includes("run_usage"));
    expect(usage).toHaveLength(2);
    expect(usage[0]!.params[1]).toBe("2026-10-19T11:30:00.000Z");
    expect(usage[1]!.params[1]).toBe("2026-09-30T11:30:00.000Z");
    expect(body.usage.today.until).toBe(NOW.toISOString());
  });

  it("rejects an impossible UTC offset instead of guessing", async () => {
    const { status, body } = await read({}, "/cloud/v1/account/health?utcOffsetMinutes=999");
    expect(status).toBe(400);
    expect(body.error.code).toBe("bad_request");
  });

  it("exposes mint's canonical entitlement verbatim instead of the stale stored tier", async () => {
    const entitlement = {
      tier: "plus",
      productId: "ovid_pro_yearly",
      period: "yearly",
      expiresAt: 1_900_000_000,
      autoRenewing: false,
      purchaseState: "cancelled",
    };
    const originalFetch = globalThis.fetch;
    const originalUrl = process.env.OVID_INTERNAL_MINT_URL;
    const originalSecret = process.env.OVID_INTERNAL_API_SECRET;
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ entitlement }), {
      status: 200,
      headers: { "content-type": "application/json" },
    }));
    process.env.OVID_INTERNAL_MINT_URL = "http://mint:8092";
    process.env.OVID_INTERNAL_API_SECRET = "test-internal-secret-0123456789abcdef";
    vi.stubGlobal("fetch", fetchImpl);
    try {
      const { status, body } = await read({ tier: "pro" });
      expect(status).toBe(200);
      expect(body.entitlement).toEqual(entitlement);
      expect(body.plan).toMatchObject({
        tier: "plus",
        id: "plus",
        name: "Ovid Plus",
        expiresAt: new Date(entitlement.expiresAt * 1000).toISOString(),
        limits: { storageBytes: 15 * GIB },
      });
      expect(fetchImpl).toHaveBeenCalledOnce();
      const [url, init] = fetchImpl.mock.calls[0]! as unknown as [string, RequestInit];
      expect(url).toContain("/internal/billing/entitlement?uid=u1");
      expect(init.method).toBe("GET");
      expect(init.body).toBeUndefined();
    } finally {
      if (originalUrl === undefined) delete process.env.OVID_INTERNAL_MINT_URL;
      else process.env.OVID_INTERNAL_MINT_URL = originalUrl;
      if (originalSecret === undefined) delete process.env.OVID_INTERNAL_API_SECRET;
      else process.env.OVID_INTERNAL_API_SECRET = originalSecret;
      vi.stubGlobal("fetch", originalFetch);
    }
  });

  it("requires authentication", async () => {
    const { db } = fakeDb();
    const app = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
    });
    const response = await app.inject({ method: "GET", url: "/cloud/v1/account/health" });
    expect(response.statusCode).toBe(401);
  });
});
