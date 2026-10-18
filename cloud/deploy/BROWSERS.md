# BROWSERS.md — P6 browser engine: pins, provisioning, capacity, egress, state, protocol

Everything an owner needs to provision and reason about the server-side
browser engine (`cloud/packages/browser`) at ACTIVATION time. This is an
OWNER-GATED artifact: nothing here is executed by task agents or CI — the
installer, the playwright chromium install, the nftables rules, and the
memory bench run are all run by hand on the production host (same gate
style as DEPLOY.md §11 / P1 Task 11 step 6). The worker consumes the env
vars from `/opt/ovid-cloud/worker.env` (template: `worker.env.example`,
"Browser engine (P6)" block); the compose-worker variant would read them
from `.env` (template: `.env.example`, same block name).

## (a) Pins

| Component | Pin | Notes |
|---|---|---|
| playwright-core | **exactly `1.64.1`** (no caret) | ⇒ Chromium **156.0.8078.4** |
| Lightpanda | **1.0.1**, asset `lightpanda-x86_64-linux` | sha256 `551747e35c51ba107b5d5277eca4b48e077b2a3b40f09a047bf6670448bc35fd`, 75,670,856 B |

- **WebP screencast probe is keyed to the playwright pin** (research §3.2:
  WebP encoding works on Chromium 156 and collapses on 124). The probe
  itself is runtime (`screencast.ts`), but its dev-only assertion lives in
  `screencast.test.ts` — **a playwright bump MUST re-run that probe test on
  the new build before deploy.** Never bump playwright casually; the pin is
  `"1.64.1"` exactly in `cloud/packages/browser/package.json`.
- **AGPL-3.0 (Lightpanda):** the binary runs as an **unmodified subprocess
  only** — never fork it, re-link against it, or vendor its source into
  this repo (research §1.3). `install-lightpanda.sh` is the only supported
  provisioning path.
- **Provenance note (research §1) — read before trusting any measurement:**
  the research doc's behavioral measurements (one-context-per-process
  behavior, broken `storageState()`, missing `Page.startScreencast`, RSS
  figures) were taken on the **nightly 1.1.0** binary. **1.0.1 is the
  pinned release and behavior transfer is untested.** Step (b)'s on-box
  gated-suite run re-proves those behaviors on 1.0.1 **BEFORE activation**.
  If they diverge, **stop and escalate to the controller** — never silently
  re-pin, never fork the binary.

## (b) Install (activation, owner-gated)

Prerequisite (fresh checkout): `pnpm install` in `cloud/` must record the
**`@ovid/e2e` → `@ovid/browser` workspace importer** (the lockfile already
carries the dependency edge — P6 Task 15 landed it — but a fresh checkout's
install is what creates the actual `node_modules` link; the deploy build
does not resolve `@ovid/browser` from `@ovid/e2e` until then). No task
agent runs this install; the wave-merger owns it.

On the production host, as root:

```bash
# 1. Lightpanda 1.0.1 → /opt/ovid-browsers/lightpanda-1.0.1/lightpanda
#    (idempotent: re-run is a no-op when the sha matches; aborts + deletes
#    on any mismatch; smokes `lightpanda version` at the end.)
bash cloud/deploy/install-lightpanda.sh

# 2. Chromium 156.0.8078.4 into the shared browser root
PLAYWRIGHT_BROWSERS_PATH=/opt/ovid-browsers/ms-playwright \
  node cloud/node_modules/playwright-core/cli.js install chromium --with-deps

# 3. EGRESS FIRST (see §(d)): install/refresh the ruleset and check
#    OVID_SANDBOX_EXTRA_BLOCKED / the rendered config before starting the
#    engine — otherwise the browser uid runs without the filter.

# 4. Fill /opt/ovid-cloud/worker.env's "Browser engine (P6)" block
#    (OVID_MASTER_KEY, OVID_BROWSER_STATE_DIR, OVID_LIGHTPANDA_BIN,
#    PLAYWRIGHT_BROWSERS_PATH; see worker.env.example) and restart
#    ovid-worker.service so the fail-fast env checks run at boot.
```

**Verification (the 1.0.1 re-proof, BEFORE activation):**

```bash
OVID_LIGHTPANDA_BIN=/opt/ovid-browsers/lightpanda-1.0.1/lightpanda \
  PLAYWRIGHT_BROWSERS_PATH=/opt/ovid-browsers/ms-playwright \
  pnpm --filter @ovid/browser test
```

