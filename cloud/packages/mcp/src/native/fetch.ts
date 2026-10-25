/**
 * Native Fetch MCP handler — a 1:1 port of the Dart NativeFetchMcpHandler
 * (lib/core/native_mcp.dart), with the egress seam swapped: the Dart class
 * ran its own URL policy because it used a raw http.Client; the cloud port
 * delegates that to ctx.fetchImpl, the per-call SSRF-guarded fetch.
 *
 * Redirects (T3-review I1): createGuardedFetch passes init through to the
 * HTTP stack, whose default is redirect:"follow" — hops followed with no
 * re-guard. This handler never lets the stack follow a hop: it requests
 * redirect:"manual" and re-enters ctx.fetchImpl once per Location, so the
 * guard re-runs scheme/host/port/DNS classification on every hop, exactly
 * like the Dart original's per-hop _urlPolicyError.
 */

import { SsrfBlockedError, type GuardedFetch } from "../ssrf.js";
import { MAX_TOOL_RESULT_CHARS, type McpToolDef, type McpToolCallResult } from "../client.js";
import {
  PUBLIC_WEB_FETCH_REQUEST,
  PublicWebFetchError,
  type PublicWebFetchRequestInit,
} from "../egress/publicWebFetch.js";
import type { McpCallContext, NativeMcpHandler } from "../transports/native.js";
import {
  authorizeProviderOperation,
  snapshotProviderArgs,
  validateProviderArgs,
  type ProviderOperation,
  type ToolContext,
} from "../providers/types.js";

export const FETCH_TOOLS: readonly string[] = ["fetch"];

/** Dart parity: _maxRedirects = 5. */
const MAX_REDIRECTS = 5;
/** Dart parity: _maxResponseBytes = 2 MiB. */
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
/** Default returned-text cap when the caller does not pass max_length. */
const DEFAULT_MAX_CHARS = 5000;
/** UTF-8 uses at most three bytes per UTF-16 code unit in a JS string. */
const MAX_RESULT_UTF8_BYTES = MAX_TOOL_RESULT_CHARS * 3;
const TRUNCATION_SUFFIX = "\n\n... [truncated]";
const FETCH_TIMEOUT_MS = 30_000;

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/** A redirect chain exceeded MAX_REDIRECTS. */
export class TooManyRedirectsError extends Error {
  constructor() {
    super("too many redirects");
    this.name = "TooManyRedirectsError";
  }
}

const CREDENTIAL_HEADERS = new Set([
  "api-key",
  "authorization",
  "cookie",
  "proxy-authorization",
  "x-api-key",
  "x-auth-token",
]);

export interface GuardedRedirectPolicy {
  /** Privileged/provider callers must never cross an origin on redirect. */
  privileged?: boolean;
  /** Values which make a URL or body secret-bearing; never replay them. */
  secretValues?: readonly string[];
}

/**
 * Return a copy of a HeadersInit with origin-bound credentials removed,
 * preserving the caller's container shape (plain object / tuple array /
 * Headers) so call sites and their tests keep seeing the shape they passed.
 */
function stripCredentialHeaders(headers: HeadersInit | undefined): HeadersInit | undefined {
  if (headers === undefined) return undefined;
  if (headers instanceof Headers) {
    const copy = new Headers(headers);
    for (const name of CREDENTIAL_HEADERS) copy.delete(name);
    return copy;
  }
  if (Array.isArray(headers)) {
    return headers.filter(([name]) => !CREDENTIAL_HEADERS.has(String(name).toLowerCase()));
  }
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(headers)) {
    if (!CREDENTIAL_HEADERS.has(name.toLowerCase())) out[name] = value;
  }
  return out;
}

function decodeUrlEncoded(value: string): string {
  // URLSearchParams uses '+' for spaces. Decode percent octets as UTF-8 so
  // escape hex case and encoded unreserved characters cannot hide a secret.
  const plusDecoded = value.replace(/\+/g, " ");
  try {
    return decodeURIComponent(plusDecoded);
  } catch {
    // An unrelated malformed escape must not disable inspection of the valid
    // runs around it. Invalid UTF-8 becomes U+FFFD; the raw value is checked too.
    return plusDecoded.replace(/(?:%[0-9a-fA-F]{2})+/g, (run) =>
      Buffer.from(run.replaceAll("%", ""), "hex").toString("utf8"),
    );
  }
}

