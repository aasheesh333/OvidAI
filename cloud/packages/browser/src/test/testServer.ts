/**
 * Shared fixture server for every gated browser test. Plain node:http on
 * 127.0.0.1:0 — no extra deps, no external network.
 */

import { createServer } from "node:http";
import type { Server } from "node:http";

/**
 * Fixture page pins used by later tasks:
 * - clickButton: a #btn at left:20 top:20 100x40 whose click sets #out to
 *   "CLICKED" (hit-testing); a #in text input at left:20 top:80 (typing and
 *   insertText targets); a document keydown handler setting #out to
 *   "KEY_ENTER" on Enter (P6 Task 7 input-injection pins).
 * - animated: full-viewport div cycling background-color every 100 ms —
 *   screencast is damage-driven, so a static page emits 0 frames (research
 *   §3.3) and this page guarantees damage.
 * - spaShell: empty #root + 12 <script src> tags + ~3.5 KB nav text (the
 *   react.dev-shaped false-positive case from research §2).
 */

export const FIXTURES = {
  staticArticle: `<!doctype html>
<html><head><title>Static article</title></head>
<body>
  <h1>A plain article</h1>
  <p>Static content with no scripts at all. The readability extraction path
  should parse this into a clean article body.</p>
  <p>Second paragraph with a <a href="/spa">link to the SPA shell</a>.</p>
  <p>Static extraction is the tier-one fast path: it parses the fetched HTML
  with a DOM implementation and runs the readability heuristic without ever
  launching a browser. When the markup already contains the full article
  prose, this is dramatically cheaper than a chromium run and the pool is
  never paid for at all.</p>
  <p>Readability scores candidate nodes by link density and text volume,
  then returns the article title, an optional byline, and a cleaned content
  subtree. Turndown converts that subtree to markdown while preserving
  anchors, so links inside the article body survive the conversion as
  inline markdown links rather than being flattened to bare text.</p>
  <p>Long-form prose in this fixture ensures the extracted text crosses the
  minimum character threshold that decides whether the static path is
  sufficient, or whether the caller must fall back to a full browser
  render of the page.</p>
</body></html>
`,
  spaShell: `<!doctype html>
<html><head><title>SPA shell</title></head>
<body>
  <div id="root"></div>
  ${Array.from({ length: 12 }, (_, i) => `<script src="/js/chunk-${i}.js"></script>`).join("\n  ")}
  <nav>
    <p>${"Navigation text block for the SPA shell fixture. ".repeat(80)}</p>
  </nav>
</body></html>
`,
  clickButton: `<!doctype html>
<html><head><title>Click</title></head>
<body>
  <button id="btn" style="position:absolute;left:20px;top:20px;width:100px;height:40px;">Click me</button>
  <input id="in" style="position:absolute;left:20px;top:80px;width:200px;height:30px;">
  <div id="out"></div>
  <script>
    document.getElementById("btn").addEventListener("click", () => {
      document.getElementById("out").textContent = "CLICKED";
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Enter") document.getElementById("out").textContent = "KEY_ENTER";
    });
  </script>
</body></html>
`,
  setCookie: `<!doctype html>
<html><head><title>Cookie</title></head>
<body><h1>Cookie page</h1><p>Sets a login cookie then renders static text.</p></body></html>
`,
  animated: `<!doctype html>
<html><head><title>Animated</title></head>
<body>
  <div id="anim" style="position:fixed;left:0;top:0;width:100vw;height:100vh;background-color:red"></div>
  <script>
    let hue = 0;
    setInterval(() => {
      hue = (hue + 30) % 360;
      document.getElementById("anim").style.backgroundColor = "hsl(" + hue + ", 100%, 50%)";
    }, 100);
  </script>
</body></html>
`,
  bigDom: `<!doctype html>
<html><head><title>Big DOM</title></head>
<body>
  <h1>Big DOM</h1>
  ${Array.from({ length: 5000 }, (_, i) => `<p class="row-${i}">Row ${i} of the big DOM fixture.</p>`).join("\n  ")}
</body></html>
`,
} as const;

export interface TestPageServer {
  origin: string;
  url(path?: string): string;
  close(): Promise<void>;
}

const ROUTES: Record<string, { body: string; type: string; headers?: Record<string, string> }> = {
  "/": { body: FIXTURES.staticArticle, type: "text/html" },
  "/spa": { body: FIXTURES.spaShell, type: "text/html" },
  "/click": { body: FIXTURES.clickButton, type: "text/html" },
  "/setcookie": {
    body: FIXTURES.setCookie,
    type: "text/html",
    headers: { "Set-Cookie": "login_tok=abc123; Path=/" },
  },
  "/animated": { body: FIXTURES.animated, type: "text/html" },
  "/big": { body: FIXTURES.bigDom, type: "text/html" },
  "/attachment": { body: "file-bytes", type: "application/octet-stream", headers: { "Content-Disposition": "attachment" } },
};

export function startTestPageServer(): Promise<TestPageServer> {
  return new Promise((resolve) => {
    const server: Server = createServer((req, res) => {
      const path = (req.url ?? "/").split("?")[0];
      // /js/* chunks referenced by the SPA shell: 200 with a tiny body.
      const route = ROUTES[path] ?? (path.startsWith("/js/") ? { body: "//chunk", type: "text/javascript" } : undefined);
      if (!route) {
        res.writeHead(404, { "Content-Type": "text/plain" });
        res.end("not found");
        return;
      }
      res.writeHead(200, {
        "Content-Type": route.type,
        ...(route.headers ?? {}),
      });
      res.end(route.body);
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (addr === null || typeof addr === "string") throw new Error("no server address");
      const origin = `http://127.0.0.1:${addr.port}`;
      resolve({
        origin,
        url: (path?: string) => `${origin}${path ?? "/"}`,
        close: () =>
          new Promise<void>((r) => {
            server.close(() => r());
          }),
      });
    });
  });
}
