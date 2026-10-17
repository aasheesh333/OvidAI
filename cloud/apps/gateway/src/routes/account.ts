/**
 * Legacy `/account/*` routes — the FastAPI contract the installed app calls
 * (registered on the gateway ROOT, outside `/cloud/v1`, with its own auth so
 * disabled-token recovery never reaches the ordinary cloud auth hook).
 *
 * Wire parity with `server/account/api.py`:
 *   - bodies are snake_case; unknown fields are rejected (422);
 *   - errors are HTTPException-parity `{"detail": code}` with the Python
 *     status codes (401/403/409/400/422);
 *   - cancellation requires `{"consent": true}`;
 *   - there is NO public finalize route.
 */

import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import {
  AccountError,
  type Claims,
  type Lifecycle,
  type PublicState,
} from "@ovid/account";

export type AccountClaimsVerifier = (
  token: string,
  attestation: string,
  opts: { allowDisabled: boolean },
) => Promise<Claims>;

export interface AccountRouteDeps {
  lifecycle: Lifecycle;
  verify: AccountClaimsVerifier;
}

class BodyError extends Error {
  constructor(
    readonly status: number,
    readonly detail: string,
  ) {
    super(detail);
    this.name = "BodyError";
  }
}

function headerValue(value: string | string[] | undefined): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value[0] ?? "";
  return "";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Pydantic `extra='forbid'` equivalent: only the named keys are accepted. */
function requireOnly(body: unknown, allowed: string[]): Record<string, unknown> {
  if (!isRecord(body)) throw new BodyError(422, "invalid_request");
  for (const key of Object.keys(body)) {
    if (!allowed.includes(key)) throw new BodyError(422, "invalid_request");
  }
  return body;
}

function parseDeleteRequest(body: unknown): string {
  const parsed = requireOnly(body, ["request_id"]);
  if (typeof parsed.request_id !== "string") {
    throw new BodyError(422, "invalid_request");
  }
  return parsed.request_id;
}

function sendError(reply: FastifyReply, err: unknown): FastifyReply {
  if (err instanceof AccountError) {
    return reply.code(err.status).send({ detail: err.code });
  }
  if (err instanceof BodyError) {
    return reply.code(err.status).send({ detail: err.detail });
  }
  // Unknown errors go to Fastify's gateway-wide 500 handler.
  throw err;
}

export function registerAccountRoutes(app: FastifyInstance, deps: AccountRouteDeps): void {
  async function run(
    request: FastifyRequest,
    action: (claims: Claims) => Promise<PublicState>,
    allowDisabled: boolean,
  ): Promise<PublicState> {
    const authorization = headerValue(request.headers.authorization);
    const attestation = headerValue(request.headers["x-firebase-appcheck"]);
    if (!authorization.startsWith("Bearer ") || authorization.length <= "Bearer ".length) {
      throw new AccountError("missing_authentication", 401);
    }
    const claims = await deps.verify(authorization.slice("Bearer ".length), attestation, {
      allowDisabled,
    });
    return action(claims);
  }

  app.post("/account/deletion", async (request, reply) => {
    try {
      // Body validation runs BEFORE authentication (FastAPI resolves params
      // first), so a malformed body is a 422 even without credentials.
      const requestId = parseDeleteRequest(request.body);
      return reply
        .code(200)
        .send(await run(request, (claims) => deps.lifecycle.request(claims, requestId), false));
    } catch (err) {
      return sendError(reply, err);
    }
  });

  app.get("/account/deletion", async (request, reply) => {
    try {
      return reply.code(200).send(await run(request, (claims) => deps.lifecycle.status(claims), true));
    } catch (err) {
      return sendError(reply, err);
    }
  });

  app.post("/account/login", async (request, reply) => {
    try {
      return reply.code(200).send(await run(request, (claims) => deps.lifecycle.login(claims), false));
    } catch (err) {
      return sendError(reply, err);
    }
  });

  app.post("/account/deletion/cancel", async (request, reply) => {
    try {
      if (!isRecord(request.body)) {
        throw new BodyError(400, "explicit_consent_required");
      }
      const body = requireOnly(request.body, ["consent"]);
      if (body.consent !== true) {
        throw new BodyError(400, "explicit_consent_required");
      }
      return reply
        .code(200)
        .send(await run(request, (claims) => deps.lifecycle.cancel(claims), true));
    } catch (err) {
      return sendError(reply, err);
    }
  });
}
