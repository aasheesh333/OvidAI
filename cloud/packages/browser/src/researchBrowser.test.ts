/**
 * ResearchBrowser decision-tree pins (P6 browser engine, Task 11).
 *
 * PURE unit tests — every engine is a stub with call counters; no network,
 * no chromium, no lightpanda process. The tree itself (research §7.1):
 *   static → lightpanda (post-JS DOM) → lightpanda-fetch → chromium.
 *
 * Semantics pinned by the ALL-reject test: `ResearchError.enginesTried`
 * lists the ESCALATION engines that were invoked. The static step is a
 * fast path whose negative outcome (not-static / fetch failure) is a
 * normal branch remembered in the error message, not an engine failure —
 * it is never listed in enginesTried.
 */

import { describe, expect, it, vi } from "vitest";

import type { BrowserEngineConfig } from "./config.js";
import type { LightpandaPool } from "./lightpanda.js";
import { createResearchBrowser, ResearchError } from "./researchBrowser.js";
import { extractReadable, type ExtractedPage } from "./staticExtract.js";
import { FIXTURES } from "./test/testServer.js";

const URL = "https://example.com/articles/one";

function makeCfg(overrides: Partial<BrowserEngineConfig> = {}): BrowserEngineConfig {
  return {
    maxLiveBrowsers: 2,
    tier1FallbackContexts: 1,
    idleEvictMs: 500,
    maxTier1Processes: 8,
    tier1TimeoutMs: 5_000,
    maxActiveScreencasts: 3,
    screencastLoadMax: 6.0,
    screencast: { width: 400, height: 300, quality: 60, everyNthFrame: 2, maxFramesInFlight: 2 },
    stateDir: null,
    lightpandaBin: null,
    allowHosts: ["127.0.0.1", "localhost"],
    ownPublicIp: null,
    chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
    ...overrides,
  };
}

function htmlResponse(html: string, init: ResponseInit = {}): Response {
  return new Response(html, { headers: { "content-type": "text/html" }, ...init });
}

interface Stubs {
  fetch: ReturnType<typeof vi.fn>;
  readPage: ReturnType<typeof vi.fn>;
  oneShot: ReturnType<typeof vi.fn>;
  chromium: ReturnType<typeof vi.fn>;
}

function makeStubs(): Stubs {
  return {
    fetch: vi.fn(async () => htmlResponse(FIXTURES.staticArticle)),
    readPage: vi.fn(async () => ({
      html: FIXTURES.staticArticle,
      title: "Static article",
      finalUrl: URL,
    })),
    oneShot: vi.fn(async () => ({ markdown: "# Fetched heading", title: "Fetched", finalUrl: URL })),
    chromium: vi.fn(async () => ({
      html: FIXTURES.staticArticle,
      title: "Static article",
      finalUrl: URL,
    })),
  };
}

function makePoolStub(s: Stubs): LightpandaPool {
  return {
    acquire: vi.fn(async () => ({ slot: 0, cdpUrl: "http://127.0.0.1:9400", pid: -1 })),
    readPage: s.readPage,
    oneShotMarkdown: s.oneShot,
    release: vi.fn(async () => {}),
    running: () => 0,
    close: vi.fn(async () => {}),
  };
}

function makeBrowser(s: Stubs, opts?: { lightpanda?: LightpandaPool | null; extract?: typeof extractReadable }) {
  return createResearchBrowser({
    fetchImpl: s.fetch as unknown as typeof fetch,
    lightpanda: opts?.lightpanda === undefined ? makePoolStub(s) : opts.lightpanda,
    chromiumRead: s.chromium as unknown as (url: string, timeoutMs: number) => Promise<{ html: string; title: string | null; finalUrl: string }>,
    cfg: makeCfg(),
    ...(opts?.extract !== undefined ? { extract: opts.extract } : {}),
  });
}

/** The research §2 SPA-shell stub: extraction "succeeds" with >=600 chars of
 *  nav text (textLength 3500) but the real isStaticEnough rejects it on the
 *  fixture's 12 external script-src tags — the exact trap T10 pinned. */
function spaExtractSeam(html: string, url: string): ExtractedPage | null {
  if (html === FIXTURES.spaShell) {
    return { title: "SPA shell", byline: null, markdown: "# SPA shell", textLength: 3500 };
  }
  return extractReadable(html, url);
}

