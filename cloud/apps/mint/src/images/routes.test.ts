import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import { Decimal } from "decimal.js";
import { discounted, exactSum, money, type Money } from "@ovid/money";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintDeps } from "../app.js";
import { HttpContractError } from "../app.js";
import { registerMintRoutes } from "../mintRoutes.js";
import { resetModelCatalogProjectionForTests } from "../catalog.js";
import { defaultCard } from "./capabilities.js";
import type { LiteLlmAdmin } from "../litellmAdmin.js";
import type { MintEnv } from "../env.js";
import { createAdmission } from "./admission.js";
import { createDirectEdit } from "./directEdit.js";
import type { ImageLedger, ImageLedgerOptions } from "./ledger.js";
import {
  LiteLlmImageService,
  IMAGE_BODY_LIMIT,
  legacyCard,
  missing,
  taskFromRequest,
  type ImageBackend,
  type ImageCard,
  type ImageTask,
} from "./service.js";
import { registerImagesRoutes } from "./routes.js";
import { ImageError, RECEIPT_RETENTION, REPLAY_RETENTION, type Receipt } from "./types.js";

/**
 * HTTP surface port of test_verifier.py, test_gateway_admission.py,
 * test_gateway_capability_routing.py and wave2_cleanup_images_test.py.
 *
 * The ledger is an in-memory exact-decimal fake (the real Postgres ledger is
 * Task 12's subject) so these tests prove the gateway's money contract:
 * reservation = discounted(bound), exact discounted settlement, terminal
 * failure receipts, zero-quota receipt/result reads, and replay.
 */

const PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const PNG_BYTES = Buffer.from(PNG_B64, "base64");

const HEADERS = {
  authorization: "Bearer token",
  "x-ovid-key": "sk-user",
  "idempotency-key": "request-1234",
};

const GEN_BODY = { model: "ovid-image", prompt: "a square", size: "1024x1024" };
const EDIT_BODY = {
  ...GEN_BODY,
  image: `data:image/png;base64,${PNG_B64}`,
};

interface Row {
  account: string;
  request: string;
  fingerprint: string;
  state: "pending" | "unknown" | "done" | "failed";
  reserved: string;
  charged: string;
  window: string;
  response?: Record<string, unknown>;
  replayUntil?: number;
  receiptUntil?: number;
  servedModel?: string;
}

class FakeLedger implements ImageLedger {
  readonly rows = new Map<string, Row>();
  readonly deleted = new Set<string>();
  now = 1_000;

  constructor(private readonly opts: ImageLedgerOptions = {}) {
    this.now = opts.clock?.() ?? this.now;
  }

  private key(account: string, request: string): string {
    return `${account}\u0000${request}`;
  }

  private receiptOf(row: Row): Receipt {
    const receipt: Receipt = {
      account_id: row.account,
      request_id: row.request,
      fingerprint: row.fingerprint,
      state: row.state === "done" ? "confirmed" : row.state,
      charged: row.state === "done" || row.state === "failed" ? row.charged : null,
    };
    if (row.servedModel) receipt.model = row.servedModel;
    return receipt;
  }

  private responseOf(row: Row): Record<string, unknown> {
    if (row.response === undefined || row.replayUntil === undefined || this.now >= row.replayUntil) {
      const receipt =
        row.receiptUntil === undefined || this.now < row.receiptUntil ? this.receiptOf(row) : null;
      throw new ImageError(410, "image_replay_expired", { receipt });
    }
    return { ...row.response, receipt: this.receiptOf(row) };
  }

  async begin(
    account: string,
    request: string,
    fingerprint: string,
    reservation: Money,
    budget: Money,
    budgetWindow: string,
  ): Promise<Record<string, unknown> | null> {
    if (this.deleted.has(account)) throw new ImageError(410, "image_account_deleted");
    const existing = this.rows.get(this.key(account, request));
    if (existing !== undefined) {
      if (existing.fingerprint !== fingerprint) throw new ImageError(409, "idempotency_conflict");
      if (existing.state === "done") return this.responseOf(existing);
      if (existing.receiptUntil !== undefined && this.now >= existing.receiptUntil) {
        throw new ImageError(410, "image_receipt_expired");
      }
      throw new ImageError(
        409,
        existing.state === "pending" || existing.state === "unknown"
          ? "image_request_pending"
          : "image_request_failed",
        { receipt: this.receiptOf(existing) },
      );
    }
    const spent = exactSum(
      [...this.rows.values()]
        .filter(
          (row) =>
            row.account === account &&
            (row.window === budgetWindow || row.state === "pending" || row.state === "unknown"),
        )
        .map((row) => money(row.state === "pending" || row.state === "unknown" ? row.reserved : row.charged)),
    );
    if (spent.plus(reservation).greaterThan(budget)) {
      throw new ImageError(402, "image_limit_reached");
    }
    this.rows.set(this.key(account, request), {
      account,
      request,
      fingerprint,
      state: "pending",
      reserved: reservation.toString(),
      charged: "0",
      window: budgetWindow,
    });
    return null;
  }

  async settle(
    account: string,
    request: string,
    actual: Money,
    response: Record<string, unknown>,
    servedModel: string | null = null,
  ): Promise<Record<string, unknown>> {
    const row = this.rows.get(this.key(account, request));
    if (row === undefined) throw new ImageError(404, "image_request_not_found");
    if (row.state === "done") {
      if (this.deleted.has(account)) throw new ImageError(410, "image_account_deleted");
      return this.responseOf(row);
    }
    if (row.state !== "pending" && row.state !== "unknown") {
      throw new ImageError(409, "image_request_failed", { receipt: this.receiptOf(row) });
    }
    row.state = "done";
    row.charged = discounted(actual).toString();
    row.response = response;
    row.servedModel = servedModel ?? undefined;
    row.replayUntil = this.now + (this.opts.replayRetention ?? REPLAY_RETENTION);
    row.receiptUntil = this.now + (this.opts.receiptRetention ?? RECEIPT_RETENTION);
    return this.responseOf(row);
  }

