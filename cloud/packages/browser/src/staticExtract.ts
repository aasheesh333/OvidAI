/**
 * Tier-1 static fast path (P6 browser engine, Task 10).
 *
 * Static fetch + DOM parse + Readability extraction run BEFORE any chromium
 * spawn decision: when the served HTML already contains the article, this
 * path is provably cheaper than a browser run and the pool is never touched.
 *
 * Note: linkedom >= 0.16 removed `parseDOM`; `parseHTML` is the same parser
 * and returns the document (plus globals) that Readability consumes.
 */

import { parseHTML } from "linkedom";
import { Readability } from "@mozilla/readability";
import TurndownService from "turndown";

export interface ExtractedPage {
  title: string | null;
  byline: string | null;
  markdown: string;
  textLength: number;
}

/** Minimum extracted prose characters for the static path to be sufficient. */
export const STATIC_MIN_CHARS = 600;

/** Max external <script src> tags a page may carry and still count as static. */
export const STATIC_MAX_SCRIPT_SRCS = 8;

/**
 * Parse `html` with linkedom, run Mozilla Readability over it, and convert
 * the resulting article subtree to markdown with Turndown.
 *
 * Returns null when Readability finds no article (including unparsable
 * input); never throws.
 */
export function extractReadable(html: string, url: string): ExtractedPage | null {
  // `url` is reserved for link-resolution in the fetch wiring (Tasks 11/12
  // call this with the request URL; Readability itself only reads the DOM).
  try {
    const dom = parseHTML(html);
    const article = new Readability(dom.document as unknown as Document).parse();
    if (!article || !article.content) return null;

    const turndown = new TurndownService({
      headingStyle: "atx",
      codeBlockStyle: "fenced",
    });
    // Default rules drop tables entirely; keep the table family as HTML so
    // tabular content survives extraction.
    turndown.keep(["table", "thead", "tbody", "tr", "td", "th", "caption"]);

    const markdown = turndown.turndown(article.content);
    return {
      title: article.title ?? null,
      byline: article.byline ?? null,
      markdown,
      textLength: (article.textContent ?? "").length,
    };
  } catch {
    return null;
  }
}

/**
 * Decide whether the static path alone is good enough to answer the request,
 * or whether the caller must escalate to a chromium render (Tier-2).
 *
 * Guards the research §2 false-positive (react.dev-shaped SPA shells that
 * carry >=600 chars of nav text): even with a readable article, a page
 * driven by many external scripts has not yet rendered its real content.
 */
export function isStaticEnough(html: string, extracted: ExtractedPage | null): boolean {
  if (extracted === null) return false;
  if (extracted.textLength < STATIC_MIN_CHARS) return false;
  try {
    // Fresh parse: Readability mutates the document it is handed (it strips
    // scripts while scoring), so the script count must come from a document
    // Readability has never touched.
    const dom = parseHTML(html);
    const scriptSrcs = dom.document.querySelectorAll("script[src]").length;
    return scriptSrcs <= STATIC_MAX_SCRIPT_SRCS;
  } catch {
    return false;
  }
}
