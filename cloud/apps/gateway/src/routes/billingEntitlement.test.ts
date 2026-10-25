// UNEXECUTED while /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md
// is active. These are source-only route contracts, not passing-test evidence.

import Fastify, { type FastifyInstance } from "fastify";
import { afterEach, describe, expect, it, vi } from "vitest";
import { verifyInternalRequest } from "@ovid/shared";
import { authHook } from "../auth.js";
import { authHeaders, stubVerifier } from "../test/stubs.js";
import { registerBillingEntitlementRoutes } from "./billingEntitlement.js";
import { BILLING_ENTITLEMENT_PATH } from "./plans.js";

const PATH = "/cloud/v1/billing/entitlement";
const SECRET = "test-internal-secret-0123456789abcdef";
const EXPIRES_AT = 1_893_456_000.125;
const EXPIRES_AT_ISO = "2030-01-01T00:00:00.125Z";

const ACTIVE = {
  tier: "plus",
  productId: "ovid_pro_yearly",
  period: "yearly",
  expiresAt: EXPIRES_AT,
  autoRenewing: true,
  purchaseState: "active",
} as const;

const apps: FastifyInstance[] = [];

afterEach(async () => {
  try {
    for (const app of apps.splice(0)) await app.close();
  } finally {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  }
});

async function get(url = PATH, headers: Record<string, string> | null = authHeaders("u1")) {
  const app = Fastify();
  apps.push(app);
  await app.register(async (scope) => {
    // This is the same verified-principal boundary used by the gateway's
    // authenticated /cloud/v1 scope. The route module does not self-authenticate.
    scope.addHook("onRequest", authHook(stubVerifier()));
    registerBillingEntitlementRoutes(scope);
  }, { prefix: "/cloud/v1" });
  return app.inject({
    method: "GET",
    url,
    ...(headers === null ? {} : { headers }),
  });
}

function configure(fetchImpl: unknown): void {
  vi.stubEnv("OVID_INTERNAL_MINT_URL", "http://mint:8092");
  vi.stubEnv("OVID_INTERNAL_API_SECRET", SECRET);
  vi.stubGlobal("fetch", fetchImpl);
}

function mintFetch(body: unknown, status = 200) {
  return vi.fn(async () => new Response(
    typeof body === "string" ? body : JSON.stringify(body),
    { status, headers: { "content-type": "application/json" } },
  ));
}

function entitlement(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...ACTIVE, ...overrides };
}

function expectUnavailable(response: any): void {
  expect(response.statusCode).toBe(503);
  expect(response.headers["cache-control"]).toBe("no-store");
  expect(response.json()).toEqual({
    error: { code: "unavailable", message: "Billing entitlement is unavailable." },
  });
  expect(response.json()).not.toHaveProperty("entitlement");
}

