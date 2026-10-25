import { z } from "zod";

import {
  PREVIEW_HTTP_IDLE_TIMEOUT_MS,
  PREVIEW_HTTP_MAX_BYTES,
  buildPreviewUpstreamHeaders,
  normalizePreviewPath,
  type PreviewHeaderInput,
} from "./previewOrigin.js";

export const DEFAULT_STUDIO_PREVIEW_WORKER_TIMEOUT_MS = 10_000;
const MAX_WORKER_TIMEOUT_MS = 30_000;
const MAX_JSON_BYTES = 1024 * 1024;
const MAX_ERROR_BYTES = 64 * 1024;
const PREVIEW_ID = /^[A-Za-z0-9_-]{1,128}$/;
const SAFE_ERROR_CODE = /^[a-z][a-z0-9_]{0,63}$/;

const previewId = z.string().regex(PREVIEW_ID);
const identity = z.string().min(1).max(512).refine(
  (value) => !/[\u0000-\u001f\u007f]/.test(value),
);
const timestamp = z.string().max(64).refine(
  (value) => Number.isFinite(Date.parse(value)),
);
const kind = z.enum(["static", "dev_server"]);
const status = z.enum(["starting", "running", "stopping", "stopped", "failed", "expired"]);

const dtoSchema = z.object({
  id: previewId,
  kind,
  status,
  generation: z.number().int().positive(),
  expiresAt: timestamp,
  lastAccessAt: timestamp.nullable(),
  logAvailable: z.boolean(),
}).strict();
const listSchema = z.object({ items: z.array(dtoSchema).max(1_000) }).strict();
const logsSchema = z.object({
  text: z.string().max(256 * 1024),
  truncated: z.boolean(),
}).strict();

const registrationCommon = {
  id: previewId,
  userId: identity,
  sessionId: identity,
  generation: z.number().int().positive(),
  status,
  expiresAt: timestamp,
  lastAccessAt: timestamp.nullable(),
};
const staticRegistrationSchema = z.object({
  ...registrationCommon,
  kind: z.literal("static"),
  bindHost: z.null(),
  port: z.null(),
}).strict();
const devRegistrationSchema = z.object({
  ...registrationCommon,
  kind: z.literal("dev_server"),
  bindHost: z.string().min(1).max(253),
  port: z.number().int().min(20_000).max(29_999),
}).strict();
const registrationSchema = z.discriminatedUnion("kind", [
  staticRegistrationSchema,
  devRegistrationSchema,
]);
const touchSchema = z.object({ touched: z.boolean() }).strict();

export type StudioPreviewKind = z.infer<typeof kind>;
export type StudioPreviewStatus = z.infer<typeof status>;
export type StudioPreviewDto = z.infer<typeof dtoSchema>;
export type StudioPreviewRegistration = z.infer<typeof registrationSchema>;
export type StudioPreviewStartBody =
  | { kind: "static"; workspacePath: string }
  | { kind: "dev_server"; projectDir: string; script: "dev" | "start" | "preview" };

export interface StudioPreviewLogs {
  text: string;
  truncated: boolean;
}

export interface StudioPreviewStaticContent {
  status: number;
  headers: Headers;
  body: Buffer;
}

const ERROR_MESSAGES: Readonly<Record<string, string>> = {
  preview_unavailable: "Studio preview worker is unavailable.",
  not_found: "Preview not found.",
  bad_request: "Invalid Studio preview definition.",
  redirect_denied: "Preview upstream redirects are not allowed.",
  response_too_large: "Preview response is too large.",
  upstream_timeout: "Preview upstream timed out.",
};

/** A sanitized worker HTTP verdict. The worker's message/body is never retained. */
export class StudioPreviewWorkerHttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(ERROR_MESSAGES[code] ?? ERROR_MESSAGES.preview_unavailable);
    this.name = "StudioPreviewWorkerHttpError";
  }
}

/** Network, timeout, malformed-DTO, or overlarge-management-response failure. */
export class StudioPreviewWorkerUnavailableError extends Error {
  readonly status = 503;
  readonly code = "preview_unavailable";

  constructor() {
    super(ERROR_MESSAGES.preview_unavailable);
    this.name = "StudioPreviewWorkerUnavailableError";
  }
}

export interface StudioPreviewWorkerClientConfig {
  baseUrl: string;
  token: string;
  timeoutMs?: number;
  idleTimeoutMs?: number;
  maxStaticBytes?: number;
  fetch?: typeof fetch;
}

export interface StudioPreviewTouchInput {
  sessionId: string;
  previewId: string;
  generation: number;
  now: Date;
}

