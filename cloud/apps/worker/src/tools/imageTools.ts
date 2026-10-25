import { createHash } from "node:crypto";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { z } from "zod";
import { signInternalRequest } from "@ovid/shared";
import { ConfinementError, resolveConfined } from "./confinement.js";
import { invalidInput, type AgentTool, type ToolContext, type ToolResult } from "./types.js";

/**
 * W8 — cloud image generation/editing tools.
 *
 * The tools execute HOST-SIDE in the worker (never in the sandbox) and call
 * mint's signed internal image routes. Provider credentials and the image
 * model pool stay server-side; the sandbox only ever sees the resulting
 * workspace file.
 *
 * Capability discovery is the SAME public projection the app uses
 * (`/v1/images/capabilities`): opaque slugs, operations, sizes and relative
 * tiers. No provider name, base URL or price crosses the boundary. The
 * capability table is rendered into each tool description and re-checked
 * before dispatch, so the model is never told about a model/size the gateway
 * cannot serve. If discovery is unavailable the tools stay registered (the
 * gateway may still route automatically) but the table is omitted.
 *
 * Results:
 *   - bytes are written to `generated/<op>_<request>.png|jpg|webp`;
 *   - the file is published through the Artifact Vault pipeline, which
 *     appends `artifact_created` (the client's inline preview);
 *   - the tool result carries the workspace path, the served model slug and
 *     the durable receipt (state + exact charged decimal). The receipt is the
 *     same one the public image API returns; no price is invented here.
 */

// ---------------------------------------------------------------------------
// Capability cards (public projection)
// ---------------------------------------------------------------------------

export const IMAGE_ALIAS = "ovid-image";
const SLUG_RE = /^ovid-image:[A-Za-z0-9_-]{3,40}$/;
const SIZE_RE = /^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$/;
const RATIO_RE = /^[1-9][0-9]?:[1-9][0-9]?$/;
const REQUEST_ID_RE = /^[A-Za-z0-9_.:-]{8,128}$/;

export const ADVANCED_EDIT_OPERATIONS = [
  "inpaint",
  "outpaint",
  "reference_style",
  "multi_image",
  "remove_background",
  "upscale",
  "variations",
] as const;

const PREFERENCES = ["balanced", "quality", "speed", "cost"] as const;

export interface ImageOperation {
  confidence?: "verified" | "estimated";
  max_inputs?: number;
  max_n?: number;
}

export interface ImageModelCard {
  slug: string;
  tags: string[];
  operations: Record<string, ImageOperation>;
  sizes: string[];
  aspect_ratios: string[];
  max_n: number;
  max_inputs: number;
  output_formats: string[];
  text_rendering: "none" | "ok" | "good";
  quality: "low" | "med" | "high";
  speed: "fast" | "medium" | "slow" | "unknown";
  latency_p50_s: number | null;
  cost_tier: "low" | "med" | "high";
  verified: boolean;
  priced: boolean;
}

