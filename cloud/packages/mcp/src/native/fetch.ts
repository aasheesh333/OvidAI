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

import type { GuardedFetch } from "../ssrf.js";
import { trimToolResult, type McpToolDef, type McpToolCallResult } from "../client.js";
import type { McpCallContext, NativeMcpHandler } from "../transports/native.js";

export const FETCH_TOOLS: readonly string[] = ["fetch"];

/** Dart parity: _maxRedirects = 5. */
const MAX_REDIRECTS = 5;
/** Dart parity: _maxResponseBytes = 2 MiB. */
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
/** Default returned-text cap when the caller does not pass max_length. */
const DEFAULT_MAX_CHARS = 5000;

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/** A redirect chain exceeded MAX_REDIRECTS. */
export class TooManyRedirectsError extends Error {
  constructor() {
    super("too many redirects");
    this.name = "TooManyRedirectsError";
  }
}

/**
 * Fetch with manually-followed redirects: one fetchImpl call per hop
 * (each call re-guarded — the I1 fix), the stack itself never follows.
 * 303 always becomes GET; 301/302 demote non-GET/HEAD to GET (browser
 * behaviour); 307/308 preserve method and body.
 */
export async function followGuardedRedirects(
  fetchImpl: GuardedFetch,
  url: string,
  init: RequestInit = {},
): Promise<Response> {
  let current = url;
  let method = init.method ?? "GET";
  let body = init.body;
  for (let hops = 0; ; hops++) {
    const res = await fetchImpl(current, { ...init, method, body, redirect: "manual" });
    const location = res.headers.get("location");
    if (!REDIRECT_STATUSES.has(res.status) || location === null) return res;
    if (hops >= MAX_REDIRECTS) throw new TooManyRedirectsError();
    if (
      res.status === 303 ||
      ((res.status === 301 || res.status === 302) && method !== "GET" && method !== "HEAD")
    ) {
      method = "GET";
      body = undefined;
    }
    current = new URL(location, current).toString();
  }
}

/** Read at most `limit` bytes of the body (Dart _readCapped), then stop. */
async function readCapped(res: Response, limit: number): Promise<string> {
  if (res.body === null) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done || value === undefined) break;
    let chunk: Uint8Array = value;
    if (total + chunk.length > limit) {
      chunk = chunk.slice(0, limit - total);
      total = limit;
      chunks.push(chunk);
      try {
        await reader.cancel();
      } catch {
        // best-effort — we already have what we need
      }
      break;
    }
    total += chunk.length;
    chunks.push(chunk);
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

function toolResult(text: string, isError = false): McpToolCallResult {
  const trimmed = trimToolResult(text);
  return { text: trimmed, isError, content: [{ type: "text", text: trimmed }] };
}

const TOOLS: McpToolDef[] = [
  {
    name: "fetch",
    description: "Fetch web page content and convert HTML to markdown/text.",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "The URL to fetch." },
        max_length: { type: "integer", description: "Maximum character length of returned text." },
        raw: { type: "boolean", description: "If true, return raw content without markdown conversion." },
      },
      required: ["url"],
    },
  },
];

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
      return TOOLS.map((t) => ({ ...t, inputSchema: { ...t.inputSchema } }));
    },

    async callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext): Promise<McpToolCallResult> {
      if (name !== "fetch") {
        return toolResult(`Unknown tool "${name}" for fetch MCP`, true);
      }

      const urlStr = args.url;
      if (typeof urlStr !== "string" || urlStr === "") {
        return toolResult("Missing required url argument", true);
      }

      const raw = args.raw === true;
      const maxLengthArg = args.max_length ?? args.maxChars;
      const maxChars =
        typeof maxLengthArg === "number" && maxLengthArg > 0 ? maxLengthArg : DEFAULT_MAX_CHARS;

      try {
        // scheme/host/port/DNS policy is ctx.fetchImpl's job (SSRF guard);
        // an invalid URL never even reaches it
        new URL(urlStr);
      } catch {
        return toolResult("Fetch error: invalid URL", true);
      }

      try {
        // every hop re-enters ctx.fetchImpl → re-guarded (I1)
        const res = await followGuardedRedirects(ctx.fetchImpl, urlStr, {
          headers: { "User-Agent": "Mozilla/5.0 (compatible; OvidAI/1.0)" },
        });

        const body = await readCapped(res, MAX_RESPONSE_BYTES);
        if (res.status < 200 || res.status >= 300) {
          const statusLine = res.statusText === "" ? `HTTP error ${res.status}` : `HTTP error ${res.status}: ${res.statusText}`;
          return toolResult(statusLine, true);
        }

        let text = raw ? body : htmlToMarkdown(body);
        if (text.length > maxChars) {
          text = `${text.slice(0, maxChars)}\n\n... [truncated]`;
        }
        // hard cap — a caller-passed max_length above the inline cap never
        // lets a tool result exceed MAX_TOOL_RESULT_CHARS
        return toolResult(text);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return toolResult(`Fetch error: ${message}`, true);
      }
    },
  };
}
