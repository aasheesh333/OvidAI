import Fastify, { type FastifyInstance } from "fastify";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { money } from "@ovid/money";
import { signInternalRequest } from "@ovid/shared";
import type { Redis } from "ioredis";
import type { MintDeps } from "../app.js";
import type { LiteLlmAdmin } from "../litellmAdmin.js";
import type { MintEnv } from "../env.js";
import type { Admission } from "./admission.js";
import type { LiteLlmImageService } from "./service.js";
import { registerImagesRoutes } from "./routes.js";
import { ImageError } from "./types.js";
import {
  INTERNAL_IMAGE_CAPABILITIES_PATH,
  INTERNAL_IMAGE_EDITS_PATH,
  INTERNAL_IMAGE_GENERATIONS_PATH,
  registerInternalImagesRoutes,
} from "./internalRoutes.js";

/**
 * W8 — the worker's signed image surface.
 *
 * Proves the four things the worker relies on:
 *   - only a correctly signed caller reaches the service;
 *   - capability discovery returns the public cards + plan quota;
 *   - generation/edit run through the SAME admission bridge as the public
 *     routes (so quota blocking is not reimplemented);
 *   - errors keep the public image envelope (code + optional receipt).
 */

const SECRET = "test-internal-secret-0123456789abcdef";
const UID = "user-1";
const TS = 1_700_000_000;
const PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

function signed(path: string, uid = UID): Record<string, string> {
  return {
    "x-ovid-timestamp": Buffer.from(String(TS), "utf8").toString("base64"),
    "x-ovid-signature": signInternalRequest(SECRET, "POST", path, uid, TS),
  };
}

function makeDeps(overrides: { key?: string | null; keyId?: string | null; banned?: boolean } = {}): MintDeps {
  const values: Record<string, string | null> = {
    [`user:${UID}:key`]: overrides.key === undefined ? "sk-user" : overrides.key,
    [`user:${UID}:keyid`]: overrides.keyId === undefined ? "key-id" : overrides.keyId,
    [`user:${UID}:banned`]: overrides.banned === true ? "1" : null,
  };
  const redis = {
    get: vi.fn(async (key: string) => values[key] ?? null),
  } as unknown as Redis;
  const litellm = {
    keyInfoStatus: vi.fn(async () => ({
      status: 200,
      info: {
        user_id: UID,
        metadata: { ovid_uid: UID },
        models: ["ovid-image"],
      },
    })),
  } as unknown as LiteLlmAdmin;
  return {
    db: {},
    redis,
    litellm,
    env: { internalApiSecret: SECRET } as MintEnv,
    clock: () => new Date(TS * 1000),
  } as unknown as MintDeps;
}

const catalogBody = {
  model: "ovid-image",
  operations: { generate: ["1024x1024"], edit: ["1024x1024"] },
  availability: "unknown",
  schema: 2,
  catalog_hash: "a".repeat(32),
  models: [{ slug: "ovid-image:img-one", operations: { generate: {}, edit: {} }, sizes: ["1024x1024"] }],
};

function makeService() {
  return {
    catalog: vi.fn(async () => catalogBody),
    execute: vi.fn(async () => ({
      model: "ovid-image",
      model_slug: "ovid-image:img-one",
      data: [{ b64_json: PNG_B64, mime_type: "image/png" }],
      receipt: {
        account_id: UID,
        request_id: "request-1",
        fingerprint: "f".repeat(64),
        state: "confirmed",
        charged: "0.0123",
      },
    })),
  } as unknown as LiteLlmImageService & {
    catalog: ReturnType<typeof vi.fn>;
    execute: ReturnType<typeof vi.fn>;
  };
}

function makeAdmission() {
  return vi.fn(async (_identity, fn) => fn({ window: `${UID}:30d`, budget: money("1.00") })) as unknown as Admission & ReturnType<typeof vi.fn>;
}