export interface StudioPreviewStaticInput {
  sessionId: string;
  previewId: string;
  method: "GET" | "HEAD";
  path: string;
  headers?: PreviewHeaderInput;
}

/** Methods deliberately omit userId: it is fixed once from the verified principal. */
export interface BoundStudioPreviewWorkerClient {
  start(sessionId: string, body: StudioPreviewStartBody): Promise<StudioPreviewDto>;
  list(sessionId: string): Promise<StudioPreviewDto[]>;
  get(sessionId: string, previewId: string): Promise<StudioPreviewDto | null>;
  stop(sessionId: string, previewId: string): Promise<StudioPreviewDto>;
  logs(sessionId: string, previewId: string): Promise<StudioPreviewLogs>;
  /** Separate private registration route; the management DTO is insufficient. */
  getLiveRegistration(
    sessionId: string,
    previewId: string,
  ): Promise<StudioPreviewRegistration | null>;
  /** Actual DB-write verdict; false also includes throttle and always requires a following read. */
  touch(input: StudioPreviewTouchInput): Promise<boolean>;
  readStatic(input: StudioPreviewStaticInput): Promise<StudioPreviewStaticContent>;
}

export interface StudioPreviewWorkerClient {
  forUser(verifiedUserId: string): BoundStudioPreviewWorkerClient;
}

class TransportFailure extends Error {
  constructor(readonly timedOut: boolean) {
    super(timedOut ? "timeout" : "transport");
  }
}

class ByteLimitFailure extends Error {}

function bounded(value: number | undefined, fallback: number, maximum: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback;
  return Math.min(maximum, Math.max(1, Math.floor(value)));
}

