import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { reportsRepo, type Db } from "@ovid/db";
import { z } from "zod";
import type { AuthPrincipal, Verifier } from "../auth.js";
import { sqlText } from "../sql.js";

/**
 * Legacy `POST /v1/reports` — port of `server/reports/api.py`.
 *
 * Caddy routes this exact path ahead of LiteLLM's `/v1/*` (Task 18). Reporter
 * identity comes ONLY from the verified token; the body is a strict
 * allowlist and unknown fields are rejected. Responses use the legacy
 * `{"detail": code}` error body and `{Cache-Control: no-store,
 * X-Content-Type-Options: nosniff}` headers.
 */

const KINDS = [
  "ai_output",
  "shared_conversation",
  "collab_message",
  "collab_participant",
] as const;
const REASONS = [
  "sexual",
  "child_safety",
  "hate",
  "violence",
  "self_harm",
  "illegal",
  "misleading",
  "privacy",
  "spam",
  "other",
] as const;

const DEFAULT_DAILY_LIMIT = 50;
const DAY_SECONDS = 86_400;
const MAX_DETAILS = 1000;
const MAX_EXCERPT = 4000;
const MAX_TARGET = 128;
const REQUEST_ID_RE = /^[A-Za-z0-9_-]{16,64}$/;

export const REPORT_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};

/** Task 15 `lifecycle.access` seam (same shape as the shares admission). */
export type ReportsAdmission = <T>(
  principal: AuthPrincipal,
  fn: (uid: string) => Promise<T>,
) => Promise<T>;

export interface ReportsDeps {
  db: Db;
  verifier: Verifier;
  admission?: ReportsAdmission;
  clock?: () => Date;
  /** Python ReportRepository default is 50 reports / 24 h / reporter. */
  dailyLimit?: number;
}

export type ReportsConfig = Omit<ReportsDeps, "db" | "verifier">;

/** Legacy HTTP error carrying the Python `(status, code)` pair. */
export class ReportsHttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
    this.name = "ReportsHttpError";
  }
}

export class ReportValidationError extends Error {
  constructor() {
    super("invalid_report");
    this.name = "ReportValidationError";
  }
}

/** Python `len(str)` counts Unicode code points. */
function codePoints(value: string): number {
  return Array.from(value).length;
}

const createReportSchema = z
  .object({
    request_id: z.string().regex(REQUEST_ID_RE),
    kind: z.enum(KINDS),
    reason: z.enum(REASONS),
    details: z
      .string()
      .optional()
      .default("")
      .refine((value) => codePoints(value) <= MAX_DETAILS),
    excerpt: z
      .string()
      .optional()
      .default("")
      .refine((value) => codePoints(value) <= MAX_EXCERPT),
    target_id: z.string().max(MAX_TARGET).nullable().optional(),
    model: z.string().max(MAX_TARGET).nullable().optional(),
  })
  .strict();

export interface CreateReport {
  request_id: string;
  kind: (typeof KINDS)[number];
  reason: (typeof REASONS)[number];
  details: string;
  excerpt: string;
  target_id: string | null;
  model: string | null;
}

export function parseCreateReport(body: unknown): CreateReport {
  const parsed = createReportSchema.safeParse(body);
  if (!parsed.success) throw new ReportValidationError();
  return {
    ...parsed.data,
    target_id: parsed.data.target_id ?? null,
    model: parsed.data.model ?? null,
  };
}

function headerValue(raw: string | string[] | undefined): string | null {
  const value = Array.isArray(raw) ? raw[0] : raw;
  return typeof value === "string" && value !== "" ? value : null;
}

function sendDetail(reply: FastifyReply, status: number, code: string): FastifyReply {
  return reply.code(status).send({ detail: code });
}

function knownError(error: unknown): { status: number; code: string } | null {
  if (typeof error !== "object" || error === null) return null;
  const candidate = error as { status?: unknown; code?: unknown };
  if (typeof candidate.code === "string" && typeof candidate.status === "number") {
    return { status: candidate.status, code: candidate.code };
  }
  return null;
}

function nowOf(deps: ReportsDeps): Date {
  return deps.clock ? deps.clock() : new Date();
}

