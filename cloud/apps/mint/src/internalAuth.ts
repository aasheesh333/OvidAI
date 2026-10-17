import type { FastifyRequest } from "fastify";
import { verifyInternalRequest } from "@ovid/shared";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";

/**
 * P9 Task 9 — the ADMIN-listener authentication seam.
 *
 * The caller is a trusted process (gateway/worker) on the docker-internal
 * network, authenticated by a per-request HMAC (see @ovid/shared's
 * internalAuth.ts). There is no Firebase verifier here: the signature binds
 * the uid, method, path and timestamp, and the uid in the BODY is the one
 * that must have been signed.
 *
 * Every failure answers the SAME 401 body — a wrong secret, a missing header,
 * a stale timestamp and a uid swap are indistinguishable to the caller.
 */

function headerValue(value: string | string[] | undefined): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value[0] ?? "";
  return "";
}

export function verifyInternalHeaders(
  deps: MintDeps,
  request: FastifyRequest,
  path: string,
  uid: string,
  now: number,
): boolean {
  return verifyInternalRequest(
    deps.env.internalApiSecret,
    request.method,
    path,
    uid,
    headerValue(request.headers["x-ovid-timestamp"]),
    headerValue(request.headers["x-ovid-signature"]),
    now,
  );
}

/** Throws the indistinguishable 401 when the request is not properly signed. */
export function requireInternalSignature(
  deps: MintDeps,
  request: FastifyRequest,
  path: string,
  uid: string,
  now: number,
): void {
  if (!verifyInternalHeaders(deps, request, path, uid, now)) {
    throw new HttpContractError(401, "unauthorized");
  }
}