function containsSecret(value: string, secrets: readonly string[]): boolean {
  const decoded = decodeUrlEncoded(value);
  return secrets.some((secret) =>
    secret !== "" && (value.includes(secret) || decoded.includes(secret)),
  );
}

function hasCredentialHeaders(headers: HeadersInit | undefined, secrets: readonly string[]): boolean {
  if (headers === undefined) return false;
  let found = false;
  new Headers(headers).forEach((value, name) => {
    if (CREDENTIAL_HEADERS.has(name.toLowerCase()) || containsSecret(value, secrets)) found = true;
  });
  return found;
}

function abortReason(signal: AbortSignal): Error {
  return signal.reason instanceof Error ? signal.reason : new Error("Fetch timed out or was aborted.");
}

async function raceWithAbort<T>(pending: Promise<T>, signal: AbortSignal | undefined): Promise<T> {
  if (signal === undefined) return pending;
  if (signal.aborted) {
    void pending.then(() => undefined, () => undefined);
    throw abortReason(signal);
  }
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const cleanup = () => signal.removeEventListener("abort", onAbort);
    const onAbort = () => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(abortReason(signal));
    };
    signal.addEventListener("abort", onAbort, { once: true });
    pending.then(
      (value) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(value);
      },
      (error: unknown) => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(error instanceof Error ? error : new Error("Fetch failed."));
      },
    );
  });
}

async function cancelReader(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  signal: AbortSignal | undefined,
): Promise<void> {
  // Invoke cancellation before racing it so abort still requests stream cleanup.
  // Synchronous/rejected cleanup errors propagate; they are never swallowed.
  const cancellation = reader.cancel();
  await raceWithAbort(cancellation, signal);
}

async function cancelResponseBody(
  body: ReadableStream<Uint8Array> | null,
  signal: AbortSignal | undefined,
): Promise<void> {
  if (body === null) return;
  const reader = body.getReader();
  try {
    await cancelReader(reader, signal);
  } finally {
    // A never-resolving cancellation must not retain the reader lock after the
    // operation's deadline. Release even when cancellation itself failed.
    reader.releaseLock();
  }
}

/**
 * Fetch with manually-followed redirects: one fetchImpl call per hop, with the
 * stack itself never following. Deprecated for privileged/provider callers:
 * use ProviderEgress. This compatibility path is for public web fetch only.
 *
 * A cross-origin hop is denied whenever the request is privileged, carries a
 * credential header, or has a declared secret in its URL/body. It is never made
 * safe by stripping credentials and replaying the request. HTTPS downgrade is
 * denied unconditionally. 303 becomes GET; 301/302 demote non-GET/HEAD to GET;
 * 307/308 preserve method and body only on an allowed hop.
 */
export async function followGuardedRedirects(
  fetchImpl: GuardedFetch,
  url: string,
  init: RequestInit = {},
  policy: GuardedRedirectPolicy = {},
): Promise<Response> {
  let current = url;
  const initialUrl = new URL(current);
  if (initialUrl.username !== "" || initialUrl.password !== "") {
    throw new SsrfBlockedError("egress_userinfo_denied");
  }
  let currentOrigin = initialUrl.origin;
  let method = init.method ?? "GET";
  let body = init.body;
  let headers = init.headers;
  const secrets = policy.secretValues ?? [];
  const credentialRequest = hasCredentialHeaders(headers, secrets);
  for (let hops = 0; ; hops++) {
    if (init.signal?.aborted) throw abortReason(init.signal);
    const res = await raceWithAbort(
      Promise.resolve().then(() => fetchImpl(current, { ...init, headers, method, body, redirect: "manual" })),
      init.signal ?? undefined,
    );
    const location = res.headers.get("location");
    if (!REDIRECT_STATUSES.has(res.status) || location === null) {
      if (hops > 0) Object.defineProperty(res, "redirected", { value: true });
      return res;
    }
    if (hops >= MAX_REDIRECTS) {
      await cancelResponseBody(res.body, init.signal ?? undefined);
      throw new TooManyRedirectsError();
    }
    let next: URL;
    try {
      next = new URL(location, current);
    } catch (error) {
      await cancelResponseBody(res.body, init.signal ?? undefined);
      throw error;
    }
    if (next.username !== "" || next.password !== "") {
      await cancelResponseBody(res.body, init.signal ?? undefined);
      throw new SsrfBlockedError("egress_userinfo_denied");
    }
    if (new URL(current).protocol === "https:" && next.protocol !== "https:") {
      await cancelResponseBody(res.body, init.signal ?? undefined);
      throw new SsrfBlockedError("egress_redirect_downgrade");
    }
    if (next.origin !== currentOrigin) {
      const secretUrl = containsSecret(current, secrets) || containsSecret(next.toString(), secrets);
      // With declared secrets, any non-null body is conservatively treated as
      // secret-bearing: stream bodies cannot be inspected without consuming them.
      const secretBody = secrets.length > 0 && body !== undefined && body !== null;
      if (policy.privileged === true || credentialRequest || secretUrl || secretBody) {
        await cancelResponseBody(res.body, init.signal ?? undefined);
        throw new SsrfBlockedError("egress_redirect_cross_origin");
      }
      headers = stripCredentialHeaders(headers);
    }
    if (
      res.status === 303 ||
      ((res.status === 301 || res.status === 302) && method !== "GET" && method !== "HEAD")
    ) {
      method = "GET";
      body = undefined;
    }
    await cancelResponseBody(res.body, init.signal ?? undefined);
    currentOrigin = next.origin;
    current = next.toString();
  }
}