async function requirePrincipal(
  request: FastifyRequest,
  verifier: Verifier,
): Promise<AuthPrincipal> {
  const authorization = headerValue(request.headers.authorization);
  if (authorization === null || !authorization.startsWith("Bearer ")) {
    throw new ReportsHttpError(401, "authentication_required");
  }
  const idToken = authorization.slice("Bearer ".length);
  if (idToken.trim() === "") throw new ReportsHttpError(401, "authentication_required");
  try {
    return await verifier(idToken, headerValue(request.headers["x-firebase-appcheck"]));
  } catch {
    throw new ReportsHttpError(401, "invalid_authentication");
  }
}

async function withAdmission<T>(
  deps: ReportsDeps,
  principal: AuthPrincipal,
  fn: (uid: string) => Promise<T>,
): Promise<T> {
  if (deps.admission !== undefined) return deps.admission(principal, fn);
  if (typeof principal.uid !== "string" || principal.uid.trim() === "") {
    throw new ReportsHttpError(401, "invalid_identity");
  }
  return fn(principal.uid);
}

/**
 * Dedup and the daily cap are checked and the row is inserted in ONE
 * transaction, serialized per reporter by an advisory lock: parallel posts
 * can no longer all read "49 so far" and then all insert.
 *
 * Python checks `(reporter, request_id)` BEFORE the daily window, so a replay
 * still returns 200 at the limit (and never burns quota); that order is kept.
 */
async function createReportWithinLimit(
  deps: ReportsDeps,
  uid: string,
  body: CreateReport,
  now: Date,
): Promise<{ id: string; created: boolean }> {
  const limit = deps.dailyLimit ?? DEFAULT_DAILY_LIMIT;
  return deps.db.transaction(async (tx) => {
    await tx.execute(`SELECT pg_advisory_xact_lock(hashtext(${sqlText(`reports:${uid}`)}))`);
    const existing = (await tx.execute(
      `SELECT id FROM reports
       WHERE reporter_uid = ${sqlText(uid)} AND request_id = ${sqlText(body.request_id)}
       LIMIT 1`,
    )) as unknown as unknown[];
    if (existing.length === 0) {
      const since = new Date(now.getTime() - DAY_SECONDS * 1000);
      const rows = (await tx.execute(
        `SELECT count(*)::int AS n FROM reports
         WHERE reporter_uid = ${sqlText(uid)} AND created_at > ${sqlText(since.toISOString())}`,
      )) as unknown as Array<{ n?: unknown }>;
      const recent = Number(rows[0]?.n ?? 0);
      if (recent >= limit) {
        throw new ReportsHttpError(429, "report_limit_reached");
      }
    }
    // Same transaction (nested savepoint): the row commits only with the cap.
    return reportsRepo.create(tx as unknown as Db, uid, {
      requestId: body.request_id,
      kind: body.kind,
      reason: body.reason,
      details: body.details,
      excerpt: body.excerpt,
      targetId: body.target_id,
      model: body.model,
    });
  });
}

export function registerReportsRoutes(app: FastifyInstance, deps: ReportsDeps): void {
  app.register(async (scope) => {
    scope.setErrorHandler((error, request, reply) => {
      const known = knownError(error);
      if (known !== null) return sendDetail(reply, known.status, known.code);
      if (error instanceof ReportValidationError) {
        return sendDetail(reply, 422, "invalid_report");
      }
      const status = (error as { statusCode?: unknown }).statusCode;
      if (typeof status === "number" && status >= 400 && status < 500) {
        // Fastify body-parse rejection (malformed JSON, too large) — Python's
        // pydantic layer answers 422 for a body it cannot validate.
        return sendDetail(reply, 422, "invalid_report");
      }
      request.log.error({ err: error }, "reports route failed");
      return sendDetail(reply, 500, "reports_unavailable");
    });

    scope.addHook("onSend", async (_request, reply, payload) => {
      for (const [name, value] of Object.entries(REPORT_HEADERS)) reply.header(name, value);
      return payload;
    });

    scope.post("/v1/reports", async (request, reply) => {
      const principal = await requirePrincipal(request, deps.verifier);
      const body = parseCreateReport(request.body);
      const result = await withAdmission(deps, principal, (uid) =>
        createReportWithinLimit(deps, uid, body, nowOf(deps)),
      );
      return reply.code(result.created ? 201 : 200).send({ id: result.id });
    });
  });
}