describe("GET /cloud/v1/billing/entitlement", () => {
  it("returns the exact Flutter DTO and signs only the verified principal's fresh mint read", async () => {
    const fetchImpl = mintFetch({
      entitlement: entitlement({ futureEntitlementField: "additive-v2" }),
    });
    configure(fetchImpl);

    const response = await get(`${PATH}?uid=someone-else`);

    expect(response.statusCode).toBe(200);
    expect(response.headers["cache-control"]).toBe("no-store");
    expect(response.json()).toEqual({
      entitlement: {
        tier: "plus",
        productId: "ovid_pro_yearly",
        period: "yearly",
        expiresAt: EXPIRES_AT_ISO,
        autoRenewing: true,
        purchaseState: "active",
      },
    });
    expect(fetchImpl).toHaveBeenCalledOnce();
    const [url, init] = fetchImpl.mock.calls[0]! as unknown as [string, RequestInit];
    expect(url).toBe(`http://mint:8092${BILLING_ENTITLEMENT_PATH}?uid=u1`);
    expect(url).not.toContain("someone-else");
    expect(init.method).toBe("GET");
    expect(init.body).toBeUndefined();
    expect(init.headers).toMatchObject({ "cache-control": "no-store" });

    const headers = init.headers as Record<string, string>;
    const timestamp = Number(Buffer.from(headers["X-Ovid-Timestamp"]!, "base64").toString("utf8"));
    expect(verifyInternalRequest(
      SECRET,
      "GET",
      BILLING_ENTITLEMENT_PATH,
      "u1",
      headers["X-Ovid-Timestamp"]!,
      headers["X-Ovid-Signature"]!,
      timestamp,
    )).toBe(true);
    expect(verifyInternalRequest(
      SECRET,
      "GET",
      BILLING_ENTITLEMENT_PATH,
      "someone-else",
      headers["X-Ovid-Timestamp"]!,
      headers["X-Ovid-Signature"]!,
      timestamp,
    )).toBe(false);
  });

  it.each([
    ["go", "ovid_plus_monthly", "monthly"],
    ["go", "ovid_plus_yearly", "yearly"],
    ["plus", "ovid_pro_monthly", "monthly"],
    ["plus", "ovid_pro_yearly", "yearly"],
    ["pro", "ovid_max_monthly", "monthly"],
    ["pro", "ovid_max_yearly", "yearly"],
  ] as const)("accepts the exact %s / %s / %s product mapping", async (tier, productId, period) => {
    configure(mintFetch({ entitlement: entitlement({ tier, productId, period }) }));
    const response = await get();
    expect(response.statusCode).toBe(200);
    expect(response.json().entitlement).toMatchObject({ tier, productId, period });
  });

  it("projects mint's terminal Free row without inventing a paid tier from its historical product", async () => {
    configure(mintFetch({
      entitlement: entitlement({
        tier: "free",
        productId: "ovid_pro_monthly",
        period: "monthly",
        expiresAt: 1_792_800_000,
        autoRenewing: false,
        purchaseState: "refunded",
      }),
    }));

    const response = await get();

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      entitlement: {
        tier: "free",
        productId: null,
        period: null,
        expiresAt: "2026-10-24T00:00:00.000Z",
        autoRenewing: false,
        purchaseState: "refunded",
      },
    });
  });

  it("preserves a stale expiry instead of hiding it or inferring Free; Flutter's isActiveAt rejects it", async () => {
    configure(mintFetch({
      entitlement: entitlement({
        tier: "go",
        productId: "ovid_plus_monthly",
        period: "monthly",
        expiresAt: 1_792_800_000,
        autoRenewing: false,
      }),
    }));

    const response = await get();

    expect(response.statusCode).toBe(200);
    expect(response.json().entitlement).toEqual({
      tier: "go",
      productId: "ovid_plus_monthly",
      period: "monthly",
      expiresAt: "2026-10-24T00:00:00.000Z",
      autoRenewing: false,
      purchaseState: "active",
    });
    expect(Date.parse(response.json().entitlement.expiresAt)).toBeLessThan(Date.parse("2026-10-25T00:00:00.000Z"));
  });

  it.each([
    ["unknown tier", entitlement({ tier: "whale" })],
    ["empty product", entitlement({ productId: "" })],
    ["unknown product", entitlement({ productId: "ovid_unknown_yearly" })],
    ["tier/product mismatch", entitlement({ productId: "ovid_max_yearly" })],
    ["period/product mismatch", entitlement({ period: "monthly" })],
    ["missing paid product", entitlement({ productId: null, period: null })],
    ["missing product period", entitlement({ period: null })],
    ["period without product", entitlement({
      tier: "free",
      productId: null,
      autoRenewing: false,
      purchaseState: "refunded",
    })],
    ["active paid without expiry", entitlement({ expiresAt: null })],
    ["unrepresentable expiry", entitlement({ expiresAt: 1e100 })],
    ["active Free contradiction", entitlement({
      tier: "free",
      productId: null,
      period: null,
      expiresAt: null,
      autoRenewing: false,
    })],
    ["terminal Free historical period mismatch", entitlement({
      tier: "free",
      period: "monthly",
      autoRenewing: false,
      purchaseState: "refunded",
    })],
    ["renewing terminal contradiction", entitlement({ purchaseState: "refunded" })],
    ["unknown purchase state", entitlement({ purchaseState: "sometimes" })],
    ["wrong renewal type", entitlement({ autoRenewing: "yes" })],
  ])("returns unavailable for malformed authority: %s", async (_name, value) => {
    configure(mintFetch({ entitlement: value }));
    expectUnavailable(await get());
  });

  it("keeps mint's unknown verdict unknown, including its empty Free/unknown placeholder", async () => {
    configure(mintFetch({
      entitlement: {
        tier: "free",
        productId: null,
        period: null,
        expiresAt: null,
        autoRenewing: false,
        purchaseState: "unknown",
      },
    }));
    expectUnavailable(await get());
  });

  it("is unavailable without configuration and performs no network or store read", async () => {
    const fetchImpl = vi.fn();
    vi.stubEnv("OVID_INTERNAL_MINT_URL", "");
    vi.stubEnv("OVID_INTERNAL_API_SECRET", "");
    vi.stubGlobal("fetch", fetchImpl);

    expectUnavailable(await get());
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("does not infer a tier from a non-2xx mint response", async () => {
    configure(mintFetch({ entitlement: ACTIVE }, 503));
    expectUnavailable(await get());
  });

  it("does not infer a tier from a failed or malformed mint read", async () => {
    configure(vi.fn(async () => { throw new Error("mint unreachable"); }));
    expectUnavailable(await get());

    configure(mintFetch("not-json"));
    expectUnavailable(await get());

    configure(mintFetch({ totals: { runs: 9 } }));
    expectUnavailable(await get());
  });

  it("requires authentication before any mint read", async () => {
    const fetchImpl = mintFetch({ entitlement: ACTIVE });
    configure(fetchImpl);

    const response = await get(PATH, null);

    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("unauthenticated");
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});
