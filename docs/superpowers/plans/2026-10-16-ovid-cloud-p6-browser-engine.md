# Ovid Cloud P6 — Two-Tier Server-Side Browser Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The agent browses the web server-side via ~36 `browser_*` tools on a two-tier engine (Tier-1 cheap research extraction, Tier-2 live Playwright chromium), and the user watches the live browser as binary screencast frames over the existing multiplexed WS and can inject input / take over control from the thin client — with per-user login state (storageState) persisted encrypted across context restarts.

**Architecture:** New package `cloud/packages/browser` owns everything engine-side: `BrowserPool` (one lazily-launched pinned chromium process; per-session `BrowserContext` isolation; admission `MAX_LIVE_BROWSERS=4` live + 2 tier-1-fallback contexts with FIFO queues; 3-min idle eviction with storageState flush), Tier-1 `ResearchBrowser` (linkedom/readability static fast path → Lightpanda serve-pool / `fetch --dump markdown` → chromium fallback, decision tree from the binding research doc), encrypted storageState persistence (merge → prune → zstd-9 → AES-256-GCM envelope → `BrowserStateStore` adapter: local disk now, R2 in P7), CDP screencast (JPEG q60 everyNthFrame=2 maxFramesInFlight=2 1280×800 default; runtime WebP probe keyed to the pinned chromium build), and input injection via Playwright `page.mouse/keyboard`. Gateway and worker stay separate processes: the gateway's new `browser` WS ops (additive to `WsClientMsg`/`WsServerMsg`) and the worker-side engine talk over **redis-q PUB/SUB only** (ephemeral frames/state/ctl/input channels — no keyspace writes, AG3-safe). The worker exposes a `BrowserEngine` facade; the tool defs are P3-registry-shaped (`name/description/parameters/inputSchema/execute`).