The real-binary gated suites (8 `OVID_LIGHTPANDA_BIN`-gated Lightpanda
tests + the real-chromium tests) must be **green ON the box** — this is the
step that re-proves the research behaviors on the pinned 1.0.1 release
(see §(a) provenance note). Any divergence: stop, escalate to the
controller, do not activate.

Also run the memory bench once and paste its ladder table into §(c):
`node cloud/scripts/browser-memory-bench.mjs` (details there).

**OPS carries (P6 ledger):**

- **The binary is host-provisioned.** The dev checkout on this box kept it
  at `/tmp/ovid-lightpanda-dl/lightpanda` because task agents cannot write
  `/opt` — that copy is dev scratch only. Production hosts MUST run
  `install-lightpanda.sh` and set `OVID_LIGHTPANDA_BIN` in `worker.env`;
  **absent/empty ⇒ tier-1 silently skips Lightpanda** (the pool is null and
  only the linkedom/chromium fallbacks run — handled, never a crash, which
  is exactly why the env var must be checked at activation).
- **Ports 9400–9407 are one-pool-per-host exclusive.** The Lightpanda pool
  binds its serve processes on that fixed range; a second worker/pool on
  the same host collides (`EADDRINUSE`). One ovid-worker per host, always.

## (c) Capacity (8 vCPU / 22 GB)

**Worker memory envelope (controller ruling R3):**

- Landed variant (host systemd): `MemoryMax=4G` on `ovid-worker.service`
  (the unit also sits inside P2's `ovid-sandboxes.slice`, `MemoryMax=10G`).
- Compose-worker variant (if ever restored): `mem_limit: 4g`.
- Both mean the same split: **~2 GB worker proper + 2 GB browser pool**.
  P2's sandbox slice keeps its own 10 G; the 22 GB box envelope from P2's
  Global Constraints is unchanged.

**Inside the pool's 2 GB share** (planned peak ≈ 1.3 GB vs the 2 GB hard
ceiling):

| Component | Budget |
|---|---|
| Chromium base process | ~78 MB |
| 4 live heavy contexts (tier-2, ≤150 MB each) | ≤600 MB |
| 2 tier-1 fallback contexts (≤100 MB each) | ≤200 MB |
| Lightpanda pool (≤8 procs) | 100–400 MB |
| linkedom fast path | ≈0 incremental (in-worker) |
| **Planned peak** | **≈1.3 GB / 2 GB ceiling** |

Research §5 measured ~256 MB for 4 shared-process contexts on Chromium 124;
the ≤600 MB line is a 1.5–2× allowance for 156. The alarm threshold
(1300 MB) and the regression bench live in
`cloud/scripts/browser-memory-bench.mjs`.

**CPU:** ≤2 cores — `MAX_ACTIVE_SCREENCASTS=3`, the frame ladder
(JPEG q60/everyNth 2 → q50/nth 3 → q40/nth 4 → paused) and
`OVID_SCREENCAST_LOAD_MAX=6.0` (host loadavg step-down).

**Whole-box fit:** fixed services + the 4 GB worker unit + P2's 10 GB
sandbox slice fit the 22 GB envelope per the ledger capacity baseline,
leaving headroom for P2's ~24 per-command jails (jails are ~2 MB resident
each per the P2 spike — the 512 MB per-env caps are ceilings, not
reservations).

**Bench output** (`node cloud/scripts/browser-memory-bench.mjs` — owner-run at
activation; gated on an installed chromium). Dev-box run captured at Task-16
time (2026-10-17, this VPS, pinned build 156.0.8078.4 from
`~/.cache/ms-playwright/chromium-1248`, 4 live contexts on the `/big`
synthetic fixture, all pages scrolled every 2 s):

```
context RSS ladder (1 shared chromium process, 4 live contexts on /big):
  0 pages open:     298 MB   (chromium base)
  1 page  open:     541 MB
  2 pages open:     782 MB
  3 pages open:    1023 MB
  4 pages open:    1264 MB

60 s scroll load: peak 1376 MB (30 samples, 9 procs in tree; alarm threshold 1300 MB, hard ceiling 2048 MB)
VERDICT: REGRESSION — peak exceeds the planned-peak alarm; investigate before activation
```