async function withDeadline<T>(
  operation: () => Promise<T>,
  timeoutMs: number,
  onTimeout: () => void,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      onTimeout();
      reject(new TransportFailure(true));
    }, timeoutMs);
  });
  try {
    return await Promise.race([Promise.resolve().then(operation), deadline]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

interface WorkerFetchExchange {
  response: Response;
  controller: AbortController;
}

async function fetchBounded(
  cfg: StudioPreviewWorkerClientConfig,
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<WorkerFetchExchange> {
  const controller = new AbortController();
  const fetchImpl = cfg.fetch ?? globalThis.fetch;
  try {
    const response = await withDeadline(
      () => fetchImpl(url, { ...init, signal: controller.signal }),
      timeoutMs,
      () => controller.abort(),
    );
    return { response, controller };
  } catch (error) {
    controller.abort();
    if (error instanceof TransportFailure) throw error;
    throw new TransportFailure(false);
  }
}

function declaredLength(response: Response): number | null {
  const raw = response.headers.get("content-length");
  if (raw === null || !/^\d+$/.test(raw)) return null;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : null;
}

function discardBody(response: Response, controller: AbortController): void {
  // This is the SAME signal supplied to fetch, including after headers arrive.
  // Never await body.cancel(): a broken upstream stream must not defeat cleanup.
  controller.abort();
  try {
    const pending = response.body?.cancel();
    if (pending !== undefined) void pending.catch(() => {});
  } catch {
    // Locked/errored streams are already covered by the fetch abort above.
  }
}

async function readBody(
  response: Response,
  method: "GET" | "HEAD",
  maxBytes: number,
  idleTimeoutMs: number,
  controller: AbortController,
): Promise<Buffer> {
  if (method === "HEAD" || response.status === 204 || response.status === 304 || response.body === null) {
    discardBody(response, controller);
    return Buffer.alloc(0);
  }
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  let completed = false;
  try {
    for (;;) {
      const next = await withDeadline(
        () => reader.read(),
        idleTimeoutMs,
        () => controller.abort(),
      );
      if (next.done) break;
      if (!(next.value instanceof Uint8Array)) throw new TransportFailure(false);
      total += next.value.byteLength;
      if (total > maxBytes) throw new ByteLimitFailure();
      chunks.push(Buffer.from(next.value.buffer, next.value.byteOffset, next.value.byteLength));
    }
    completed = true;
    return Buffer.concat(chunks, total);
  } catch (error) {
    controller.abort();
    try {
      void reader.cancel().catch(() => {});
    } catch {
      // Synchronously broken stream cleanup cannot replace the bounded error.
    }
    throw error;
  } finally {
    // A timed-out read may still be pending; releasing then would throw and
    // mask the bounded outcome. Successful EOF is safe to release.
    if (completed) reader.releaseLock();
  }
}

function errorCode(value: unknown): string {
  if (typeof value !== "object" || value === null) return "unavailable";
  const envelope = (value as { error?: unknown }).error;
  if (typeof envelope !== "object" || envelope === null) return "unavailable";
  const code = (envelope as { code?: unknown }).code;
  return typeof code === "string" && SAFE_ERROR_CODE.test(code) ? code : "unavailable";
}

async function httpError(
  response: Response,
  cfg: StudioPreviewWorkerClientConfig,
  controller: AbortController,
): Promise<StudioPreviewWorkerHttpError> {
  let code = "unavailable";
  try {
    const body = await readBody(
      response,
      "GET",
      MAX_ERROR_BYTES,
      bounded(cfg.idleTimeoutMs, PREVIEW_HTTP_IDLE_TIMEOUT_MS, PREVIEW_HTTP_IDLE_TIMEOUT_MS),
      controller,
    );
    code = errorCode(JSON.parse(body.toString("utf8")));
  } catch {
    // Status is still safe to relay through the gateway's fixed error mapping.
  }
  return new StudioPreviewWorkerHttpError(response.status, code);
}

async function requestJson<T>(
  cfg: StudioPreviewWorkerClientConfig,
  schema: z.ZodType<T>,
  options: {
    method: "GET" | "POST";
    url: string;
    userId: string;
    body?: unknown;
    notFound?: boolean;
  },
): Promise<T | null> {
  const timeoutMs = bounded(
    cfg.timeoutMs,
    DEFAULT_STUDIO_PREVIEW_WORKER_TIMEOUT_MS,
    MAX_WORKER_TIMEOUT_MS,
  );
  let exchange: WorkerFetchExchange;
  try {
    exchange = await fetchBounded(cfg, options.url, {
      method: options.method,
      redirect: "manual",
      headers: {
        "x-ovid-internal-token": cfg.token,
        "x-ovid-user-id": options.userId,
        accept: "application/json",
        ...(options.body !== undefined ? { "content-type": "application/json" } : {}),
      },
      ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}),
    }, timeoutMs);
  } catch {
    throw new StudioPreviewWorkerUnavailableError();
  }

  const { response, controller } = exchange;
  try {
    if (isRedirect(response.status)) {
      throw new StudioPreviewWorkerUnavailableError();
    }
    if (!response.ok) {
      if (options.notFound === true && response.status === 404) {
        discardBody(response, controller);
        return null;
      }
      throw await httpError(response, cfg, controller);
    }
    const declared = declaredLength(response);
    if (declared !== null && declared > MAX_JSON_BYTES) {
      throw new StudioPreviewWorkerUnavailableError();
    }
    const body = await readBody(
      response,
      "GET",
      MAX_JSON_BYTES,
      bounded(cfg.idleTimeoutMs, PREVIEW_HTTP_IDLE_TIMEOUT_MS, PREVIEW_HTTP_IDLE_TIMEOUT_MS),
      controller,
    );
    let json: unknown;
    try {
      json = JSON.parse(body.toString("utf8"));
    } catch {
      throw new StudioPreviewWorkerUnavailableError();
    }
    const parsed = schema.safeParse(json);
    if (!parsed.success) throw new StudioPreviewWorkerUnavailableError();
    return parsed.data;
  } catch (error) {
    discardBody(response, controller);
    if (error instanceof StudioPreviewWorkerHttpError ||
        error instanceof StudioPreviewWorkerUnavailableError) throw error;
    throw new StudioPreviewWorkerUnavailableError();
  }
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}

function sessionBase(cfg: StudioPreviewWorkerClientConfig, sessionId: string): string {
  const base = cfg.baseUrl.replace(/\/+$/, "");
  return `${base}/internal/sessions/${encodeURIComponent(sessionId)}`;
}

function previewBase(
  cfg: StudioPreviewWorkerClientConfig,
  sessionId: string,
  previewId: string,
): string {
  return `${sessionBase(cfg, sessionId)}/previews/${encodeURIComponent(previewId)}`;
}

export function createStudioPreviewWorkerClient(
  cfg: StudioPreviewWorkerClientConfig,
): StudioPreviewWorkerClient {
  return {
    forUser(verifiedUserId) {
      if (verifiedUserId.trim() === "" || verifiedUserId.trim() !== verifiedUserId) {
        throw new Error("A verified Studio preview user is required.");
      }
      const uid = verifiedUserId;
      const json = <T>(
        schema: z.ZodType<T>,
        options: {
          method: "GET" | "POST";
          url: string;
          body?: unknown;
          notFound?: boolean;
        },
      ): Promise<T | null> => requestJson(cfg, schema, { ...options, userId: uid });
      const required = async <T>(operation: Promise<T | null>): Promise<T> => {
        const result = await operation;
        if (result === null) throw new StudioPreviewWorkerUnavailableError();
        return result;
      };

      return {
        start(sessionId, body) {
          return required(json(dtoSchema, {
            method: "POST",
            url: `${sessionBase(cfg, sessionId)}/previews`,
            body,
          }));
        },
        async list(sessionId) {
          const result = await required(json(listSchema, {
            method: "GET",
            url: `${sessionBase(cfg, sessionId)}/previews`,
          }));
          return result.items;
        },
        get(sessionId, previewId) {
          return json(dtoSchema, {
            method: "GET",
            url: previewBase(cfg, sessionId, previewId),
            notFound: true,
          });
        },
        stop(sessionId, previewId) {
          return required(json(dtoSchema, {
            method: "POST",
            url: `${previewBase(cfg, sessionId, previewId)}/stop`,
          }));
        },
        logs(sessionId, previewId) {
          return required(json(logsSchema, {
            method: "GET",
            url: `${previewBase(cfg, sessionId, previewId)}/logs`,
          }));
        },
        getLiveRegistration(sessionId, previewId) {
          return json(registrationSchema, {
            method: "GET",
            url: `${previewBase(cfg, sessionId, previewId)}/registration`,
            notFound: true,
          });
        },
        async touch(input) {
          if (!Number.isSafeInteger(input.generation) || input.generation <= 0 ||
              !Number.isFinite(input.now.getTime())) {
            throw new StudioPreviewWorkerUnavailableError();
          }
          const result = await json(touchSchema, {
            method: "POST",
            url: `${previewBase(cfg, input.sessionId, input.previewId)}/touch`,
            body: {
              generation: input.generation,
              now: input.now.toISOString(),
            },
          });
          if (result === null) throw new StudioPreviewWorkerUnavailableError();
          return result.touched;
        },
        async readStatic(input) {
          if (input.method !== "GET" && input.method !== "HEAD") {
            throw new StudioPreviewWorkerHttpError(405, "method_not_allowed");
          }
          const path = normalizePreviewPath(input.path);
          if (path === null) throw new StudioPreviewWorkerHttpError(400, "bad_path");
          const maxBytes = bounded(cfg.maxStaticBytes, PREVIEW_HTTP_MAX_BYTES, PREVIEW_HTTP_MAX_BYTES);
          const idleTimeoutMs = bounded(
            cfg.idleTimeoutMs,
            PREVIEW_HTTP_IDLE_TIMEOUT_MS,
            PREVIEW_HTTP_IDLE_TIMEOUT_MS,
          );
          const headers = buildPreviewUpstreamHeaders(input.headers ?? {});
          let exchange: WorkerFetchExchange;
          try {
            exchange = await fetchBounded(cfg, `${previewBase(cfg, input.sessionId, input.previewId)}/static${path}`, {
              method: input.method,
              headers: {
                ...headers,
                "x-ovid-internal-token": cfg.token,
                "x-ovid-user-id": uid,
              },
              redirect: "manual",
            }, idleTimeoutMs);
          } catch (error) {
            if (error instanceof TransportFailure && error.timedOut) {
              throw new StudioPreviewWorkerHttpError(504, "upstream_timeout");
            }
            throw new StudioPreviewWorkerUnavailableError();
          }

          const { response, controller } = exchange;
          try {
            if (isRedirect(response.status)) {
              throw new StudioPreviewWorkerHttpError(502, "redirect_denied");
            }
            if (!response.ok && response.status !== 304) {
              throw await httpError(response, cfg, controller);
            }
            const declared = declaredLength(response);
            if (declared !== null && declared > maxBytes) {
              throw new StudioPreviewWorkerHttpError(413, "response_too_large");
            }
            const body = await readBody(response, input.method, maxBytes, idleTimeoutMs, controller);
            return { status: response.status, headers: new Headers(response.headers), body };
          } catch (error) {
            discardBody(response, controller);
            if (error instanceof StudioPreviewWorkerHttpError) throw error;
            if (error instanceof ByteLimitFailure) {
              throw new StudioPreviewWorkerHttpError(413, "response_too_large");
            }
            if (error instanceof TransportFailure && error.timedOut) {
              throw new StudioPreviewWorkerHttpError(504, "upstream_timeout");
            }
            throw new StudioPreviewWorkerUnavailableError();
          }
        },
      };
    },
  };
}
