#!/usr/bin/env node
/**
 * browser-memory-bench.mjs — P6 Task 16 activation bench (owner-run, manual).
 *
 * Proves the P6 Global-Constraints memory envelope ON THE BOX: one shared
 * chromium process + 4 live contexts over the pool's default config
 * (MAX_LIVE_BROWSERS=4), driven against a LOCAL synthetic heavy fixture
 * (`/big` — no internet), sampled for 60 s while every page scrolls.
 *
 * Prints the research-§5-shaped ladder (0/1/2/3/4 pages) + peak total RSS,
 * and exits NON-ZERO when peak > 1300 MB — the Global-Constraints planned
 * peak (~1.3 GB) with headroom before the 2 GB pool share of the 4 GB
 * worker unit (controller ruling R3). It is a regression ALARM, not a unit
 * test: cloud/deploy/BROWSERS.md §(c) carries the budget math and the
 * paste-in slot for this output.
 *
 * Usage:   node cloud/scripts/browser-memory-bench.mjs
 * Gates:   chromium must be installed (PLAYWRIGHT_BROWSERS_PATH or the
 *          default ~/.cache/ms-playwright) — exits 2 with a clear message
 *          otherwise. Run on an otherwise-idle box (RSS is measured for the
 *          whole chromium process TREE this process owns, so concurrent
 *          test chromium runs do not pollute it, but CPU contention does).
 * Exits:   0 = under threshold, 1 = peak > 1300 MB, 2 = gated, 3 = error.
 */

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import process from "node:process";

// Relative dist import (not "@ovid/browser"): the workspace link for the
// package name is only created by a fresh `pnpm install` (wave-merger owns
// that; T15's ledger), while the dist + its node_modules are always here.
import {
  chromiumExecutableExists,
  createBrowserPool,
  loadBrowserEngineConfig,
} from "../packages/browser/dist/index.js";

const CONTEXTS = 4; // MAX_LIVE_BROWSERS — the pool share being proven
const SAMPLE_INTERVAL_MS = 2_000;
const SAMPLE_DURATION_MS = 60_000;
const ALARM_MB = 1300; // planned peak ≈1.3 GB; hard ceiling is 2 GB

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Local fixture: /big — synthetic heavy DOM (no network). Deterministic
// (seeded LCG) so runs are comparable across hosts and time.
// ---------------------------------------------------------------------------

function heavyHtml() {
  let seed = 42;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const words =
    "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt labore dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute irure in reprehenderit voluptate velit esse cillum".split(
      " ",
    );
  const parts = [];
  parts.push(
    "<!doctype html><html><head><meta charset='utf-8'><title>bench /big</title><style>",
    "body{font:14px/1.45 system-ui;margin:0}",
    ".b{padding:6px 10px;border-bottom:1px solid #ddd}",
    ".b:nth-child(3n){background:#f7f7f7}.b:nth-child(7n){background:#eef}",
    ".b:nth-child(5n) span{color:#333}.b:nth-child(11n) a{color:#04a}",
    ".g{display:grid;grid-template-columns:repeat(8,1fr);gap:4px}",
    "</style></head><body><h1>synthetic heavy DOM</h1><div class='g'>",
  );
  for (let i = 0; i < 240; i++) {
    parts.push(`<div class='c'>${i}</div>`);
  }
  parts.push("</div><main>");
  for (let i = 0; i < 6000; i++) {
    let text = "";
    for (let w = 0; w < 30; w++) text += words[Math.floor(rnd() * words.length)] + " ";
    parts.push(
      `<div class='b' data-i='${i}'><span>${text.trim()}</span> ` +
        `<a href='#n${Math.floor(rnd() * 6000)}'>link</a> <em>${rnd().toFixed(6)}</em></div>`,
    );
  }
  parts.push("</main></body></html>");
  return parts.join("");
}

function startFixtureServer() {
  const body = heavyHtml();
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      if (req.url === "/big") {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end(body);
      } else {
        res.writeHead(404).end("not found");
      }
    });
    server.listen(0, "127.0.0.1", () => {
      resolve({ server, base: `http://127.0.0.1:${server.address().port}` });
    });
  });
}

// ---------------------------------------------------------------------------
// RSS sampling: the whole chromium process TREE owned by this process.
//
// playwright-core 1.64 exposes no browser.process(), so the root is found
// structurally: the ps row whose PPID is THIS node process and whose args
// look like a chromium binary (chrome / headless_shell). Every descendant
// of that root (renderers, gpu, utility) is summed via PPID edges.
// ---------------------------------------------------------------------------

const CHROMIUM_ARG_HINT = /(?:chrome|headless_shell|chromium)/;

function psRows() {
  const out = execFileSync("ps", ["-eo", "pid=,ppid=,rss=,args="], { encoding: "utf8" });
  const rows = [];
  for (const line of out.split("\n")) {
    const m = line.match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
    if (!m) continue;
    rows.push({ pid: Number(m[1]), ppid: Number(m[2]), rssKb: Number(m[3]), args: m[4] });
  }
  return rows;
}