describe("createResearchBrowser decision tree", () => {
  it("static HTML answers on the static engine; lightpanda and chromium are never called", async () => {
    const s = makeStubs();
    const rb = makeBrowser(s);
    const result = await rb.read(URL);
    expect(result.engine).toBe("static");
    expect(result.title).toBe("Static article");
    expect(result.markdown).toMatch(/#{1,2} A plain article/);
    expect(result.finalUrl).toBe(URL);
    expect(result.ms).toBeGreaterThanOrEqual(0);
    expect(s.fetch).toHaveBeenCalledTimes(1);
    expect(s.readPage).not.toHaveBeenCalled();
    expect(s.oneShot).not.toHaveBeenCalled();
    expect(s.chromium).not.toHaveBeenCalled();
  });

  it("SPA shell (readable >=600 chars but 12 script-src tags) escalates to lightpanda, not chromium", async () => {
    const s = makeStubs();
    s.fetch.mockResolvedValue(htmlResponse(FIXTURES.spaShell));
    const rb = makeBrowser(s, { extract: spaExtractSeam });
    const result = await rb.read(URL);
    expect(result.engine).toBe("lightpanda");
    // The post-JS DOM (stubbed as the rendered article) is what gets served.
    expect(result.markdown).toMatch(/A plain article/);
    expect(s.readPage).toHaveBeenCalledTimes(1);
    expect(s.oneShot).not.toHaveBeenCalled();
    expect(s.chromium).not.toHaveBeenCalled();
  });

  it("a non-OK fetch status escalates to lightpanda (remembered, not thrown)", async () => {
    const s = makeStubs();
    s.fetch.mockResolvedValue(htmlResponse("nope", { status: 404 }));
    const rb = makeBrowser(s);
    const result = await rb.read(URL);
    expect(result.engine).toBe("lightpanda");
  });

  it("a non-HTML content-type escalates to lightpanda", async () => {
    const s = makeStubs();
    s.fetch.mockResolvedValue(new Response("{}", { headers: { "content-type": "application/json" } }));
    const rb = makeBrowser(s);
    const result = await rb.read(URL);
    expect(result.engine).toBe("lightpanda");
  });

  it("lightpanda.readPage rejecting falls through to lightpanda-fetch", async () => {
    const s = makeStubs();
    s.fetch.mockResolvedValue(htmlResponse(FIXTURES.spaShell));
    s.readPage.mockRejectedValue(new Error("cdp connection closed"));
    const rb = makeBrowser(s);
    const result = await rb.read(URL);
    expect(result.engine).toBe("lightpanda-fetch");
    expect(result.markdown).toContain("Fetched heading");
    expect(result.title).toBe("Fetched");
    expect(s.chromium).not.toHaveBeenCalled();
  });

  it("both lightpanda paths rejecting falls through to chromium", async () => {
    const s = makeStubs();
    s.fetch.mockResolvedValue(htmlResponse(FIXTURES.spaShell));
    s.readPage.mockRejectedValue(new Error("readPage boom"));
    s.oneShot.mockRejectedValue(new Error("fetch boom"));
    const rb = makeBrowser(s);
    const result = await rb.read(URL);
    expect(result.engine).toBe("chromium");
    expect(s.chromium).toHaveBeenCalledTimes(1);
  });

  it("every engine failing rejects with ResearchError and the exact enginesTried array", async () => {
    const s = makeStubs();
    s.fetch.mockRejectedValue(new Error("ECONNREFUSED"));
    s.readPage.mockRejectedValue(new Error("readPage boom"));
    s.oneShot.mockRejectedValue(new Error("fetch boom"));
    s.chromium.mockRejectedValue(new Error("chromium boom"));
    const rb = makeBrowser(s);
    const err = await rb.read(URL).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ResearchError);
    // "static" produced no result (fetch failed) — it is not tried-and-failed
    // and is therefore absent; only the invoked escalation engines are listed.
    expect((err as ResearchError).enginesTried).toEqual(["lightpanda", "lightpanda-fetch", "chromium"]);
  });

  it("prefer:'render' skips straight to chromium (fetch + lightpanda untouched)", async () => {
    const s = makeStubs();
    const rb = makeBrowser(s);
    const result = await rb.read(URL, { prefer: "render" });
    expect(result.engine).toBe("chromium");
    expect(s.fetch).not.toHaveBeenCalled();
    expect(s.readPage).not.toHaveBeenCalled();
    expect(s.oneShot).not.toHaveBeenCalled();
    expect(s.chromium).toHaveBeenCalledTimes(1);
  });

  it("lightpanda:null skips both lightpanda steps — an SPA shell falls straight to chromium", async () => {
    const s = makeStubs();
    s.fetch.mockResolvedValue(htmlResponse(FIXTURES.spaShell));
    const rb = makeBrowser(s, { lightpanda: null, extract: spaExtractSeam });
    const result = await rb.read(URL);
    expect(result.engine).toBe("chromium");
    expect(s.chromium).toHaveBeenCalledTimes(1);
  });

  it("a hanging static fetch escalates within the per-step timeout (AbortSignal wired)", async () => {
    const s = makeStubs();
    s.fetch.mockImplementation(() => new Promise<Response>(() => undefined));
    const rb = makeBrowser(s);
    const t0 = Date.now();
    const result = await rb.read(URL, { timeoutMs: 50 });
    expect(Date.now() - t0).toBeLessThan(200);
    expect(result.engine).toBe("lightpanda");
    // The router handed fetch an AbortSignal so a REAL fetch self-cancels too.
    const init = s.fetch.mock.calls[0]![1] as RequestInit | undefined;
    expect(init?.signal).toBeInstanceOf(AbortSignal);
  });

  it("a chromium render whose DOM yields no article rejects with ResearchError", async () => {
    const s = makeStubs();
    // The static step must fail first (404) or it would answer outright.
    s.fetch.mockResolvedValue(htmlResponse("nope", { status: 404 }));
    // "<html>" is the T10-pinned input readability finds no article in.
    s.chromium.mockResolvedValue({ html: "<html>", title: "t", finalUrl: URL });
    const rb = makeBrowser(s, { lightpanda: null });
    const err = await rb.read(URL).then(
      () => null,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(ResearchError);
    expect((err as ResearchError).enginesTried).toEqual(["chromium"]);
  });

  it("close() closes the lightpanda pool", async () => {
    const s = makeStubs();
    const pool = makePoolStub(s);
    const rb = makeBrowser(s, { lightpanda: pool });
    await rb.close();
    expect(pool.close).toHaveBeenCalledTimes(1);
  });
});