/** Read at most `limit` bytes of the body (Dart _readCapped), then stop. */
async function readCapped(res: Response, limit: number, signal?: AbortSignal): Promise<string> {
  if (res.body === null) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let cancelStarted = false;
  const cancel = async (): Promise<void> => {
    if (cancelStarted) return;
    cancelStarted = true;
    await cancelReader(reader, signal);
  };
  try {
    for (;;) {
      const { done, value } = await raceWithAbort(reader.read(), signal);
      if (done || value === undefined) break;
      let chunk: Uint8Array = value;
      if (total + chunk.length > limit) {
        chunk = chunk.slice(0, limit - total);
        total = limit;
        chunks.push(chunk);
        await cancel();
        break;
      }
      total += chunk.length;
      chunks.push(chunk);
      if (total === limit) {
        await cancel();
        break;
      }
    }
  } catch (error) {
    await cancel();
    throw error;
  } finally {
    reader.releaseLock();
  }
  // invalid UTF-8 sequences are replaced, like Dart's allowMalformed: true
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * HTML → markdown-ish text, a straight port of the Dart _htmlToMarkdown:
 * strip script/style/noscript, map headings/links/bold/italic/pre/code/list
 * items, break blocks, strip remaining tags, decode entities, tidy spaces.
 */
export function htmlToMarkdown(html: string): string {
  let s = html;
  s = s.replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, "");
  s = s.replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, "");
  s = s.replace(/<noscript\b[^<]*(?:(?!<\/noscript>)<[^<]*)*<\/noscript>/gi, "");

  // Headings
  s = s.replace(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi, (_m, level: string, content: string) => {
    const hashes = "#".repeat(Number.parseInt(level, 10) || 1);
    return `\n\n${hashes} ${content.trim()}\n\n`;
  });

  // Links
  s = s.replace(
    /<a\s+[^>]*href=["']([^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi,
    (_m, href: string, text: string) => `[${text.trim()}](${href})`,
  );

  // Bold / italics
  s = s.replace(/<(?:strong|b)>([\s\S]*?)<\/(?:strong|b)>/gi, (_m, inner: string) => `**${inner}**`);
  s = s.replace(/<(?:em|i)>([\s\S]*?)<\/(?:em|i)>/gi, (_m, inner: string) => `*${inner}*`);

  // Code & pre
  s = s.replace(/<pre\b[^>]*>([\s\S]*?)<\/pre>/gi, (_m, inner: string) => `\n\`\`\`\n${inner.trim()}\n\`\`\`\n`);
  s = s.replace(/<code\b[^>]*>([\s\S]*?)<\/code>/gi, (_m, inner: string) => `\`${inner}\``);

  // Lists
  s = s.replace(/<li\b[^>]*>([\s\S]*?)<\/li>/gi, (_m, inner: string) => `\n- ${inner.trim()}`);

  // Block breaks
  s = s.replace(/<(?:p|div|br\s*\/?|tr)\b[^>]*>/gi, "\n");

  // Strip remaining tags
  s = s.replace(/<[^>]+>/g, "");

  // HTML entities
  s = s
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'");

  // Clean whitespace
  s = s.replace(/[ \t]+/g, " ");
  s = s.replace(/\n{3,}/g, "\n\n");
  return s.trim();
}

