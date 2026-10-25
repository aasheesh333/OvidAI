import { describe, expect, it, vi } from "vitest";
import { verifyInternalRequest } from "@ovid/shared";
import {
  BILLING_ENTITLEMENT_PATH,
  createBillingEntitlementClient,
  type BillingEntitlement,
} from "./plans.js";
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

// GET /cloud/v1/plans — the plan screen's data.
//
// The web plan screen carried its own hard-coded copy of the plans, so it
// advertised prices and allowances the server did not bill (it claimed "50M
// tokens a day" while the gateway enforces a USD allowance). This route is
// the one place the screen can read them from.
//
// Two rules it must keep:
//   - the live table wins: an owner editing a price in /admin must change
//     what the screen shows;
//   - a plan the product does not describe renders "unknown", never 0 — a
//     zero would claim a storage limit of nothing.

/** A db stub whose only job is `plansRepo.list` (select → from → orderBy). */
function dbWithPlans(rows: Array<Record<string, unknown>>): Db {
  const chain = {
    from: () => chain,
    orderBy: async () => rows,
  };
  return { select: () => chain } as unknown as Db;
}

function planRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "free",
    name: "Free",
    priceUsd: "0",
    enabled: true,
    aliases: [],
    windowHours: 24,
    mult: "1",
    slowMode: false,
    autoOss: false,
    position: 0,
    ...overrides,
  };
}

async function read(rows: Array<Record<string, unknown>>) {
  const app = buildGateway({
    system: stubSystemBus(),
    db: dbWithPlans(rows),
    queues: stubQueues().queues,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
  });
  const response = await app.inject({
    method: "GET",
    url: "/cloud/v1/plans",
    headers: authHeaders("u1"),
  });
  return { status: response.statusCode, body: response.json() };
}

describe("GET /cloud/v1/plans", () => {
  it("returns the live table in position order, with the product's limits merged in", async () => {
    const { status, body } = await read([
      planRow(),
      planRow({ id: "go", name: "Ovid Go", priceUsd: "5", mult: "1.5", aliases: ["starter", "3x"], position: 1 }),
      planRow({ id: "plus", name: "Ovid Plus", priceUsd: "18", mult: "5", aliases: ["7x"], autoOss: true, position: 2 }),
      planRow({ id: "pro", name: "Ovid Pro", priceUsd: "99", mult: "20", aliases: ["max", "15x"], autoOss: true, position: 3 }),
    ]);

    expect(status).toBe(200);
    expect(body.plans.map((p: any) => [p.id, p.name, p.priceUsd, p.mult])).toEqual([
      ["free", "Free", 0, 1],
      ["go", "Ovid Go", 5, 1.5],
      ["plus", "Ovid Plus", 18, 5],
      ["pro", "Ovid Pro", 99, 20],
    ]);
    expect(body.plans.map((p: any) => [p.storageGb, p.manualModels, p.customConnectors, p.projectFiles])).toEqual([
      [3, false, 0, 80],
      [5, false, 5, 100],
      [15, true, 20, 150],
      [75, true, 20, 250],
    ]);
    // The store charges these in rupees in India. They are the product's
    // prices, not a conversion of the dollar ones.
    expect(body.plans.map((p: any) => p.priceInr)).toEqual([0, 499, 1799, 9999]);
    expect(body.plans[0].uploads).toEqual({ count: 50, windowHours: 24 });
  });

  it("shows an admin's edit, not the seed", async () => {
    const { body } = await read([
      planRow(),
      planRow({ id: "go", name: "Go Annual", priceUsd: "42", mult: "2", aliases: [], position: 1 }),
    ]);
    expect(body.plans[1]).toMatchObject({ name: "Go Annual", priceUsd: 42, mult: 2 });
  });

  it("hides a disabled plan — disabled means stop selling", async () => {
    const { body } = await read([
      planRow(),
      planRow({ id: "go", enabled: false, position: 1 }),
      planRow({ id: "pro", position: 2 }),
    ]);
    expect(body.plans.map((p: any) => p.id)).toEqual(["free", "pro"]);
  });

  it("reports unknown limits as null, never as 0", async () => {
    // A plan the product table does not describe (an owner-created "team"
    // plan) has no storage or connector limits on the server, so the screen
    // must be able to tell "not known" apart from "none".
    const { body } = await read([
      planRow(),
      planRow({ id: "team", name: "Team", priceUsd: "120", mult: "40", aliases: [], position: 1 }),
    ]);
    expect(body.plans[1]).toMatchObject({
      id: "team",
      storageGb: null,
      customConnectors: null,
      projectFiles: null,
      manualModels: null,
      uploads: null,
    });
  });

  it("resolves a legacy plan id to the tier it means", async () => {
    // Rows seeded before the ids were aligned carry `starter` / `max`.
    const { body } = await read([
      planRow(),
      planRow({ id: "starter", name: "Starter", priceUsd: "5", mult: "1.5", aliases: ["3x"], position: 1 }),
    ]);
    expect(body.plans[1]).toMatchObject({ id: "starter", tier: "go", storageGb: 5, projectFiles: 100 });
  });
});

describe("read-only mint billing entitlement client", () => {
  const entitlement: BillingEntitlement = {
    tier: "plus",
    productId: "ovid_pro_yearly",
    period: "yearly",
    expiresAt: 1_900_000_000,
    autoRenewing: false,
    purchaseState: "cancelled",
  };

  it("signs a GET for the verified uid and returns mint's value verbatim", async () => {
    const now = 1_800_000_000;
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ entitlement }), {
      status: 200,
      headers: { "content-type": "application/json" },
    }));
    const client = createBillingEntitlementClient({
      baseUrl: "http://mint:8092/",
      secret: "test-internal-secret-0123456789abcdef",
      fetchImpl: fetchImpl as typeof fetch,
      clock: () => now,
    });
    expect(await client.entitlement("u1")).toEqual(entitlement);
    expect(fetchImpl).toHaveBeenCalledOnce();
    const [url, init] = fetchImpl.mock.calls[0]! as unknown as [string, RequestInit];
    expect(url).toBe(`http://mint:8092${BILLING_ENTITLEMENT_PATH}?uid=u1`);
    expect(init.method).toBe("GET");
    expect(init.body).toBeUndefined();
    const headers = init.headers as Record<string, string>;
    expect(verifyInternalRequest(
      "test-internal-secret-0123456789abcdef",
      "GET",
      BILLING_ENTITLEMENT_PATH,
      "u1",
      headers["X-Ovid-Timestamp"]!,
      headers["X-Ovid-Signature"]!,
      now,
    )).toBe(true);
  });

  it("is unavailable without configuration and never makes a store or network call", async () => {
    const fetchImpl = vi.fn();
    const client = createBillingEntitlementClient({
      baseUrl: "",
      secret: "",
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    expect(await client.entitlement("u1")).toBeNull();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("does not infer a tier from malformed or non-authoritative response text", async () => {
    const client = createBillingEntitlementClient({
      baseUrl: "http://mint:8092",
      secret: "test-internal-secret-0123456789abcdef",
      fetchImpl: async () => new Response(JSON.stringify({
        entitlement: { ...entitlement, tier: "whale", price: 999 },
      }), { status: 200 }),
    });
    expect(await client.entitlement("u1")).toBeNull();
  });
});