**Reading of the dev-box numbers (do not paper over at activation):** the
bench's PPID-tree sampling measures the **chromium tree ONLY** — the 1376 MB
peak excludes the Lightpanda pool (100–400 MB) and the tier-1 fallback
contexts (up to 2, ≤200 MB), both of which are additive in production. So
the real worst-case headroom against the 2048 MB hard pool ceiling is
**~272–572 MB**, not the 672 MB the bare 2048−1376 arithmetic suggests —
still under, but tighter. Like-for-like at the component level: the plan
sub-total for what the bench actually measures is ~678 MB (~78 MB base +
4×150 MB contexts), so the measured 1376 MB is a **~2× component-level
miss** — worse than the ~6% the aggregate 1376-vs-1300 comparison suggests.
Per-context
delta measured ~240 MB at this synthetic worst-case load (all 4 pages
scrolled concurrently) vs the ≤150 MB/≤600 MB plan, and the chromium base
measured 298 MB (5 procs: browser + gpu + network + utilities) vs the ~78
MB plan figure — the plan numbers came from research §5's lighter fixture
on Chromium 124. The alarm did its job: **the owner re-runs the bench at
activation and treats a peak > 1300 MB as an investigate-first gate** —
known levers are `MAX_LIVE_BROWSERS` 4→3 (drops the worst-case by roughly
one context) and/or a lighter fixture if the owner judges `/big`
unrepresentative. Never raise the alarm threshold to make a run pass.

**ACTIVATION RE-RUN (2026-10-18, production host, `PLAYWRIGHT_BROWSERS_PATH=
/opt/ovid-browsers/ms-playwright`, gate 14):**

```
context RSS ladder (1 shared chromium process, 4 live contexts on /big):
  0 pages open:     303 MB   (chromium base)
  1 page  open:     549 MB
  2 pages open:     793 MB
  3 pages open:    1037 MB
  4 pages open:    1275 MB

60 s scroll load: peak 1392 MB (30 samples, 9 procs in tree; alarm threshold 1300 MB, hard ceiling 2048 MB)
VERDICT: REGRESSION — peak exceeds the planned-peak alarm; investigate before activation
```

The production-host numbers are consistent with the dev-box capture
(base 303 vs 298 MB; peak 1392 vs 1376 MB; per-context delta ~243 vs
~240 MB) — the finding is REPRODUCIBLE, not a dev-box artifact. Status:
**investigate-first gate, unresolved.**

**MUSE EPHEMERAL STEP-LEASE + RESOURCE DIET (2026-10-18, founder directive).**
Implemented in `packages/browser`:

- **15 s idle freeze** (`BROWSER_IDLE_EVICT_MS`, default now 15 000): a live
  context exists only while a step runs or the user is in takeover. On freeze
  the engine captures `storageState`, flushes it through persistence, closes
  the context, and releases the pool slot. The session's last http(s) URL is
  remembered and re-navigated on the next step, so eviction is transparent.
- **Resource diet** (`OVID_BROWSER_BLOCK_HEAVY_RESOURCES`, default on):
  `context.route` aborts `media` and `font` requests plus a tracker-host list
  (doubleclick, googletagmanager, google-analytics, facebook, hotjar, …);
  documents, scripts, stylesheets, XHR/fetch and images stay.
- **Chromium flags**: `--js-flags=--max-old-space-size=96`,
  `--renderer-process-limit=2`, `--disable-extensions`,
  `--disable-background-networking`, `--disable-component-update`,
  `--disable-sync`, `--mute-audio`, `--no-first-run`. Verified on the live
  process (`ps` shows both flags).
- **Cap raised** to `MAX_LIVE_BROWSERS=24` in both the production worker env
  and staging.

**Honest measurement (same bench, after the diet):** 302/554/792/1028/1272 MB,
60 s peak **1391 MB** — unchanged from 1392 MB. The bench fixture is a
synthetic heavy DOM with no fonts, media or trackers, so the diet has nothing
to block there; the per-context floor is DOM/renderer-bound, not network-
bound. The diet's win shows on real pages, and the 15 s lease means a busy
100-user box holds only the contexts that are mid-step.

