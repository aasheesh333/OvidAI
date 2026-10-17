import Fastify, { type FastifyError, type FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { Alerter } from "./alerts.js";
import type { MintEnv } from "./env.js";
import type { LiteLlmAdmin } from "./litellmAdmin.js";
import { registerMintRoutes } from "./mintRoutes.js";
import { registerUsageRoutes } from "./usage.js";

/**
 * Mint's TWO Fastify apps:
 *  - publicApp  (port 8091): the app-facing surface — /mint, /usage, /plans,
 *    /v1/models, /v1/images/* (Tasks 5–6, 12–15) + /healthz.
 *  - adminApp   (port 8092): the owner console (Task 8), guarded by
 *    OVID_ADMIN_MASTER_KEY — never reachable from the public listener.
 *
 * Both are returned UNLISTENED so tests inject() against them directly.
 */

/**
 * FastAPI HTTPException parity: mint's contract errors keep the LEGACY wire
 * shape — body {"detail": string} (+ any headers verbatim) — because the
 * installed APK and the LiteLLM hook depend on it. This is deliberately NOT
 * the /cloud ApiError envelope the gateway uses.
 */
export class HttpContractError extends Error {
  constructor(
    readonly status: number,
    readonly detail: string,
    readonly headers?: Record<string, string>,
  ) {
    super(detail);
    this.name = "HttpContractError";
  }
}

/** Verified identity — Task 6's verifier.ts becomes the canonical producer. */
export interface MintIdentity {
  uid: string;
  email: string | null;
  platform: "android" | "web";
}

export type MintIdentityVerifier = (headers: {
  authorization: string;
  appcheck: string;
  xff: string;
  xRealIp: string;
}) => Promise<MintIdentity>;

export interface MintDeps {
  db: Db;
  redis: Redis;
  litellm: LiteLlmAdmin;
  env: MintEnv;
  alerter: Alerter;
  verifyIdentity: MintIdentityVerifier;
  /** Reserved for time-sensitive logic (windows, budgets, sweeps). */
  clock?: () => Date;
  /** Seams for later tasks' outbound calls (billing Play API, image probes). */
  fetchImpl?: typeof fetch;
  /**
   * Task 6: the mintlock wait (mint.py: 20 × 250 ms). Injectable so the
   * route/key-mint tests can pin the 409 without a 5-second sleep.
   */
  mintLock?: { pollMs: number; polls: number };
}

/**
 * Shared error/not-found handling for both apps:
 *  - HttpContractError → its status, {"detail": …} body and headers VERBATIM;
 *  - Fastify 4xx (body-parse etc.) → {"detail": message};
 *  - anything else → logged server-side, collapsed to a generic 500 (the
 *    internal message never crosses the wire);
 *  - unknown routes → 404 {"detail":"Not Found"} (FastAPI's shape).
 */
function installErrorHandling(app: FastifyInstance): void {
  // Param stays FastifyError (Fastify's handler generic requires it); a
  // thrown HttpContractError narrows via instanceof — same pattern the
  // gateway's handler uses for its own error classes.
  app.setErrorHandler((error: FastifyError, request, reply) => {
    if (error instanceof HttpContractError) {
      return reply
        .code(error.status)
        .headers(error.headers ?? {})
        .send({ detail: error.detail });
    }
    const status = typeof error.statusCode === "number" ? error.statusCode : 500;
    if (status < 400 || status >= 500) {
      request.log.error({ err: error }, "unhandled error in mint route");
      return reply.code(500).send({ detail: "Internal server error." });
    }
    return reply.code(status).send({ detail: error.message });
  });

  app.setNotFoundHandler((_request, reply) => {
    return reply.code(404).send({ detail: "Not Found" });
  });
}

/**
 * Builds the public + admin apps. The public app gets /healthz here (the
 * orchestrator probe — explicitly unauthenticated); every real route is
 * registered by its own task (Tasks 5–8, 12–15) against these same deps.
 */
export function buildMintApps(deps: MintDeps): {
  publicApp: FastifyInstance;
  adminApp: FastifyInstance;
} {
  void deps; // routes registering on deps land in Tasks 5+; scaffold keeps
  // the parameter wired so every later task composes against the same shape.

  const publicApp = Fastify({ logger: false });
  installErrorHandling(publicApp);
  publicApp.get("/healthz", async () => ({ ok: true }));
  // Task 5: the app-facing /usage contract. Task 6: /mint, /upgrade, /plans
  // and /v1/models. Later tasks register their own route groups here.
  registerUsageRoutes(publicApp, deps);
  registerMintRoutes(publicApp, deps);

  const adminApp = Fastify({ logger: false });
  installErrorHandling(adminApp);
  // Task 8 ports the console routes here; the scaffold has none yet, so the
  // admin surface answers 404 for everything except the error contract.

  return { publicApp, adminApp };
}