function truncateWithTotalCap(text: string, cap: number): string {
  if (text.length <= cap) return text;
  if (cap === 1) return "…";
  if (cap < TRUNCATION_SUFFIX.length) return `${text.slice(0, cap - 1)}…`;
  return `${text.slice(0, cap - TRUNCATION_SUFFIX.length)}${TRUNCATION_SUFFIX}`;
}

function omissionNotice(omitted: number): string {
  return `\n\n[…${omitted} characters omitted — ask again with a narrower query to see the middle…]\n\n`;
}

/** Head/tail trimming whose notice is inside, not added beyond, the hard cap. */
function trimFetchToolResult(text: string): string {
  if (text.length <= MAX_TOOL_RESULT_CHARS) return text;
  let omitted = text.length;
  // The notice contains the omitted count, so converge its decimal width
  // before selecting the exact head/tail lengths. The fallback is also capped.
  for (let attempt = 0; attempt < 16; attempt++) {
    const notice = omissionNotice(omitted);
    const retained = MAX_TOOL_RESULT_CHARS - notice.length;
    if (retained < 2) return truncateWithTotalCap(text, MAX_TOOL_RESULT_CHARS);
    const head = Math.floor(retained / 2);
    const tail = retained - head;
    const nextOmitted = text.length - retained;
    if (nextOmitted === omitted) {
      return `${text.slice(0, head)}${notice}${text.slice(text.length - tail)}`;
    }
    omitted = nextOmitted;
  }
  return truncateWithTotalCap(text, MAX_TOOL_RESULT_CHARS);
}

function toolResult(text: string, isError = false): McpToolCallResult {
  const trimmed = trimFetchToolResult(text);
  return { text: trimmed, isError, content: [{ type: "text", text: trimmed }] };
}

export const FETCH_OPERATIONS: readonly ProviderOperation[] = [{
  name: "fetch",
  description: "Fetch credential-free public-web HTTPS content and convert HTML to markdown/text through the checked-address public-web boundary.",
  inputSchema: {
    type: "object",
    properties: {
      url: { type: "string", minLength: 1, maxLength: 2_048, description: "The public HTTPS URL to fetch (port 443 only; no userinfo)." },
      max_length: { type: "integer", minimum: 1, maximum: 100_000, description: "Maximum total returned characters, including any truncation notice; a 6000-character final cap also applies." },
      raw: { type: "boolean", description: "If true, return raw content without HTML-to-markdown conversion." },
    },
    required: ["url"],
    additionalProperties: false,
    maxProperties: 3,
  },
  effect: "read",
  approval: "mode",
  requiredScopes: [],
  request: { originKey: "public-web", method: "GET", pathTemplate: "/{url}" },
  limits: { timeoutMs: 30_000, responseBytes: MAX_RESPONSE_BYTES, frameBytes: MAX_RESPONSE_BYTES, pageBytes: MAX_RESPONSE_BYTES },
  // 6,000 UTF-16 code units total; at most 18,000 UTF-8 bytes, notices included.
  outputPolicy: { kind: "redacted_text", maxBytes: MAX_RESULT_UTF8_BYTES },
}];

function publicWebAuthorizationContext(ctx: McpCallContext): ToolContext {
  const candidate = ctx as unknown as Partial<ToolContext>;
  return {
    ...candidate,
    sessionId: candidate.sessionId ?? "",
    runId: candidate.runId ?? "",
    userId: candidate.userId ?? ctx.uid,
    connectionId: candidate.connectionId ?? "",
    providerId: "fetch",
    mode: candidate.mode ?? "safe",
    planMode: candidate.planMode ?? false,
    unattended: candidate.unattended ?? true,
    isSubagent: candidate.isSubagent ?? false,
    depth: candidate.depth ?? 0,
    callKey: candidate.callKey ?? "",
    signal: candidate.signal ?? new AbortController().signal,
  } as ToolContext;
}