**Tech Stack:** Node 22 (≥22.15 for `node:zlib` zstd), pnpm workspaces, TypeScript strict, Vitest, `playwright-core` **exactly 1.64.1** (→ Chromium **156.0.8078.4**), Lightpanda **1.0.1** x86_64-linux (sha256 `551747e35c51ba107b5d5277eca4b48e077b2a3b40f09a047bf6670448bc35fd`, 75,670,856 B), linkedom + @mozilla/readability + turndown, ioredis, zod, `node:crypto` (AES-256-GCM), `node:zlib` (zstdCompressSync level 9), Fastify 5 / @fastify/websocket (existing gateway).

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` (G6, §6.1 browser-engine, §6.2 browser WS channel, §9 capacity, §10 R2 layout, §11 secrets/SSRF, §14 P6 row, §15 fallback wording). **Binding research:** `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/research/p6-browser-tiers.md` (all measured numbers below cite it). **Behavioral reference (AG4):** `lib/core/agent_service.dart` `browser_*` cases + tool defs (~lines 8057–8790, 15554–17800) and `lib/core/session_browser_profiles.dart` (cookie-merge semantics ported in Task 3).

## Global Constraints

- Copied from the P1 plan (`docs/superpowers/plans/2026-10-15-ovid-cloud-p0-p1-spine.md`): wire format JSON **camelCase**; ids **UUIDv7**; timestamps ISO-8601 UTC; new code only under `cloud/`; deploy target `/opt/ovid-cloud`; never edit `/opt/ovid-gateway/docker-compose.yml` or the live Caddyfile without timestamped backup + validation; REST under `/cloud/v1/*`, WS at `/cloud/ws`; error envelope `{ "error": { "code", "message" } }` on REST and `{ op:"error", code, message, sessionId? }` on WS; commit after every task; `cd cloud && pnpm -r build && pnpm -r test` green before committing.
- `@ovid/shared` extensions are **ADDITIVE ONLY**: existing `ws.test.ts`, `events.test.ts`, `rest.test.ts` and the e2e `spine.test.ts` must pass unmodified. Existing ops (`subscribe/unsubscribe/ping`) keep exact semantics.
- Redis split (AG3): the browser bridge uses **redis-q PUB/SUB channels only** (`browser:{sessionId}:{frames|state|ctl|input}`) — pub/sub messages never enter the keyspace or count against `maxmemory`; no XADD/SET for frame data. Durable browser state goes to the `BrowserStateStore` (local disk now, R2 in P7), never Redis.
- Auth: browser WS ops ride the same single-use ticket handshake; every op enforces ownership via `sessions.get(db, sessionId, uid)` — wrong owner ⇒ `{op:"error",code:"forbidden",sessionId}` and the connection stays open (Task 8 pattern).
- Playwright pin: `playwright-core` **`"1.64.1"` exactly** (no caret) — Chromium 156.0.8078.4. The WebP screencast probe is keyed to this pin (research §3.2: WebP works on 156, collapses on 124); JPEG is the spec-of-record default, WebP only after a runtime magic-byte probe.
- Lightpanda pin: release **1.0.1** asset `lightpanda-x86_64-linux`, sha256 `551747e35c51ba107b5d5277eca4b48e077b2a3b40f09a047bf6670448bc35fd`, installed under `/opt/ovid-browsers/lightpanda-1.0.1/` by an **owner-gated activation script** (same gate style as P1 Task 11 Step 6). AGPL-3.0: run the **unmodified binary as a subprocess only** — never fork, re-link, or vendor its source (research §1.3).
- Screencast defaults (research §3.3/§7.2, binding): JPEG q60, `everyNthFrame=2` (≈3–4 fps on scroll-driven content), `maxFramesInFlight=2`, 1280×800. Spec §6.2's "binary WebP frames 3–5 fps" is implemented as *binary JPEG frames, WebP via probe* per the research amendment.
- Resource envelope on the **8 vCPU / 22 GB** box (ledger capacity shift; spec §9's 12c/30GB baseline revised): browser pool budget stays **2 GB** — measured/planned: chromium base ~78 MB + 4 live heavy contexts (research §5 measured 256 MB total on chromium 124; plan ≤ **600 MB** at 1.5–2× allowance for 156), + 2 tier-1 fallback contexts ≤ 200 MB, Lightpanda pool ≤ 8 procs ≈ 100 MB idle / ≤ 400 MB burst, linkedom fast path ≈ 0 incremental (in-worker). Planned peak ≈ 1.3 GB, hard ceiling 2 GB (compose `mem_limit: 4g` on worker = ~2 GB Node + 2 GB browsers). CPU ≤ 2 cores: `MAX_ACTIVE_SCREENCASTS=3`, frame ladder q60/nth2 → q50/nth3 → q40/nth4 → paused, loadavg step-down. Admission constants: `MAX_LIVE_BROWSERS=4` (spec §9, FIFO queue beyond), `MAX_TIER1_PROCESSES=8`, `BROWSER_IDLE_EVICT_MS=180000` (3-min, mirrors sandbox hibernation), `TIER1_TIMEOUT_MS=20000`.
- **No browser processes leak:** every test tears down contexts/pools in `afterAll`; `BrowserEngine.close()` (wired to worker SIGTERM) closes every chromium context, the chromium process, every Lightpanda process, and every dedicated redis connection; pending queue waiters are rejected, never hung.
- Tests needing real chromium are `describe.skipIf(!chromiumExecutableExists())`-guarded; tests needing Lightpanda are `skipIf(!lightpandaAvailable(bin))`-guarded. `node node_modules/playwright-core/cli.js install chromium --with-deps` (with `PLAYWRIGHT_BROWSERS_PATH`) is an **activation/dev-setup step, never CI-default**. No test ever reaches the public internet — local `http.createServer` fixtures on `127.0.0.1:0` only (allowed through the SSRF guard via `OVID_BROWSER_ALLOW_HOSTS=127.0.0.1,localhost` in tests).
- SSRF/egress: application-level guard (`navigableUrlReason` + `assertPublicHost`: block RFC1918, 127/8, 169.254/16, CGNAT 100.64/10, IPv6 ULA/link-local, IPv4-embedded IPv6, and the VPS's own public IP `OVID_PUBLIC_IP`; Dart `isAllowedBrowserUrl` parity) **plus** a documented nftables owner-match requirement for the worker uid in Task 16 (ruleset owned by P2; browser processes run as the worker user — decision documented in `BROWSERS.md`).
- Production boundary: P6 tasks never touch the live stack; deploy artifact changes are dry-validated (`bash -n`, `docker compose config -q`) and activation (Lightpanda install, compose up, nftables) is owner-gated.
- Node ≥ 22.15 required for `node:zlib` zstd (verified working on the box's v22.23.3); no new native npm deps for compression/encryption.

## Review Focus

1. **Cross-tenant state bleed** — user A's cookies/localStorage must never surface in user B's context: Lightpanda processes are kill-recycled after *every* lease (1-context-per-process model makes wiping unverifiable, research §1.3), chromium contexts are per-session, and `mergeStorageState` only ever replaces domains/origins the captured state actually touched. Pinned by Task 3 (merge-isolation tests incl. ported `CookieMerge` cases), Task 11 (recycle-after-lease test), Task 15 (per-user round-trip + boundary e2e leg).
2. **Process / connection leaks** — crashed navigations, worker SIGTERM, gateway socket drops must not leave chromium or Lightpanda processes, redis subscriber connections, or screencast CDP sessions behind. Pinned by Task 4 (`close()` ⇒ `stats()` zeros, waiters rejected), Task 8 (`close()` quits every dedicated connection), Task 11 (`close()` reaps all procs — test asserts `running()===0` and no child pids survive), Task 14 (SIGTERM-path test asserts engine stats zero).
3. **Slow or dead viewer client** — a client that stops reading must not grow server memory (gateway drops frames above a 4 MB `bufferedAmount` high-water) and a gateway crash without `viewer_leave` must stop the screencast (worker sweeps viewers stale > 90 s; gateway re-sends `viewer_join` every 30 s). Pinned by Task 9 (high-water drop test) and Task 8 (stale-viewer sweep ⇒ `onViewersChange(…, 0)`).
4. **Hostile URLs and input events** — `file:`/`javascript:` schemes, private-IP hosts, NaN/out-of-viewport coordinates, giant scroll deltas, workspace-escaping upload/download paths: every one returns a clean model-visible refusal string (never a throw, never a crash) and input coordinates are clamped to the viewport. Pinned by Task 1 (`navigableUrlReason`/`assertPublicHost` cases incl. Dart refusal-copy parity), Task 7 (clamp + `BrowserInputError`), Tasks 12/13 (refusal-copy and path-escape tests).
5. **storageState size outliers and tamper** — a 1 MB+ captured state (research §4.2 measured a 1,019,996-byte wikipedia case) is pruned under the 8 MB cap keeping small login cookies; a corrupt/tampered stored blob decodes to a loud `BrowserStateError` and the persistence service degrades to a fresh state (log, never crash-loop). Pinned by Task 3 (prune + envelope tamper tests).

---

### Task 1: `@ovid/browser` scaffold — package, engine config, SSRF/URL guard

**Files:**
- Create: `cloud/packages/browser/package.json`, `cloud/packages/browser/tsconfig.json`, `cloud/packages/browser/src/index.ts`
- Create: `cloud/packages/browser/src/config.ts`, `cloud/packages/browser/src/url.ts`
- Create: `cloud/packages/browser/src/test/testServer.ts` (shared fixture server used by every later gated test)
- Test: `cloud/packages/browser/src/{config.test.ts,url.test.ts}`
- Modify: `cloud/packages/browser/src/index.ts` (each later task appends its re-export line)

**Interfaces:**
- Consumes: Task-1 workspace layout from P1 (`tsconfig.base.json` conventions, `@ovid/<name>` package shape); `@ovid/shared` (nothing yet).
- Produces (every later task imports from `@ovid/browser`):

```ts
// config.ts
export interface ScreencastConfig { width: number; height: number; quality: number; everyNthFrame: number; maxFramesInFlight: number; }
export interface BrowserEngineConfig {
  maxLiveBrowsers: number;        // MAX_LIVE_BROWSERS, default 4
  tier1FallbackContexts: number;  // MAX_TIER1_FALLBACK_CONTEXTS, default 2
  idleEvictMs: number;            // BROWSER_IDLE_EVICT_MS, default 180_000
  maxTier1Processes: number;      // MAX_TIER1_PROCESSES, default 8
  tier1TimeoutMs: number;         // TIER1_TIMEOUT_MS, default 20_000
  maxActiveScreencasts: number;   // MAX_ACTIVE_SCREENCASTS, default 3
  screencastLoadMax: number;      // OVID_SCREENCAST_LOAD_MAX, default 6.0 (os.loadavg()[0] step-down threshold on 8c)
  screencast: ScreencastConfig;   // defaults {1280, 800, 60, 2, 2}
  stateDir: string | null;        // OVID_BROWSER_STATE_DIR (null ⇒ no persistence)
  lightpandaBin: string | null;   // OVID_LIGHTPANDA_BIN (null ⇒ tier-1 skips Lightpanda steps)
  allowHosts: string[];           // OVID_BROWSER_ALLOW_HOSTS, comma-split, default [] (tests: ["127.0.0.1","localhost"])
  ownPublicIp: string | null;     // OVID_PUBLIC_IP (SSRF self-block; P2 nftables uses the same value)
  chromiumArgs: string[];         // default ["--no-sandbox","--disable-dev-shm-usage","--disable-gpu"]
}
export function loadBrowserEngineConfig(raw: NodeJS.ProcessEnv): BrowserEngineConfig; // throws `${NAME} must be a positive integer`-style on malformed

// url.ts
export function navigableUrlReason(url: string, tool: string): string | null; // null = allowed; Dart unloadableUrlReason parity: only http/https (empty scheme allowed as relative); refusal copy names the tool + scheme
export class SsrfError extends Error {}
export async function assertPublicHost(url: string, cfg: Pick<BrowserEngineConfig, "allowHosts" | "ownPublicIp">, lookup?: (host: string) => Promise<string[]>): Promise<void>; // throws SsrfError; blocks RFC1918, 127/8, 169.254/16, 100.64/10, ::1, fc00::/7, fe80::/10, IPv4-embedded IPv6, ownPublicIp; allowHosts bypass (exact host match)
export function createSsrfGuardedFetch(cfg: Pick<BrowserEngineConfig, "allowHosts" | "ownPublicIp">, fetchImpl?: typeof fetch): typeof fetch; // assertPublicHost before each request

// test/testServer.ts
export const FIXTURES: { staticArticle: string; spaShell: string; clickButton: string; setCookie: string; animated: string; bigDom: string };
export interface TestPageServer { origin: string; url(path?: string): string; close(): Promise<void>; }
export function startTestPageServer(): Promise<TestPageServer>; // 127.0.0.1:0; routes: / (staticArticle), /spa (spaShell), /click (clickButton), /setcookie (Set-Cookie login_tok=abc123; Path=/ then staticArticle), /animated (animated), /big (bigDom), /attachment (Content-Disposition attachment body "file-bytes")
```

Fixture pins used by later tasks: `clickButton` = a `<button id="btn">` absolutely positioned at left:20px top:20px width:100px height:40px whose click sets `#out` textContent to `CLICKED`; `animated` = full-viewport div cycling `background-color` every 100 ms (screencast is damage-driven — a static page emits 0 frames, research §3.3); `spaShell` = empty `<div id="root">` + 12 `<script src>` tags + ~3.5 KB of nav text (the react.dev-shaped false-positive case from research §2).

- [ ] **Step 1: Write failing tests.** `config.test.ts`: defaults exactly as the Produces block (assert all 5 admission numbers + screencast {1280,800,60,2,2}); `MAX_LIVE_BROWSERS=6` overrides; `MAX_LIVE_BROWSERS=abc` and `BROWSER_IDLE_EVICT_MS=-1` throw naming the variable; `OVID_BROWSER_ALLOW_HOSTS=a.com, b.com` → `["a.com","b.com"]`; unset `OVID_LIGHTPANDA_BIN` → `lightpandaBin: null`. `url.test.ts`: `navigableUrlReason("file:///etc/passwd","browser_open")` returns a string containing `browser_open` and `file:`; `javascript:alert(1)` refused; `https://x.test` and `http://x.test` → null; with `allowHosts:["127.0.0.1"]`, `assertPublicHost("http://127.0.0.1:3000/x", cfg)` resolves, and with `allowHosts:[]` throws `SsrfError`; `http://169.254.169.254/latest/meta-data/` throws; `http://10.0.0.5/`, `http://192.168.1.1/`, `http://100.64.0.1/`, `http://[::1]/`, `http://[::ffff:10.0.0.1]/` throw; a host whose injected `lookup` returns `["172.16.0.9"]` throws (DNS-resolution check); `ownPublicIp:"203.0.113.7"` + `http://203.0.113.7/` throws; `createSsrfGuardedFetch` rejects a private-IP URL without calling the stub `fetchImpl` (assert 0 calls) and passes through `https://example.invalid` (stubbed fetch resolves).
- [ ] **Step 2: Run to verify fail.** `cd /root/OvidAI/cloud && pnpm install && pnpm --filter @ovid/browser test` — Expected: FAIL (modules missing). Deps to add in this step: `@ovid/shared workspace:*`, `playwright-core "1.64.1"` (exact), `ioredis ^5.11.1`, `zod ^3.25.76`, `linkedom ^0.18.0`, `@mozilla/readability ^0.6.0`, `turndown ^7.2.0`; dev: `@types/node ^22.20.5`, `@types/turndown`, `typescript ^5.6.0`, `vitest ^2.1.9`, `ws ^8.22.0`, `@types/ws`. Package scripts identical to `@ovid/worker` (`build: tsc -p tsconfig.json`, `test: vitest run --passWithNoTests`).
- [ ] **Step 3: Implement** `config.ts`, `url.ts`, `test/testServer.ts`. IP classifier: parse with `node:net` `isIP` + manual range checks (no new deps); `lookup` default `node:dns/promises`.resolve4+resolve6. `index.ts` re-exports `config.js` + `url.js` (later tasks append).
- [ ] **Step 4: Run to verify pass.** Same command — Expected: all PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): browser package scaffold, engine config, SSRF url guard"`

### Task 2: `@ovid/shared` — additive browser channel protocol

**Files:**
- Create: `cloud/packages/shared/src/browser.ts`
- Modify: `cloud/packages/shared/src/ws.ts` (extend both unions + schemas), `cloud/packages/shared/src/index.ts` (`export * from "./browser.js";`)
- Test: `cloud/packages/shared/src/browser.test.ts`; extend `cloud/packages/shared/src/ws.test.ts` with NEW cases only (existing cases untouched)

**Interfaces:**
- Consumes: nothing (zod only).
- Produces (gateway Task 9, worker bridge Task 8, tools Tasks 12/13, e2e Task 15 all import these exact names):

```ts
// browser.ts
export const BROWSER_FRAME_FORMAT = { jpeg: 1, webp: 2 } as const;      // 1-byte prefix on redis frames-channel publishes
export type BrowserFrameFormat = "jpeg" | "webp";
export interface BrowserStateDto {
  sessionId: string; live: boolean; url: string | null; title: string | null;
  takeover: boolean; screencast: boolean; frameFormat: BrowserFrameFormat;
  viewport: { width: number; height: number };
}
export type BrowserInputEvent =
  | { type: "tap"; x: number; y: number }
  | { type: "double_tap"; x: number; y: number }
  | { type: "long_press"; x: number; y: number; durationMs?: number }
  | { type: "scroll"; dx: number; dy: number; x?: number; y?: number }
  | { type: "swipe"; fromX: number; fromY: number; toX: number; toY: number; steps?: number }
  | { type: "key"; key: string; text?: string };
export type BrowserCtlMsg =
  | { type: "viewer_join"; viewerId: string }
  | { type: "viewer_leave"; viewerId: string }
  | { type: "takeover"; enabled: boolean };
export const browserStateDtoSchema: z.ZodType<BrowserStateDto>;
export const browserInputEventSchema: z.ZodType<BrowserInputEvent>;
export const browserCtlMsgSchema: z.ZodType<BrowserCtlMsg>;
export function browserFramesChannel(sessionId: string): string;  // `browser:${sessionId}:frames`
export function browserStateChannel(sessionId: string): string;   // `browser:${sessionId}:state`
export function browserCtlChannel(sessionId: string): string;     // `browser:${sessionId}:ctl`
export function browserInputChannel(sessionId: string): string;   // `browser:${sessionId}:input`

// ws.ts — ADDITIVE union members only:
// WsClientMsg += { op: "browser_attach"; sessionId: string }
//              | { op: "browser_detach"; sessionId: string }
//              | { op: "browser_input"; sessionId: string; input: BrowserInputEvent }
//              | { op: "browser_takeover"; sessionId: string; enabled: boolean }
// WsServerMsg += { op: "browser_state"; sessionId: string; state: BrowserStateDto }
```

Wire contract for BINARY frames (documented in `browser.ts` header comment): while a socket has an active `browser_attach`, the server sends screencast frames as raw **binary** WS messages (image bytes only — the redis 1-byte format prefix is stripped by the gateway); the image format is `state.frameFormat` from the latest `browser_state` op. One browser attach per socket: a second `browser_attach` replaces the first (old one gets `viewer_leave`). Client input coordinates are page CSS pixels in the `state.viewport` (client scales its canvas to match).

- [ ] **Step 1: Write failing tests.** `browser.test.ts`: each `BrowserInputEvent` variant round-trips `browserInputEventSchema`; `{type:"tap",x:"a"}` rejected; channel helpers return the exact strings above; `browserStateDtoSchema` rejects missing `frameFormat` and rejects `frameFormat:"png"`. New `ws.test.ts` cases: each new client op parses (`browser_input` with a full tap event); `{op:"browser_state",sessionId,state}` parses as server msg; **regression pin:** `{op:"subscribe",sessionId:"s"}` and `{op:"ping"}` still parse and `{op:"nope"}` still throws (existing behavior unchanged).
- [ ] **Step 2: Run to verify fail.** `cd /root/OvidAI/cloud && pnpm --filter @ovid/shared test` — Expected: FAIL (browser.ts missing).
- [ ] **Step 3: Implement** `browser.ts`; extend the two `z.discriminatedUnion` arrays in `ws.ts` (no edits to existing members); add the index re-export.
- [ ] **Step 4: Run to verify pass + additive gate.** `pnpm --filter @ovid/shared test` — Expected: all PASS, and `git diff` shows zero changes to pre-existing test cases. Then `pnpm --filter @ovid/gateway test && pnpm --filter @ovid/e2e test` (with `TEST_DATABASE_URL`/`TEST_REDIS_URL` from `bash scripts/dev-services.sh`) — Expected: existing suites still green.
- [ ] **Step 5: Commit.** `git add cloud/packages/shared && git commit -m "feat(cloud): shared browser channel protocol (ws ops, input events, state dto)"`

### Task 3: storageState — merge rules, prune, zstd + AES-256-GCM envelope, store adapter, persistence service

**Files:**
- Create: `cloud/packages/browser/src/{storageState.ts,stateStore.ts}`
- Test: `cloud/packages/browser/src/{storageState.test.ts,stateStore.test.ts}`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: nothing from earlier P6 tasks (pure module).
- Produces (Task 4 pool opts, Tasks 12/14 flush/restore):

```ts
// storageState.ts — Playwright storageState() JSON shape (subset pinned)
export interface StorageCookie { name: string; value: string; domain: string; path: string; expires: number; httpOnly: boolean; secure: boolean; sameSite: "Strict" | "Lax" | "None"; }
export interface StorageOrigin { origin: string; localStorage: { name: string; value: string }[]; }
export interface StorageState { cookies: StorageCookie[]; origins: StorageOrigin[]; }
export const storageStateSchema: z.ZodType<StorageState>;
export const MAX_RAW_STATE_BYTES = 8 * 1024 * 1024;
export function mergeStorageState(stored: StorageState | null, captured: StorageState): StorageState;
export function pruneStorageState(state: StorageState, maxBytes?: number): StorageState; // default MAX_RAW_STATE_BYTES
export interface BrowserStateEnvelope { v: 1; wrappedDek: string; iv: string; data: string; } // all base64
export class BrowserStateError extends Error {}
export function encodeBrowserState(state: StorageState, masterKey: string): string;   // JSON envelope
export function decodeBrowserState(blob: string, masterKey: string): StorageState;     // throws BrowserStateError

// stateStore.ts — key layout matches spec §10 R2 (`users/{uid}/browser/{profile_id}.zst`) so P7 swaps the impl only
export interface BrowserStateKey { userId: string; profileId: string; }
export const DEFAULT_PROFILE_ID = "main";
export function browserStateKeyPath(key: BrowserStateKey): string;
export interface BrowserStateStore {
  save(key: BrowserStateKey, blob: string): Promise<void>;
  load(key: BrowserStateKey): Promise<string | null>;
  delete(key: BrowserStateKey): Promise<void>;
}
export function createLocalDiskStateStore(rootDir: string): BrowserStateStore; // atomic tmp+rename; key parts must match /^[A-Za-z0-9_-]{1,64}$/ else throw (path-traversal guard)
export interface StorageStatePersistence {
  flush(userId: string, captured: StorageState): Promise<void>;  // load → merge → prune → encode → save, per-user in-process mutex
  restore(userId: string): Promise<StorageState | null>;          // null when absent; corrupt blob ⇒ BrowserStateError logged-and-swallowed → null (fresh start, Review Focus #5)
}
export function createStorageStatePersistence(store: BrowserStateStore, masterKey: string, opts?: { log?: (msg: string, err?: unknown) => void }): StorageStatePersistence;
```

Pinned algorithms:
- **Merge** (ports `CookieMerge.missingPairs` semantics from `lib/core/session_browser_profiles.dart:100` — a merge can add logins but never clobbers untouched ones): let D = distinct `cookie.domain` values in `captured.cookies`, O = distinct `captured.origins[].origin`. Result = stored entries whose domain ∉ D and origin ∉ O, plus ALL captured entries; output sorted by (domain,name,path) for cookies and by origin for origins (byte-stable, idempotent: `merge(merge(s,c),c)` deep-equals `merge(s,c)`).
- **Prune:** while `Buffer.byteLength(JSON.stringify(state))` > maxBytes: drop the origin with the largest localStorage total (whole entry), repeat; then drop cookies with `expires` in the past; then drop cookies with the longest values. If still over ⇒ return `{cookies:[],origins:[]}`.
- **Envelope (compress-then-encrypt, research §4.2):** KEK = `sha256(masterKey)`; DEK = 32 random bytes; `wrappedDek` = base64(AES-256-GCM(DEK, KEK, 12-byte iv_w) ‖ authTag); `data` = base64(AES-256-GCM(`zstdCompressSync(JSON.stringify(state), {params:{[ZSTD_c_compressionLevel]:9}})`, DEK, 12-byte random iv)); `iv` = base64(iv). Decode reverses and ends with `storageStateSchema.parse` — every failure path throws `BrowserStateError` with `{cause}`.
- **IndexedDB limitation (document in `storageState.ts` header):** capture is `context.storageState()` defaults = cookies + localStorage only; IndexedDB-backed logins (Firebase-style) do NOT survive eviction. The `indexedDB:true` opt-in exists in Playwright ≥1.51 (research §4.1) and is a deliberate P6 non-goal per the controller dispatch.

- [ ] **Step 1: Write failing tests.** `storageState.test.ts`: merge keeps stored cookie for `other.test` when captured only touched `site.test` (Review Focus #1); merge replaces same-domain cookies wholesale; merge idempotent + byte-stable (two encodes of the same merge are identical strings); ported Dart cases — `missingPairs`-equivalent: own cookie value wins over donor for same name *within its own domain*, donor-only names are added; prune: synthetic state with one 9 MB origin + one small origin holding `login_tok` cookie → `prune(state, 1_000_000)` result ≤ 1 MB, big origin gone, `login_tok` cookie AND small origin present (Review Focus #5); encode→decode round-trips deep-equal; flipping one base64 char inside `data` ⇒ `BrowserStateError` (not a crash, not silent garbage); wrong masterKey ⇒ `BrowserStateError`; hand-edited `v:2` ⇒ `BrowserStateError`. `stateStore.test.ts` (tmp rootDir via `fs.mkdtemp`): save→load round-trip; load missing → null; delete→load → null; `userId:"../evil"` throws; two concurrent `flush` calls with different captured domains both present in the final stored state (mutex + read-modify-write); corrupt stored blob → `restore` returns null and `log` was called.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test` — Expected: FAIL.
- [ ] **Step 3: Implement** both modules per the pinned algorithms (`node:zlib` zstd — guard at module load: `typeof zstdCompressSync !== "function"` ⇒ throw "node:zlib zstd requires Node >= 22.15").
- [ ] **Step 4: Run to verify pass.** Same command — Expected: all PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): storageState merge/prune, zstd+AES-256-GCM envelope, local-disk state store"`

### Task 4: `BrowserPool` — chromium lifecycle, admission, FIFO queue, per-session contexts, idle eviction, health

**Files:**
- Create: `cloud/packages/browser/src/pool.ts`
- Test: `cloud/packages/browser/src/pool.test.ts`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: `BrowserEngineConfig` (Task 1); `StorageState` (Task 3) for context seeding; `playwright-core`.
- Produces (Tasks 8/11/12/14 consume):

```ts
export type PoolClass = "live" | "tier1";
export interface LiveContextHandle { sessionId: string; context: BrowserContext; page: Page; createdAt: number; touch(): void; }
export interface Tier1Lease { context: BrowserContext; page: Page; release(): Promise<void>; }
export class BrowserPoolBusyError extends Error {}   // queue timeout; message: "The browser pool is full (4 live browser slots busy). The request was queued and timed out — try again shortly."
export interface BrowserPoolOptions {
  onIdleEvict?(sessionId: string, context: BrowserContext): Promise<void>; // called BEFORE context.close — engine flushes storageState here
  queueTimeoutMs?: number;                    // default 30_000
  launch?(): Promise<Browser>;                // test seam; default chromium.launch({ headless: true, args: cfg.chromiumArgs })
  now?(): number;
  sweepIntervalMs?: number;                   // default 30_000, unref'd
}
export interface BrowserPool {
  acquireLive(sessionId: string, opts?: { storageState?: StorageState | null }): Promise<LiveContextHandle>; // same sessionId ⇒ existing handle (touch); FIFO beyond cfg.maxLiveBrowsers
  acquireTier1(): Promise<Tier1Lease>;        // FIFO beyond cfg.tier1FallbackContexts; lease.release closes the context
  peekLive(sessionId: string): LiveContextHandle | null;
  releaseLive(sessionId: string): Promise<void>;  // closes + removes the context (caller flushes state BEFORE)
  evictIdle(): Promise<string[]>;             // handles untouched > cfg.idleEvictMs: onIdleEvict → close; returns evicted sessionIds
  liveCount(): number; tier1Count(): number; queueDepth(): number;
  stats(): { browserAlive: boolean; live: number; tier1: number; queued: number };
  close(): Promise<void>;                     // reject waiters (BrowserPoolBusyError), onIdleEvict NOT called, close all contexts, browser.close(), stop sweep timer
}
export function createBrowserPool(cfg: BrowserEngineConfig, opts?: BrowserPoolOptions): BrowserPool; // lazy: chromium launches on FIRST acquire
export function chromiumExecutableExists(): boolean; // playwright-core registry executablePath + existsSync — the skipIf gate for every chromium test
```

Context creation (both classes): `browser.newContext({ storageState: opts.storageState ?? undefined, viewport: { width: cfg.screencast.width, height: cfg.screencast.height }, ignoreHTTPSErrors: false, serviceWorkers: "block" })` (serviceWorkers blocked per research §4.1 mitigation for Tier-1 hygiene; live contexts too — SWs re-register on load, and blocking keeps eviction state clean). Health: `browser.on("disconnect")` ⇒ mark dead, reject all waiters with `BrowserPoolBusyError` ("browser process died — retry"), clear live/tier1 maps; the next acquire relaunches.

- [ ] **Step 1: Write failing tests** — ALL `describe.skipIf(!chromiumExecutableExists())`, `cfg` with `maxLiveBrowsers:2, tier1FallbackContexts:1, idleEvictMs:500, screencast:{width:400,height:300,...}`, `queueTimeoutMs:1000`, `sweepIntervalMs:100`, against `startTestPageServer()` (Task 1). Cases: acquireLive → page navigates to fixture `/` and `page.title()` matches; same-session re-acquire returns the SAME handle object; 3rd distinct session queues then resolves when one releases (FIFO order pinned: two waiters admitted in enqueue order); waiter exceeding `queueTimeoutMs` rejects with `BrowserPoolBusyError`; tier-1 lease beyond cap queues, `release()` frees a slot; **isolation pin (Review Focus #1):** set `document.cookie` via page A (session s1), acquire session s2 → its `document.cookie` for the same origin is empty; **storageState seeding:** `acquireLive(s3, {storageState})` with a `login_tok` cookie → `context.cookies()` contains it; **idle eviction:** with injected `now`, `evictIdle()` returns [s1], calls `onIdleEvict` before close, `peekLive(s1)===null`, `liveCount()` dropped; **close():** with 2 live + 1 queued → queued rejects, `stats()` = `{browserAlive:false,live:0,tier1:0,queued:0}` and `browser.process()` is null/exited (Review Focus #2); every test ends with `pool.close()` in `afterEach`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test pool` — Expected: FAIL.
- [ ] **Step 3: Implement** `pool.ts` per the pinned semantics (single chromium process shared by both classes — research §5: shared caches make one process + N contexts cheaper than N processes).
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS (skipped cleanly when chromium absent: run once with `PLAYWRIGHT_BROWSERS_PATH=/nonexistent` to prove the skip path exits 0).
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): chromium BrowserPool — admission, FIFO queue, idle eviction, health"`

### Task 5: `BrowserSessionRegistry` — tabs, console/network/dialog/popup buffers, takeover flag

**Files:**
- Create: `cloud/packages/browser/src/sessions.ts`
- Test: `cloud/packages/browser/src/sessions.test.ts`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: `LiveContextHandle` (Task 4); `playwright-core` types.
- Produces (Tasks 7/8/12/13/14 consume):

```ts
export const TAKEOVER_REFUSAL = "The user is currently controlling the browser live (takeover). Browser tools are paused — wait for the user to release control, then retry.";
export const CONSOLE_BUFFER_CAP = 200; export const NETWORK_BUFFER_CAP = 200; export const DIALOG_HOLD_MS = 10_000;
export interface ConsoleEntry { ts: number; type: string; text: string; location: string | null; }
export interface NetworkEntry { ts: number; url: string; method: string; status: number | null; failure: string | null; }
export interface DialogEntry { id: string; type: "alert" | "confirm" | "prompt" | "beforeunload"; message: string; defaultValue: string | null; resolve(action: "accept" | "dismiss", text?: string): void; heldAt: number; }
export interface PopupEntry { url: string; openedAt: number; }
export interface SessionBrowser {
  sessionId: string; userId: string; handle: LiveContextHandle;
  tabs: Page[]; activeIndex: number; takeover: boolean; lastActivityAt: number;
  console: ConsoleEntry[]; network: NetworkEntry[]; dialogs: DialogEntry[]; popups: PopupEntry[];
}
export interface BrowserSessionRegistry {
  open(entry: { sessionId: string; userId: string; handle: LiveContextHandle }): SessionBrowser; // instruments entry.handle.page
  get(sessionId: string): SessionBrowser | null;
  close(sessionId: string): SessionBrowser | null;      // removes entry only — the POOL owns context closing
  activePage(sessionId: string): Page | null;
  addTab(sessionId: string, page: Page): number;         // instruments, appends, switches active; returns new index
  closeTab(sessionId: string, index: number): boolean;   // closes page (not context), fixes activeIndex; refuses last tab (returns false)
  switchTab(sessionId: string, index: number): boolean;
  setTakeover(sessionId: string, enabled: boolean): boolean;   // false when session unknown
  refuseReasonIfTakeover(sessionId: string): string | null;    // TAKEOVER_REFUSAL when flagged, else null
  touch(sessionId: string): void;                              // lastActivityAt + handle.touch()
}
export function createBrowserSessionRegistry(opts?: { now?: () => number; onDialogTimeout?(d: DialogEntry): void }): BrowserSessionRegistry;
export function instrumentPage(session: SessionBrowser, page: Page): void;
```

`instrumentPage` pins: `page.on("console")` → console ring (cap 200, drop oldest); `page.on("response")`/`page.on("requestfailed")` → network ring (cap 200); `page.on("dialog")` → hold (do NOT auto-resolve) and push a `DialogEntry` whose `resolve` wraps `dialog.accept/dismiss`; held dialogs auto-dismiss after `DIALOG_HOLD_MS` via an unref'd timer (calls `onDialogTimeout`, removes entry); `page.on("popup")` → push `PopupEntry{url: popup.url()}` and CLOSE the popup page (server-side popups never render; `browser_popups open` re-opens in a tab). Buffers are per-SESSION (shared across its tabs), matching Dart's per-tab-strip model.

- [ ] **Step 1: Write failing tests** (chromium-gated, uses Task 4 pool at `maxLiveBrowsers:2`, fixture server): open() returns entry with `tabs.length===1, activeIndex===0`; console.log from page appears in `console` with type/text; buffer cap: 250 logs → `console.length===200` and the NEWEST entry is present, oldest gone; a navigation records a network entry with status 200; `addTab` → 2 tabs + active switched + new tab instrumented (its console also lands in the shared buffer); `closeTab(0)` → remaining tab active; `closeTab` of last tab returns false; `switchTab(5)` returns false; dialog: page triggers `confirm("q?")` → entry held (`dialogs.length===1`, page JS blocked), tool-side `resolve("accept")` → page proceeds, entry removed; dialog timeout: injected `now`/short hold via opts override is NOT exposed — instead pin `onDialogTimeout` fires with the real `DIALOG_HOLD_MS` using vitest fake timers (`vi.useFakeTimers()` + `advanceTimersByTime(10_000)`); popup: `window.open(url)` → `popups[0].url` recorded and popup page closed; takeover: `setTakeover(s,true)` → `refuseReasonIfTakeover(s)===TAKEOVER_REFUSAL` (exact string), `setTakeover(s,false)` → null, unknown session → null + `setTakeover` false. Plus a pure-unit leg (no chromium): registry bookkeeping with stubbed handle/page objects verifying close() doesn't call context.close (Review Focus pool-ownership boundary).
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test sessions` — Expected: FAIL.
- [ ] **Step 3: Implement** `sessions.ts`.
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): per-session browser registry — tabs, console/network/dialog buffers, takeover flag"`

### Task 6: `ScreencastService` — CDP screencast, WebP probe with JPEG fallback, ack flow control, screenshot

**Files:**
- Create: `cloud/packages/browser/src/screencast.ts`
- Test: `cloud/packages/browser/src/screencast.test.ts`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: `ScreencastConfig` (Task 1), `BrowserFrameFormat` (Task 2 shared), `playwright-core` (`context.newCDPSession(page)`).
- Produces (Tasks 8/12/14 consume):

```ts
export interface ScreencastFrame { format: BrowserFrameFormat; data: Buffer; }
export interface LadderStep { quality: number; everyNthFrame: number; }
export const SCREENCAST_LADDER: readonly LadderStep[];  // [{60,2},{50,3},{40,4}] — research §5 knob 2
export interface ScreencastHandle {
  format(): BrowserFrameFormat;
  framesSent(): number;
  adjust(step: LadderStep): Promise<void>;   // stop + restart screencast with new params (same format)
  stop(): Promise<void>;                     // Page.stopScreencast + detach CDP session; idempotent
}
export function frameMagicFormat(data: Buffer): BrowserFrameFormat | null; // RIFF....WEBP → "webp"; FFD8 → "jpeg"; 89504E47 → "png" (null otherwise)
export async function startScreencast(page: Page, cfg: ScreencastConfig, onFrame: (f: ScreencastFrame) => void, opts?: { format?: BrowserFrameFormat }): Promise<ScreencastHandle>;
export async function probeWebpSupport(page: Page, cfg: ScreencastConfig): Promise<boolean>; // start with format:"webp" on the ANIMATED fixture; first frame within 3 s with frameMagicFormat==="webp" ⇒ true; timeout or non-RIFF magic ⇒ false; ALWAYS stops the probe screencast
export async function captureScreenshot(page: Page, opts?: { type?: "jpeg" | "png"; quality?: number }): Promise<Buffer>; // default jpeg q70 (research §3.3: 99 KB/139 ms at 1280×800)
```

`startScreencast` pins: `cdp = await page.context().newCDPSession(page)`; `Page.startScreencast { format: opts.format ?? "jpeg", quality: cfg.quality, maxWidth: cfg.width, maxHeight: cfg.height, everyNthFrame: cfg.everyNthFrame, maxFramesInFlight: cfg.maxFramesInFlight }`; on `Page.screencastFrame` → `onFrame({format, data: Buffer.from(ev.data,"base64")})` then `cdp.send("Page.screencastFrameAck",{sessionId: ev.sessionId})` — ack AFTER handing off (this is the backpressure path; `maxFramesInFlight:2` bounds latency for slow clients, research §3.4); `stop()` also removes the listener and `cdp.detach()` (Review Focus #2: no dangling CDP sessions); default format **jpeg** — webp only via explicit `opts.format` after a successful probe (research §7.2: JPEG is the spec-of-record default).

- [ ] **Step 1: Write failing tests** (chromium-gated; fixture `/animated` — damage-driven, a static page yields 0 frames by design): `frameMagicFormat` unit cases (RIFF+WEBP buffer → "webp", FFD8 prefix → "jpeg", 89504E47 → "png", garbage → null); `startScreencast` with format "jpeg" on `/animated` collects ≥3 frames in ≤10 s, every frame `frameMagicFormat==="jpeg"`, `framesSent()` matches collected count; `stop()` ⇒ no further frames for 500 ms and a second `stop()` does not throw; `adjust({quality:40,everyNthFrame:4})` keeps delivering frames afterwards; `probeWebpSupport` returns a boolean and leaves no running screencast (assert a subsequent manual `Page.startScreencast` via fresh CDP session succeeds — proves cleanup); `captureScreenshot` returns FFD8-magic bytes > 1 KB. NOTE for implementers: whether the probe yields `true` here depends on the pinned build (expected true on 156 per research §3.2) — assert boolean-ness in CI, and assert `true` in a separate test annotated `it.skipIf(process.env.CI)` so a future chromium bump fails loudly on the dev box, not flakily in CI.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test screencast` — Expected: FAIL.
- [ ] **Step 3: Implement** `screencast.ts`.
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): CDP screencast — JPEG default, WebP probe, ack flow control, ladder"`

### Task 7: Input injection — client events → Playwright mouse/keyboard/touch

**Files:**
- Create: `cloud/packages/browser/src/input.ts`
- Test: `cloud/packages/browser/src/input.test.ts`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: `BrowserInputEvent` (Task 2 shared), `playwright-core` Page.
- Produces (Tasks 8/14 consume):

```ts
export class BrowserInputError extends Error {}  // malformed event; message: "Invalid browser input: <reason>"
export async function applyInputEvent(page: Page, event: BrowserInputEvent): Promise<void>;
```

Mapping (research §3.4: Playwright wrappers are the verified equivalent of raw `Input.dispatch*` and add actionability handling — no raw CDP): `tap` → `page.mouse.click(x,y)`; `double_tap` → `page.mouse.dblclick(x,y)`; `long_press` → `mouse.move` + `mouse.down` + sleep(`durationMs ?? 600`) + `mouse.up`; `scroll` → optional `mouse.move(x,y)` when x/y present, then `page.mouse.wheel(dx, dy)` with dx/dy clamped to ±10 000; `swipe` → `mouse.move(from)` + `down` + `steps ?? 8` interpolated `move`s + `up`; `key` → `text` present ? `page.keyboard.insertText(text)` : `page.keyboard.press(key)`. Coordinates: `Math.round`, clamped to `[0, viewport.width-1] × [0, viewport.height-1]` from `page.viewportSize()` (fallback 1280×800); non-finite numbers ⇒ `BrowserInputError`; unknown `key` strings pass through to Playwright (its error is caught and rewrapped as `BrowserInputError`).

- [ ] **Step 1: Write failing tests** (chromium-gated, fixture `/click`): `tap` at (70,40) (the pinned button center) ⇒ `#out` textContent `CLICKED`; `key` `{key:"k"}` after focusing an `<input>` (extend fixture with `<input id="in">`) types; `{key:"Enter"}` triggers the fixture's keydown-Enter handler setting `#out` to `KEY_ENTER`; `{text:"héllo"}` inserts unicode into the input; `scroll` `{dx:0,dy:300}` ⇒ `window.scrollY > 0` on a tall page (fixture `/big`); `swipe` across the button ⇒ click chain fires (button center to center + 5px); clamp: `tap` at (99999, -5) does not throw and lands inside the viewport (assert no crash + page still responsive); malformed: `{type:"tap",x:NaN,y:0}` and `{type:"nope"}` (cast) ⇒ `BrowserInputError` (Review Focus #4); `long_press` with `durationMs:120` on the button ⇒ elapsed ≥ 100 ms measured around the call and `CLICKED` set on release.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test input` — Expected: FAIL.
- [ ] **Step 3: Implement** `input.ts` (extend `FIXTURES.clickButton` in `test/testServer.ts` with the `#in` input + Enter handler if Task 1 didn't include them — additive fixture edits allowed).
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): browser input injection from client events"`

### Task 8: Worker-side Redis browser bridge — frames/state publish, ctl/input subscribe, viewer refcount

**Files:**
- Create: `cloud/packages/browser/src/bridge.ts`
- Test: `cloud/packages/browser/src/bridge.test.ts`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: channel helpers + `BrowserCtlMsg`/`BrowserInputEvent`/`BrowserStateDto`/`BROWSER_FRAME_FORMAT` (Task 2 shared), `ScreencastFrame` (Task 6), ioredis.
- Produces (Task 14 engine consumes; Task 9 gateway is the peer):

```ts
export interface BridgeHandlers {
  onViewersChange(sessionId: string, viewers: number): void;  // fired on every 0↔n or n↔m transition
  onInput(sessionId: string, event: BrowserInputEvent): void; // only zod-valid events
  onTakeover(sessionId: string, enabled: boolean): void;
}
export interface BrowserBridge {
  watch(sessionId: string): Promise<void>;     // ONE dedicated ioredis subscriber connection per session; subscribes ctl+input
  unwatch(sessionId: string): Promise<void>;   // unsubscribe + quit connection (awaited)
  publishFrame(sessionId: string, frame: ScreencastFrame): void; // PUBLISH Buffer.concat([prefix byte, data]) — fire-and-forget, errors logged not thrown
  publishState(sessionId: string, state: BrowserStateDto): void; // PUBLISH JSON
  viewerCount(sessionId: string): number;
  close(): Promise<void>;                      // unwatch all + quit the shared publisher connection (Review Focus #2)
}
export function createRedisBrowserBridge(opts: {
  redisFactory: () => IORedis;      // dedicated connections; publisher created lazily on first publish
  handlers: BridgeHandlers;
  viewerStaleMs?: number;           // default 90_000
  sweepIntervalMs?: number;         // default 30_000, unref'd
  now?: () => number;               // test seam
  log?(msg: string, err?: unknown): void;
}): BrowserBridge;
```

Viewer bookkeeping: per watched session a `Map<viewerId, lastSeenMs>`; `viewer_join` sets/refreshes (gateway re-sends every 30 s as a heartbeat), `viewer_leave` deletes; any size transition fires `onViewersChange`; the sweep drops viewers with `lastSeen < now - viewerStaleMs` (gateway crash without leave ⇒ screencast stops, Review Focus #3). Malformed ctl/input JSON or schema-invalid payloads: log + ignore, connection survives (Review Focus #4). `watch` twice for one session is idempotent (single connection).

- [ ] **Step 1: Write failing tests** (`describe.skipIf(!process.env.TEST_REDIS_URL)`; a test-side plain ioredis connection plays the gateway): watch → test publishes ctl `viewer_join {viewerId:"v1"}` → `onViewersChange(s,1)`; second join v2 → `(s,2)`; duplicate v1 join → NO event (size unchanged); leave v1 → `(s,1)`; stale sweep: injected `now` + `viewerStaleMs:1000, sweepIntervalMs:50` → after advancing, `(s,0)` fires without any leave; input: publish a valid tap → `onInput` with the exact event; publish `{type:"tap"}` (missing x/y) and `not-json` → no handler call, no crash, subsequent valid input still delivered; takeover ctl → `onTakeover(s,true)`; **frame round-trip:** test subscribes `browserFramesChannel(s)`, `publishFrame(s,{format:"webp",data:Buffer.from("RIFFxxxxWEBP")})` → received Buffer's byte 0 === `BROWSER_FRAME_FORMAT.webp` (2) and the remainder equals the payload; state round-trip parses via `browserStateDtoSchema`; `unwatch` → `viewer_leave` published afterwards produces no handler call and the subscriber connection is gone (assert via test-side `CLIENT LIST` count delta or the factory tracking created connections); `close()` quits every connection the factory created (factory-count assertion, Review Focus #2).
- [ ] **Step 2: Run to verify fail.** `TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm --filter @ovid/browser test bridge` — Expected: FAIL.
- [ ] **Step 3: Implement** `bridge.ts` (ioredis subscriber in pub/sub mode gets its own connection per the Task-4 events-package lesson; every connection tracked for `close()`).
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): redis browser bridge — frames/state pub, ctl/input sub, viewer refcount"`

### Task 9: Gateway `browser` WS channel — attach/detach/input/takeover, binary frame relay

**Files:**
- Create: `cloud/apps/gateway/src/browserChannel.ts`
- Modify: `cloud/apps/gateway/src/ws.ts` (`WsDeps.browser?`, four new switch cases, binary send path), `cloud/apps/gateway/src/app.ts` (`GatewayDeps.browser?`), `cloud/apps/gateway/src/main.ts` (wire `browser: { redisFactory: () => new Redis(cfg.redisQUrl) }`)
- Test: `cloud/apps/gateway/src/browserChannel.test.ts`

**Interfaces:**
- Consumes: Task 2 shared ops/channels; `TicketStore`, `sessions.get` ownership (existing); ioredis.
- Produces:

```ts
// browserChannel.ts
export interface BrowserChannelDeps { redisFactory: () => IORedis; }
export const BROWSER_VIEWER_HEARTBEAT_MS = 30_000;   // re-publish viewer_join while attached
export const BROWSER_FRAME_HIGH_WATER = 4 * 1024 * 1024; // socket.bufferedBytes above this ⇒ DROP frame
// ws.ts additions (shape pinned; implementer wires into handleWsConnection):
// WsDeps += browser?: BrowserChannelDeps
```

Behavior pins (all inside `handleWsConnection`, after ticket auth): `browser_attach` — if `deps.browser` undefined ⇒ `{op:"error",code:"unavailable",message:"Browser channel not configured."}`; ownership via `sessions.get` (uuid-guarded) ⇒ null → `{op:"error",code:"forbidden",sessionId}` (connection survives); an existing attach on this socket is replaced (old: `viewer_leave` + subscriber quit). On success: `viewerId = randomUUID()`; ONE dedicated subscriber connection subscribing state+frames channels; publish ctl `viewer_join`; forward state messages as `{op:"browser_state",sessionId,state}` (validated by `browserStateDtoSchema`, invalid → log+drop); forward frame messages as **binary** `socket.send(buf.subarray(1))` only when `readyState===OPEN && bufferedAmount <= BROWSER_FRAME_HIGH_WATER` (else drop — Review Focus #3); 30 s heartbeat interval re-publishes `viewer_join` (unref'd). `browser_input` — requires an active attach for that sessionId (else `{op:"error",code:"not_attached",sessionId}`); zod-validates `input` (invalid → `{op:"error",code:"bad_message"}`); PUBLISHes to the input channel. `browser_takeover` — same attach precondition; PUBLISHes ctl `{type:"takeover",enabled}`. `browser_detach` / socket `close` / replace — publish `viewer_leave`, unsubscribe, `quit()` the subscriber connection (awaited in teardown; registered in the same pre-await teardown bookkeeping pattern as the existing `teardownAll`).

- [ ] **Step 1: Write failing tests** (`skipIf(!TEST_REDIS_URL || !TEST_DATABASE_URL)`; harness = real `buildGateway` (test verifier, real ticket store, db ownership rows) + `ws` client on `listen(0)` + a test-side ioredis peer on the redis channels, mirroring `ws.test.ts`): attach to owned session → peer observes `viewer_join` on ctl, client receives nothing until the peer publishes; peer publishes a state JSON → client receives `{op:"browser_state"}`; peer publishes `[0x01, ...jpegbytes]` on frames → client receives a BINARY message equal to `jpegbytes` (prefix stripped); input op → peer receives the exact event JSON on the input channel; takeover op → peer receives ctl takeover; attach to someone else's session → `{op:"error",code:"forbidden"}` and the socket still serves a subsequent valid `subscribe` (regression: channel independence); attach with `deps.browser` undefined → `{op:"error",code:"unavailable"}` (build a second gateway without browser deps); input without attach → `not_attached`; malformed input payload → `bad_message`; re-attach replaces: peer sees leave(v1)+join(v2); **slow-client drop:** stub-send socket (or client that pauses reading + tiny high-water override via a test-only export) → frames beyond the water are dropped, connection stays open and a later small frame still arrives; **teardown:** client closes → peer observes `viewer_leave` and the gateway's subscriber count returns to baseline (track via `redisFactory` wrapper counting `quit()`s, Review Focus #2); heartbeat: with an injected short interval (export a test seam `BROWSER_VIEWER_HEARTBEAT_MS` override through `WsConnectionOptions.browserHeartbeatMs?`), a second `viewer_join` with the SAME viewerId arrives. Existing `ws.test.ts` + `spine.test.ts` remain untouched and green.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/gateway test` — Expected: FAIL (new suite).
- [ ] **Step 3: Implement** `browserChannel.ts` + the `ws.ts`/`app.ts`/`main.ts` wiring (additive switch cases; the browser attach state lives beside the existing `subs` map with the same closed/readyState guards).
- [ ] **Step 4: Run to verify pass + additive gate.** `pnpm --filter @ovid/gateway test` and `pnpm --filter @ovid/e2e test` — Expected: ALL green, zero edits to pre-existing test files except the new suite.
- [ ] **Step 5: Commit.** `git add cloud/apps/gateway cloud/packages && git commit -m "feat(cloud): gateway browser WS channel — attach/detach/input/takeover, binary frame relay"`

### Task 10: Tier-1 static fast path — linkedom + readability extraction

**Files:**
- Create: `cloud/packages/browser/src/staticExtract.ts`
- Test: `cloud/packages/browser/src/staticExtract.test.ts`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: `FIXTURES` (Task 1).
- Produces (Tasks 11/12 consume):

```ts
export interface ExtractedPage { title: string | null; byline: string | null; markdown: string; textLength: number; }
export function extractReadable(html: string, url: string): ExtractedPage | null; // linkedom parse + @mozilla/readability + Turndown; null when Readability finds no article
export const STATIC_MIN_CHARS = 600;
export const STATIC_MAX_SCRIPT_SRCS = 8;
export function isStaticEnough(html: string, extracted: ExtractedPage | null): boolean; // extracted !== null && textLength >= 600 && count of <script src> <= 8
```

- [ ] **Step 1: Write failing tests** (pure, no chromium): `extractReadable(FIXTURES.staticArticle, url)` → markdown contains the article heading (as `#`/`##`) and ≥600 chars of the prose, `title` non-null, `textLength >= 600`; `extractReadable(FIXTURES.spaShell, url)` → `isStaticEnough(...) === false` (the react.dev false-positive case from research §2 — 12 script-src tags); a server-rendered fixture with long text + 5 script-src tags → true; garbage HTML (`"<html>"`) → `extractReadable` returns null (no throw) and `isStaticEnough` false; markdown sanity: a fixture `<a href>` inside the article survives as `[text](href)` in markdown (links preserved, matching `fetch --dump markdown` behavior).
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test staticExtract` — Expected: FAIL.
- [ ] **Step 3: Implement** (`linkedom` `parseDOM`, `new Readability(dom.document).parse()`, `TurndownService` with default rules + keep-list for tables).
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): tier-1 static extraction fast path (linkedom + readability + turndown)"`

### Task 11: Tier-1 Lightpanda pool + `ResearchBrowser` decision tree + chromium fallback

**Files:**
- Create: `cloud/packages/browser/src/{lightpanda.ts,researchBrowser.ts}`
- Test: `cloud/packages/browser/src/{lightpanda.test.ts,researchBrowser.test.ts}`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: `extractReadable`/`isStaticEnough` (Task 10), `BrowserEngineConfig` (Task 1), `BrowserPool.acquireTier1` (Task 4), `playwright-core` `connectOverCDP`, `node:child_process`.
- Produces (Task 14 engine consumes):

```ts
// lightpanda.ts
export class LightpandaError extends Error {}
export const LIGHTPANDA_PORT_BASE = 9400;               // proc slot i → port base+i (127.0.0.1 bind only)
export function lightpandaAvailable(binPath: string | null): boolean; // binPath !== null && existsSync && X_OK
export interface LightpandaLease { slot: number; cdpUrl: string; pid: number; }
export interface LightpandaPool {
  acquire(timeoutMs: number): Promise<LightpandaLease>;  // FIFO beyond cfg.maxTier1Processes; spawns `bin serve --host 127.0.0.1 --port P`, waits for CDP readiness ≤5 s
  readPage(url: string, timeoutMs: number): Promise<{ html: string; title: string; finalUrl: string }>; // acquire → connectOverCDP → the process's SINGLE context/page → goto(domcontentloaded) → content() → disconnect → release
  oneShotMarkdown(url: string, timeoutMs: number): Promise<{ markdown: string; title: string | null; finalUrl: string }>; // `bin fetch --dump markdown <url>` subprocess; stdout cap 4 MB; non-zero exit/timeout ⇒ LightpandaError
  release(lease: LightpandaLease): Promise<void>;        // ALWAYS kill(proc)+reap (SIGKILL after 2 s grace) — cross-user hygiene by construction (Review Focus #1; research §1.3: 1 context/proc, no verifiable cookie wipe)
  running(): number;
  close(): Promise<void>;                                // kill all, reap all, reject waiters with LightpandaError
}
export function createLightpandaPool(binPath: string, cfg: BrowserEngineConfig, opts?: { spawnImpl?: typeof spawn; now?: () => number }): LightpandaPool;

// researchBrowser.ts
export type ResearchEngine = "static" | "lightpanda" | "lightpanda-fetch" | "chromium";
export interface ResearchResult { markdown: string; title: string | null; finalUrl: string; engine: ResearchEngine; ms: number; }
export class ResearchError extends Error { enginesTried: ResearchEngine[]; }
export interface ResearchBrowser {
  read(url: string, opts?: { timeoutMs?: number; prefer?: "fast" | "render" }): Promise<ResearchResult>;
  close(): Promise<void>;
}
export function createResearchBrowser(deps: {
  fetchImpl: typeof fetch;                       // SSRF-guarded (Task 1)
  lightpanda: LightpandaPool | null;             // null ⇒ both lightpanda steps skipped
  chromiumRead(url: string, timeoutMs: number): Promise<{ html: string; title: string | null; finalUrl: string }>; // engine wires this to pool.acquireTier1
  cfg: BrowserEngineConfig;
  extract?: typeof extractReadable;              // test seam
}): ResearchBrowser;
```

Decision tree (research §7.1, binding) — pinned exactly:
1. `prefer:"render"` → skip to step 5 (chromium).
2. `fetchImpl(url)` (timeout = `opts.timeoutMs ?? cfg.tier1TimeoutMs`): non-OK status, non-`text/html` content-type, or network error ⇒ skip to step 3 (remembering the failure); else `extractReadable(html, finalUrl)` and `isStaticEnough` ⇒ **return `{engine:"static"}`**.
3. `lightpanda.readPage(url, timeout)` → `extractReadable(html)` → non-null ⇒ **return `{engine:"lightpanda"}`** (post-JS DOM — SPA coverage). Failure/timeout ⇒ step 3b.
4. `lightpanda.oneShotMarkdown(url, timeout)` ⇒ **return `{engine:"lightpanda-fetch"}`**. Failure ⇒ step 5. (`lightpanda === null` skips 3+4.)
5. `chromiumRead(url, timeout)` → `extractReadable` ⇒ **return `{engine:"chromium"}`**. Failure ⇒ throw `ResearchError` with `enginesTried` in order.

- [ ] **Step 1: Write failing tests.** `researchBrowser.test.ts` (PURE — stub `fetchImpl`/`lightpanda`/`chromiumRead`/`extract`, injected counters): static HTML ⇒ engine "static" and lightpanda/chromium never called; SPA-shell HTML (isStaticEnough false via stubbed extract returning `textLength:3500` but `scriptSrcs>8` — stub `extract` + real `isStaticEnough` on the fixture) ⇒ "lightpanda"; lightpanda.readPage rejects ⇒ "lightpanda-fetch"; both lightpanda paths reject ⇒ "chromium"; ALL reject ⇒ `ResearchError` with `enginesTried === ["static-not-tried"...]` — pin exact array `["lightpanda","lightpanda-fetch","chromium"]` (static produced no result, it is not "tried-and-failed" — document semantics: enginesTried lists engines invoked); `prefer:"render"` ⇒ only chromiumRead called; `lightpanda:null` ⇒ SPA shell falls straight to "chromium"; per-step timeout: stub fetch that never resolves + `timeoutMs:50` ⇒ escalation happens within ~200 ms (AbortSignal wired). `lightpanda.test.ts` (`describe.skipIf(!lightpandaAvailable(process.env.OVID_LIGHTPANDA_BIN ?? null))`, local fixture server only): `acquire` spawns a proc (pid alive, `running()===1`), `release` kills it (`running()===0`, `process.kill(pid,0)` throws ESRCH after ≤3 s); two leases get different ports; `readPage(url)` on fixture `/` returns html containing the article marker and `finalUrl` === requested; **isolation pin (Review Focus #1):** lease A navigates to `/setcookie` (login_tok set in its proc), releases; lease B `readPage("/")` — the page's `document.cookie` (via a second readPage to a fixture echoing cookies, add `/echo-cookies` route in testServer) contains NO `login_tok`; pool at `maxTier1Processes:1` ⇒ second acquire waits until first release (FIFO); `close()` with a live lease ⇒ `running()===0` and no stray `lightpanda` pids (pgrep audit); `oneShotMarkdown` on fixture `/` returns markdown containing the article heading (skipIf same gate).
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test research` — Expected: FAIL.
- [ ] **Step 3: Implement** both modules (`node:child_process.spawn` with `stdio:["ignore","pipe","pipe"]`; CDP readiness = retry `connectOverCDP` every 100 ms ≤ 5 s; kill = SIGTERM → 2 s → SIGKILL; all procs tracked in a Set for `close()`; add the `/echo-cookies` fixture route to `test/testServer.ts`).
- [ ] **Step 4: Run to verify pass.** Same command (+ `OVID_LIGHTPANDA_BIN` set when the binary is present) — Expected: PASS (lightpanda suite skips cleanly without the binary).
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): tier-1 Lightpanda pool + ResearchBrowser decision tree + chromium fallback"`

### Task 12: Browser tools I — session ops, navigation, inspection, reading, screenshot, tabs (17 tools)

**Files:**
- Create: `cloud/packages/browser/src/sessionOps.ts`, `cloud/packages/browser/src/tools/{types.ts,definitions.ts,navigation.ts,inspection.ts}`
- Test: `cloud/packages/browser/src/tools/toolsNavigation.test.ts`
- Modify: `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: `BrowserPool`/`LiveContextHandle` (Task 4), `BrowserSessionRegistry`/`TAKEOVER_REFUSAL`/`instrumentPage` (Task 5), `StorageStatePersistence` (Task 3), `navigableUrlReason`/`assertPublicHost` (Task 1), `captureScreenshot` (Task 6), `extractReadable` (Task 10), shared schemas (Task 2).
- Produces (Task 13 extends the roster; Task 14 engine consumes):

```ts
// tools/types.ts
export interface BrowserToolContext { sessionId: string; userId: string; }
export interface BrowserArtifactRef { kind: "screenshot" | "download"; path: string; mimeType: string; bytes: number; } // path = WORKSPACE-RELATIVE (P2 jail root); P7 artifact pipeline seam — documented in types.ts header
export interface BrowserToolResult { content: string; artifacts?: BrowserArtifactRef[]; }
export interface BrowserToolDef {
  name: string;                       // "browser_open" …
  description: string;                // model-facing copy (Dart descriptions ported, panel references removed)
  parameters: Record<string, unknown>; // JSON Schema object handed to the model (Dart-parity shapes)
  inputSchema: z.ZodTypeAny;          // server-side validation
  execute(input: unknown, ctx: BrowserToolContext): Promise<BrowserToolResult>; // NEVER throws; failures are content strings
}
export interface BrowserToolsDeps {
  pool: BrowserPool; registry: BrowserSessionRegistry;
  persistence: StorageStatePersistence | null;   // null ⇒ no login restore/flush (dev mode)
  cfg: BrowserEngineConfig;
  workspaceDir(userId: string, sessionId: string): Promise<string>; // P2 seam; impl must mkdir -p; tests inject a tmpdir
  notifyState?(sessionId: string): void;          // engine → bridge.publishState hook (Task 14)
  now?(): number;
}
export const TOOL_ERROR_PREFIX = "error: ";       // every failure content starts with this
export const TEXT_OUTPUT_CAP = 5000;              // Dart spillToolOutput parity for open/navigate
export const READ_MARKDOWN_CAP = 8000;

// sessionOps.ts — the ONE open/close path shared by tools and the engine
export interface SessionOps { pool; registry; persistence; cfg; notifyState?(sessionId: string): void; } // structural subset of BrowserToolsDeps
export async function ensureSession(ops: SessionOps, ctx: BrowserToolContext): Promise<SessionBrowser>; // registry hit ⇒ touch+return; else persistence?.restore(userId) → pool.acquireLive(sessionId,{storageState}) → registry.open → notifyState
export async function releaseSession(ops: SessionOps, sessionId: string): Promise<void>; // registry.get → context.storageState() capture → persistence?.flush(userId, captured) → registry.close → pool.releaseLive → notifyState; idempotent (unknown session = no-op)
export async function withSession<T>(deps: BrowserToolsDeps, ctx: BrowserToolContext, fn: (s: SessionBrowser, page: Page) => Promise<T>): Promise<T>; // ensureSession + touch + refusal/URL-guard wrapper
export function guardUrl(url: string, toolName: string, cfg: BrowserEngineConfig): Promise<string | null>; // navigableUrlReason → assertPublicHost(SsrfError) → refusal copy or null
export function createBrowserTools(deps: BrowserToolsDeps): BrowserToolDef[]; // full roster (Task 12: 17 defs; Task 13 appends 19; final array sorted by name — prompt-cache-stable, spec §6.1)
export const BROWSER_TOOL_NAMES: readonly string[]; // grows with the roster
```

Task-12 roster (names, args, result shapes — descriptions port the Dart copy minus WebView/panel references):
- `browser_open` `{url}` / `browser_navigate` `{url}` (identical impl; Dart keeps both for model familiarity): guardUrl refusal OR `ensureSession` → `page.goto(url,{waitUntil:"domcontentloaded",timeout:30_000})` → content = `"{title}\n{finalUrl}\n\n{text}"` where text = `extractReadable(page.content())?.markdown ?? innerText`, truncated to `TEXT_OUTPUT_CAP` with `"\n…[truncated N chars]"`; empty text ⇒ exact Dart fallback copy `"Loaded {url} (no readable text extracted from the rendered page; try browser_read or browser_outline)."`; goto timeout/net error ⇒ `TOOL_ERROR_PREFIX + "navigation failed: {message}"`; pool busy (`BrowserPoolBusyError`) ⇒ its message verbatim (clean, model can back off). `notifyState` after success.
- `browser_back`/`browser_forward`/`browser_reload` `{}`: `page.goBack/goForward/reload({waitUntil:"domcontentloaded"})` → `"{title}\n{url}"`; no history ⇒ `TOOL_ERROR_PREFIX + "no history entry"`.
- `browser_read` `{}`: `extractReadable(page.content(), url)` → markdown capped `READ_MARKDOWN_CAP` (+truncation note); null extraction ⇒ innerText fallback capped; empty ⇒ `"The page has no readable text content."`.
- `browser_outline` `{}`: in-page evaluate collecting `h1–h6` (with level), `a[href]` (text+href, cap 100), `button`, `input/select/textarea` (id/name/type/placeholder) → indented text skeleton (Dart parity).
- `browser_snapshot` `{}`: `page.locator("body").ariaSnapshot()` capped 8000 chars — the a11y tree the model uses to pick targets.
- `browser_find` `{text}`: count + first-match ±80-char snippet from `document.body.innerText` (Dart parity).
- `browser_wait_for` `{text?,selector?,state?("visible"|"hidden"|"text"),timeoutMs?}`: Playwright `locator.waitFor`/`page.waitForFunction(text)`, default timeout 10 000, cap 30 000 → `"matched: {condition}"` or `"timeout"` (Dart parity — timeout is a RESULT, not an error).
- `browser_evaluate` `{expression}`: `page.evaluate(expr)` → `JSON.stringify(result)` capped 5000; evaluation error ⇒ `TOOL_ERROR_PREFIX + message`.
- `browser_screenshot` `{type?("jpeg"|"png"),quality?}`: `captureScreenshot(activePage)` → write `{wsRoot}/browser/screenshots/{ISO-ts}-{rand6}.{jpg|png}` → `{content:"screenshot saved: browser/screenshots/{name} ({kb} KB)", artifacts:[{kind:"screenshot",path:"browser/screenshots/{name}",mimeType,bytes}]}` — the P3 loop attaches artifacts to the model request; the P7 pipeline references them by workspace path (seam documented in `types.ts`).
- `browser_resize` `{width,height}`: clamp 320–3840 × 240–2160 → `page.setViewportSize` → `"viewport {w}x{h}"` (screencast maxWidth/Height stay at cfg values; document).
- `browser_new_tab` `{url}`: guardUrl → `context.newPage()` + goto → `registry.addTab` → notifyState → `"{title}\n{url} (tab {i} of {n})"`. `browser_switch_tab` `{index}` / `browser_close_tab` `{index}` → registry ops + notifyState; out-of-range ⇒ `TOOL_ERROR_PREFIX + "tab index {i} out of range (0..{n-1})"`. `browser_list_tabs` `{}` → one line per tab `"* {i}: {title} — {url}"` with the active marked.
- Every `execute`: `inputSchema.safeParse` fail ⇒ `TOOL_ERROR_PREFIX + "invalid arguments: {issues}"`; `registry.refuseReasonIfTakeover(sessionId)` non-null (for tools that DRIVE an existing session; `browser_open`/`navigate` included) ⇒ return `{content: TAKEOVER_REFUSAL}` FIRST; body wrapped in try/catch ⇒ `TOOL_ERROR_PREFIX + message` (never throws — the P3 loop stays healthy).

- [ ] **Step 1: Write failing tests** (chromium-gated; deps = real pool (`maxLiveBrowsers:2`) + registry + tmpdir workspace + fixture server + `cfg.allowHosts:["127.0.0.1","localhost"]`; recording `notifyState` stub): `browser_open` on `/` → content contains fixture title + url + ≥600 chars of article markdown, `notifyState` called once; open on `file:///etc/passwd` → content contains `"file:"` refusal, NO context created (`pool.liveCount()===0`); open on `http://169.254.169.254/` → SSRF refusal copy; open twice same session → one live context; `browser_read` after open → markdown capped (fixture `/big` ⇒ content length ≤ 8000 + truncation note); `browser_outline` on `/click` lists the button; `browser_snapshot` contains `button`; `browser_find {text:"CLICKED"}` before click → `"0 matches"`-shaped result, after `page.evaluate` click → count ≥1 + snippet; `browser_evaluate {expression:"1+1"}` → `"2"`; `browser_evaluate` syntax error → `TOOL_ERROR_PREFIX`; `browser_wait_for {text:"nope",timeoutMs:200}` → `"timeout"` (no throw); `browser_screenshot` → file exists under `{tmp}/browser/screenshots/`, FFD8 magic, artifact ref path is workspace-relative, `bytes` matches file size; `browser_new_tab` on `/click` → list_tabs shows 2 with active marker, switch_tab(0)/close_tab(1) round-trip, close_tab(9) → range error; **takeover refusal (Review Focus #4):** `registry.setTakeover(s,true)` → `browser_open` AND `browser_read` return EXACTLY `TAKEOVER_REFUSAL`; invalid args (`browser_find {}`) → `TOOL_ERROR_PREFIX + "invalid arguments"`; **sessionOps:** `releaseSession` with a persistence stub → `flush` called with a `StorageState` containing the fixture `login_tok` cookie (after visiting `/setcookie`), context closed (`pool.liveCount()` back to 0), `notifyState` called; `releaseSession` unknown session → no-op; `ensureSession` restores: persistence stub returning a stored state with `login_tok` → after `browser_open("/")`, `context.cookies()` includes `login_tok`; roster pin: `createBrowserTools(deps).map(t=>t.name)` equals the 17 sorted names and every def has non-empty `description` + `parameters.type==="object"`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test toolsNavigation` — Expected: FAIL.
- [ ] **Step 3: Implement** `sessionOps.ts` + `tools/*` (one `execute` wrapper factory DRYs the parse/takeover/try-catch preamble for all tools).
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): browser tools I — navigation, inspection, reading, screenshot, tabs"`

### Task 13: Browser tools II — interaction, forms, cookies, dialogs, transfers (19 tools)

**Files:**
- Create: `cloud/packages/browser/src/tools/{interaction.ts,transfers.ts}`
- Test: `cloud/packages/browser/src/tools/toolsInteraction.test.ts`
- Modify: `cloud/packages/browser/src/tools/definitions.ts` (roster += 19), `cloud/packages/browser/src/index.ts`

**Interfaces:**
- Consumes: everything Task 12 produces (`BrowserToolDef`, `withSession`, `guardUrl`, `TOOL_ERROR_PREFIX`, deps), `applyInputEvent`/`BrowserInputError` (Task 7) for tap/swipe family, registry dialog/popup/console/network buffers (Task 5).
- Produces: the completed 36-tool roster (`BROWSER_TOOL_NAMES` final), consumed by Task 14 (`engine.tools`) and P3's registry.

Roster + result shapes (Dart descriptions ported; all follow the Task-12 execute wrapper):
- `browser_click {selector}` → `page.click(selector,{timeout:10_000})` → `"clicked {selector}"`; not found ⇒ `TOOL_ERROR_PREFIX + "selector not found: {selector}"`. `browser_double_click {selector,count?(2|3)}` → `page.dblclick`/`tripleclick` → `"double-clicked {selector}"`. `browser_hover {selector}` → `page.hover`.
- `browser_tap_at {x,y}` / `browser_swipe {fromX,fromY,toX,toY,steps?}` / `browser_long_press {selector?,x?,y?,durationMs?}` — mapped through `applyInputEvent` (long_press resolves selector→bounding-box center when `selector` given); `BrowserInputError` ⇒ refusal copy.
- `browser_drag {from,to,steps?}` → `page.dragAndDrop(from,to)` → `"dragged {from} → {to}"`.
- `browser_type {selector,text,submit?}` → `page.fill(selector,text)` + focus/`input`/`change` are fill-native; `submit` ⇒ `page.press(selector,"Enter")` → `"typed {n} chars into {selector}"`. `browser_fill {fields}` → sequential fills → one result line per field. `browser_select {selector,value}` → `page.selectOption` → `"selected {value}"`. `browser_press_key {key}` → `page.keyboard.press(key)`.
- `browser_scroll {direction("up"|"down"|"top"|"bottom"),amount?(default 600),selector?}` → `page.mouse.wheel` (down/up) or `window.scrollTo` (top/bottom), element-scoped via `evaluate` when `selector` → `"scrolled {direction} {px}px"` + new `scrollY`.
- `browser_cookies {get?|set?|delete?|clear?}` (exactly one arg; Dart parity): get → `"{name}={value}"` or `"no cookie named {name}"`; set → parse `"name=value; path=/; domain=…"` → `context.addCookies` (url derived from active page origin) → `"cookie set"`; delete → `context.addCookies` with `expires:1` → `"cookie deleted"`; clear → `context.clearCookies()` → `"all cookies cleared"`.
- `browser_dialog {action("read"|"accept"|"dismiss"),text?}` → operates on `session.dialogs[0]` (held, Task 5): read → `"{type}: {message}"` or `"no pending dialog"`; accept/dismiss → `entry.resolve(action,text)` → `"dialog accepted/dismissed"`.
- `browser_console {action("read"|"clear")}` → buffered entries as `"{type} {text}"` lines (cap last 50 in output) / clears. `browser_network {action("list"|"clear")}` → `"{method} {status} {url}"` lines (last 50) / clears. `browser_popups {action("list"|"open"|"clear"),url?}` → list buffered; open → `context.newPage().goto(url)` + `registry.addTab` (guardUrl first); clear → empties.
- `browser_download {url,filename?}` (transfers.ts): guardUrl → `session.handle.context.request.get(url)` (shares the context cookie jar) → non-OK ⇒ error copy; bytes > `DOWNLOAD_MAX_BYTES = 50*1024*1024` ⇒ `"Download refused: file exceeds the 50 MB limit."`; filename default = URL basename or `download-{ts}`; sanitized (`basename`, reject `..`/absolute — escape ⇒ `"Download refused: invalid filename."`); written under `{wsRoot}/browser/downloads/{filename}` → `{content:"saved {n} bytes to browser/downloads/{filename}", artifacts:[{kind:"download",path,mimeType:content-type,bytes}]}`. ALSO wired here: `context.on("download")` (page-initiated) auto-saves to the same dir and appends a network-buffer entry (feasible-parity with Dart's download flow).
- `browser_upload {selector,path}` (transfers.ts): resolve `path` against `workspaceDir` → `path.resolve` must stay inside (`relative()` without leading `..`) else `"Upload refused: path escapes the session workspace."` (Review Focus #4); missing file ⇒ error copy; `page.setInputFiles(selector, absPath)` → `"uploaded {path} to {selector}"`.

- [ ] **Step 1: Write failing tests** (chromium-gated; fixture server; tmp workspace pre-seeded with `uploads/hello.txt`): click on `/click` `#btn` → `#out` becomes CLICKED and result `"clicked #btn"`; click missing selector → `TOOL_ERROR_PREFIX + "selector not found"` (no throw); type into `#in` + `submit:true` → fixture's submit handler ran (assert via `browser_find`); fill 2 fields → both values set; select on a fixture `<select>` (extend `/click` fixture) → value applied; press_key Enter → fixture handler; scroll down 300 on `/big` → scrollY ≥ 250; tap_at (70,40) → CLICKED (via applyInputEvent mapping); long_press 120 ms → elapsed ≥ 100; swipe → CLICKED; drag between two fixture drop-zones → drop event recorded; cookies: visit `/setcookie` → `{get:"login_tok"}` → `"login_tok=abc123"`; `{set:"x=1; path=/"}` → `{get:"x"}` → `"x=1"`; `{delete:"x"}` → get → not found; `{clear:true}` → login_tok gone; dialog: `/click` variant triggering `prompt("p?")` (extend fixture) → `{action:"read"}` shows `"prompt: p?"` → `{action:"accept",text:"yes"}` → page received "yes"; console: page logs → `{action:"read"}` contains the text, `{action:"clear"}` empties; network: after a navigation `{action:"list"}` contains a 200 line; popups: `window.open` → `{action:"list"}` shows it, `{action:"open",url}` adds a tab, `{action:"clear"}` empties; download: `{url:"{origin}/attachment"}` → file on disk with body `file-bytes`, artifact ref correct; download of `/big` with a stubbed 1-byte limit override (dep-injected `downloadMaxBytes` seam on BrowserToolsDeps, default 50 MB) → refusal copy; download filename `"../evil"` → refusal; upload `{selector:"#file",path:"uploads/hello.txt"}` → fixture echoes the file name; upload `path:"../../etc/passwd"` → escape refusal (Review Focus #4); **takeover:** with flag set, `browser_click` and `browser_cookies` return exactly `TAKEOVER_REFUSAL`; roster pin: final `BROWSER_TOOL_NAMES.length === 36`, sorted, no duplicates, and every name starts with `browser_`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test toolsInteraction` — Expected: FAIL.
- [ ] **Step 3: Implement** `interaction.ts` + `transfers.ts`; extend `definitions.ts` roster; add the `downloadMaxBytes?: number` dep seam.
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/browser && git commit -m "feat(cloud): browser tools II — interaction, forms, cookies, dialogs, transfers"`

### Task 14: `BrowserEngine` facade + worker wiring + graceful shutdown

**Files:**
- Create: `cloud/packages/browser/src/engine.ts`
- Create: `cloud/packages/browser/src/index.ts` final export surface (audit)
- Modify: `cloud/apps/worker/src/main.ts` (env + engine construction + SIGTERM), `cloud/apps/worker/package.json` (+`@ovid/browser workspace:*`)
- Test: `cloud/packages/browser/src/engine.test.ts`, `cloud/apps/worker/src/main.browser.test.ts`

**Interfaces:**
- Consumes: Tasks 1–13 (pool, registry, bridge, screencast, input, research, tools, sessionOps, persistence, config).
- Produces (Task 15 e2e; P3's loop later):

```ts
// engine.ts
export interface BrowserEngineDeps {
  cfg: BrowserEngineConfig;
  redisFactory: () => IORedis;                       // bridge connections
  persistence: StorageStatePersistence | null;       // null when cfg.stateDir null or no master key
  fetchImpl?: typeof fetch;                          // default createSsrfGuardedFetch(cfg)
  workspaceDir?(userId: string, sessionId: string): Promise<string>; // default: path.join(cfg-based root env OVID_WORKSPACES_ROOT ?? "/workspaces/users", userId, "sessions", sessionId) + mkdir -p
  now?(): number; log?(msg: string, err?: unknown): void;
}
export interface BrowserEngine {
  pool: BrowserPool; registry: BrowserSessionRegistry; research: ResearchBrowser; tools: BrowserToolDef[];
  openSession(sessionId: string, userId: string): Promise<SessionBrowser>;   // sessionOps.ensureSession + bridge.watch
  releaseSession(sessionId: string): Promise<void>;                          // sessionOps.releaseSession + bridge.unwatch + publishState {live:false} — P3 calls at run end
  publishState(sessionId: string): void;                                     // builds BrowserStateDto from registry + screencast status → bridge.publishState
  screencastCount(): number;
  close(): Promise<void>;   // releaseSession(all live, flushing state) → bridge.close → research.close → pool.close; idempotent
}
export function createBrowserEngine(deps: BrowserEngineDeps): Promise<BrowserEngine>;
```

Engine behavior pins: `notifyState` wired into tool deps = `publishState`. Bridge handlers: `onViewersChange(s, n>0)` → if no screencast for s and `screencastCount() < cfg.maxActiveScreencasts` → start on `registry.activePage(s)` with format = cached probe result (probe once per engine via `probeWebpSupport` on the first screencast start; failure ⇒ "jpeg" forever for this engine lifetime); `n > maxActiveScreencasts` overflow or `os.loadavg()[0] > cfg.screencastLoadMax` (10 s unref'd monitor) → `handle.adjust(SCREENCAST_LADDER[i])` step-down; viewers 0 → `stop()`. `onInput(s,e)` → `applyInputEvent(registry.activePage(s), e)` (errors logged, never thrown into redis). `onTakeover(s,enabled)` → `registry.setTakeover` + `publishState`. Tab switch/navigation → tools call `notifyState`; screencast follows the active tab (on `activeIndex` change the engine restarts the screencast on the new page — hooked by re-publishing state + a `screencastPage !== activePage` check in the 10 s monitor). Pool `onIdleEvict` → capture `context.storageState()` → `persistence?.flush` → `registry.close` → `bridge.unwatch` → `publishState {live:false}` (flush-before-close ordering is the 3-min hibernation mirror, research §5 knob 5). `close()` ordering pinned above (state flushed BEFORE processes die, Review Focus #2).

Worker `main.ts` additions: `loadWorkerEnv` gains `masterKey: string | null` (`OVID_MASTER_KEY`, required non-empty when `OVID_BROWSER_STATE_DIR` is set — refuse boot otherwise, same loud-failure mindset), `browserStateDir`, and passes `process.env` to `loadBrowserEngineConfig`; constructs `persistence = stateDir && masterKey ? createStorageStatePersistence(createLocalDiskStateStore(stateDir), masterKey) : null`; `const browser = await createBrowserEngine({cfg, redisFactory: () => new Redis(cfg-redisQUrl), persistence})`; `shutdown()` awaits `browser.close()` BEFORE `worker.close()`.

- [ ] **Step 1: Write failing tests.** `engine.test.ts` (chromium + TEST_REDIS_URL gated; a test-side redis peer simulates the gateway): `openSession` → peer sees state `{live:true}` after a viewer_join; viewer_join → within 10 s peer receives ≥1 binary frame on the animated fixture (screencast started; prefix byte matches `BROWSER_FRAME_FORMAT` of the published state's `frameFormat`); viewer_leave → frames stop (500 ms quiet) and `screencastCount()===0`; input event through the peer → `/click` fixture flips to CLICKED (end-to-end injection path); takeover ctl → `registry.get(s).takeover===true` AND a tool call (`tools` lookup `browser_read`.execute) returns exactly `TAKEOVER_REFUSAL`; state publish includes url/title after `browser_open` via `engine.tools`; idle eviction: injected `now` + `idleEvictMs:200` → sweep evicts → peer sees `{live:false}` and persistence stub `flush` received the `login_tok` cookie state; `close()` with one live session → `flush` called, `pool.stats().browserAlive===false`, `bridge` connections quit (factory count), second `close()` no-throw (idempotent). `main.browser.test.ts` (pure env tests, no chromium): `loadWorkerEnv` with `OVID_BROWSER_STATE_DIR` set and `OVID_MASTER_KEY` missing → throws naming `OVID_MASTER_KEY`; both set → parsed; neither set → `masterKey:null` and boot path unaffected (assert via exported pieces, not by running main).
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/browser test engine && pnpm --filter @ovid/worker test` — Expected: FAIL.
- [ ] **Step 3: Implement** `engine.ts` + worker wiring.
- [ ] **Step 4: Run to verify pass + full suite.** `cd cloud && pnpm -r build && pnpm -r test` (with dev-services env) — Expected: ALL green, no hung processes (vitest exits cleanly — leaked chromium/handles would hang it).
- [ ] **Step 5: Commit.** `git add cloud/packages/browser cloud/apps/worker && git commit -m "feat(cloud): browser engine facade, worker wiring, graceful shutdown"`

### Task 15: e2e — agent browses, viewer attaches mid-run, input takeover, storageState round-trip

**Files:**
- Create: `cloud/apps/e2e/src/browser.e2e.test.ts`
- Modify: `cloud/apps/e2e/package.json` (+`@ovid/browser workspace:*` dep)

**Interfaces:**
- Consumes: `buildGateway` + tickets (P1 Tasks 6–8) with `browser` deps (Task 9), `createBrowserEngine` (Task 14), `@ovid/db` repos, fixture server (Task 1), `ws` client.
- Produces: the browser regression harness P7/P8 extend.

- [ ] **Step 1: Write the e2e test** (`skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL || !chromiumExecutableExists())`; all components REAL in one process over dev Postgres/Redis, boundaries stubbed exactly like `spine.test.ts`: test verifier, `users.ensure` for two uids). Flow (one `it` per leg, shared beforeAll rig):
  **Leg a — agent run browses (simulated P3 loop):** `engine = await createBrowserEngine(...)` with tmp `stateDir` + test master key; `tools = engine.tools`; find `browser_open` → `execute({url: fixture "/"}, {sessionId, userId})` → content contains the fixture title; `browser_read` → ≥600 chars markdown; `run` events NOT involved (tool-level simulation — documented: the P3 loop integration test lands with P3; this leg pins the dispatch's "agent run uses browser_open+read against a local test HTTP server" at the executor seam).
  **Leg b — viewer attaches mid-"run" and receives frames:** before opening, navigate the session to `/animated` via `browser_open`; WS client: ticket → `subscribe` (sanity) → `browser_attach` → receives `{op:"browser_state", state:{live:true}}` then ≥2 BINARY frames within 15 s whose bytes match the state's `frameFormat` magic (Review Focus: frames flow to a mid-run attacher).
  **Leg c — input injection clicks the button:** `browser_open` `/click`; attach (or reuse); send `{op:"browser_input", sessionId, input:{type:"tap",x:70,y:40}}`; then `browser_find {text:"CLICKED"}` via the tool → count ≥1 (proves client JSON → gateway → redis → worker → Playwright → DOM).
  **Leg d — takeover:** send `{op:"browser_takeover",sessionId,enabled:true}` → next state frame has `takeover:true`; `browser_click` tool → exactly `TAKEOVER_REFUSAL`; `enabled:false` → tool works again.
  **Leg e — storageState login round-trips a context restart:** `browser_open` `/setcookie` → `engine.releaseSession(sessionId)` (flush) → `engine.openSession` again + `browser_cookies {get:"login_tok"}` → `"login_tok=abc123"`; AND the encrypted blob on disk under `{tmp}/users/{uid}/browser/main.zst` parses via `decodeBrowserState` with the test key (proves at-rest encryption, not just in-memory).
  **Leg f — boundaries:** second uid's WS client `browser_attach` to the first uid's session → `{op:"error",code:"forbidden"}`; that client receives ZERO binary frames for the whole test (tracked counter, Review Focus #1).
  Teardown: client sockets closed → peer-verified `viewer_leave`; `engine.close()`; assert `engine.pool.stats()` zeros and no test-spawned chromium pid alive.
- [ ] **Step 2: Run to verify fail, then make wiring fixes only** (unit suites must stay green — same rule as P1 Task 10): `TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/e2e test` — Expected: `spine.test.ts` PASS + `browser.e2e.test.ts` PASS.
- [ ] **Step 3: Full check.** `cd cloud && pnpm -r build && pnpm -r test` — Expected: all green twice in a row (flake check for the frame-timing legs).
- [ ] **Step 4: Commit.** `git add cloud/apps/e2e && git commit -m "test(cloud): browser e2e — agent browse, live viewer frames, input takeover, state round-trip"`

### Task 16: Deploy & activation artifacts — pinned installs, env, egress story, memory bench (owner-gated)

**Files:**
- Create: `cloud/deploy/install-lightpanda.sh`, `cloud/deploy/BROWSERS.md`, `cloud/scripts/browser-memory-bench.mjs`
- Modify: `cloud/deploy/.env.example`, `cloud/deploy/docker-compose.yml` (worker service only)
- Test: dry validation commands (no unit tests for shell/docs; the bench script is `node --check`-validated)

**Interfaces:**
- Consumes: built apps; pinned constants from Global Constraints.
- Produces: repeatable, checksum-verified browser runtime provisioning + the documented capacity/egress decisions.

- [ ] **Step 1: `install-lightpanda.sh`.** Constants: `VERSION=1.0.1`, `URL=https://github.com/lightpanda-io/browser/releases/download/1.0.1/lightpanda-x86_64-linux`, `SHA256=551747e35c51ba107b5d5277eca4b48e077b2a3b40f09a047bf6670448bc35fd`, `SIZE=75670856`, `DEST=/opt/ovid-browsers/lightpanda-1.0.1`. Idempotent: exit 0 early if `$DEST/lightpanda` exists AND sha256 matches. Otherwise download to `$DEST.tmp`, verify `printf '%s  %s\n' "$SHA256" file | sha256sum -c -` (abort + delete on mismatch), `install -m 0755` into place, smoke `"$DEST/lightpanda" version` (must exit 0 and print a version string). Refuses to run as a non-root user without write access to `/opt/ovid-browsers`.
- [ ] **Step 2: `.env.example` + compose.** `.env.example` additions (documented block "Browser engine (P6)"): `OVID_MASTER_KEY=CHANGE_ME` (generate `openssl rand -hex 32`; shared with P9 escrow per spec §11), `OVID_BROWSER_STATE_DIR=/opt/ovid-cloud/browser-states`, `OVID_LIGHTPANDA_BIN=/opt/ovid-browsers/lightpanda-1.0.1/lightpanda`, `PLAYWRIGHT_BROWSERS_PATH=/opt/ovid-browsers/ms-playwright`, `OVID_WORKSPACES_ROOT=/workspaces/users`, `OVID_PUBLIC_IP=CHANGE_ME` (the VPS's own public IP for SSRF self-block), commented defaults for `MAX_LIVE_BROWSERS=4`, `MAX_TIER1_PROCESSES=8`, `MAX_ACTIVE_SCREENCASTS=3`, `BROWSER_IDLE_EVICT_MS=180000`, `TIER1_TIMEOUT_MS=20000`, `OVID_BROWSER_ALLOW_HOSTS=` (MUST stay empty in production). Compose worker service: `mem_limit: 4g` (2 GB Node + 2 GB browser pool), environment passthrough of every var above, volumes `/opt/ovid-browsers:/opt/ovid-browsers:ro` and `ovid-browser-states:/opt/ovid-cloud/browser-states` (named volume; the local-disk store until P7/R2). Note in the compose comment: if P2 lands the host-systemd worker (spike Architecture A), the mounts become direct paths and only `mem_limit` moves to the systemd unit (`MemoryMax=4G`).
- [ ] **Step 3: `BROWSERS.md`.** Sections (exact content requirements): **(a) Pins** — playwright-core 1.64.1 ⇒ Chromium 156.0.8078.4; WebP screencast probe is keyed to this pin (research §3.2) — a playwright bump MUST re-run the probe test (`screencast.test.ts` dev-only assertion); Lightpanda 1.0.1 + sha256 + AGPL-3.0 subprocess-only rule. **(b) Install (activation, owner-gated)** — `bash cloud/deploy/install-lightpanda.sh`; `PLAYWRIGHT_BROWSERS_PATH=/opt/ovid-browsers/ms-playwright node cloud/node_modules/playwright-core/cli.js install chromium --with-deps`; verification: `OVID_LIGHTPANDA_BIN=… pnpm --filter @ovid/browser test` runs the gated suites green ON the box. **(c) Capacity (8 vCPU / 22 GB)** — the Global-Constraints budget table verbatim: pool 2 GB ceiling (planned peak ≈1.3 GB: chromium base 78 MB + 4 live contexts ≤600 MB + 2 tier-1 contexts ≤200 MB + Lightpanda ≤8 procs 100–400 MB), CPU ≤2 cores (`MAX_ACTIVE_SCREENCASTS=3` + ladder + `screencastLoadMax=6.0`), fixed services ~10 GB + browser 2 GB leaves ~10 GB cgroup headroom for P2's ~24 per-command jails (ledger capacity baseline; jails are ~2 MB resident each per the P2 spike — the 512 MB caps are ceilings, not reservations). **(d) SSRF/egress decision** — browser processes run **as the worker user** (chromium `--no-sandbox` because nested chromium-sandbox userns is unavailable to an unprivileged container/worker uid; the compensating controls are: app-level `assertPublicHost` on every navigation/fetch/download + the nftables requirement below). Requirement handed to P2 (who owns the ruleset): for the worker uid (`OVID_BROWSER_EGRESS_UID`, coordinate value with P2's uid plan), `nft add rule inet ovid_egress output meta skuid <uid> ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, <OVID_PUBLIC_IP> } counter drop` — placed AFTER an allow rule for the specific internal endpoints the worker itself needs (Postgres/Redis/mint/LiteLLM addresses, loopback always allowed). DNS-rebinding caveat documented: the app-level resolve-check is TOCTOU-prone; nftables is the backstop (spec §11). **(e) storageState** — per-user profile `main`, key layout `users/{uid}/browser/main.zst` (R2-compatible, P7 swaps `BrowserStateStore` impl only), envelope format (v1, wrappedDek/iv/data, zstd-9 → AES-256-GCM, KEK=sha256(OVID_MASTER_KEY)), limitations: **IndexedDB NOT captured** (Firebase-style logins won't survive eviction; `indexedDB:true` opt-in deferred), sessionStorage/service workers/HTTP cache not captured (research §4.1), 8 MB raw cap + prune order, corrupt blob ⇒ fresh start + loud log. **(f) Protocol card for the Flutter client (P8)** — the four client ops, `browser_state` fields, binary-frame contract (raw image bytes, format from state, one attach per socket, replace semantics), input coordinate space (page CSS px in `state.viewport`), takeover semantics (agent tools refuse while flagged; frames keep flowing so the user sees their own actions — research §3.4).
- [ ] **Step 4: `cloud/scripts/browser-memory-bench.mjs`** — imports `@ovid/browser` dist; launches a pool (`maxLiveBrowsers:4`), opens 4 contexts on the local fixture `/big` (synthetic heavy DOM — no internet), samples `browser.process().pid` tree RSS via `ps -o rss=,pid= --ppid` + the root pid every 2 s for 60 s while scrolling each page, prints the research-§5-shaped ladder table (0/1/2/3/4 pages) + peak total, exits non-zero if peak > 1200 MB (the planning ceiling from Global Constraints — a regression alarm, not a unit test). Manual/activation step: run it on the box, paste the output table into `BROWSERS.md` §(c) and the SDD ledger.
- [ ] **Step 5: Verify (dry, non-disruptive).** `bash -n cloud/deploy/install-lightpanda.sh` → OK; `node --check cloud/scripts/browser-memory-bench.mjs` → OK; `docker compose -f cloud/deploy/docker-compose.yml config -q` → OK; `grep -c OVID_MASTER_KEY cloud/deploy/.env.example` ≥ 1. **Do NOT run the installer, compose up, playwright install, or any nftables command — activation is owner-gated (P1 Task 11 Step 6 pattern).**
- [ ] **Step 6: Commit.** `git add cloud/deploy cloud/scripts && git commit -m "chore(cloud): browser deploy artifacts — pinned Lightpanda install, env, egress docs, memory bench"`

---

## Self-Review Notes (completed per writing-plans skill)

- **Spec coverage:** G6 two-tier engine → Tasks 10–11 (Tier-1) + 4–7 (Tier-2). §6.2 browser WS channel (binary frames 3–5 fps + JSON input + takeover flag) → Tasks 2/6/7/8/9 (JPEG q60/nth2 measured ≈3.25 fps on scroll-driven content per research §3.3 — the spec's "WebP" amended to "JPEG, WebP via probe" per the binding research recommendation). §6.1 storageState per user encrypted at rest → Task 3 (+ R2 key layout compatibility, P7 swap). §9 `MAX_LIVE_BROWSERS=4` + FIFO → Task 4; pool budget rechecked against the 8c/22GB envelope (Global Constraints numbers; Task 16 documents + benches). §10 `users/{uid}/browser/{profile_id}.zst` layout → Task 3 `browserStateKeyPath` (no Postgres `browser_states` row in P6 — the envelope is self-describing and the local-disk adapter is the index; P7 adds the row when R2 lands. Deliberate, documented.). §11 SSRF + AES-256-GCM envelope + master key → Tasks 1/3/16(d). §14 P6 "working software" line (agent browses; user watches/takes over) → Task 15 legs a–d. §15 Lightpanda-with-chromium-fallback → Task 11 decision tree. §16 builder's latitude (Lightpanda-vs-chromium final call) → exercised per research §7.1. Dart tool surface (`agent_service.dart` ~36 `browser_*` tools) → Tasks 12/13; `browser_desktop` deliberately NOT ported (on-device zoom concept; server viewport is fixed — `browser_resize` covers responsive testing; documented in `definitions.ts`). `session_browser_profiles.dart` semantics → Task 3 merge port (per-session isolation kept at runtime via contexts; Dart's per-session jars + share-on-restart collapse to per-user profile `main` + per-domain merge — spec §6.1 says per-USER storageState; deviation from Dart documented here and in `storageState.ts`).
- **Step scan:** every task has the failing-test → fail → implement → pass → commit cycle; bodies only where tests can't pin the algorithm (merge/prune/envelope in Task 3, decision tree in Task 11, engine ordering in Task 14); refusal copies and constants are exact strings/numbers.
- **Type consistency:** `BrowserEngineConfig` field names identical in Tasks 1/4/11/14; `ScreencastFrame`/`BrowserFrameFormat`/`BROWSER_FRAME_FORMAT` defined once (Tasks 2/6) and consumed by 8/9/14/15; `StorageState`/`StorageStatePersistence` defined Task 3, consumed 4/12/14; `SessionOps.ensureSession/releaseSession` defined Task 12, consumed by Task 14 engine (no duplicate open/close path); `BrowserToolDef` shape fixed in Task 12, roster extended in 13 (36 total, both tasks pin the count at their stage: 17 → 36); `LiveContextHandle` (Task 4) is the only context-ownership path — registry `close()` explicitly does NOT close contexts (Task 5 test pins this).
- **Review Focus:** all five lines carry named tests in their owning tasks (RF#1 → T3/T11/T15e; RF#2 → T4/T8/T11/T14; RF#3 → T8 sweep + T9 high-water; RF#4 → T1/T7/T12/T13 refusal + clamp tests; RF#5 → T3 prune/tamper tests).
- **Proportion:** ~730 lines for a 16-task, 3-new-subsystem phase (pool/tier-1/live-channel) + 36-tool port; code blocks are signatures, pinned constants and test-assertion lists, not implementations.
- **Known coordination risks (flagged for the controller, not solvable inside P6):** (1) P3's tool-registry `ToolDef` shape must accept `{name, description, parameters, inputSchema, execute(input,ctx)→{content,artifacts?}}` — P6 exports this; reconcile at P3 integration. (2) P2 owns `workspaceDir` provisioning and the nftables ruleset — P6 consumes an injected function and documents requirements (Task 16d). (3) P7 must implement `BrowserStateStore` against R2 with the same key layout. (4) redis-q carries ephemeral browser pub/sub (no keyspace writes) — AG3-compatible by construction; if the controller prefers isolation, a redis-c instance can be swapped via `redisFactory` only. (5) P1's compose runs the worker as a container while the P2 spike recommends host systemd — Task 16 documents both mount/limit variants; whichever P2 picks, the browser artifacts adapt by config only.