**Consequence for the 800-1000 target:** at ~240 MB per heavy context, a
6-8 GB browser share supports **24-32 simultaneous contexts**, not 60-100.
60+ requires ~60-100 MB/context, which the founder's own estimate assumes for
light pages — true for Lightpanda/HTTP work, not for a fully rendered
Chromium page. The 800-1000 user target therefore rests on the 80/20 mix
(background/Lightpanda vs live browser), not on 100 concurrent Chromium
contexts on this box. The same levers apply
(`MAX_LIVE_BROWSERS` 4→3 ≈ −1 context ≈ −240 MB at this load; the fixture
question is the owner's). Per the §(c) budget math the hard ceiling still
holds at 4 contexts (1392 + tier-1/lightpanda ≤ ~700 MB vs 2048 MB), but
the planned-peak alarm is intentionally stricter than the ceiling, so this
stays open as an owner decision rather than being closed here.

## (d) SSRF / egress decision

**Browser processes run as a dedicated uid, never as the worker uid.** The
worker runs as root (the systemd unit's `User=root`) because it needs
cgroup/setuid/nftables privileges; it drops every Chromium and Lightpanda
process to `OVID_BROWSER_EGRESS_UID` (recommended **230000**, outside the
sandbox jail block 200000–209999 production / 220000–229999 staging). The
nftables rules key on exactly that uid, so the filter matches real browser
traffic.

How the drop is applied (`cloud/packages/browser/src/uidDrop.ts`):

- **Lightpanda** — `child_process.spawn(..., { uid, gid, env })` for both
  `serve` and one-shot `fetch`.
- **Chromium** — Playwright 1.64.1 has **no uid/gid launch option**: its
  `LaunchOptions` exposes none, and its internal `launchProcess` spawns the
  browser with only `{ detached, env, cwd, shell, stdio }`. The engine
  therefore writes a root-owned 0755 shim at boot and passes it as
  Playwright's `executablePath`. The shim chowns Playwright's root-created
  `--user-data-dir` to the browser uid, then `exec`s
  `setpriv --reuid=<uid> --regid=<uid> --clear-groups <chromium>`. Every
  Chromium child (zygote, renderers, crashpad) inherits the uid.
- The engine creates a per-engine runtime tree (`HOME`, `TMPDIR`, `XDG_*`,
  downloads), chowns it to the uid, and passes it in the browser
  environment. The shim itself stays root-owned 0755, so the browser uid
  can traverse but not rewrite the launch mechanism.

**Configuration and fail-closed rules** (`packages/browser/src/config.ts`,
`uidDrop.ts`):

- `OVID_BROWSER_EGRESS_UID` accepts a single uid (`230000`) or a range
  (`230000-230099`); the engine uses the **first** uid and the renderer keys
  the whole range. It must be `>= 100000` and must **not** overlap the
  sandbox block (`OVID_SANDBOX_UID_BASE` / `OVID_SANDBOX_UID_MAX`).
- `OVID_BROWSER_UID_DROP` is `auto` (default), `required`, or `disabled`.
  `disabled` is a dev/test escape hatch and is **refused when
  `NODE_ENV=production`**. In production a dedicated uid is **required**:
  the worker refuses to boot rather than silently run browsers as root.
- Boot fails loudly (there is no root fallback) when the worker is not
  root, the uid is below 100000, the uid overlaps the sandbox block,
  `setpriv` is missing, Chromium is missing/non-executable, or the uid-drop
  probe (`/bin/true` spawned as the uid + `chromium --version` through the
  shim) fails.
- The Chromium install root must be traversable and the binary executable
  by the browser uid — production installs under `/opt/ovid-browsers`, never
  under `/root`. Workspace files passed to `browser_upload` must likewise be
  readable by the browser uid (normal workspace modes 0644/0755 are fine;
  do not create agent files 0600 if uploads must reach the browser).

Chromium launches with `--no-sandbox` because the nested chromium-sandbox
userns is unavailable to an unprivileged container/worker uid (the pinned
`chromiumArgs`: `--no-sandbox --disable-dev-shm-usage --disable-gpu`). The
compensating controls are:

1. **App-level guard on every navigation/fetch/download** —
   `assertPublicHost` / `navigableUrlReason` (`cloud/packages/browser/src/url.ts`)
   blocks RFC1918, 127/8, 169.254/16, CGNAT 100.64/10, IPv6 ULA/link-local,
   IPv4-embedded IPv6, and the VPS's own public IP (`OVID_PUBLIC_IP`) —
   Dart `isAllowedBrowserUrl` parity.
2. **The nftables requirement below** (ruleset owned by P2 —
   `deploy/net/install-nft.sh`; rendered by
   `cloud/packages/sandbox/src/renderNftCli.ts`).

**Requirement for P2's ruleset:** set `OVID_BROWSER_EGRESS_UID` to the same
dedicated uid the engine applies (a range is fine — the engine uses its
first uid), then render/install with `deploy/net/install-nft.sh`. The
renderer emits, keyed on that uid/range, drop rules mirroring the app
guard's FULL block list:

```bash
# v4
nft add rule inet ovid_sandbox output meta skuid <uid> ip daddr \
  { 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, <OVID_PUBLIC_IP> } counter drop
# v6
nft add rule inet ovid_sandbox output meta skuid <uid> ip6 daddr \
  { ::1, fe80::/10, fc00::/7, fec0::/10, ff00::/8, 2002::/16, 64:ff9b::/96 } counter drop
```

These rules are now effective: the browser processes actually run as
`<uid>`. Before this fix they were inert (the worker uid was 0 and the
renderer refuses anything below 100000).

**Parity with `assertPublicHost`:** the v4 set matches the app guard's
RFC1918 + CGNAT + link-local ranges, and the v6 set matches it range for
range (loopback, link-local, ULA, site-local, multicast, 6to4, NAT64). Both
are defaults in `cloud/packages/sandbox/src/net.ts` (`DEFAULT_BLOCKED_V4` /
`DEFAULT_BLOCKED_V6`) — no `OVID_SANDBOX_EXTRA_BLOCKED` entry is needed for
them; keep those defaults at least as wide as the app guard. **The loopback
rule is intentionally NOT parity** — see below.

**Loopback (deliberately broader than the sandbox uid's treatment):** the
browser uid is allowed the **WHOLE of `127.0.0.0/8` and `::1`**, not
address+port. Chromium's own DevTools listener binds an ephemeral loopback
port and the engine calls LiteLLM on `:4000`; a narrow port allow would
break the browser, so the renderer hardcodes the whole range and rejects
loopback entries in `OVID_BROWSER_EGRESS_ALLOW`. The sandbox uid, by
contrast, has loopback dropped. **Residual risk:** the browser process can
open loopback connections to any host service; it holds no DB/mint
credentials, but that surface is reachable. **Owner-gate follow-up:** a
netns per browser context, or a dedicated loopback port allowlist once the
DevTools port can be pinned.

**Both drop rules are placed AFTER the browser section's accept rules**
for the internal endpoints the worker itself needs (`browserAllowedV4`,
address-scoped — the renderer does not match on port) and after the
hardcoded `127.0.0.0/8` + `::1` loopback accepts.

**DNS-rebinding caveat (spec §11):** the app-level resolve-check is
TOCTOU-prone — a public name can resolve to a private address after the
check passes. nftables is the backstop, which is why the rules above are a
hard activation requirement, not optional hardening.

`OVID_BROWSER_ALLOW_HOSTS` **must stay empty in production** — it exists so
tests can hit `127.0.0.1` fixtures.

## (e) storageState

- **Scope:** per-user profile `main` (spec §6.1: per-USER state; Dart's
  per-session jars + share-on-restart collapse to per-user + per-domain
  merge — deviation documented in `storageState.ts`).
- **Key layout (R2):** `users/{uid}/browser/main.zst`. **P7 OWNS the
  `browser_states` table and the landed `BrowserStateBlobStore`**
  (controller ruling R2) — P6 never creates the table, and P6's local-disk
  adapter implements the same interface so the eventual swap to P7's
  `createBrowserStateBlobStore(storage)` is impl-only.
- **Envelope format (binary v1, raw bytes — NO base64/JSON wrapper):**
  `OVIDBS01` magic ‖ version ‖ `iv_w` ‖ wrappedDek ‖ `iv` ‖
  AES-256-GCM(zstd-9-compressed data, DEK). KEK = sha256(`OVID_MASTER_KEY`).
  The blob is **opaque to the store** — only the envelope codec understands
  it.
- **Limitations (research §4.1):**
  - **IndexedDB is NOT captured.** Firebase-style logins will not survive
    eviction; the `indexedDB:true` opt-in is deferred.
  - sessionStorage, service workers, and the HTTP cache are not captured.
  - 8 MB raw cap; prune order applies when over cap (session cookies with
    `expires: -1` are never pruned).
  - A corrupt/tampered blob ⇒ fresh start + loud log (never a crash).

## (f) Protocol card — Flutter client (P8)

All ops ride the existing multiplexed WS (`/cloud/ws`) after the single-use
ticket handshake; every op enforces session ownership
(`sessions.get(db, sessionId, uid)` — wrong owner ⇒
`{op:"error",code:"forbidden",sessionId}` and the connection stays open).

**The four client ops:**

| op | payload | effect |
|---|---|---|
| `browser_attach` | `{op, sessionId}` | start receiving `browser_state` + binary frames for this session (no ack op — the worker's next state publish is the confirmation) |
| `browser_detach` | `{op, sessionId}` | stop receiving (peer-verified leave) |
| `browser_input` | `{op, sessionId, input: BrowserInputEvent}` | inject tap / double_tap / long_press / scroll / key / text into the live page |
| `browser_takeover` | `{op, sessionId, enabled: boolean}` | flag the session takeover on/off |

**`browser_state` fields** (`{op:"browser_state", sessionId, state}`):
`live`, `url`, `title` (nullable), `takeover`, `screencast`,
`frameFormat` (`"jpeg" | "webp"`), `viewport {width, height}`.

**Binary-frame contract:** frames are raw image bytes on the socket —
decode by the magic byte, NOT by a fixed format (the format comes from
`state.frameFormat`; WebP only when the runtime probe passed on the
installed chromium). One attach per socket; a second attach replaces the
first session's feed.

**Input coordinate space:** page CSS pixels within `state.viewport` (the
fixed 1280×800 cast viewport — no device-pixel-ratio math client-side).

**Client contract — no input before the screencast is live (T14-I2,
binding on P8):** the client **MUST NOT** send any `browser_input` until it
has received a `browser_state` frame with `screencast: true`. For ~3 s
after attach the engine is still running the WebP probe against an internal
`data:` fixture; input sent during that window is applied to the fixture
and **silently lost** — neither the gateway nor the engine gates it. Queue
input locally and flush it once the first `screencast: true` state arrives.

**Takeover semantics:** while `takeover:true`, the agent's `browser_*`
interaction tools refuse (`TAKEOVER_REFUSAL`), but **frames keep flowing**
so the user sees their own actions land (research §3.4). `enabled:false`
hands control back and the tools work again.

**Known quirk, flagged for intent (ledger M4):** the screencast ladder's
"viewer overflow" compares one session's viewer count against the
engine-wide `MAX_ACTIVE_SCREENCASTS` cap, and the overflow branch returns
before any start — a session whose *first* join already exceeds the cap
never gets a cast at all. Spec-literal as pinned; the controller owns the
intent call. Do not "fix" client-side.

## (g) Operational notes

- **Shutdown order (ledger M5, pinned):** on SIGTERM the worker closes the
  browser engine **before** the worker's own queue drain —
  `BrowserEngine.close()` releases every live session **flushing
  storageState BEFORE each context dies** (flush-before-drain), closes all
  contexts, the chromium process, every Lightpanda process, and the
  dedicated redis connections; only then does the worker tear itself down.
  Never reorder — draining first would drop un-flushed login state.
- **Browser temp-dir quota (T13 residual, accepted):** a page-initiated
  multi-GB download reaches the browser's temp file before the 50 MB cap
  enforcement deletes it — worker memory is never involved, the file never
  reaches the workspace, but worst-case the DISK briefly sees the full
  transfer. Recommended at activation: give the worker unit's temp space a
  hard bound (e.g. `PrivateTmp=yes` + `Tmpfs=/tmp:size=2G` on
  `ovid-worker.service`, or an XFS project quota on the browser state/tmp
  area) so a hostile page cannot pressure the root filesystem. True
  mid-transfer abort is not available in Playwright (it would break
  POST-generated downloads); the quota is the compensating control.
- **Eviction:** live contexts idle > `BROWSER_IDLE_EVICT_MS` (3 min,
  mirroring sandbox hibernation) are flushed (storageState persisted) and
  closed by the pool's sweep.
- **No internet in tests, ever:** all browser tests use loopback
  `http.createServer` fixtures; the only reachability escape hatch is
  `OVID_BROWSER_ALLOW_HOSTS`, which is empty in production.
