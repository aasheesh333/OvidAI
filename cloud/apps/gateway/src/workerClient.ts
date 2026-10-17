import type { ApiError, UiManifest } from "@ovid/shared";

/**
 * Gateway → worker file-service client (P7 Task 12).
 *
 * The worker's internal file service (Task 11, port 8091) is the gateway's
 * ONLY view of workspace bytes: it owns warm-vs-cold (a cold session is
 * lazily range-read out of the archive, never extracted) and the live tree.
 * This module is a thin, typed transport over that private HTTP surface:
 *
 *  - every request carries `x-ovid-internal-token` (the shared container
 *    secret) and `x-ovid-user-id` (the gateway authenticated the caller and
 *    enforced session ownership BEFORE proxying — the service trusts both);
 *  - HTTP-level errors (404/400/409/413/…) RESOLVE as discriminated results
 *    `{ ok: false, status, error }` so routes map them onto the public
 *    envelope without try/catch ladders;
 *  - only TRANSPORT failures (connect refused, timeout, malformed response)
 *    throw `WorkerUnavailableError`, which the routes answer with 503.
 */

/** Default transport timeout (ms) — global fetch + AbortSignal.timeout. */
export const DEFAULT_WORKER_TIMEOUT_MS = 10_000;

/** Inline read answer from the worker (base64 body + metadata). */
export interface WorkerFileContent {
  kind: "content";
  path: string;
  sizeBytes: number;
  sha256Hex: string;
  contentType: string;
  contentBase64: string;
  /** Task 11's additive provenance field (warm disk vs archive member). */
  source?: "warm" | "archive";
}

/** Presigned-redirect answer from the worker (binary/oversize files). */
export interface WorkerFileRedirect {
  kind: "redirect";
  path: string;
  sizeBytes: number;
  contentType: string;
  downloadUrl: string;
  expiresAt: string;
}

/**
 * Discriminated call result: HTTP-level errors resolve, only transport
 * failures throw. `error` is the service's ApiError envelope (or a
 * synthesized internal one when the body was not parseable).
 */
export type WorkerResult<T> =
  | { ok: true; value: T }
  | { ok: false; status: number; error: ApiError };

export interface WorkerClient {
  getTree(
    userId: string,
    sessionId: string,
  ): Promise<WorkerResult<{ tree: UiManifest }>>;
  getFile(
    userId: string,
    sessionId: string,
    path: string,
  ): Promise<WorkerResult<WorkerFileContent | WorkerFileRedirect>>;
  putFile(
    userId: string,
    sessionId: string,
    path: string,
    contentBase64: string,
  ): Promise<WorkerResult<{ path: string; sizeBytes: number; sha256: string }>>;
}

/** The file service is unreachable or answered garbage (route → 503). */
export class WorkerUnavailableError extends Error {
  constructor(message: string, opts?: { cause?: unknown }) {
    super(message, opts?.cause === undefined ? undefined : { cause: opts.cause });
    this.name = "WorkerUnavailableError";
  }
}

export interface WorkerClientConfig {
  /** e.g. `http://127.0.0.1:8091` — the container-internal file service. */
  baseUrl: string;
  token: string;
  /** Default 10_000. */
  timeoutMs?: number;
}

function isApiErrorEnvelope(v: unknown): v is ApiError {
  if (typeof v !== "object" || v === null) return false;
  const error = (v as { error?: unknown }).error;
  if (typeof error !== "object" || error === null) return false;
  const { code, message } = error as { code?: unknown; message?: unknown };
  return typeof code === "string" && typeof message === "string";
}

async function request<T>(
  cfg: WorkerClientConfig,
  opts: { method: "GET" | "PUT"; url: string; userId: string; body?: unknown },
): Promise<WorkerResult<T>> {
  let res: Response;
  try {
    res = await fetch(opts.url, {
      method: opts.method,
      headers: {
        "x-ovid-internal-token": cfg.token,
        "x-ovid-user-id": opts.userId,
        ...(opts.body !== undefined ? { "content-type": "application/json" } : {}),
      },
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      signal: AbortSignal.timeout(cfg.timeoutMs ?? DEFAULT_WORKER_TIMEOUT_MS),
    });
  } catch (err) {
    throw new WorkerUnavailableError(
      `worker file service unreachable: ${err instanceof Error ? err.message : String(err)}`,
      { cause: err },
    );
  }

  let json: unknown = null;
  try {
    json = await res.json();
  } catch {
    json = null;
  }

  if (!res.ok) {
    const error: ApiError = isApiErrorEnvelope(json)
      ? json
      : {
          error: {
            code: "internal",
            message: `worker file service answered ${res.status}`,
          },
        };
    return { ok: false, status: res.status, error };
  }

  if (json === null || typeof json !== "object") {
    throw new WorkerUnavailableError(
      `worker file service returned a malformed ${opts.method} ${opts.url} response`,
    );
  }
  return { ok: true, value: json as T };
}

export function createWorkerClient(cfg: WorkerClientConfig): WorkerClient {
  const base = cfg.baseUrl.replace(/\/+$/, "");
  const sessionUrl = (sessionId: string, suffix: string): string =>
    `${base}/internal/sessions/${encodeURIComponent(sessionId)}${suffix}`;

  return {
    async getTree(userId, sessionId) {
      return request<{ tree: UiManifest }>(cfg, {
        method: "GET",
        url: sessionUrl(sessionId, "/tree"),
        userId,
      });
    },

    async getFile(userId, sessionId, path) {
      return request<WorkerFileContent | WorkerFileRedirect>(cfg, {
        method: "GET",
        url: `${sessionUrl(sessionId, "/file")}?path=${encodeURIComponent(path)}`,
        userId,
      });
    },

    async putFile(userId, sessionId, path, contentBase64) {
      return request<{ path: string; sizeBytes: number; sha256: string }>(cfg, {
        method: "PUT",
        url: `${sessionUrl(sessionId, "/file")}?path=${encodeURIComponent(path)}`,
        userId,
        body: { contentBase64 },
      });
    },
  };
}