describe("internal image routes (worker -> mint admin listener)", () => {
  let app: FastifyInstance;
  let deps: MintDeps;
  let service: ReturnType<typeof makeService>;
  let admission: ReturnType<typeof makeAdmission>;

  beforeEach(async () => {
    deps = makeDeps();
    service = makeService();
    admission = makeAdmission();
    app = Fastify();
    registerInternalImagesRoutes(app, deps, service, admission, {
      deletionPending: async () => false,
      effectiveTier: async () => "free",
      freeCapRemaining: async () => 5,
    });
    await app.ready();
  });

  it("rejects an unsigned caller with 401 and never touches the service", async () => {
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      payload: { uid: UID, request_id: "request-1", prompt: "a cube" },
    });
    expect(res.statusCode).toBe(401);
    expect(service.execute).not.toHaveBeenCalled();
  });

  it("the public image app never registers the internal paths", async () => {
    const publicApp = Fastify();
    registerImagesRoutes(publicApp, deps, null, null);
    await publicApp.ready();
    const res = await publicApp.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      payload: { uid: UID, request_id: "request-1", prompt: "a cube" },
    });
    expect(res.statusCode).toBe(404);
  });

  it("rejects a signature bound to a different uid", async () => {
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      headers: signed(INTERNAL_IMAGE_GENERATIONS_PATH, "someone-else"),
      payload: { uid: UID, request_id: "request-1", prompt: "a cube" },
    });
    expect(res.statusCode).toBe(401);
    expect(service.execute).not.toHaveBeenCalled();
  });

  it("serves capabilities with the public cards and the plan quota", async () => {
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_CAPABILITIES_PATH,
      headers: signed(INTERNAL_IMAGE_CAPABILITIES_PATH),
      payload: { uid: UID },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json() as Record<string, unknown>;
    expect(body.model).toBe("ovid-image");
    expect(body.catalog_hash).toBe("a".repeat(32));
    expect(body.quota).toEqual({ tier: "free", free_cap_remaining: 5 });
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(service.catalog).toHaveBeenCalledTimes(1);
  });

  it("runs generation through admission and the shared service", async () => {
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      headers: signed(INTERNAL_IMAGE_GENERATIONS_PATH),
      payload: { uid: UID, request_id: "request-1", prompt: "a cube", size: "1024x1024" },
    });
    expect(res.statusCode).toBe(200);
    expect(admission).toHaveBeenCalledTimes(1);
    expect(admission.mock.calls[0]![0]).toEqual({ uid: UID, keyId: "key-id", tier: "free" });
    expect(service.execute).toHaveBeenCalledWith(
      UID,
      "request-1",
      "generate",
      { prompt: "a cube", size: "1024x1024" },
      expect.anything(),
      { budgetWindow: `${UID}:30d` },
    );
    const body = res.json() as { receipt: { charged: string } };
    expect(body.receipt.charged).toBe("0.0123");
  });

  it("runs edit through the edit route and forwards the image data URL", async () => {
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_EDITS_PATH,
      headers: signed(INTERNAL_IMAGE_EDITS_PATH),
      payload: {
        uid: UID,
        request_id: "request-2",
        prompt: "make it blue",
        image: `data:image/png;base64,${PNG_B64}`,
      },
    });
    expect(res.statusCode).toBe(200);
    expect(service.execute).toHaveBeenCalledWith(
      UID,
      "request-2",
      "edit",
      {
        prompt: "make it blue",
        image: `data:image/png;base64,${PNG_B64}`,
      },
      expect.anything(),
      { budgetWindow: `${UID}:30d` },
    );
  });

  it("maps an exhausted allowance to the public 402 envelope", async () => {
    admission.mockImplementationOnce(async () => {
      throw new ImageError(402, "image_limit_reached");
    });
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      headers: signed(INTERNAL_IMAGE_GENERATIONS_PATH),
      payload: { uid: UID, request_id: "request-1", prompt: "a cube" },
    });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ error: { code: "image_limit_reached" } });
    expect(service.execute).not.toHaveBeenCalled();
  });

  it("refuses a missing virtual key before any paid work", async () => {
    app = Fastify();
    registerInternalImagesRoutes(app, makeDeps({ keyId: null }), service, admission, {
      deletionPending: async () => false,
      effectiveTier: async () => "free",
      freeCapRemaining: async () => 5,
    });
    await app.ready();
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      headers: signed(INTERNAL_IMAGE_GENERATIONS_PATH),
      payload: { uid: UID, request_id: "request-1", prompt: "a cube" },
    });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: { code: "sign_in_required" } });
    expect(service.execute).not.toHaveBeenCalled();
  });

  it("refuses a key without the ovid-image scope", async () => {
    deps = makeDeps();
    (deps.litellm.keyInfoStatus as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      status: 200,
      info: { user_id: UID, metadata: { ovid_uid: UID }, models: ["gpt-4o"] },
    });
    app = Fastify();
    registerInternalImagesRoutes(app, deps, service, admission, {
      deletionPending: async () => false,
      effectiveTier: async () => "free",
      freeCapRemaining: async () => 5,
    });
    await app.ready();
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      headers: signed(INTERNAL_IMAGE_GENERATIONS_PATH),
      payload: { uid: UID, request_id: "request-1", prompt: "a cube" },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: { code: "image_access_denied" } });
  });

  it("rejects an invalid request_id before admission", async () => {
    const res = await app.inject({
      method: "POST",
      url: INTERNAL_IMAGE_GENERATIONS_PATH,
      headers: signed(INTERNAL_IMAGE_GENERATIONS_PATH),
      payload: { uid: UID, request_id: "short", prompt: "a cube" },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: { code: "invalid_request_id" } });
    expect(admission).not.toHaveBeenCalled();
  });
});
