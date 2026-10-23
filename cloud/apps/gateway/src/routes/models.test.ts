import { describe, expect, it } from "vitest";
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

// GET /cloud/v1/models — the catalog the model picker reads.
//
// The route exists so a client can offer a real choice instead of a static
// "Auto" pill. It must never advertise a model the send route would reject,
// and it must distinguish "no models" from "the catalog could not be read" —
// the second is our problem, not the user's, and must not grey out every
// manual choice.

/** A db stub whose only job is `users.ensure` (one row, tier "free"). */
function dbWithTier(tier: string): Db {
  const row = { uid: "u1", email: null, tier };
  return {
    insert: () => ({
      values: () => ({
        onConflictDoUpdate: () => ({ returning: async () => [row] }),
      }),
    }),
  } as unknown as Db;
}

async function read(
  catalog: (() => Promise<readonly string[] | null>) | undefined,
  tier = "free",
) {
  const app = buildGateway({
    system: stubSystemBus(),
    db: dbWithTier(tier),
    queues: stubQueues().queues,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
    ...(catalog !== undefined ? { modelCatalog: catalog } : {}),
  });
  const response = await app.inject({
    method: "GET",
    url: "/cloud/v1/models",
    headers: authHeaders("u1"),
  });
  return { status: response.statusCode, body: response.json() };
}

describe("GET /cloud/v1/models", () => {
  it("always offers auto, and lists the catalog sorted and deduped", async () => {
    const { status, body } = await read(async () => ["Zeta", "alpha", "alpha", " beta "]);
    expect(status).toBe(200);
    expect(body.auto).toBe("auto");
    expect(body.models).toEqual(["alpha", "beta", "zeta"]);
    expect(body.known).toBe(true);
  });

  it("reports the account tier so the client can gate manual choice", async () => {
    const { body } = await read(async () => ["m"], "plus");
    expect(body.tier).toBe("plus");
  });

  it("says whether the tier may pick a manual model", async () => {
    // The rule lives in plans.ts; the client must not re-derive it from `tier`
    // with its own copy of the table (which is how the web and Flutter clients
    // drifted apart).
    const cases: Array<[string, boolean]> = [
      ["free", false],
      ["go", false],
      ["plus", true],
      ["pro", true],
    ];
    for (const [tier, allowed] of cases) {
      const { body } = await read(async () => ["m"], tier);
      expect(body.manualModelsAllowed, `tier ${tier}`).toBe(allowed);
    }
  });

  it("resolves legacy tier spellings the same way planFor does", async () => {
    // These are the values real `users.tier` rows hold. `3x` is the old Go
    // alias and is auto-only; the paid aliases must not lose manual models.
    const cases: Array<[string, boolean]> = [
      ["3x", false],
      ["7x", true],
      ["15x", true],
      ["max", true],
    ];
    for (const [tier, allowed] of cases) {
      const { body } = await read(async () => ["m"], tier);
      expect(body.manualModelsAllowed, `tier ${tier}`).toBe(allowed);
    }
  });

  it("an unreadable catalog is 'unknown', not 'no models'", async () => {
    const { status, body } = await read(async () => {
      throw new Error("redis down");
    });
    // Still a 200: the picker keeps Auto working and shows no manual list,
    // rather than telling the user their plan has no models.
    expect(status).toBe(200);
    expect(body.models).toEqual([]);
    expect(body.known).toBe(false);
  });

  it("no catalog seam at all is also 'unknown'", async () => {
    const { body } = await read(undefined);
    expect(body.known).toBe(false);
  });

  it("requires authentication", async () => {
    const app = buildGateway({
      system: stubSystemBus(),
      db: dbWithTier("free"),
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    const response = await app.inject({ method: "GET", url: "/cloud/v1/models" });
    expect(response.statusCode).toBe(401);
  });
});
