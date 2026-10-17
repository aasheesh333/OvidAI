import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { MintDeps } from "../app.js";
import { isBanned } from "../antiAbuse.js";
import { setModelCatalogProjection } from "../catalog.js";
import { effectiveTier, freeCapRemaining } from "../windows.js";
import { createAdmission, type Admission } from "./admission.js";
import { createImagesAuth } from "./auth.js";
import { PublicCatalog } from "./catalog.js";
import {
  IMAGE_BODY_LIMIT,
  LiteLlmImageService,
} from "./service.js";
import { ImageError } from "./types.js";

/**
 * Port of server/images/verifier.py mount_images():
 *
 *   GET  /v1/images/capabilities                 catalog + ETag/304
 *   GET  /v1/images/requests/:requestId          receipt  (zero-quota safe)
 *   GET  /v1/images/requests/:requestId/result   replay   (zero-quota safe)
 *   POST /v1/images/generations                  generate
 *   POST /v1/images/edits                        edit
 *
 * Mount rule: without BOTH the service and the shared admission bridge the
 * routes stay closed (503 image_unavailable). Error bodies are the exact
 * public envelope `{"error":{"code", …},"receipt"?}` with Cache-Control
 * no-store; unexpected failures collapse to 401/403 image_access_denied or
 * 503 image_unavailable and never echo JWT/DB/provider text.
 */

function headerValue(value: string | string[] | undefined): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value[0] ?? "";
  return "";
}

function headersOf(request: FastifyRequest): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(request.headers)) {
    if (typeof value === "string") out[key] = value;
    else if (Array.isArray(value)) out[key] = value.join(",");
  }
  return out;
}

function pathOf(request: FastifyRequest): string {
  return request.url.split("?")[0] ?? request.url;
}

function sendImageError(reply: FastifyReply, error: ImageError): FastifyReply {
  const body: { error: Record<string, unknown>; receipt?: unknown } = {
    error: { code: error.code },
  };
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  if (error.retryAfterSeconds !== null) {
    body.error.retryAfterSeconds = error.retryAfterSeconds;
    headers["Retry-After"] = String(error.retryAfterSeconds);
  }
  if (error.detail !== null) Object.assign(body.error, error.detail);
  if (error.receipt !== null) body.receipt = error.receipt;
  return reply.code(error.status).headers(headers).send(body);
}

function sendUnexpected(reply: FastifyReply, error: unknown): FastifyReply {
  const candidate = error as { status?: unknown; statusCode?: unknown };
  const raw =
    typeof candidate?.status === "number"
      ? candidate.status
      : typeof candidate?.statusCode === "number"
        ? candidate.statusCode
        : 0;
  const status = raw === 401 || raw === 403 ? raw : 503;
  return reply
    .code(status)
    .headers({ "Cache-Control": "no-store" })
    .send({ error: { code: status === 503 ? "image_unavailable" : "image_access_denied" } });
}

function handleError(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof ImageError) return sendImageError(reply, error);
  return sendUnexpected(reply, error);
}

export interface ImagesRouteOptions {
  /** Test seams for the settings-backed identity ladder. */
  effectiveTier?(deps: MintDeps, uid: string): Promise<string>;
  freeCapRemaining?(deps: MintDeps, uid: string): Promise<number>;
  isBanned?(deps: MintDeps, uid: string, ip: string): Promise<boolean>;
}

