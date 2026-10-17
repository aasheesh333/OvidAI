import { describe, expect, it } from "vitest";

import { FIXTURES } from "./test/testServer.js";
import {
  extractReadable,
  isStaticEnough,
  STATIC_MAX_SCRIPT_SRCS,
  STATIC_MIN_CHARS,
} from "./staticExtract.js";

const URL = "https://example.com/articles/plain";

/**
 * Server-rendered page: long readable prose plus `scriptCount` external
 * script tags. This is the shape a "normal" SSR blog/docs page has — enough
 * text for readability and a handful of analytics/framework bundles.
 */
function serverRendered(scriptCount: number): string {
  const prose = Array.from(
    { length: 12 },
    (_, i) =>
      `<p>Section ${i}: this server-rendered paragraph carries plain prose that the static extraction path should recover without any browser involvement.</p>`,
  ).join("\n  ");
  const scripts = Array.from(
    { length: scriptCount },
    (_, i) => `<script src="/js/bundle-${i}.js"></script>`,
  ).join("\n  ");
  return `<!doctype html>
<html><head><title>Server-rendered</title></head>
<body>
  <h1>A server-rendered page</h1>
  ${prose}
  ${scripts}
</body></html>
`;
}

describe("static extraction tier-1 pins", () => {
  it("exposes the research-pinned thresholds", () => {
    expect(STATIC_MIN_CHARS).toBe(600);
    expect(STATIC_MAX_SCRIPT_SRCS).toBe(8);
  });
});

describe("extractReadable", () => {
  it("extracts the static article: heading as markdown heading, >=600 prose chars, title, byline field", () => {
    const extracted = extractReadable(FIXTURES.staticArticle, URL);
    expect(extracted).not.toBeNull();
    expect(extracted!.title).toBe("Static article");
    // byline is part of the ExtractedPage contract; absent on this fixture.
    expect(extracted!.byline).toBeNull();
    // The article heading survives as a markdown # / ## heading.
    expect(extracted!.markdown).toMatch(/#{1,2} A plain article/);
    // Enough prose to be worth serving without a browser.
    expect(extracted!.textLength).toBeGreaterThanOrEqual(STATIC_MIN_CHARS);
    expect(extracted!.markdown.length).toBeGreaterThanOrEqual(600);
  });

  it("keeps in-article <a href> as [text](href) markdown (fetch --dump markdown parity)", () => {
    const extracted = extractReadable(FIXTURES.staticArticle, URL);
    expect(extracted).not.toBeNull();
    expect(extracted!.markdown).toContain("[link to the SPA shell](/spa)");
  });

  it("returns null (no throw) on garbage HTML", () => {
    let out: ReturnType<typeof extractReadable> = undefined;
    expect(() => {
      out = extractReadable("<html>", URL);
    }).not.toThrow();
    expect(out).toBeNull();
    expect(isStaticEnough("<html>", out)).toBe(false);
  });
});

describe("isStaticEnough", () => {
  it("accepts the no-script static article", () => {
    const extracted = extractReadable(FIXTURES.staticArticle, URL);
    expect(extracted).not.toBeNull();
    expect(isStaticEnough(FIXTURES.staticArticle, extracted)).toBe(true);
  });

  it("rejects the SPA shell (research §2 react.dev false-positive: 12 script-src tags)", () => {
    const extracted = extractReadable(FIXTURES.spaShell, URL);
    // The trap this guard exists for: readability DOES find >=600 chars of
    // nav text on a client-rendered shell, so text alone must not pass.
    expect(extracted).not.toBeNull();
    expect(extracted!.textLength).toBeGreaterThanOrEqual(STATIC_MIN_CHARS);
    expect(isStaticEnough(FIXTURES.spaShell, extracted)).toBe(false);
  });

  it("accepts a server-rendered page with long text and 5 script-src tags", () => {
    const html = serverRendered(5);
    const extracted = extractReadable(html, URL);
    expect(extracted).not.toBeNull();
    expect(extracted!.textLength).toBeGreaterThanOrEqual(STATIC_MIN_CHARS);
    expect(isStaticEnough(html, extracted)).toBe(true);
  });

  it("holds the boundary: exactly 8 script-src tags passes, 9 fails", () => {
    const atBoundary = serverRendered(STATIC_MAX_SCRIPT_SRCS);
    const atBoundaryExtracted = extractReadable(atBoundary, URL);
    expect(atBoundaryExtracted).not.toBeNull();
    expect(isStaticEnough(atBoundary, atBoundaryExtracted)).toBe(true);

    const overBoundary = serverRendered(STATIC_MAX_SCRIPT_SRCS + 1);
    const overBoundaryExtracted = extractReadable(overBoundary, URL);
    expect(overBoundaryExtracted).not.toBeNull();
    expect(isStaticEnough(overBoundary, overBoundaryExtracted)).toBe(false);
  });

  it("rejects when readability finds no article (extracted === null)", () => {
    expect(isStaticEnough(FIXTURES.staticArticle, null)).toBe(false);
  });
});
