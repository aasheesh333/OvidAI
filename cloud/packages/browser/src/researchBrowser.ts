/**
 * ResearchBrowser — the Tier-1 decision tree (P6 Task 11; research §7.1).
 *
 *   1. prefer:"render"                     -> straight to chromium
 *   2. static fetch + extractReadable      -> engine "static"
 *      (gated on isStaticEnough — NOT extractReadable !== null: SPA shells
 *      carry >=600 chars of readable nav text while NOT being static; the
 *      T10-carry trap)
 *   3. lightpanda pool readPage (post-JS)  -> engine "lightpanda"
 *   3b. lightpanda one-shot fetch          -> engine "lightpanda-fetch"
 *   5. chromium fallback                   -> engine "chromium"
 *   (lightpanda === null skips 3 + 4 entirely)
 *
 * `ResearchError.enginesTried` lists the ESCALATION engines that were
 * INVOKED, in tree order. The static step is a fast path, not an engine:
 * a negative outcome there (fetch error, non-HTML, not-static-enough) is
 * remembered and folded into the final error message, but "static" never
 * appears in enginesTried — it did not produce a result, so it is not
 * "tried-and-failed".
 */

import { extractReadable, isStaticEnough, type ExtractedPage } from "./staticExtract.js";
import type { BrowserEngineConfig } from "./config.js";
import type { LightpandaPool } from "./lightpanda.js";

export type ResearchEngine = "static" | "lightpanda" | "lightpanda-fetch" | "chromium";

export interface ResearchResult {
  markdown: string;
  title: string | null;
  finalUrl: string;
  engine: ResearchEngine;
  ms: number;
}

export class ResearchError extends Error {
  readonly enginesTried: ResearchEngine[];

  constructor(message: string, enginesTried: ResearchEngine[]) {
    super(message);
    this.name = "ResearchError";
    this.enginesTried = enginesTried;
  }
}

export interface ResearchBrowser {
  read(url: string, opts?: { timeoutMs?: number; prefer?: "fast" | "render" }): Promise<ResearchResult>;
  close(): Promise<void>;
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export function createResearchBrowser(deps: {
  /** SSRF-guarded fetch (Task 1's url guard wiring is the caller's job). */
  fetchImpl: typeof fetch;
  /** null => both lightpanda steps are skipped. */
  lightpanda: LightpandaPool | null;
  /** Chromium fallback; the engine wires this to BrowserPool.acquireTier1. */
  chromiumRead(url: string, timeoutMs: number): Promise<{ html: string; title: string | null; finalUrl: string }>;
  cfg: BrowserEngineConfig;
  /** Test seam; defaults to the real staticExtract extractor. */
  extract?: typeof extractReadable;
}): ResearchBrowser {
  const extract = deps.extract ?? extractReadable;

  async function read(url: string, opts: { timeoutMs?: number; prefer?: "fast" | "render" } = {}): Promise<ResearchResult> {
    const timeoutMs = opts.timeoutMs ?? deps.cfg.tier1TimeoutMs;
    const startedAt = Date.now();
    const enginesTried: ResearchEngine[] = [];
    let staticNote = "";
    const result = (partial: Omit<ResearchResult, "ms">): ResearchResult => ({
      ...partial,
      ms: Date.now() - startedAt,
    });

    // ------------------------------------------------------------------
    // Steps 2-4 — skipped ENTIRELY on prefer:"render" (skip to step 5).
    // ------------------------------------------------------------------
    if (opts.prefer !== "render") {
      // Step 2: static fast path.
      // AbortSignal is wired into fetchImpl so a REAL fetch self-cancels; the
      // race also rejects against the signal so a hanging fetch (or a stub
      // that ignores signals) still escalates at the per-step timeout.
      const signal = AbortSignal.timeout(timeoutMs);
      try {
        const res = await Promise.race([
          deps.fetchImpl(url, { signal, redirect: "follow" }),
          new Promise<never>((_, reject) => {
            signal.addEventListener(
              "abort",
              () => reject(new Error(`static fetch timed out after ${timeoutMs} ms`)),
              { once: true },
            );
          }),
        ]);
        const contentType = res.headers.get("content-type") ?? "";
        if (!res.ok) {
          staticNote = `static fetch: HTTP ${res.status}`;
        } else if (!contentType.includes("text/html")) {
          staticNote = `static fetch: content-type "${contentType}" is not text/html`;
        } else {
          const html = await res.text();
          const finalUrl = res.url || url;
          const extracted = extract(html, finalUrl);
          // T10 CARRY: gate on isStaticEnough, not extracted !== null — the
          // SPA shell extracts >=600 chars of nav text while NOT being static.
          if (isStaticEnough(html, extracted)) {
            return result({
              markdown: extracted!.markdown,
              title: extracted!.title,
              finalUrl,
              engine: "static",
            });
          }
          staticNote =
            extracted === null
              ? "static fetch: readability found no article"
              : "static fetch: page is not static enough (script-heavy shell)";
        }
      } catch (err) {
        staticNote = `static fetch failed: ${messageOf(err)}`;
      }

      if (deps.lightpanda !== null) {
        // ------------------------------------------------------------
        // Step 3: lightpanda pool readPage — the post-JS DOM (SPA coverage).
        // ------------------------------------------------------------
        enginesTried.push("lightpanda");
        try {
          const page = await deps.lightpanda.readPage(url, timeoutMs);
          const extracted = extract(page.html, page.finalUrl);
          if (extracted !== null) {
            return result({
              markdown: extracted.markdown,
              title: extracted.title,
              finalUrl: page.finalUrl,
              engine: "lightpanda",
            });
          }
          staticNote += "; lightpanda DOM yielded no readable article";
        } catch (err) {
          staticNote += `; lightpanda readPage failed: ${messageOf(err)}`;
        }

        // ------------------------------------------------------------
        // Step 3b/4: one-shot `fetch --dump markdown` subprocess.
        // ------------------------------------------------------------
        enginesTried.push("lightpanda-fetch");
        try {
          const shot = await deps.lightpanda.oneShotMarkdown(url, timeoutMs);
          return result({
            markdown: shot.markdown,
            title: shot.title,
            finalUrl: shot.finalUrl,
            engine: "lightpanda-fetch",
          });
        } catch (err) {
          staticNote += `; lightpanda fetch failed: ${messageOf(err)}`;
        }
      }
    } else {
      staticNote = "render preferred";
    }

    // ------------------------------------------------------------------
    // Step 5: chromium fallback (BrowserPool tier-1 lease).
    // ------------------------------------------------------------------
    enginesTried.push("chromium");
    try {
      const page = await deps.chromiumRead(url, timeoutMs);
      const extracted: ExtractedPage | null = extract(page.html, page.finalUrl);
      if (extracted === null) {
        throw new Error("chromium render: readability found no article");
      }
      return result({
        markdown: extracted.markdown,
        title: extracted.title ?? page.title,
        finalUrl: page.finalUrl,
        engine: "chromium",
      });
    } catch (err) {
      throw new ResearchError(
        `research read failed for ${url} (${staticNote}${staticNote ? "; " : ""}engines tried: ${enginesTried.join(", ")}): ${messageOf(err)}`,
        enginesTried,
      );
    }
  }

  return {
    read,
    close: async () => {
      await deps.lightpanda?.close();
    },
  };
}