  async unknown(account: string, request: string): Promise<void> {
    const row = this.rows.get(this.key(account, request));
    if (row?.state === "pending") row.state = "unknown";
  }

  async fail(account: string, request: string): Promise<void> {
    const row = this.rows.get(this.key(account, request));
    if (row?.state === "pending") {
      row.state = "failed";
      row.reserved = "0";
      row.receiptUntil = this.now + (this.opts.receiptRetention ?? RECEIPT_RETENTION);
    }
  }

  async receipt(account: string, request: string): Promise<Receipt> {
    if (this.deleted.has(account)) throw new ImageError(410, "image_account_deleted");
    const row = this.rows.get(this.key(account, request));
    if (row === undefined) throw new ImageError(404, "image_request_not_found");
    if (row.receiptUntil !== undefined && this.now >= row.receiptUntil) {
      throw new ImageError(410, "image_receipt_expired");
    }
    return this.receiptOf(row);
  }

  async replay(account: string, request: string): Promise<Record<string, unknown>> {
    if (this.deleted.has(account)) throw new ImageError(410, "image_account_deleted");
    const row = this.rows.get(this.key(account, request));
    if (row === undefined) throw new ImageError(404, "image_request_not_found");
    if (row.receiptUntil !== undefined && this.now >= row.receiptUntil) {
      throw new ImageError(410, "image_receipt_expired");
    }
    if (row.state !== "done") {
      throw new ImageError(
        409,
        row.state === "pending" || row.state === "unknown"
          ? "image_request_pending"
          : "image_request_failed",
        { receipt: this.receiptOf(row) },
      );
    }
    return this.responseOf(row);
  }

  async spent(
    account: string,
    opts: { includePending?: boolean; budgetWindow?: string | null } = {},
  ): Promise<Money> {
    return exactSum(
      [...this.rows.values()]
        .filter(
          (row) =>
            row.account === account &&
            (opts.budgetWindow === undefined ||
              opts.budgetWindow === null ||
              row.window === opts.budgetWindow),
        )
        .map((row) =>
          money(
            opts.includePending === true &&
              (row.state === "pending" || row.state === "unknown")
              ? row.reserved
              : row.charged,
          ),
        ),
    );
  }

  async purgeExpired(): Promise<number> {
    return 0;
  }

  async deleteAccount(account: string): Promise<void> {
    this.deleted.add(account);
  }

  expireReplay(account: string, request: string): void {
    const row = this.rows.get(this.key(account, request));
    if (row !== undefined) row.replayUntil = 0;
  }

  expireReceipt(account: string, request: string): void {
    const row = this.rows.get(this.key(account, request));
    if (row !== undefined) row.receiptUntil = 0;
  }
}

interface Call {
  url: string;
  path: string;
  model: string;
  body: unknown;
}

type Handler = (call: Call, index: number) => Response | Promise<Response>;

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function successResponse(cost = "0.10"): Response {
  return jsonResponse(
    200,
    { data: [{ b64_json: PNG_B64 }], usage: {} },
    { "x-litellm-response-cost": cost },
  );
}

function makeFetch(handler: Handler): { fetchImpl: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const parsed = new URL(url);
    let body: unknown = undefined;
    if (typeof init?.body === "string") {
      try {
        body = JSON.parse(init.body);
      } catch {
        body = init.body;
      }
    }
    const model = String((body as { model?: unknown } | undefined)?.model ?? "");
    const call: Call = { url, path: parsed.pathname, model, body };
    calls.push(call);
    return handler(call, calls.length - 1);
  }) as typeof fetch;
  return { fetchImpl, calls };
}

const DEFAULT_BACKENDS: ImageBackend[] = [
  { model: "image-a", sizes: ["1024x1024"], edit: true },
  { model: "image-b", sizes: ["1024x1024"], edit: true },
];

function makeDeps(): {
  deps: MintDeps;
  keyInfo: { value: Record<string, unknown> };
  redis: Map<string, string>;
} {
  const redis = new Map<string, string>([
    ["user:u:key", "sk-user"],
    ["user:u:keyid", "key-id"],
  ]);
  const keyInfo = {
    value: {
      user_id: "u",
      metadata: { ovid_uid: "u" },
      models: ["ovid-image"],
    } as Record<string, unknown>,
  };
  const litellm = {
    keyInfoStatus: async () => ({ status: 200, info: keyInfo.value }),
    keyInfo: async () => keyInfo.value,
    rawModels: async () => ({ status: 200, body: { data: [] }, text: "" }),
  } as unknown as LiteLlmAdmin;
  const deps = {
    db: {} as unknown as Db,
    redis: {
      get: async (key: string) => redis.get(key) ?? null,
    } as unknown as Redis,
    litellm,
    env: { appcheckEnabled: false } as unknown as MintEnv,
    alerter: async () => {},
    verifyIdentity: async ({ authorization }: { authorization: string }) => {
      const token = authorization.replace(/^bearer\s+/i, "");
      if (token !== "token") throw new HttpContractError(401, "invalid id token");
      return { uid: "u", email: null, platform: "android" as const };
    },
  } as MintDeps;
  return { deps, keyInfo, redis };
}

interface Harness {
  app: FastifyInstance;
  ledger: FakeLedger;
  service: LiteLlmImageService | null;
  calls: Call[];
  state: { freeCap: number; keySpend: number; admissionCalls: number };
  clock: { now: number };
  deps: MintDeps;
  keyInfo: { value: Record<string, unknown> };
  redis: Map<string, string>;
}