export function registerImagesRoutes(
  publicApp: FastifyInstance,
  deps: MintDeps,
  service: LiteLlmImageService | null,
  admission: Admission | null,
  opts: ImagesRouteOptions = {},
): void {
  const auth = createImagesAuth({
    env: deps.env,
    redis: deps.redis,
    litellm: deps.litellm,
    verifyIdentity: deps.verifyIdentity,
    effectiveTier: (uid) => (opts.effectiveTier ?? effectiveTier)(deps, uid),
    freeCapRemaining: (uid) => (opts.freeCapRemaining ?? freeCapRemaining)(deps, uid),
    isBanned: (uid, ip) => (opts.isBanned ?? isBanned)(deps, uid, ip),
    clock: deps.clock === undefined ? undefined : () => deps.clock!().getTime(),
  });

  // The PublicCatalog masking hook is installed only when the images mount is
  // composed, so an isolated Task-6 passthrough keeps its historical contract
  // while the production mount hides private backends and the image alias.
  publicApp.addHook("onReady", async () => {
    const privateNames = service === null ? [] : await service.privateModelNames();
    setModelCatalogProjection(
      new PublicCatalog(privateNames, () => service !== null && admission !== null),
    );
  });

  publicApp.register(async (scope) => {
    // Raw-body capture: the Python route bounds the wire bytes before JSON
    // parsing (413), accepts any Content-Type long enough to answer 415, and
    // parses JSON itself (400 on malformed input).
    scope.removeContentTypeParser("application/json");
    scope.addContentTypeParser("application/json", { parseAs: "buffer" }, (_request, body, done) => {
      done(null, body);
    });
    scope.addContentTypeParser("*", { parseAs: "buffer" }, (_request, body, done) => {
      done(null, body);
    });

    scope.setErrorHandler((error, _request, reply) => {
      const code = (error as { code?: unknown }).code;
      if (code === "FST_ERR_CTP_BODY_TOO_LARGE") {
        return sendImageError(reply, new ImageError(413, "image_too_large"));
      }
      if (code === "FST_ERR_CTP_INVALID_MEDIA_TYPE") {
        return sendImageError(reply, new ImageError(415, "invalid_image_request"));
      }
      return handleError(reply, error);
    });

    const getHandler = async (request: FastifyRequest, reply: FastifyReply) => {
      try {
        if (service === null || admission === null) {
          throw new ImageError(503, "image_unavailable");
        }
        const params = request.params as { requestId?: string };
        const receiptRead = typeof params.requestId === "string";
        const identity = receiptRead
          ? await auth.verifyIdentity(headersOf(request))
          : await auth.authenticate(headersOf(request));

        let result: Record<string, unknown>;
        if (!receiptRead) {
          result = (await service.catalog()) as unknown as Record<string, unknown>;
        } else if (pathOf(request).endsWith("/result")) {
          result = await service.ledger.replay(identity.uid, params.requestId!);
        } else {
          result = { receipt: await service.ledger.receipt(identity.uid, params.requestId!) };
        }

        const headers: Record<string, string> = { "Cache-Control": "no-store" };
        if (!receiptRead) headers["X-Ovid-Gateway"] = "2";
        const digest = typeof result.catalog_hash === "string" ? result.catalog_hash : null;
        if (digest !== null) {
          const etag = `"${digest}"`;
          headers.ETag = etag;
          const sent = headerValue(request.headers["if-none-match"])
            .split(",")
            .map((value) => value.trim().replace(/^W\//, ""));
          if (sent.includes(etag)) return reply.code(304).headers(headers).send();
        }
        return reply.headers(headers).send(result);
      } catch (error) {
        return handleError(reply, error);
      }
    };

    const postHandler = async (request: FastifyRequest, reply: FastifyReply) => {
      try {
        if (service === null || admission === null) {
          throw new ImageError(503, "image_unavailable");
        }
        // verifier.py authenticates before inspecting the request body: an
        // unauthenticated caller learns nothing about content-type handling.
        const identity = await auth.authenticate(headersOf(request));
        const contentType = headerValue(request.headers["content-type"]);
        if (contentType.split(";")[0]!.trim() !== "application/json") {
          throw new ImageError(415, "invalid_image_request");
        }
        const raw = Buffer.isBuffer(request.body)
          ? request.body
          : typeof request.body === "string"
            ? Buffer.from(request.body)
            : Buffer.from(JSON.stringify(request.body ?? null));
        if (raw.length > IMAGE_BODY_LIMIT) throw new ImageError(413, "image_too_large");
        let body: unknown;
        try {
          body = JSON.parse(raw.toString("utf8"));
        } catch {
          throw new ImageError(400, "invalid_image_request");
        }

        const operation = pathOf(request).endsWith("/edits") ? "edit" : "generate";
        const requestId = headerValue(request.headers["idempotency-key"]);
        const result = await admission(identity, (ctx) =>
          service.execute(
            identity.uid,
            requestId,
            operation,
            body as Record<string, unknown>,
            ctx.budget,
            { budgetWindow: ctx.window },
          ),
        );
        return reply.headers({ "Cache-Control": "no-store" }).send(result);
      } catch (error) {
        return handleError(reply, error);
      }
    };

    scope.get("/v1/images/capabilities", getHandler);
    scope.get("/v1/images/requests/:requestId", getHandler);
    scope.get("/v1/images/requests/:requestId/result", getHandler);
    scope.post("/v1/images/generations", { bodyLimit: IMAGE_BODY_LIMIT }, postHandler);
    scope.post("/v1/images/edits", { bodyLimit: IMAGE_BODY_LIMIT }, postHandler);
  });
}

export { createAdmission };