function sampleTree() {
  const rows = psRows();
  const root = rows.find(
    (r) => r.ppid === process.pid && CHROMIUM_ARG_HINT.test(r.args) && !/^ps\b/.test(r.args),
  );
  if (!root) return { rootPid: null, procs: 0, totalMb: 0 };
  const children = new Map();
  for (const r of rows) {
    if (!children.has(r.ppid)) children.set(r.ppid, []);
    children.get(r.ppid).push(r);
  }
  let procs = 0;
  let rssKb = 0;
  const stack = [root];
  while (stack.length) {
    const r = stack.pop();
    procs++;
    rssKb += r.rssKb;
    for (const c of children.get(r.pid) ?? []) stack.push(c);
  }
  return { rootPid: root.pid, procs, totalMb: rssKb / 1024 };
}

const mb = (n) => (n >= 100 ? n.toFixed(0) : n.toFixed(1));

// ---------------------------------------------------------------------------

async function main() {
  if (!chromiumExecutableExists()) {
    console.error(
      "browser-memory-bench: GATED — no chromium installation found " +
        "(PLAYWRIGHT_BROWSERS_PATH / ~/.cache/ms-playwright). Install it per " +
        "cloud/deploy/BROWSERS.md §(b), then re-run. Nothing was measured.",
    );
    process.exitCode = 2;
    return;
  }

  const { server, base } = await startFixtureServer();
  // loadBrowserEngineConfig({}) = every pinned default; the bench pins the
  // admission shape explicitly so local env cannot skew the envelope proof.
  const cfg = {
    ...loadBrowserEngineConfig({}),
    maxLiveBrowsers: CONTEXTS,
    stateDir: null,
    allowHosts: [],
    ownPublicIp: null,
  };
  // sweepIntervalMs 0 — the bench owns timing; no background idle eviction.
  const pool = createBrowserPool(cfg, { sweepIntervalMs: 0 });

  const handles = [];
  try {
    // Row 0 — chromium base with ZERO pages: launch the browser via a
    // throwaway tier-1 lease and release it (the process stays alive).
    const warm = await pool.acquireTier1();
    await warm.release();
    await sleep(500);
    const baseSample = sampleTree();
    if (!baseSample.rootPid) throw new Error("could not locate the chromium process tree — see sampling notes in the header");
    console.log(`browser-memory-bench: chromium root pid ${baseSample.rootPid} (${baseSample.procs} procs at base)`);
    const ladder = [`  0 pages open:  ${mb(baseSample.totalMb).padStart(6)} MB   (chromium base)`];

    // Rows 1..4 — one live context at a time, each on /big + scrolled.
    for (let i = 1; i <= CONTEXTS; i++) {
      const h = await pool.acquireLive(`bench-${i}`);
      handles.push(h);
      await h.page.goto(`${base}/big`, { waitUntil: "domcontentloaded", timeout: 60_000 });
      await h.page.mouse.wheel(0, 800);
      await h.page.evaluate(() => window.scrollTo(0, document.body.scrollHeight / 2));
      await sleep(500);
      const s = sampleTree();
      ladder.push(`  ${i} page${i > 1 ? "s" : " "} open:  ${mb(s.totalMb).padStart(6)} MB`);
    }

    // 60 s sampling while scrolling every page every 2 s.
    const samples = [];
    const startedAt = Date.now();
    let tick = 0;
    while (Date.now() - startedAt < SAMPLE_DURATION_MS) {
      for (const h of handles) {
        h.touch();
        await h.page.mouse.wheel(0, 300 + ((tick * 137) % 900));
        if (tick % 3 === 0) {
          await h.page.evaluate(
            (n) => window.scrollTo(0, (document.body.scrollHeight * ((n * 7) % 10)) / 10),
            tick,
          );
        }
      }
      tick++;
      await sleep(SAMPLE_INTERVAL_MS);
      samples.push(sampleTree());
    }

    const peak = samples.reduce((a, s) => Math.max(a, s.totalMb), 0);
    const last = samples[samples.length - 1];
    console.log("\ncontext RSS ladder (1 shared chromium process, 4 live contexts on /big):");
    for (const row of ladder) console.log(row);
    console.log(
      `\n${SAMPLE_DURATION_MS / 1000} s scroll load: peak ${mb(peak)} MB ` +
        `(${samples.length} samples, ${last.procs} procs in tree; alarm threshold ${ALARM_MB} MB, hard ceiling 2048 MB)`,
    );
    console.log(
      `VERDICT: ${peak > ALARM_MB ? "REGRESSION — peak exceeds the planned-peak alarm; investigate before activation" : "OK — within the planned peak"}`,
    );
    if (peak > ALARM_MB) process.exitCode = 1;
    console.log("\nPaste the ladder + peak above into cloud/deploy/BROWSERS.md §(c) and the SDD ledger.");
  } finally {
    await pool.close().catch(() => {});
    server.close();
  }
}

main().catch((err) => {
  console.error("browser-memory-bench: FAILED:", err);
  process.exit(3);
});