async function makeHarness(
  handler: Handler,
  opts: {
    backends?: ImageBackend[];
    cards?: ImageCard[];
    directEdit?: ReturnType<typeof createDirectEdit> | null;
    clock?: () => number;
    service?: LiteLlmImageService | null;
    admission?: boolean;
    extraRoutes?: (app: FastifyInstance, deps: MintDeps) => void;
  } = {},
): Promise<Harness> {
  const { deps, keyInfo, redis } = makeDeps();
  const ledger = new FakeLedger();
  const clock = { now: 1_000 };
  const clockFn = opts.clock ?? (() => clock.now);
  const { fetchImpl, calls } = makeFetch(handler);
  const service =
    opts.service === undefined
      ? new LiteLlmImageService(
          {
            ledger,
            backends: async () => opts.backends ?? DEFAULT_BACKENDS,
            cards: opts.cards === undefined ? undefined : async () => opts.cards!,
            directEdit: opts.directEdit ?? undefined,
            fetchImpl,
            litellmBaseUrl: "http://litellm.test",
            maxUpstreamCost: money("1.00"),
            userKey: async () => "sk-user",
            userKeyId: async () => "key-id",
            keySpend: async () => 0,
          },
          { clock: clockFn },
        )
      : opts.service;
  const state = { freeCap: 10, keySpend: 0, admissionCalls: 0 };
  const baseAdmission = createAdmission({
    effectiveTier: async () => "free",
    tierBudget: async () => ({ budget: 10, duration: "24h" }),
    freeCapRemaining: async () => state.freeCap,
    keySpend: async () => state.keySpend,
  });
  const admission = async (
    identity: { uid: string; keyId: string; tier: string },
    fn: (ctx: { window: string; budget: Money }) => Promise<Record<string, unknown>>,
  ) => {
    state.admissionCalls += 1;
    return baseAdmission(identity, fn);
  };

  const app = Fastify();
  registerImagesRoutes(app, deps, opts.admission === false ? null : service, admission, {
    effectiveTier: async () => "free",
    freeCapRemaining: async () => state.freeCap,
  });
  opts.extraRoutes?.(app, deps);
  await app.ready();
  return { app, ledger, service, calls, state, clock, deps, keyInfo, redis };
}

function eqMoney(actual: string | Decimal, expected: string): void {
  expect(money(actual).equals(new Decimal(expected))).toBe(true);
}

/** A complete capability card; tests override only the fields they exercise. */
function imageCard(over: Partial<ImageCard> = {}): ImageCard {
  return {
    ...defaultCard("image-a"),
    slug: "ovid-image:img-aaaaaa",
    sizes: {
      native: ["1024x1024"],
      aspect_ratios: ["1:1"],
      source: "declared",
      confidence: 0.9,
    },
    operations: {
      generate: { supported: true, source: "declared", confidence: 0.9 },
      edit: { supported: true, source: "declared", confidence: 0.9 },
    },
    ...over,
  };
}

beforeEach(() => {
  resetModelCatalogProjectionForTests();
});

describe("default routing fidelity", () => {
  const card: ImageCard = imageCard();

  it("accepts requirements.operation with routing.py's matrix", () => {
    expect(taskFromRequest("generate", { requirements: { operation: "variations" } }).operation).toBe(
      "variations",
    );
    expect(
      taskFromRequest("edit", { requirements: { operation: "remove_background" } }).operation,
    ).toBe("remove_background");
    expect(taskFromRequest("edit", { requirements: { operation: "inpaint" } }).operation).toBe(
      "inpaint",
    );
    expect(() => taskFromRequest("generate", { requirements: { operation: "upscale" } })).toThrow();
    expect(() => taskFromRequest("edit", { requirements: { operation: "generate" } })).toThrow();
    expect(() => taskFromRequest("generate", { requirements: { operation: "bogus" } })).toThrow();
  });

  it("rejects 0:0 aspect ratios and accepts Python's ratio form", () => {
    expect(
      taskFromRequest("generate", { requirements: { aspect_ratio: "16:9" } }).aspect_ratio,
    ).toBe("16:9");
    expect(() => taskFromRequest("generate", { requirements: { aspect_ratio: "0:0" } })).toThrow();
    expect(() => taskFromRequest("generate", { requirements: { aspect_ratio: "00:01" } })).toThrow();
  });

  it("uses Python's size:/aspect_ratio:/inputs: reason forms", () => {
    expect(missing(card, taskFromRequest("edit", { size: "999x999" }))).toContain("size:999x999");
    expect(
      missing(card, taskFromRequest("generate", { requirements: { aspect_ratio: "16:9" } })),
    ).toContain("aspect_ratio:16:9");

    const inputs: ImageTask = {
      ...taskFromRequest("edit", {}),
      operation: "edit",
      n_inputs: 2,
    };
    // routing.py needs(): more than one input requires multi_image, so the
    // capability reason wins before the max_inputs count is considered.
    expect(missing(card, inputs)).toContain("multi_image");
    expect(missing(card, { ...inputs, n_inputs: 1 })).toEqual([]);

    // A multi-image card with a smaller max_inputs reports the exact count.
    const capped: ImageCard = {
      ...card,
      operations: {
        ...card.operations,
        multi_image: { supported: true, source: "probed", confidence: 0.9, max_inputs: 1 },
      },
    };
    expect(missing(capped, inputs)).toContain("inputs:2");
  });
  it("derives edit_transport from discovered params (T13 M3)", () => {
    expect(
      legacyCard({
        model: "image-a",
        sizes: ["1024x1024"],
        edit: true,
        params: { model: "openai/cb/gpt-image-2", edit_transport: "direct" },
      }).edit_transport,
    ).toBe("direct");
    expect(
      legacyCard({ model: "image-a", sizes: ["1024x1024"], edit: true }).edit_transport,
    ).toBeNull();
  });
});

