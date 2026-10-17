// Web tools — ports of the `fetch_url` and `web_search` dispatch cases in
// lib/core/agent_service.dart (P3 Task 10).
//
// fetch_url keeps the Dart host-grant semantics: a host outside the allowlist
// prompts through the ApprovalGate BEFORE any bytes leave the process, and a
// denial returns EXACTLY 'DENIED by user'. The egress itself is the Task 2
// guarded fetch — assertSafeUrl runs on every redirect hop, so a granted site
// can never bounce the request into a private range or the cloud metadata
// service. The guard also runs up front so the user is never asked to approve
// a host the SSRF check would refuse anyway (fail-closed, never prompt).
//
// web_search is the free DuckDuckGo-HTML scraper: 1–4 queries run
// concurrently, one failed query fails the whole call, and sources are
// merged round-robin (rank 1 of A, rank 1 of B, …) deduped by URL.

import { randomUUID } from "node:crypto";

import { htmlToMarkdown } from "../htmlToMarkdown.js";
import type { ApprovalGate, EgressFetch, SandboxPort } from "../ports.js";
import type { SsrfGuard } from "../ssrf.js";
import type { Tool, ToolContext } from "../types.js";
import { spillToolOutput } from "./spill.js";

const FETCH_URL_CAP = 8000;
const USER_AGENT = "OvidAgent/1.0";

export function createFetchUrlTool(deps: {
  egress: EgressFetch;          // SSRF-guarded (createGuardedEgressFetch)
  guard: SsrfGuard;             // up-front parse/check, before the approval prompt
  approvals: ApprovalGate;      // host grants (full gate lands Task 12)
  sandbox: SandboxPort;         // spillToolOutput target for bodies over the cap
  workspaceRelDir?: string;
}): Tool {
  return {
    spec: {
      name: "fetch_url",
      description: "Fetch a URL and return clean markdown/text content.",
      parameters: {
        type: "object",
        properties: {
          url: { type: "string" },
        },
        required: ["url"],
      },
    },
    timeoutMs: 60_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext) {
      try {
        if (typeof args.url !== "string") {
          throw new Error("url must be a string");
        }
        // Parse + scheme/port/host check first: an invalid or non-public
        // target is refused without ever raising an approval card.
        const safeUrl = await deps.guard.assertSafeUrl(args.url);
        const host = safeUrl.hostname;

        // Strict permission model: a host outside the allowlist prompts
        // Allow / Deny / Always allow instead of a silent fetch.
        const decision = await deps.approvals.approve(ctx, {
          approvalId: randomUUID(),
          kind: "tool",
          tool: "fetch_url",
          summary: `Network access: ${host}`,
          detail:
            "The agent (fetch_url) wants to reach a network host outside " +
            `the allowlist:\n${host}\n\n` +
            'Allow once, Deny, or "Always allow" to grant this host (and ' +
            "its subdomains) for this session.",
          allowAlways: true,
          pathTargets: [],
          hostTargets: [host],
        });
        if (decision !== "allow" && decision !== "always") {
          return { content: "DENIED by user" };
        }

        // SECURITY: the egress re-checks the target on EVERY redirect hop,
        // so a granted site cannot bounce the request to a private range
        // or loopback.
        const res = await deps.egress(safeUrl.toString(), {
          headers: { "user-agent": USER_AGENT },
          signal: ctx.signal,
        });
        if (!res.ok) {
          throw new Error(`HTTP ${res.status}`);
        }
        const body = await res.text();
        const contentType = res.headers.get("content-type") ?? "";
        const text = contentType.toLowerCase().includes("html")
          ? htmlToMarkdown(body)
          : body;
        const out = await spillToolOutput(
          { sandbox: deps.sandbox, userId: ctx.userId, workspaceRelDir: deps.workspaceRelDir ?? "" },
          "fetch_url",
          text,
          FETCH_URL_CAP,
        );
        return { content: out };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return { content: `fetch failed: ${message}` };
      }
    },
  };
}

// ---------------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------------

export const WEB_SEARCH_MAX_QUERIES = 4;
export const WEB_SEARCH_MAX_RESULTS = 8;
const DEFAULT_DDG_BASE = "https://html.duckduckgo.com/html/";

interface WebSearchSource {
  url: string;
  title: string;
  snippet: string;
}

/** Strip HTML tags from a snippet for plain-text display (Dart `_stripHtml`). */
function stripHtml(html: string): string {
  return html
    .replace(/<[^>]+>/g, "")
    .split("&amp;").join("&")
    .split("&lt;").join("<")
    .split("&gt;").join(">")
    .split("&quot;").join('"')
    .split("&#39;").join("'")
    .replace(/\s{2,}/g, " ")
    .trim();
}