export interface ImageCapabilities {
  models: ImageModelCard[];
  catalog_hash: string | null;
  quota?: { tier: string; free_cap_remaining: number | null };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringsWhere(value: unknown, re: RegExp): string[] {
  if (!Array.isArray(value)) return [];
  const out: string[] = [];
  for (const item of value) {
    if (typeof item === "string" && re.test(item) && !out.includes(item)) out.push(item);
  }
  return out;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return typeof value === "string" && (allowed as readonly string[]).includes(value)
    ? (value as T)
    : fallback;
}

/** Strict, defensive parse of ONE public card. Malformed cards are dropped. */
export function parseImageCard(raw: unknown): ImageModelCard | null {
  if (!isObject(raw)) return null;
  const slug = raw.slug;
  if (typeof slug !== "string" || !SLUG_RE.test(slug)) return null;

  const operations: Record<string, ImageOperation> = {};
  if (isObject(raw.operations)) {
    for (const [name, value] of Object.entries(raw.operations)) {
      if (!/^[a-z_]{2,32}$/.test(name)) continue;
      const record = isObject(value) ? value : {};
      operations[name] = {
        ...(record.confidence === "verified" || record.confidence === "estimated"
          ? { confidence: record.confidence }
          : {}),
        ...(typeof record.max_inputs === "number" ? { max_inputs: record.max_inputs } : {}),
        ...(typeof record.max_n === "number" ? { max_n: record.max_n } : {}),
      };
    }
  }
  if (!("generate" in operations) && !("edit" in operations)) return null;

  const input = isObject(raw.input) ? raw.input : {};
  const maxInputs =
    typeof input.max_images === "number"
      ? Math.max(0, Math.min(16, Math.trunc(input.max_images)))
      : "edit" in operations
        ? 1
        : 0;

  const latency = raw.latency_p50_s;
  const tags = stringsWhere(raw.tags, /^[a-z_]{2,24}$/);

  return {
    slug,
    tags,
    operations,
    sizes: stringsWhere(raw.sizes, SIZE_RE),
    aspect_ratios: stringsWhere(raw.aspect_ratios, RATIO_RE),
    max_n:
      typeof raw.max_n === "number" ? Math.max(1, Math.min(16, Math.trunc(raw.max_n))) : 1,
    max_inputs: maxInputs,
    output_formats: stringsWhere(raw.output_formats, /^[a-z0-9]{2,8}$/),
    text_rendering: oneOf(raw.text_rendering, ["none", "ok", "good"] as const, "none"),
    quality: oneOf(raw.quality, ["low", "med", "high"] as const, "med"),
    speed: oneOf(raw.speed, ["fast", "medium", "slow", "unknown"] as const, "unknown"),
    latency_p50_s: typeof latency === "number" && latency >= 0 ? latency : null,
    cost_tier: oneOf(raw.cost_tier, ["low", "med", "high"] as const, "med"),
    verified: raw.verified === true,
    // `priced === false` (or the `unpriced` tag) means the gateway could never
    // settle the job; the model must never select it.
    priced: raw.priced !== false && !tags.includes("unpriced"),
  };
}

/**
 * Parse a `/capabilities` body. The gateway always returns `models`; the
 * legacy `operations` map is accepted so an older gateway still yields a
 * truthful (if coarse) card.
 */
export function parseImageCapabilities(raw: unknown): ImageCapabilities {
  if (!isObject(raw)) return { models: [], catalog_hash: null };
  const hash = raw.catalog_hash;
  const catalog_hash =
    typeof hash === "string" && /^[a-f0-9]{16,64}$/.test(hash) ? hash : null;

  let models: ImageModelCard[] = [];
  if (Array.isArray(raw.models)) {
    models = raw.models.map(parseImageCard).filter((card): card is ImageModelCard => card !== null);
  } else if (isObject(raw.operations)) {
    const operations: Record<string, ImageOperation> = {};
    const sizes = new Set<string>();
    for (const op of ["generate", "edit"] as const) {
      const list = raw.operations[op];
      const valid = stringsWhere(list, SIZE_RE);
      if (valid.length > 0) operations[op] = {};
      for (const size of valid) sizes.add(size);
    }
    if (Object.keys(operations).length > 0) {
      models = [
        {
          slug: IMAGE_ALIAS,
          tags: [],
          operations,
          sizes: [...sizes],
          aspect_ratios: [],
          max_n: 1,
          max_inputs: "edit" in operations ? 1 : 0,
          output_formats: ["png"],
          text_rendering: "none",
          quality: "med",
          speed: "unknown",
          latency_p50_s: null,
          cost_tier: "med",
          verified: false,
          priced: true,
        },
      ];
    }
  }

  const quota = isObject(raw.quota)
    ? {
        tier: typeof raw.quota.tier === "string" ? raw.quota.tier : "unknown",
        free_cap_remaining:
          typeof raw.quota.free_cap_remaining === "number"
            ? raw.quota.free_cap_remaining
            : null,
      }
    : undefined;

  return {
    models,
    catalog_hash,
    ...(quota !== undefined ? { quota } : {}),
  };
}

/** Cards that can serve [op] and can be settled (priced). */
export function modelsFor(caps: ImageCapabilities | null, op: "generate" | "edit"): ImageModelCard[] {
  if (caps === null) return [];
  return caps.models.filter((card) => card.priced && card.operations[op] !== undefined);
}

function union(cards: readonly ImageModelCard[], key: "sizes" | "aspect_ratios"): string[] {
  const out: string[] = [];
  for (const card of cards) {
    for (const value of card[key]) if (!out.includes(value)) out.push(value);
  }
  return out;
}

/** One compact line per card, exactly what the model is allowed to select. */
function capabilityTable(caps: ImageCapabilities | null, op: "generate" | "edit"): string {
  const cards = modelsFor(caps, op);
  if (cards.length === 0) {
    return "No image model is currently advertised for this operation; the gateway may still route automatically.";
  }
  return [
    "Available models (omit `model` for automatic selection):",
    ...cards.map((card) => {
      const ops = Object.keys(card.operations).join(",");
      const ratios =
        card.aspect_ratios.length > 0 ? `; ratios ${card.aspect_ratios.join(",")}` : "";
      const latency = card.latency_p50_s === null ? "" : ` ~${card.latency_p50_s}s`;
      return (
        `- ${card.slug}: ops ${ops}; sizes ${card.sizes.join(",")}${ratios}; ` +
        `speed ${card.speed}${latency}; cost ${card.cost_tier}; quality ${card.quality}; ` +
        `text ${card.text_rendering}${card.verified ? "" : " (estimated)"}`
      );
    }),
  ].join("\n");
}

/** Plan truthfulness: say so BEFORE the model spends a turn on a blocked call. */
function quotaNote(caps: ImageCapabilities | null): string {
  const quota = caps?.quota;
  if (quota === undefined) return "";
  if (quota.tier === "free" && quota.free_cap_remaining !== null && quota.free_cap_remaining <= 0) {
    return "The plan's image allowance is exhausted; image requests are refused until it resets.";
  }
  return "";
}

// ---------------------------------------------------------------------------
// Internal HTTP client (HMAC, admin listener only)
// ---------------------------------------------------------------------------

export const CAPABILITIES_PATH = "/internal/v1/images/capabilities";
export const GENERATIONS_PATH = "/internal/v1/images/generations";
export const EDITS_PATH = "/internal/v1/images/edits";

/** Image generation is slow; keep the HTTP call and the tool timeout aligned. */
export const IMAGE_TOOL_TIMEOUT_MS = 180_000;

export interface ImageCallSuccess {
  ok: true;
  body: Record<string, unknown>;
}

export interface ImageCallFailure {
  ok: false;
  status: number;
  code: string;
  detail: Record<string, unknown> | null;
  receipt: unknown;
  retryAfterSeconds: number | null;
}

export type ImageCallResult = ImageCallSuccess | ImageCallFailure;

export type ImageCall = (
  path: string,
  userId: string,
  body: Record<string, unknown>,
  signal?: AbortSignal,
) => Promise<ImageCallResult>;

export interface InternalImageClientOptions {
  baseUrl: string;
  secret: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  now?: () => number;
}

function parseJson(text: string): unknown {
  if (text === "") return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/** Signed POST to mint's admin listener; never throws for HTTP answers. */
export function createInternalImageClient(opts: InternalImageClientOptions): ImageCall {
  const base = opts.baseUrl.replace(/\/+$/, "");
  const fetchImpl = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? IMAGE_TOOL_TIMEOUT_MS;
  const now = opts.now ?? (() => Date.now());

  return async function call(path, userId, body, signal) {
    const timestamp = Math.floor(now() / 1000);
    const timeout = AbortSignal.timeout(timeoutMs);
    const combined =
      signal === undefined
        ? timeout
        : typeof AbortSignal.any === "function"
          ? AbortSignal.any([timeout, signal])
          : timeout;
    const res = await fetchImpl(`${base}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "X-Ovid-Timestamp": Buffer.from(String(timestamp), "utf8").toString("base64"),
        "X-Ovid-Signature": signInternalRequest(opts.secret, "POST", path, userId, timestamp),
      },
      body: JSON.stringify({ uid: userId, ...body }),
      signal: combined,
    });
    const parsed = parseJson(await res.text());
    if (res.ok) {
      return { ok: true, body: isObject(parsed) ? parsed : {} };
    }
    const error = isObject(parsed) && isObject(parsed.error) ? parsed.error : null;
    const detail = error === null ? null : { ...error };
    const rawRetry = error?.retryAfterSeconds ?? res.headers.get("retry-after");
    const retry =
      typeof rawRetry === "number"
        ? rawRetry
        : typeof rawRetry === "string" && /^[0-9]+$/.test(rawRetry)
          ? Number.parseInt(rawRetry, 10)
          : null;
    const code =
      typeof error?.code === "string"
        ? error.code
        : isObject(parsed) && typeof parsed.detail === "string"
          ? parsed.detail
          : "image_unavailable";
    return {
      ok: false,
      status: res.status,
      code,
      detail,
      receipt: isObject(parsed) ? (parsed.receipt ?? null) : null,
      retryAfterSeconds: retry !== null && Number.isFinite(retry) ? retry : null,
    };
  };
}

/**
 * Fetch capability cards for the tool descriptions. Returns null when the
 * gateway is unreachable or refuses discovery — the tools stay registered and
 * the server remains authoritative.
 */
export async function fetchImageCapabilities(
  call: ImageCall,
  userId: string,
): Promise<ImageCapabilities | null> {
  try {
    const result = await call(CAPABILITIES_PATH, userId, {}, undefined);
    return result.ok ? parseImageCapabilities(result.body) : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Artifact publishing (wired by the worker composition root)
// ---------------------------------------------------------------------------

export interface ImageArtifactInput {
  userId: string;
  sessionId: string;
  name: string;
  contentType: string;
  content: Buffer;
}

export interface ImageArtifactRecord {
  id: string;
  url: string;
  expiresAt: string;
  sizeBytes: number;
  contentType: string;
}

export type ImageArtifactPublisher = (input: ImageArtifactInput) => Promise<ImageArtifactRecord>;

export interface ImageFailureNotifier {
  notifyAgentFailed(a: {
    userId: string;
    sessionId: string;
    sessionTitle: string;
    code: string;
    message: string;
  }): Promise<void>;
}

export interface ImageVisionDecision {
  supports: boolean;
  model: string;
  message: string;
}

/**
 * W8 vision guard. Editing an image requires the SELECTED CHAT MODEL to be
 * able to see it; a custom/text-only provider would otherwise issue a blind
 * edit and the user would pay for a wrong result. The worker processor
 * supplies this decision (same catalog + family list as the attachment
 * guard). Generation does not need the chat model to see anything.
 */
export type ImageVisionGuard = () => Promise<ImageVisionDecision>;

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

export type ImageToolContext = Pick<ToolContext, "userId" | "sessionId" | "runId">;

export interface ImageUsageFact {
  account: string;
  request: string;
  sessionId: string;
  runId: string;
  op: "generate" | "edit";
  costUsd: string | null;
}

export type ImageUsageRecorder = (fact: ImageUsageFact) => Promise<unknown>;

export interface ImageToolDeps {
  call: ImageCall;
  capabilities: ImageCapabilities | null;
  publishArtifact: ImageArtifactPublisher;
  /** Approved image_usage_facts satellite; optional for older tool embedders. */
  recordUsage?: ImageUsageRecorder;
  log?: (message: string) => void;
  notifier?: ImageFailureNotifier;
  visionGuard?: ImageVisionGuard;
}

/**
 * The production seam `runProcessor` consumes. `capabilities` is cached by the
 * composition root; `createTools` is per run so the description carries the
 * cards fetched for that run.
 */
export interface ImageTooling {
  capabilities(userId: string): Promise<ImageCapabilities | null>;
  createTools(o: {
    capabilities: ImageCapabilities | null;
    visionGuard?: ImageVisionGuard;
  }): readonly AgentTool[];
}

const MAX_IMAGE_BYTES = 16 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;

const MIME_BY_EXT: Readonly<Record<string, string>> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
};

const EXT_BY_MIME: Readonly<Record<string, string>> = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/webp": ".webp",
};

function isToolResult(value: unknown): value is ToolResult {
  return isObject(value) && typeof value.content === "string" && typeof value.isError === "boolean";
}

function zodInput(err: z.ZodError): ToolResult {
  const issue = err.issues[0];
  const where = issue === undefined || issue.path.length === 0 ? "" : `${issue.path.join(".")}: `;
  return invalidInput(new Error(`${where}${issue?.message ?? "invalid input"}`));
}

function confinedResult(err: ConfinementError): ToolResult {
  return { content: `confined: ${err.message}`, isError: true };
}

function requestIdFor(
  explicit: string | undefined,
  ctx: ToolContext,
  op: "generate" | "edit",
  material: string,
): string {
  if (explicit !== undefined) return explicit;
  // Stable within a run: a retry of the same call replays the ledger entry
  // instead of double-charging. The model passes an explicit request_id when
  // it wants a second, distinct image.
  const digest = createHash("sha256")
    .update([op, ctx.runId, material].join("\u0000"))
    .digest("hex")
    .slice(0, 32);
  return `img-${digest}`;
}

function safeFilePart(requestId: string): string {
  return requestId.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 96);
}

function sniffMime(buf: Buffer): string | null {
  if (buf.length >= 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return "image/png";
  }
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
    return "image/jpeg";
  }
  if (
    buf.length >= 12 &&
    buf.toString("ascii", 0, 4) === "RIFF" &&
    buf.toString("ascii", 8, 12) === "WEBP"
  ) {
    return "image/webp";
  }
  return null;
}

async function readImageFile(
  ctx: ToolContext,
  path: string,
  label: string,
  allowed: readonly string[],
): Promise<{ dataUrl: string; mime: string } | ToolResult> {
  let host: string;
  try {
    host = await resolveConfined(ctx.sandbox.workspaceDir, path);
  } catch (err) {
    if (err instanceof ConfinementError) return confinedResult(err);
    throw err;
  }
  let size: number;
  try {
    size = (await stat(host)).size;
  } catch {
    return { content: `${label}: no such file: ${path}`, isError: true };
  }
  if (size <= 0) return { content: `${label}: file is empty: ${path}`, isError: true };
  if (size > MAX_IMAGE_BYTES) {
    return { content: `${label}: image is larger than 16 MiB: ${path}`, isError: true };
  }
  const buf = await readFile(host);
  const mime = MIME_BY_EXT[extname(host).toLowerCase()] ?? sniffMime(buf);
  if (mime === null || !allowed.includes(mime)) {
    return {
      content: `${label}: unsupported image type (expected ${allowed.join(", ")}): ${path}`,
      isError: true,
    };
  }
  return { dataUrl: `data:${mime};base64,${buf.toString("base64")}`, mime };
}

function failureMessage(failure: ImageCallFailure): string {  const alternatives = Array.isArray(failure.detail?.alternatives)
    ? failure.detail!.alternatives.filter((v): v is string => typeof v === "string")
    : [];
  const suffix = alternatives.length > 0 ? ` Retry with model set to one of: ${alternatives.join(", ")}.` : "";
  let message: string;
  switch (failure.code) {
    case "image_limit_reached":
      message =
        "The image allowance for this plan is exhausted. Image generation and editing are " +
        "blocked until the allowance resets or the plan changes. Tell the user; do not retry in this run.";
      break;
    case "image_capacity_unavailable":
      message =
        "The image service is temporarily at capacity. Stop image attempts in this run" +
        (failure.retryAfterSeconds === null
          ? "."
          : ` and tell the user to try again after ${failure.retryAfterSeconds} seconds.`);
      break;
    case "image_unavailable":
      message = "The image service is unavailable right now. Report this; do not retry in this run.";
      break;
    case "sign_in_required":
      message = "Image access requires a fresh sign-in. Ask the user to sign in again.";
      break;
    case "image_access_denied":
      message = "This account cannot use Ovid image generation or editing.";
      break;
    case "unsupported_image_operation":
      message = `The chosen image model cannot perform this operation.${suffix || " Use a local tool or tell the user."}`;
      break;
    case "invalid_image_request":
    case "invalid_image":
    case "invalid_request_id":
    case "image_too_large":
      message = "The image request was rejected. Fix the prompt, size, model or image path and try once.";
      break;
    case "image_request_pending":
      message =
        "A previous image request with this request_id is still being confirmed. Do not submit a " +
        "new request; reuse the same request_id and report the pending state.";
      break;
    case "idempotency_conflict":
      message = "This request_id was already used with different arguments. Use a new request_id.";
      break;
    case "image_request_failed":
      message = "The previous image request with this request_id failed. Use a new request_id.";
      break;
    case "image_account_deleted":
    case "account_deletion_pending":
      message = "This account is scheduled for deletion and cannot generate images.";
      break;
    case "image_replay_expired":
    case "image_receipt_expired":
      message = "The stored image result/receipt has expired. Submit a new request with a new request_id.";
      break;
    case "image_request_not_found":
      message = "No image request exists with that request_id.";
      break;
    default:
      message = "The image service could not complete this request.";
  }
  return message;
}

function imageFailure(failure: ImageCallFailure): ToolResult {
  return { content: `${failureMessage(failure)} [${failure.code}]`, isError: true };
}

/**
 * A user-visible turn-tail row (the client renders `system_note.message`).
 * Best-effort: the tool result is authoritative; the note only makes a
 * blocked/refused action explicit in the transcript and after a reload.
 */
async function note(ctx: ToolContext, code: string, message: string): Promise<void> {
  await ctx.emitEvent("system_note", { code, message }).catch(() => {});
}

function validateCapabilities(
  caps: ImageCapabilities | null,
  op: "generate" | "edit",
  input: { model?: string; size?: string; requirements?: { aspect_ratio?: string; operation?: string } },
): string | null {
  if (caps === null || caps.models.length === 0) return null;
  let candidates = modelsFor(caps, op);
  if (input.model !== undefined && input.model !== IMAGE_ALIAS) {
    const card = caps.models.find((c) => c.slug === input.model);
    if (card === undefined || !card.priced || card.operations[op] === undefined) {
      const alternatives = modelsFor(caps, op).map((c) => c.slug);
      return `unsupported_model: ${input.model} cannot ${op}.${
        alternatives.length > 0 ? ` Use one of: ${alternatives.join(", ")}` : ""
      }`;
    }
    candidates = [card];
  }
  if (candidates.length === 0) {
    return `unsupported_operation: no advertised image model supports ${op} right now.`;
  }
  if (input.size !== undefined) {
    const sizes = union(candidates, "sizes");
    if (sizes.length > 0 && !sizes.includes(input.size)) {
      return `unsupported_size: ${input.size} is not advertised for ${op}. Use one of: ${sizes.join(", ")}`;
    }
  }
  const ratio = input.requirements?.aspect_ratio;
  if (ratio !== undefined) {
    const ratios = union(candidates, "aspect_ratios");
    if (ratios.length > 0 && !ratios.includes(ratio)) {
      return `unsupported_aspect_ratio: ${ratio} is not advertised for ${op}. Use one of: ${ratios.join(", ")}`;
    }
  }
  const requiredOp = input.requirements?.operation;
  if (requiredOp !== undefined && requiredOp !== op) {
    if (!candidates.some((card) => card.operations[requiredOp] !== undefined)) {
      return `unsupported_operation: no advertised image model supports ${requiredOp}.`;
    }
  }
  return null;
}

const RECEIPT_COST_RE = /^\d+(?:\.\d{1,10})?$/;

function confirmedReceiptCost(body: Record<string, unknown>): string | null {
  const receipt = isObject(body.receipt) ? body.receipt : null;
  if (receipt?.state !== "confirmed" || typeof receipt.charged !== "string") return null;
  const charged = receipt.charged;
  const [whole] = charged.split(".");
  return RECEIPT_COST_RE.test(charged) && whole!.length <= 28 ? charged : null;
}

async function recordImageUsage(
  ctx: ImageToolContext,
  deps: ImageToolDeps,
  op: "generate" | "edit",
  requestId: string,
  body: Record<string, unknown>,
): Promise<void> {
  if (deps.recordUsage === undefined) return;
  try {
    await deps.recordUsage({
      account: ctx.userId,
      request: requestId,
      sessionId: ctx.sessionId,
      runId: ctx.runId,
      op,
      costUsd: confirmedReceiptCost(body),
    });
  } catch (err) {
    // Telemetry must not turn an already-confirmed image into a failed tool.
    (deps.log ?? console.warn)(
      `[worker] image usage record failed (run ${ctx.runId}): ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

function artifactPublicationFailure(error: unknown): ToolResult {
  const code = typeof (error as { code?: unknown } | null)?.code === "string"
    ? String((error as { code: string }).code)
    : "artifact_unavailable";
  const safeCode = /^[a-z][a-z0-9_]{2,64}$/.test(code) ? code : "artifact_unavailable";
  const message = safeCode === "project_file_limit"
    ? "The project file allowance is exhausted."
    : safeCode === "storage_quota_exceeded" || safeCode === "upload_limit_reached"
      ? "The storage allowance for this plan is exhausted."
      : "Artifact publication is temporarily unavailable.";
  return { content: `${safeCode}: ${message}`, isError: true };
}

async function persistImage(
  ctx: ToolContext,
  deps: ImageToolDeps,
  op: "generate" | "edit",
  requestId: string,
  body: Record<string, unknown>,
): Promise<ToolResult> {
  await recordImageUsage(ctx, deps, op, requestId, body);
  const rows = Array.isArray(body.data) ? body.data : [];
  const first = rows[0];
  if (!isObject(first) || typeof first.b64_json !== "string" || first.b64_json === "") {
    return { content: "invalid_image_response: the gateway returned no image bytes", isError: true };
  }
  const mime = typeof first.mime_type === "string" ? first.mime_type : "image/png";
  const ext = EXT_BY_MIME[mime] ?? ".png";
  const buffer = Buffer.from(first.b64_json, "base64");
  if (buffer.length === 0 || buffer.length > MAX_OUTPUT_BYTES) {
    return { content: "invalid_image_response: the returned image is empty or too large", isError: true };
  }

  const dir = join(ctx.sandbox.workspaceDir, "generated");
  await mkdir(dir, { recursive: true });
  const fileName = `${op}_${safeFilePart(requestId)}${ext}`;
  const rel = `generated/${fileName}`;
  await writeFile(join(dir, fileName), buffer);

  let artifact: ImageArtifactRecord;
  try {
    artifact = await deps.publishArtifact({
      userId: ctx.userId,
      sessionId: ctx.sessionId,
      name: rel,
      contentType: mime,
      content: buffer,
    });
  } catch (err) {
    // Publication is part of the requested artifact outcome. Never report a
    // successful vault publication or hide a project/quota/grant refusal in an
    // additive artifact_error field on an otherwise successful tool result.
    return artifactPublicationFailure(err);
  }

  const payload = {
    path: rel,
    model: typeof body.model_slug === "string" ? body.model_slug : body.model ?? null,
    receipt: isObject(body.receipt) ? body.receipt : null,
    artifact: { id: artifact.id, expiresAt: artifact.expiresAt, sizeBytes: artifact.sizeBytes },
  };
  const verb = op === "generate" ? "Generated" : "Edited";
  return {
    content: `${verb} image saved to ${rel}.\n${JSON.stringify(payload)}`,
    isError: false,
  };
}

const generateRequirementSchema = z
  .object({
    aspect_ratio: z.string().regex(RATIO_RE).optional(),
    transparent_background: z.boolean().optional(),
    text_rendering: z.boolean().optional(),
    operation: z.enum(["generate", "variations"]).optional(),
  })
  .strict();

const editRequirementSchema = z
  .object({
    aspect_ratio: z.string().regex(RATIO_RE).optional(),
    transparent_background: z.boolean().optional(),
    text_rendering: z.boolean().optional(),
    operation: z.enum(["edit", ...ADVANCED_EDIT_OPERATIONS]).optional(),
  })
  .strict();

const generateSchema = z
  .object({
    prompt: z.string().trim().min(1).max(8000),
    size: z.string().regex(SIZE_RE).optional(),
    aspect_ratio: z.string().regex(RATIO_RE).optional(),
    model: z.string().min(1).max(64).optional(),
    requirements: generateRequirementSchema.optional(),
    preference: z.enum(PREFERENCES).optional(),
    request_id: z.string().regex(REQUEST_ID_RE).optional(),
  })
  .strict();

const editSchema = z
  .object({
    prompt: z.string().trim().min(1).max(8000),
    path: z.string().min(1),
    mask_path: z.string().min(1).optional(),
    reference_paths: z.array(z.string().min(1)).max(7).optional(),
    size: z.string().regex(SIZE_RE).optional(),
    aspect_ratio: z.string().regex(RATIO_RE).optional(),
    model: z.string().min(1).max(64).optional(),
    requirements: editRequirementSchema.optional(),
    preference: z.enum(PREFERENCES).optional(),
    request_id: z.string().regex(REQUEST_ID_RE).optional(),
  })
  .strict();

/** Merge the top-level `aspect_ratio` shorthand into `requirements`. */
function mergedRequirements<T extends { aspect_ratio?: string }>(
  requirements: T | undefined,
  aspectRatio: string | undefined,
): T | undefined {
  if (aspectRatio === undefined) return requirements;
  return { ...(requirements ?? {}), aspect_ratio: aspectRatio } as T;
}

const LOCAL_OPS_GUIDANCE =
  "LOCAL operations need NO model, cost nothing and are instant: crop, resize, rotate, flip and " +
  "format conversion. Use local tools for those. Choose the cheapest/fastest model that satisfies " +
  "the task unless the user asks for top quality (preference \"quality\"); omit `model` to let the " +
  "server pick automatically (recommended).";

export function createImageTools(deps: ImageToolDeps): AgentTool[] {
  const generate: AgentTool = {
    name: "generate_image",
    description: [
      "Generate one image through Ovid Cloud. The image is saved into the workspace, published to " +
        "the Artifact Vault and previewed inline in chat. Returns the saved path, the served model " +
        "and the receipt.",
      LOCAL_OPS_GUIDANCE,
      capabilityTable(deps.capabilities, "generate"),
      quotaNote(deps.capabilities),
      "Pass a stable `request_id` and reuse it for retries; pass a new one for a second image.",
    ].join("\n"),
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        prompt: {
          type: "string",
          minLength: 1,
          maxLength: 8000,
          description: "The user's image description, verbatim.",
        },
        size: {
          type: "string",
          pattern: "^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$",
          description: "Optional output size. Pick the entry matching the wanted aspect ratio; omit for automatic.",
        },
        aspect_ratio: {
          type: "string",
          pattern: "^[1-9][0-9]?:[1-9][0-9]?$",
          description:
            'Exact output ratio the user asked for, e.g. "4:5" or "16:9". A model with that native ratio is preferred.',
        },
        model: {
          type: "string",
          description: "Optional opaque model slug from the table; omit for automatic selection.",
        },
        requirements: {
          type: "object",
          additionalProperties: false,
          properties: {
            aspect_ratio: {
              type: "string",
              pattern: "^[1-9][0-9]?:[1-9][0-9]?$",
              description: "Only models with this NATIVE ratio are considered.",
            },
            transparent_background: {
              type: "boolean",
              description: "Require alpha/transparent output (PNG).",
            },
            text_rendering: {
              type: "boolean",
              description: "Set when legible text inside the image matters.",
            },
          },
        },
        preference: {
          type: "string",
          enum: [...PREFERENCES],
          description: "cost/speed = cheapest/fastest capable model; quality = best output; default balanced.",
        },
        request_id: {
          type: "string",
          pattern: "^[A-Za-z0-9_.:-]{8,128}$",
          description: "Stable unique id for this image job. Reuse it for retries; never change it after an uncertain outcome.",
        },
      },
      required: ["prompt"],
    },
    async execute(input, ctx) {
      const parsed = generateSchema.safeParse(input);
      if (!parsed.success) return zodInput(parsed.error);
      const args = parsed.data;
      const requirements = mergedRequirements(args.requirements, args.aspect_ratio);
      const invalid = validateCapabilities(deps.capabilities, "generate", {
        ...(args.model === undefined ? {} : { model: args.model }),
        ...(args.size === undefined ? {} : { size: args.size }),
        ...(requirements === undefined ? {} : { requirements }),
      });
      if (invalid !== null) return { content: `invalid_input: ${invalid}`, isError: true };

      const requestId = requestIdFor(args.request_id, ctx, "generate", `${args.prompt}\u0000${args.size ?? ""}`);
      let result: ImageCallResult;
      try {
        result = await deps.call(
          GENERATIONS_PATH,
          ctx.userId,
          {
            request_id: requestId,
            prompt: args.prompt,
            ...(args.size === undefined ? {} : { size: args.size }),
            ...(args.model === undefined ? {} : { model: args.model }),
            ...(requirements === undefined ? {} : { requirements }),
            ...(args.preference === undefined ? {} : { preference: args.preference }),
          },
          ctx.signal,
        );
      } catch (err) {
        return {
          content: `image_unavailable: ${err instanceof Error ? err.message : String(err)}`,
          isError: true,
        };
      }
      if (!result.ok) {
        if (result.code === "image_limit_reached" || result.code === "image_capacity_unavailable") {
          await note(ctx, result.code, failureMessage(result));
        }
        return imageFailure(result);
      }
      return persistImage(ctx, deps, "generate", requestId, result.body);
    },
  };

  const edit: AgentTool = {
    name: "edit_image",
    description: [
      "Edit ONE existing workspace image through Ovid Cloud. Use the exact attachment or returned " +
        "file path. Pass the user's instruction verbatim as prompt; never add changes they did not " +
        "ask for. Omit `model` and `size` for automatic routing.",
      LOCAL_OPS_GUIDANCE,
      capabilityTable(deps.capabilities, "edit"),
      quotaNote(deps.capabilities),
      "Pass a stable `request_id` and reuse it for retries.",
    ].join("\n"),
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        prompt: {
          type: "string",
          minLength: 1,
          maxLength: 8000,
          description: "The user's edit instruction, verbatim.",
        },
        path: {
          type: "string",
          minLength: 1,
          description: "Exact workspace path of the image to edit (attachment or previously generated file).",
        },
        mask_path: {
          type: "string",
          minLength: 1,
          description: "Optional exact path of a mask PNG (inpaint): transparent pixels mark the area to repaint.",
        },
        reference_paths: {
          type: "array",
          maxItems: 7,
          items: { type: "string", minLength: 1 },
          description: "Optional extra image paths (style reference / multi-image compose).",
        },
        size: {
          type: "string",
          pattern: "^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$",
          description: "Optional output size; omit for automatic.",
        },
        aspect_ratio: {
          type: "string",
          pattern: "^[1-9][0-9]?:[1-9][0-9]?$",
          description: 'Exact output ratio the user asked for, e.g. "4:5" or "16:9".',
        },
        model: {
          type: "string",
          description: "Optional opaque model slug from the table; omit for automatic selection.",
        },
        requirements: {
          type: "object",
          additionalProperties: false,
          properties: {
            aspect_ratio: { type: "string", pattern: "^[1-9][0-9]?:[1-9][0-9]?$" },
            transparent_background: { type: "boolean" },
            text_rendering: { type: "boolean" },
            operation: {
              type: "string",
              enum: [...ADVANCED_EDIT_OPERATIONS, "edit"],
              description: "Specific edit kind; routes only to models that advertise it.",
            },
          },
        },
        preference: { type: "string", enum: [...PREFERENCES] },
        request_id: {
          type: "string",
          pattern: "^[A-Za-z0-9_.:-]{8,128}$",
          description: "Stable unique id for this edit job. Reuse it for retries.",
        },
      },
      required: ["prompt", "path"],
    },
    async execute(input, ctx) {
      const parsed = editSchema.safeParse(input);
      if (!parsed.success) return zodInput(parsed.error);
      const args = parsed.data;
      const requirements = mergedRequirements(args.requirements, args.aspect_ratio);

      // W8 vision guard: a blind edit is a paid wrong result. The selected
      // chat model must be able to see the source image. Fail CLOSED: if the
      // capability read itself fails, do not spend on an unverifiable edit.
      if (deps.visionGuard !== undefined) {
        let decision;
        try {
          decision = await deps.visionGuard();
        } catch (err) {
          return {
            content: `image_unavailable: could not verify model vision support (${
              err instanceof Error ? err.message : String(err)
            })`,
            isError: true,
          };
        }
        if (!decision.supports) {
          await deps.notifier
            ?.notifyAgentFailed({
              userId: ctx.userId,
              sessionId: ctx.sessionId,
              sessionTitle: "",
              code: "model_no_vision",
              message: decision.message,
            })
            .catch(() => {});
          // The turn-tail row is the "graceful in-chat error" (and survives a
          // reload through the event mirror); the tool result tells the model
          // exactly what to say next.
          await note(ctx, "model_no_vision", decision.message);
          return { content: decision.message, isError: true };
        }
      }

      const invalid = validateCapabilities(deps.capabilities, "edit", {
        ...(args.model === undefined ? {} : { model: args.model }),
        ...(args.size === undefined ? {} : { size: args.size }),
        ...(requirements === undefined ? {} : { requirements }),
      });
      if (invalid !== null) return { content: `invalid_input: ${invalid}`, isError: true };

      const source = await readImageFile(ctx, args.path, "path", [
        "image/png",
        "image/jpeg",
        "image/webp",
      ]);
      if (isToolResult(source)) return source;

      let mask: { dataUrl: string } | null = null;
      if (args.mask_path !== undefined) {
        const read = await readImageFile(ctx, args.mask_path, "mask_path", ["image/png"]);
        if (isToolResult(read)) return read;
        mask = { dataUrl: read.dataUrl };
      }

      const references: string[] = [];
      for (const path of args.reference_paths ?? []) {
        const read = await readImageFile(ctx, path, "reference_paths", [
          "image/png",
          "image/jpeg",
          "image/webp",
        ]);
        if (isToolResult(read)) return read;
        references.push(read.dataUrl);
      }

      const requestId = requestIdFor(
        args.request_id,
        ctx,
        "edit",
        `${args.prompt}\u0000${args.path}\u0000${args.size ?? ""}`,
      );
      const result = await (async (): Promise<ImageCallResult> => {
        try {
          return await deps.call(
            EDITS_PATH,
            ctx.userId,
            {
              request_id: requestId,
              prompt: args.prompt,
              image: source.dataUrl,
              ...(mask === null ? {} : { mask: mask.dataUrl }),
              ...(references.length === 0 ? {} : { images: references }),
              ...(args.size === undefined ? {} : { size: args.size }),
              ...(args.model === undefined ? {} : { model: args.model }),
              ...(requirements === undefined ? {} : { requirements }),
              ...(args.preference === undefined ? {} : { preference: args.preference }),
            },
            ctx.signal,
          );
        } catch (err) {
          return {
            ok: false,
            status: 0,
            code: "image_unavailable",
            detail: { message: err instanceof Error ? err.message : String(err) },
            receipt: null,
            retryAfterSeconds: null,
          };
        }
      })();
      if (!result.ok) {
        if (result.code === "image_limit_reached" || result.code === "image_capacity_unavailable") {
          await note(ctx, result.code, failureMessage(result));
        }
        return imageFailure(result);
      }
      return persistImage(ctx, deps, "edit", requestId, result.body);
    },
  };

  return [generate, edit];
}