export function createFetchHandler(): NativeMcpHandler {
  return {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "fetch", version: "1.0.0" },
      };
    },

    async listTools(): Promise<McpToolDef[]> {
      return FETCH_OPERATIONS.map((operation) => ({ ...operation, inputSchema: { ...operation.inputSchema } }));
    },

    async callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext): Promise<McpToolCallResult> {
      const operation = FETCH_OPERATIONS[0];
      if (name !== "fetch" || operation === undefined) {
        return toolResult(`Unknown tool "${name}" for fetch MCP`, true);
      }
      try {
        args = snapshotProviderArgs(args);
      } catch {
        return toolResult("Invalid operation arguments.", true);
      }
      if (!validateProviderArgs(operation.inputSchema, args).ok) return toolResult("Invalid operation arguments.", true);
      const authorization = await authorizeProviderOperation(publicWebAuthorizationContext(ctx), operation, args);
      if (authorization.kind === "deny") return toolResult(`Operation denied (${authorization.code}).`, true);

      const urlStr = args.url;
      if (typeof urlStr !== "string" || urlStr === "") {
        return toolResult("Missing required url argument", true);
      }

      const raw = args.raw === true;
      const maxLengthArg = args.max_length ?? args.maxChars;
      const maxChars =
        typeof maxLengthArg === "number" && maxLengthArg > 0 ? maxLengthArg : DEFAULT_MAX_CHARS;

      let parsed: URL;
      try {
        parsed = new URL(urlStr);
      } catch {
        return toolResult("Fetch error: invalid URL", true);
      }
      if (
        parsed.protocol !== "https:" ||
        parsed.username !== "" ||
        parsed.password !== "" ||
        (parsed.port !== "" && parsed.port !== "443")
      ) {
        return toolResult("Fetch error: public HTTPS URL required", true);
      }

      const abortController = new AbortController();
      const callerSignal = (ctx as unknown as Partial<ToolContext>).signal;
      const abortFromCaller = () => abortController.abort(callerSignal?.reason);
      if (callerSignal?.aborted === true) abortFromCaller();
      else callerSignal?.addEventListener("abort", abortFromCaller, { once: true });
      const deadline = setTimeout(() => {
        abortController.abort(new Error("Fetch timed out after 30 seconds."));
      }, FETCH_TIMEOUT_MS);
      deadline.unref?.();
      try {
        try {
          // This function alone advances Location and owns the redirect count.
          // Every current hop re-enters ctx.fetchImpl; the marked worker transport
          // validates/connects only that hop and returns redirect metadata without
          // following it. The non-wire marker never reaches dispatcher fields.
          const requestInit: PublicWebFetchRequestInit = {
            headers: { "User-Agent": "Mozilla/5.0 (compatible; OvidAI/1.0)" },
            signal: abortController.signal,
            [PUBLIC_WEB_FETCH_REQUEST]: true,
          };
          const res = await followGuardedRedirects(ctx.fetchImpl, urlStr, requestInit, { privileged: false });

          if (res.status < 200 || res.status >= 300) {
            await cancelResponseBody(res.body, abortController.signal);
            return toolResult(`HTTP error ${res.status}`, true);
          }
          const body = await readCapped(res, MAX_RESPONSE_BYTES, abortController.signal);

          let text = raw ? body : htmlToMarkdown(body);
          if (text.length > maxChars) text = truncateWithTotalCap(text, maxChars);
          // The final head/tail cap includes its omission notice; mirrored
          // content and text are the same bounded string.
          return toolResult(text);
        } catch (err) {
          if (abortController.signal.aborted) {
            return toolResult("Fetch error: request timed out or was aborted.", true);
          }
          if (err instanceof TooManyRedirectsError) {
            return toolResult("Fetch error: too many redirects", true);
          }
          if (err instanceof PublicWebFetchError) {
            return toolResult(`Fetch error: ${err.code}`, true);
          }
          if (err instanceof SsrfBlockedError) {
            return toolResult("Fetch error: request blocked.", true);
          }
          return toolResult("Fetch error: request failed.", true);
        }
      } finally {
        clearTimeout(deadline);
        callerSignal?.removeEventListener("abort", abortFromCaller);
      }
    },
  };
}