/** One DuckDuckGo HTML search → parsed sources (title/url/snippet). */
async function ddgSearch(query: string, deps: { egress: EgressFetch; ddgBase?: string }): Promise<WebSearchSource[]> {
  const base = deps.ddgBase ?? DEFAULT_DDG_BASE;
  const url = `${base}?q=${encodeURIComponent(query)}`;
  const res = await deps.egress(url, { headers: { "user-agent": USER_AGENT } });
  if (res.status !== 200) {
    throw new Error(`search failed for "${query}" (HTTP ${res.status})`);
  }
  const html = await res.text();
  const results: WebSearchSource[] = [];
  const resultRegex =
    /<a[^>]+class="result__a"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<a[^>]+class="result__snippet"[^>]*>([\s\S]*?)<\/a>/g;
  for (const m of html.matchAll(resultRegex)) {
    if (results.length >= WEB_SEARCH_MAX_RESULTS) break;
    const title = stripHtml(m[1] ?? "");
    const snippet = stripHtml(m[2] ?? "");
    const hrefMatch = /href="([^"]+)"/.exec(m[0]);
    let href = hrefMatch?.[1] ?? "";
    // DuckDuckGo wraps links as /l/?uddg=<urlencoded>; unwrap them.
    const uddg = /[?&]uddg=([^&]+)/.exec(href);
    if (uddg) {
      try {
        href = decodeURIComponent(uddg[1] ?? "");
      } catch {
        href = uddg[1] ?? ""; // malformed escape: keep the raw tail (Dart throws)
      }
    }
    if (title === "" || href === "") continue;
    if (!href.startsWith("http")) continue;
    results.push({ url: href, title, snippet });
  }
  return results;
}

/** Fan out, round-robin merge, render — Dart `_webSearch`. */
async function webSearch(queries: string[], deps: { egress: EgressFetch; ddgBase?: string }): Promise<string> {
  // Fan out concurrently. A failure rejects the whole call.
  const perQuery = await Promise.all(queries.map((q) => ddgSearch(q, deps)));

  // Round-robin merge: rank 1 of query A, rank 1 of B, …, rank 2 of A…
  const byUrl = new Map<string, WebSearchSource>();
  const ordered: WebSearchSource[] = [];
  let rank = 0;
  let added = true;
  while (added) {
    added = false;
    for (const sources of perQuery) {
      if (rank < sources.length) {
        added = true;
        const s = sources[rank];
        if (!byUrl.has(s.url)) {
          byUrl.set(s.url, s);
          ordered.push(s);
        }
      }
    }
    rank += 1;
  }

  const capped = ordered.slice(0, WEB_SEARCH_MAX_RESULTS);
  if (capped.length === 0) return "No results found.";
  const lines = capped.map(
    (s) =>
      `- [${s.title === "" ? s.url : s.title}](${s.url})` +
      `${s.snippet === "" ? "" : ` — ${s.snippet}`}`,
  );
  const truncated =
    ordered.length > capped.length
      ? `\n\n(Showing the first ${capped.length} sources. Refine the query for more.)`
      : "";
  return (
    `Web search: ${queries.join(" | ")}\n\nSources:\n` +
    `${lines.join("\n")}${truncated}\n\n` +
    "Cite the relevant URLs above as markdown links in your answer."
  );
}

export function createWebSearchTool(deps: { egress: EgressFetch; ddgBase?: string }): Tool {
  return {
    spec: {
      name: "web_search",
      description:
        "Search the web for current information. Accepts 1–4 non-empty " +
        "search queries; use a one-item array for a single search. Returns " +
        "a list of sources with titles, URLs and snippets. Cite the " +
        "relevant URLs as markdown links in your answer.",
      parameters: {
        type: "object",
        properties: {
          queries: {
            type: "array",
            items: { type: "string" },
            description: "1–4 search queries (exact duplicates run once).",
          },
        },
        required: ["queries"],
      },
    },
    timeoutMs: 60_000,
    async execute(args: Record<string, unknown>) {
      const raw = args.queries;
      const list: unknown[] = Array.isArray(raw) ? raw : [raw];
      const queries = list
        .map((q) => String(q ?? "").trim())
        .filter((q) => q !== "");
      // Keep first occurrence of each exact query.
      const distinct: string[] = [];
      for (const q of queries) {
        if (!distinct.includes(q)) distinct.push(q);
      }
      if (distinct.length === 0) {
        return { content: "Error: queries must contain at least one query" };
      }
      if (distinct.length > WEB_SEARCH_MAX_QUERIES) {
        return {
          content: `Error: queries must contain at most ${WEB_SEARCH_MAX_QUERIES} queries`,
        };
      }
      try {
        return { content: await webSearch(distinct, deps) };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return { content: `Error: ${message}` };
      }
    },
  };
}
