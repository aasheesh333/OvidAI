import { afterEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { buildMintApps, HttpContractError, type MintDeps } from "./app.js";
import { loadMintEnv } from "./env.js";
import type { LiteLlmAdmin } from "./litellmAdmin.js";

/**
 * buildMintApps-level scaffold behavior: /healthz, the 404 shape, and the
 * legacy HttpContractError mapping ({"detail": …} — FastAPI HTTPException
 * parity, NOT the /cloud ApiError envelope). No services: db/redis/litellm
 * are inert stubs the scaffold never touches.
 */

function baseEnv(): NodeJS.ProcessEnv {
  return {
    NODE_ENV: "test",
    DATABASE_URL: "postgres://u:p@localhost:5432/ovid_cloud_test",
    REDIS_DB2_URL: "redis://localhost:6379/9",
    LITELLM_MASTER_KEY: "sk-litellm-master",
    OVID_ADMIN_MASTER_KEY: "sk-admin-master",
    OVID_INTERNAL_API_SECRET: "sk-internal",
    FIREBASE_PROJECT_ID: "ovid-test-project",
  };
}

function makeDeps(): MintDeps {
  return {
    db: {} as Db,
    redis: {} as Redis,
    litellm: {} as LiteLlmAdmin,
    env: loadMintEnv(baseEnv()),
    alerter: async () => {},
    verifyIdentity: async () => ({ uid: "uid-1", email: null, platform: "android" }),
  };
}

describe("buildMintApps", () => {
  let apps: { publicApp: FastifyInstance; adminApp: FastifyInstance } | undefined;

  afterEach(async () => {
    if (apps !== undefined) {
      await apps.publicApp.close();
      await apps.adminApp.close();
      apps = undefined;
    }
  });

  it("publicApp GET /healthz → 200 {ok:true}", async () => {
    apps = buildMintApps(makeDeps());
    const res = await apps.publicApp.inject({ method: "GET", url: "/healthz" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });
  });

  it("adminApp unknown route → 404 with the legacy {detail} shape", async () => {
    apps = buildMintApps(makeDeps());
    const res = await apps.adminApp.inject({ method: "GET", url: "/admin/nope" });
    expect(res.statusCode).toBe(404);
    expect(res.json()).toEqual({ detail: "Not Found" });
  });

  it("publicApp unknown route → 404 with the same shape", async () => {
    apps = buildMintApps(makeDeps());
    const res = await apps.publicApp.inject({ method: "GET", url: "/nope" });
    expect(res.statusCode).toBe(404);
    expect(res.json()).toEqual({ detail: "Not Found" });
  });

  it("a route throwing HttpContractError(429,'x') → 429 body {detail:'x'}", async () => {
    apps = buildMintApps(makeDeps());
    // A scratch route to drive the error handler — real routes land in Tasks 5+.
    apps.publicApp.get("/boom", async () => {
      throw new HttpContractError(429, "x");
    });
    const res = await apps.publicApp.inject({ method: "GET", url: "/boom" });
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({ detail: "x" });
  });

  it("HttpContractError headers are passed through verbatim (legacy shapes)", async () => {
    apps = buildMintApps(makeDeps());
    apps.publicApp.get("/limited", async () => {
      throw new HttpContractError(402, "monthly free limit reached", {
        "cache-control": "no-store",
      });
    });
    const res = await apps.publicApp.inject({ method: "GET", url: "/limited" });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ detail: "monthly free limit reached" });
    expect(res.headers["cache-control"]).toBe("no-store");
  });

  it("an unexpected route throw → 500 {detail:'Internal server error.'} (message never leaks)", async () => {
    apps = buildMintApps(makeDeps());
    apps.publicApp.get("/bug", async () => {
      throw new Error("secret db password in here");
    });
    const res = await apps.publicApp.inject({ method: "GET", url: "/bug" });
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({ detail: "Internal server error." });
    expect(res.body).not.toContain("secret");
  });
});