describe("images HTTP surface", () => {
  it("serves capabilities with an ETag round-trip and no private data", async () => {
    const h = await makeHarness(() => successResponse());
    const first = await h.app.inject({
      method: "GET",
      url: "/v1/images/capabilities",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(first.statusCode).toBe(200);
    const body = first.json();
    expect(body.model).toBe("ovid-image");
    expect(body.schema).toBe(2);
    expect(body.availability).toBe("unknown");
    expect(body.operations.generate).toEqual(["1024x1024"]);
    expect(body.operations.edit).toEqual(["1024x1024"]);
    expect(Array.isArray(body.models)).toBe(true);
    expect(first.headers["x-ovid-gateway"]).toBe("2");
    expect(first.headers.etag).toBe(`"${body.catalog_hash}"`);
    expect(first.body).not.toContain("image-a");
    expect(first.body).not.toContain("api_base");
    expect(first.body).not.toContain("prov/");

    const again = await h.app.inject({
      method: "GET",
      url: "/v1/images/capabilities",
      headers: {
        authorization: HEADERS.authorization,
        "x-ovid-key": HEADERS["x-ovid-key"],
        "if-none-match": `W/${first.headers.etag}`,
      },
    });
    expect(again.statusCode).toBe(304);
    expect(again.body).toBe("");
  });

  it("generates, charges the exact discounted amount, and replays without a paid call", async () => {
    const h = await makeHarness(() => successResponse("0.10"));
    const first = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(first.statusCode).toBe(200);
    const body = first.json();
    expect(body.model).toBe("ovid-image");
    expect(body.data).toEqual([{ b64_json: PNG_B64, mime_type: "image/png" }]);
    expect(body.receipt.state).toBe("confirmed");
    eqMoney(body.receipt.charged, "0.03");
    expect(h.calls).toHaveLength(1);
    eqMoney(await h.ledger.spent("u"), "0.03");

    const replay = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(replay.statusCode).toBe(200);
    expect(replay.json()).toEqual(body);
    expect(h.calls).toHaveLength(1);
  });

  it("keeps receipts and results readable at zero quota without admission", async () => {
    const h = await makeHarness(() => successResponse());
    const first = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(first.statusCode).toBe(200);
    h.state.freeCap = 0;
    const admissionCalls = h.state.admissionCalls;

    const blocked = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: { ...HEADERS, "idempotency-key": "request-9999" },
      payload: GEN_BODY,
    });
    expect(blocked.statusCode).toBe(402);
    expect(blocked.json()).toEqual({ error: { code: "image_limit_reached" } });
    expect(h.state.admissionCalls).toBe(admissionCalls);

    const receipt = await h.app.inject({
      method: "GET",
      url: "/v1/images/requests/request-1234",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(receipt.statusCode).toBe(200);
    expect(receipt.json().receipt.charged).toBe(first.json().receipt.charged);

    const result = await h.app.inject({
      method: "GET",
      url: "/v1/images/requests/request-1234/result",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(result.statusCode).toBe(200);
    expect(result.json()).toEqual(first.json());
    expect(result.headers["cache-control"]).toBe("no-store");
    expect(h.state.admissionCalls).toBe(admissionCalls);
    expect(h.calls).toHaveLength(1);
  });

  it("maps receipt/result ledger states to 404/410 and keeps the receipt after replay expiry", async () => {
    const h = await makeHarness(() => successResponse());
    await h.app.inject({ method: "POST", url: "/v1/images/generations", headers: HEADERS, payload: GEN_BODY });

    const missing = await h.app.inject({
      method: "GET",
      url: "/v1/images/requests/nope-1234",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(missing.statusCode).toBe(404);
    expect(missing.json()).toEqual({ error: { code: "image_request_not_found" } });

    h.ledger.expireReplay("u", "request-1234");
    const expired = await h.app.inject({
      method: "GET",
      url: "/v1/images/requests/request-1234/result",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(expired.statusCode).toBe(410);
    expect(expired.json().error.code).toBe("image_replay_expired");
    expect(expired.json().receipt.state).toBe("confirmed");

    const receipt = await h.app.inject({
      method: "GET",
      url: "/v1/images/requests/request-1234",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(receipt.statusCode).toBe(200);

    h.ledger.expireReceipt("u", "request-1234");
    const gone = await h.app.inject({
      method: "GET",
      url: "/v1/images/requests/request-1234",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(gone.statusCode).toBe(410);
    expect(gone.json().error.code).toBe("image_receipt_expired");
  });

  it("enforces the auth ladder: key ownership, image scope, ban and expiry", async () => {
    const h = await makeHarness(() => successResponse());
    const get = (headers: Record<string, string>) =>
      h.app.inject({ method: "GET", url: "/v1/images/capabilities", headers });

    const wrongKey = await get({
      authorization: HEADERS.authorization,
      "x-ovid-key": "sk-other",
    });
    expect(wrongKey.statusCode).toBe(401);
    expect(wrongKey.json()).toEqual({ error: { code: "sign_in_required" } });

    const missingBearer = await get({ "x-ovid-key": HEADERS["x-ovid-key"] });
    expect(missingBearer.statusCode).toBe(401);
    expect(missingBearer.json()).toEqual({ error: { code: "sign_in_required" } });

    h.keyInfo.value = { user_id: "u", metadata: { ovid_uid: "u" }, models: ["other"] };
    const unscoped = await get({
      authorization: HEADERS.authorization,
      "x-ovid-key": HEADERS["x-ovid-key"],
    });
    expect(unscoped.statusCode).toBe(403);
    expect(unscoped.json()).toEqual({ error: { code: "image_access_denied" } });

    h.keyInfo.value = {
      user_id: "someone-else",
      metadata: { ovid_uid: "u" },
      models: ["ovid-image"],
    };
    expect(
      (
        await get({
          authorization: HEADERS.authorization,
          "x-ovid-key": HEADERS["x-ovid-key"],
        })
      ).statusCode,
    ).toBe(403);

    h.keyInfo.value = { user_id: "u", metadata: { ovid_uid: "u" }, models: ["ovid-image"], expires: "2000-01-01T00:00:00Z" };
    expect(
      (
        await get({
          authorization: HEADERS.authorization,
          "x-ovid-key": HEADERS["x-ovid-key"],
        })
      ).statusCode,
    ).toBe(401);

    h.keyInfo.value = { user_id: "u", metadata: { ovid_uid: "u" }, models: ["ovid-image"] };
    h.redis.set("user:u:banned", "1");
    const banned = await get({
      authorization: HEADERS.authorization,
      "x-ovid-key": HEADERS["x-ovid-key"],
    });
    expect(banned.statusCode).toBe(403);
    expect(banned.json()).toEqual({ error: { code: "image_access_denied" } });
  });

  it("rejects wrong content types, oversized bodies, bad JSON and missing request ids", async () => {
    const h = await makeHarness(() => successResponse());
    const post = (payload: string, headers: Record<string, string>, contentType = "application/json") =>
      h.app.inject({
        method: "POST",
        url: "/v1/images/generations",
        headers: { ...HEADERS, "content-type": contentType, ...headers },
        payload,
      });

    const text = await post(JSON.stringify(GEN_BODY), {}, "text/plain");
    expect(text.statusCode).toBe(415);
    expect(text.json()).toEqual({ error: { code: "invalid_image_request" } });

    // verifier.py authenticates before inspecting the body: no auth wins.
    const anonymous = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: { "content-type": "text/plain" },
      payload: "not json",
    });
    expect(anonymous.statusCode).toBe(401);
    expect(anonymous.json()).toEqual({ error: { code: "sign_in_required" } });

    const badJson = await post("{", {});
    expect(badJson.statusCode).toBe(400);
    expect(badJson.json()).toEqual({ error: { code: "invalid_image_request" } });

    const missingId = await post(JSON.stringify(GEN_BODY), { "idempotency-key": "" });
    expect(missingId.statusCode).toBe(400);
    expect(missingId.json()).toEqual({ error: { code: "invalid_request_id" } });

    const huge = await post("a".repeat(IMAGE_BODY_LIMIT + 1), {});
    expect(huge.statusCode).toBe(413);
    expect(huge.json()).toEqual({ error: { code: "image_too_large" } });
  });

  it("validates edit data URLs before admission", async () => {
    const h = await makeHarness(() => successResponse());
    const post = (body: Record<string, unknown>) =>
      h.app.inject({ method: "POST", url: "/v1/images/edits", headers: HEADERS, payload: body });

    for (const image of [
      "data:image/png;base64,bm90YW4gaW1hZ2U=",
      "data:image/png;base64,AAAA",
      `data:image/jpeg;base64,${PNG_B64}`,
      `data:image/png;base64,${PNG_BYTES.subarray(0, PNG_BYTES.length - 12).toString("base64")}`,
    ]) {
      const response = await post({ ...EDIT_BODY, image });
      expect(response.statusCode).toBe(400);
      expect(response.json()).toEqual({ error: { code: "invalid_image" } });
    }
    expect(h.calls).toHaveLength(0);
    expect((await h.ledger.spent("u", { includePending: true })).equals(money("0"))).toBe(true);

    const ok = await post(EDIT_BODY);
    expect(ok.statusCode).toBe(200);
    expect(ok.json().receipt.state).toBe("confirmed");
    expect(h.calls[0]!.path).toBe("/v1/images/edits");
  });

  it("rejects unknown body fields, empty prompts and bad sizes before admission", async () => {
    const h = await makeHarness(() => successResponse());
    for (const payload of [
      { ...GEN_BODY, bogus: 1 },
      { ...GEN_BODY, prompt: "   " },
      { ...GEN_BODY, size: "999x99" },
      { ...GEN_BODY, preference: "wow" },
      { ...GEN_BODY, requirements: { bogus: true } },
      { ...GEN_BODY, requirements: { aspect_ratio: "0:0" } },
      { ...GEN_BODY, model: "prov/private" },
    ]) {
      const response = await h.app.inject({
        method: "POST",
        url: "/v1/images/generations",
        headers: { ...HEADERS, "idempotency-key": "request-bad1" },
        payload,
      });
      expect(response.statusCode, JSON.stringify(payload)).toBe(400);
      expect(response.json()).toEqual({ error: { code: "invalid_image_request" } });
    }
    expect(h.calls).toHaveLength(0);

    // A syntactically valid size outside SIZES is not a request error: it
    // fails capability routing with 422 (routing.py normalize_size + missing).
    const unroutableSize = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: { ...HEADERS, "idempotency-key": "request-bad1" },
      payload: { ...GEN_BODY, size: "999x999" },
    });
    expect(unroutableSize.statusCode).toBe(422);
    expect(unroutableSize.json().error.code).toBe("unsupported_image_operation");
    expect(h.calls).toHaveLength(0);

    const unknownSlug = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: { ...HEADERS, "idempotency-key": "request-bad2" },
      payload: { ...GEN_BODY, model: "ovid-image:img-nope00" },
    });
    expect(unknownSlug.statusCode).toBe(422);
    expect(unknownSlug.json().error.code).toBe("unsupported_image_operation");
    expect(unknownSlug.json().error.reason).toBe("unknown_model");
  });

  it("falls back on a structured no_capacity refusal and keeps a zero receipt on exhaustion", async () => {
    const h = await makeHarness((call) => {
      if (call.model === "image-a") {
        return jsonResponse(503, {
          error: {
            message:
              "litellm.ServiceUnavailableError: ServiceUnavailableError: [OI]Exception - " +
              "no available provider for image-a (all offers exhausted or in cooldown); try again shortly",
            type: "service_unavailable_error",
          },
        });
      }
      return successResponse("0.10");
    });
    const result = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(result.statusCode).toBe(200);
    expect(h.calls.map((c) => c.model)).toEqual(["image-a", "image-b"]);
    expect(result.json().receipt.state).toBe("confirmed");
  });

  it("returns image_capacity_unavailable with a bounded Retry-After and a failed receipt", async () => {
    const h = await makeHarness(() =>
      jsonResponse(503, { error: { type: "no_capacity", message: "Unavailable" } }),
    );
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(response.statusCode).toBe(503);
    expect(response.json().error).toEqual({
      code: "image_capacity_unavailable",
      retryAfterSeconds: 30,
    });
    expect(response.headers["retry-after"]).toBe("30");
    expect(response.headers["cache-control"]).toBe("no-store");
    expect(response.json().receipt.state).toBe("failed");
    expect(response.json().receipt.charged).toBe("0");
    expect(h.calls.map((c) => c.model)).toEqual(["image-a", "image-b"]);
    expect((await h.ledger.spent("u", { includePending: true })).equals(money("0"))).toBe(true);

    // Cooldowns block new ids without another paid attempt, then expire on the clock.
    const blocked = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: { ...HEADERS, "idempotency-key": "request-2000" },
      payload: GEN_BODY,
    });
    expect(blocked.statusCode).toBe(503);
    expect(blocked.json().error.code).toBe("image_capacity_unavailable");
    expect(h.calls).toHaveLength(2);

    const capability = await h.app.inject({
      method: "GET",
      url: "/v1/images/capabilities",
      headers: { authorization: HEADERS.authorization, "x-ovid-key": HEADERS["x-ovid-key"] },
    });
    expect(capability.statusCode).toBe(503);
    expect(capability.json().error.code).toBe("image_capacity_unavailable");
    expect(capability.json().receipt).toBeUndefined();
  });

  it("expires a cooldown after the bounded delay without a paid probe", async () => {
    const h = await makeHarness(
      (call) =>
        h.clock.now < 1_020 && call.model === "image-a"
          ? jsonResponse(503, { error: { type: "no_capacity" } })
          : successResponse(),
    );
    const first = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    // image-a refused, image-b served immediately (one cooldown only).
    expect(first.statusCode).toBe(200);
    expect(h.calls.map((c) => c.model)).toEqual(["image-a", "image-b"]);

    // A new id still tries image-a? No: it is cooling down until +30.
    const blocked = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: { ...HEADERS, "idempotency-key": "request-3000" },
      payload: GEN_BODY,
    });
    expect(blocked.statusCode).toBe(200);
    expect(h.calls.map((c) => c.model)).toEqual(["image-a", "image-b", "image-b"]);

    h.clock.now += 31;
    const recovered = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: { ...HEADERS, "idempotency-key": "request-3001" },
      payload: GEN_BODY,
    });
    expect(recovered.statusCode).toBe(200);
    expect(h.calls.map((c) => c.model)).toEqual(["image-a", "image-b", "image-b", "image-a"]);
  });

  it("falls back on pre-provider 400 codes but returns image_unavailable when exhausted", async () => {
    for (const code of ["not_an_image_model", "unsupported_modality", "unsupported_n"]) {
      const h = await makeHarness((call) =>
        call.model === "image-a"
          ? jsonResponse(503, { error: { type: "no_capacity" } })
          : jsonResponse(400, { error: { code } }),
      );
      const response = await h.app.inject({
        method: "POST",
        url: "/v1/images/generations",
        headers: HEADERS,
        payload: GEN_BODY,
      });
      expect(response.statusCode, code).toBe(502);
      expect(response.json().error.code, code).toBe("image_unavailable");
      expect(response.json().receipt.state, code).toBe("failed");
      expect(response.json().receipt.charged, code).toBe("0");
      expect(h.calls.map((c) => c.model), code).toEqual(["image-a", "image-b"]);
    }
  });

  it("keeps an ambiguous failure pending without fallback and retains the reservation", async () => {
    const h = await makeHarness(() =>
      jsonResponse(404, { error: { code: "model_not_found" } }),
    );
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error).toEqual({ code: "image_request_pending" });
    expect(response.headers["retry-after"]).toBeUndefined();
    expect(response.json().receipt.state).toBe("unknown");
    expect(response.json().receipt.charged).toBeNull();
    expect(h.calls.map((c) => c.model)).toEqual(["image-a"]);
    expect((await h.ledger.spent("u", { includePending: true })).equals(money("0.30"))).toBe(true);

    const replay = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(replay.statusCode).toBe(409);
    expect(replay.json().error.code).toBe("image_request_pending");
    expect(h.calls).toHaveLength(1);
  });

  it("never settles an invalid upstream image and keeps the reservation", async () => {
    const h = await makeHarness(() =>
      jsonResponse(200, { data: [{ b64_json: "bm90YW4gaW1hZ2U=" }] }),
    );
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("image_request_pending");
    expect((await h.ledger.spent("u", { includePending: true })).equals(money("0.30"))).toBe(true);
  });

  it("uses the direct JSON edit transport for direct cards", async () => {
    const directCalls: string[] = [];
    const direct = createDirectEdit(
      {
        images: {
          inferhubApiKey: "sk-inferhub",
          directEditHosts: "api.inferhub.dev",
          editCostUsd: "0.04",
        },
      } as unknown as MintEnv,
      {
        maxUpstreamCost: money("1.00"),
        fetchImpl: (async (url: string | URL | Request) => {
          directCalls.push(String(url));
          return jsonResponse(200, { data: [{ b64_json: PNG_B64 }] });
        }) as typeof fetch,
      },
    );
    const cards: ImageCard[] = [imageCard({ edit_transport: "direct" })];
    const h = await makeHarness(() => successResponse(), {
      backends: [
        {
          model: "image-a",
          sizes: ["1024x1024"],
          edit: true,
          params: { model: "openai/cb/gpt-image-2", api_base: "https://api.inferhub.dev/v1" },
        },
      ],
      cards,
      directEdit: direct,
    });
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/images/edits",
      headers: HEADERS,
      payload: EDIT_BODY,
    });
    expect(response.statusCode).toBe(200);
    expect(directCalls).toHaveLength(1);
    expect(h.calls).toHaveLength(0);
    eqMoney(response.json().receipt.charged, "0.012");
  });

  it("never takes the direct branch for a stale direct card when the transport is disabled", async () => {
    // Regression (T14 review MEDIUM): the card persisted `direct`, but the
    // discovered api_base is not allowlisted / the key is gone. The service
    // must fall back to LiteLLM instead of throwing inside DirectEdit.post and
    // turning the request into 409 with a retained reservation.
    const directCalls: string[] = [];
    const direct = createDirectEdit(
      {
        images: {
          inferhubApiKey: "sk-inferhub",
          directEditHosts: "api.inferhub.dev",
          editCostUsd: "0.04",
        },
      } as unknown as MintEnv,
      {
        maxUpstreamCost: money("1.00"),
        fetchImpl: (async (url: string | URL | Request) => {
          directCalls.push(String(url));
          return jsonResponse(200, { data: [{ b64_json: PNG_B64 }] });
        }) as typeof fetch,
      },
    );
    const cards: ImageCard[] = [imageCard({ edit_transport: "direct" })];
    const h = await makeHarness(() => successResponse(), {
      backends: [
        {
          model: "image-a",
          sizes: ["1024x1024"],
          edit: true,
          // Not on directEditHosts: enabled_for() is false.
          params: { model: "openai/cb/gpt-image-2", api_base: "https://images.example.com/v1" },
        },
      ],
      cards,
      directEdit: direct,
    });
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/images/edits",
      headers: HEADERS,
      payload: EDIT_BODY,
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().receipt.state).toBe("confirmed");
    eqMoney(response.json().receipt.charged, "0.03");
    expect(directCalls).toHaveLength(0);
    expect(h.calls).toHaveLength(1);
    expect(h.calls[0]!.path).toBe("/v1/images/edits");
    // Settled, not an ambiguous 409 with the reservation retained.
    expect((await h.ledger.spent("u")).equals(money("0.03"))).toBe(true);
  });

  it("logs a direct-provider credential rejection and keeps the reservation", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const direct = createDirectEdit(
        {
          images: {
            inferhubApiKey: "sk-inferhub",
            directEditHosts: "api.inferhub.dev",
          },
        } as unknown as MintEnv,
        {
          maxUpstreamCost: money("1.00"),
          fetchImpl: (async () =>
            jsonResponse(401, { error: { message: "provider secret" } })) as typeof fetch,
        },
      );
      const cards: ImageCard[] = [imageCard({ edit_transport: "direct" })];
      const h = await makeHarness(() => successResponse(), {
        backends: [
          {
            model: "image-a",
            sizes: ["1024x1024"],
            edit: true,
            params: { model: "openai/cb/gpt-image-2", api_base: "https://api.inferhub.dev/v1" },
          },
        ],
        cards,
        directEdit: direct,
      });
      const response = await h.app.inject({
        method: "POST",
        url: "/v1/images/edits",
        headers: HEADERS,
        payload: EDIT_BODY,
      });
      expect(response.statusCode).toBe(409);
      expect(response.json().error).toEqual({ code: "image_request_pending" });
      expect(response.json().receipt.state).toBe("unknown");
      expect(response.json().receipt.charged).toBeNull();
      expect(response.body).not.toContain("provider secret");
      expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("status=401"));
      expect(
        (await h.ledger.spent("u", { includePending: true })).equals(money("0.30")),
      ).toBe(true);
    } finally {
      errorSpy.mockRestore();
    }
  });

  it("treats a direct-edit timeout as an ambiguous outcome (reservation retained)", async () => {
    const direct = createDirectEdit(
      {
        images: {
          inferhubApiKey: "sk-inferhub",
          directEditHosts: "api.inferhub.dev",
        },
      } as unknown as MintEnv,
      {
        maxUpstreamCost: money("1.00"),
        timeoutMs: 5,
        fetchImpl: (async () => {
          throw new DOMException("The operation timed out.", "TimeoutError");
        }) as unknown as typeof fetch,
      },
    );
    const cards: ImageCard[] = [imageCard({ edit_transport: "direct" })];
    const h = await makeHarness(() => successResponse(), {
      backends: [
        {
          model: "image-a",
          sizes: ["1024x1024"],
          edit: true,
          params: { model: "openai/cb/gpt-image-2", api_base: "https://api.inferhub.dev/v1" },
        },
      ],
      cards,
      directEdit: direct,
    });
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/images/edits",
      headers: HEADERS,
      payload: EDIT_BODY,
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error).toEqual({ code: "image_request_pending" });
    expect(response.json().receipt.state).toBe("unknown");
    // The reservation is retained (never released on an ambiguous transport).
    expect((await h.ledger.spent("u", { includePending: true })).equals(money("0.30"))).toBe(true);
  });

  it("changes catalog_hash when a card changes and honours a stale ETag", async () => {
    const cards: ImageCard[] = [imageCard()];
    const h = await makeHarness(() => successResponse(), {
      backends: [{ model: "image-a", sizes: ["1024x1024"], edit: true }],
      cards,
    });
    const get = (ifNoneMatch?: string) =>
      h.app.inject({
        method: "GET",
        url: "/v1/images/capabilities",
        headers: {
          authorization: HEADERS.authorization,
          "x-ovid-key": HEADERS["x-ovid-key"],
          ...(ifNoneMatch === undefined ? {} : { "if-none-match": ifNoneMatch }),
        },
      });

    const before = await get();
    expect(before.statusCode).toBe(200);
    const stale = await get('"other"');
    expect(stale.statusCode).toBe(200);

    cards[0]!.operations.edit = { supported: false, source: "declared", confidence: 0.9 };
    const after = await get();
    expect(after.statusCode).toBe(200);
    expect(after.json().catalog_hash).not.toBe(before.json().catalog_hash);
    expect(after.headers.etag).toBe(`"${after.json().catalog_hash}"`);
  });

  it("forwards the card's first native size when the request omits size", async () => {
    const h = await makeHarness(() => successResponse(), {
      backends: [{ model: "image-a", sizes: ["1536x1024"], edit: false }],
    });
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: { model: "ovid-image", prompt: "a wide square" },
    });
    expect(response.statusCode).toBe(200);
    expect(h.calls).toHaveLength(1);
    expect((h.calls[0]!.body as { size?: string }).size).toBe("1536x1024");
  });

  it("keeps every ambiguous upstream outcome pending without fallback", async () => {
    const cases: { name: string; reply: Response | (() => never) }[] = [
      { name: "unstructured 400", reply: jsonResponse(400, { error: { code: "validation_error" } }) },
      { name: "text 400", reply: new Response("Bad request", { status: 400 }) },
      { name: "text 404", reply: new Response("Not found", { status: 404 }) },
      { name: "502 mid-chain", reply: jsonResponse(502, { error: { message: "bad gateway" } }) },
      { name: "503 message", reply: jsonResponse(503, { error: { message: "upstream disconnected" } }) },
      { name: "503 html", reply: new Response("<html>gateway unavailable</html>", { status: 503 }) },
      { name: "503 bare no_capacity text", reply: jsonResponse(503, { error: { message: "no_capacity" } }) },
      {
        name: "capacity message for another model",
        reply: jsonResponse(503, {
          error: {
            message:
              "litellm.ServiceUnavailableError: ServiceUnavailableError: no available provider for " +
              "another-model (all offers exhausted or in cooldown); try again shortly",
          },
        }),
      },
      { name: "500 no_capacity type", reply: jsonResponse(500, { error: { type: "no_capacity" } }) },
      {
        name: "503 unrecognized code",
        reply: jsonResponse(503, { error: { code: "unrecognized", accepted: false } }),
      },
      {
        name: "transport error",
        reply: () => {
          throw new Error("socket closed");
        },
      },
    ];

    for (const [index, testCase] of cases.entries()) {
      const h = await makeHarness((call) => {
        if (call.model !== "image-a") throw new Error("fallback must never happen");
        return typeof testCase.reply === "function" ? testCase.reply() : testCase.reply.clone();
      });
      const response = await h.app.inject({
        method: "POST",
        url: "/v1/images/generations",
        headers: { ...HEADERS, "idempotency-key": `uncertain-${index}` },
        payload: GEN_BODY,
      });
      expect(response.statusCode, testCase.name).toBe(409);
      expect(response.json().error, testCase.name).toEqual({ code: "image_request_pending" });
      expect(response.headers["retry-after"], testCase.name).toBeUndefined();
      expect(response.json().receipt.state, testCase.name).toBe("unknown");
      expect(response.json().receipt.charged, testCase.name).toBeNull();
      expect(h.calls.map((c) => c.model), testCase.name).toEqual(["image-a"]);
      expect(
        (await h.ledger.spent("u", { includePending: true })).equals(money("0.30")),
        testCase.name,
      ).toBe(true);
    }
  });

  it("bounds Retry-After and never copies provider text", async () => {
    const cases: [string, number][] = [
      ["999999999999999999999999", 120],
      ["0", 1],
      ["-1", 30],
      ["12", 12],
      ["nan", 30],
      ["1.5", 30],
      ["private detail", 30],
    ];
    for (const [raw, expected] of cases) {
      const h = await makeHarness(() =>
        jsonResponse(503, { error: { code: "no_capacity", message: "secret" } }, { "retry-after": raw }),
      );
      const response = await h.app.inject({
        method: "POST",
        url: "/v1/images/generations",
        headers: HEADERS,
        payload: GEN_BODY,
      });
      expect(response.statusCode, raw).toBe(503);
      expect(response.json().error, raw).toEqual({
        code: "image_capacity_unavailable",
        retryAfterSeconds: expected,
      });
      expect(response.headers["retry-after"], raw).toBe(String(expected));
      expect(response.body, raw).not.toContain("secret");
      expect(response.body, raw).not.toContain("image-a");
      expect(response.body, raw).not.toContain("image-b");
    }
  });

  it("replays a failed request id as image_request_failed without a paid retry", async () => {
    const h = await makeHarness(() =>
      jsonResponse(503, { error: { type: "no_capacity", message: "Unavailable" } }),
    );
    const first = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(first.statusCode).toBe(503);
    expect(h.calls).toHaveLength(2);

    const replay = await h.app.inject({
      method: "POST",
      url: "/v1/images/generations",
      headers: HEADERS,
      payload: GEN_BODY,
    });
    expect(replay.statusCode).toBe(409);
    expect(replay.json().error.code).toBe("image_request_failed");
    expect(replay.json().receipt.state).toBe("failed");
    expect(replay.headers["retry-after"]).toBeUndefined();
    expect(h.calls).toHaveLength(2);
  });

  it("removes private backends and the image alias from /v1/models once mounted", async () => {
    const h = await makeHarness(() => successResponse(), {
      extraRoutes: (app, deps) => {
        deps.litellm.rawModels = async () => ({
          status: 200,
          body: {
            data: [
              { id: "auto" },
              { id: "image-a" },
              { id: "openai/image-a" },
              { id: "ovid-image" },
            ],
          },
          text: "",
        });
        registerMintRoutes(app, deps);
      },
    });
    const response = await h.app.inject({
      method: "GET",
      url: "/v1/models",
      headers: { authorization: "Bearer sk-user" },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      object: "list",
      data: [{ id: "auto", object: "model", owned_by: "ovid" }],
    });
    expect(response.headers["x-ovid-gateway"]).toBe("2");
  });

  it("stays closed with 503 image_unavailable when service or admission is absent", async () => {
    const h = await makeHarness(() => successResponse(), { admission: false });
    for (const request of [
      { method: "GET" as const, url: "/v1/images/capabilities" },
      { method: "GET" as const, url: "/v1/images/requests/request-1234" },
      { method: "GET" as const, url: "/v1/images/requests/request-1234/result" },
      { method: "POST" as const, url: "/v1/images/generations", payload: GEN_BODY },
      { method: "POST" as const, url: "/v1/images/edits", payload: EDIT_BODY },
    ]) {
      const response = await h.app.inject({
        ...request,
        headers: request.method === "POST" ? HEADERS : { authorization: HEADERS.authorization },
      });
      expect(response.statusCode, request.url).toBe(503);
      expect(response.json()).toEqual({ error: { code: "image_unavailable" } });
    }
  });
});
