# Ovid Cloud Migration — Design Specification

**Date:** 2026-10-15
**Status:** Approved by owner in conversation (2026-10-15). Supersedes the "no hosted execution"
clauses in `docs/superpowers/plans/2026-10-08-private-account-sync.md:19` and
`docs/superpowers/plans/2026-10-09-live-collaboration.md:18,158-172`, and selects **Option F
(server-side execution)** from `docs/superpowers/specs/2026-10-06-targetsdk36-runtime-architecture.md` §5.

---

## 1. Intent and Why

Ovid AI today runs the entire agent (loop, ~135 tools, sandbox, MCP, plugins, browser, schedules)
**on the user's Android device** via a Termux/proot jail, with a Python FastAPI backend
(`server/`) providing only gateway/account services. This blocks Play Store distribution
(targetSdk 28 requirement, W^X on Android 10+), dies when the app is backgrounded, and makes
setup a 7–8 minute per-device install.

We are migrating to a **100% server-side, cloud-native autonomous agent** (Meta Muse / Manus
style): the Flutter app becomes a **zero-setup thin client**; all execution happens on the
owner's VPS in isolated per-user sandboxes; tasks **continue running when the app is closed or
offline**, and state re-syncs on reconnect via replayable event streams.

## 2. Goals

- G1. Agent runs (chat turns, coding tasks, scheduled tasks) execute entirely server-side,
  detached from any client connection.
- G2. Flutter app: zero setup. No sandbox install, no Termux, no runtime downloads.
- G3. Per-user strict isolation (bubblewrap + cgroups v2) with zero host access.
- G4. 1-keystroke library installs (<100 ms cache hits) via shared pnpm/uv stores.
- G5. Heavy-compiler blocker (gradle/make/gcc/… and fork bombs) with a friendly refusal message.
- G6. Two-tier server browser: cheap headless research tier + live Playwright screencast tier
  the user can watch and take over.
- G7. Hibernation: idle workspaces/browser states zstd-compressed to Cloudflare R2 after
  3 minutes; lazy rehydration with a <5 KB file-tree manifest first, per-file extraction on demand.
- G8. Muse-style autonomous scheduler: user (or agent) describes *what to do* and *when*
  (one-off date/time, interval, daily-at, cron); the server executes it without the user present
  and reports results via push notification + in-app feed.
- G9. Free/Pro monetization gate on MCP & plugins: Free = curated built-in MCPs only (shared
  singletons); Pro = custom MCP servers (stdio-in-sandbox / HTTP / SSE), custom plugins,
  higher concurrency, extended storage.
- G10. Replace the Python backend entirely (strangler migration; LiteLLM proxy + its Python
  quota hook are the only Python kept, retired last if ever).
- G11. ≥100 concurrent connected users on the current VPS (8 vCPU / 22 GB), per §9 capacity model.

## 3. Non-Goals

- NG1. Multi-machine scale-out (design stays location-transparent: env-driven URLs, stateless
  gateway, separate worker process — a second box is config-only later).
- NG2. iOS/web clients (Flutter Android remains the only client; thin-client protocol is
  transport-agnostic for the future).
- NG3. Keeping on-device execution as a fallback path (sideload builds lose the local sandbox;
  the app is thin for everyone).
- NG4. Stripe or any non-Play payment rail.
- NG5. Re-implementing LiteLLM (model gateway, provider keys, fallbacks, cost tracking stay there).

## 4. Anti-Goals (failure even if it "works")

- AG1. Any design where closing the app kills or pauses a run.
- AG2. Any per-user duplication of node_modules/site-packages (defeats the shared-store goal).
- AG3. Any Redis configuration where queue/billing/event state can be evicted (`allkeys-lru`
  on authoritative data — the documented P0 — must never recur).
- AG4. Silent behavior drift from the Dart agent: the existing Dart test suite
  (`test/`, ~4,000 tests) is the behavioral contract; ported modules carry ported test cases.
- AG5. User-visible setup steps in the app (the only allowed "setup" is server-side).

## 5. Locked Decisions (owner)

| # | Decision |
|---|---|
| D1 | **Full TypeScript rewrite** of the agent core (no Dart agentd). Node/TS everywhere except LiteLLM's Python hook. |
| D2 | **Keep LiteLLM** as the model gateway. TS `mint` re-implementation keeps the `/mint`, `/usage`, `/plans`, `/v1/models` client contracts and the `ovid_pools.py` in-proxy hook semantics. |
| D3 | **BYOK kept via server-side key escrow**: user provider keys uploaded, envelope-encrypted in Postgres, used by the server agent directly against the provider (bypassing LiteLLM) through the single SSRF-guarded egress client. |
| D4 | **Current VPS** (this box: `vps-6bc54f43-vps-ovh-ca`, 8 vCPU / 22 GB / 193 GB — migrated 2026-10-16 from `vm-mtx87lmp`; live stack at `/opt/ovid-gateway`), re-provisioned; must handle **≥100 concurrent users**. |
| D5 | **Control mode removed** (accessibility `device_*` tools, overlay). **Voice input stays on-device** (STT → text upstream). **On-device WebView browser removed**; browser is server-side per G6. |
| D6 | Python backend replaced entirely (account, billing, collaboration, images, mint, reports, shares, sync). `private_sync` is **deleted, not ported** — server becomes authoritative for transcripts/memory/usage; the app keeps a read cache. |
| D7 | Cloudflare **R2** for object storage (workspaces, browser states, artifacts, image results). Owner provisions bucket + API token (env vars `OVID_R2_*`); agents never see Cloudflare credentials. |
| D8 | Scheduler must work like Meta Muse: description + time/date, autonomous completion without the user (see §8). |

## 6. System Architecture

Single VPS, Docker Compose. Public edge unchanged: Cloudflare → Caddy (`api.ovidsi.com`,
`ovidsi.com`). New TS stack lives in repo at `cloud/` and deploys to `/opt/ovid-cloud`.

```
Flutter thin client
   │  HTTPS (REST) + WSS (4 channel kinds) + FCM push
   ▼
Caddy ──► ovid-gateway (Fastify, TS, stateless)
   │        ├─ auth: Firebase ID token + App Check (firebase-admin Node SDK)
   │        ├─ REST: sessions, messages (cursor pages), schedules, file-tree/files,
   │        │        terminal attach, browser attach, BYOK escrow, GitHub OAuth,
   │        │        billing, usage, shares, collab, reports, account deletion
   │        └─ WS channels (single connection, multiplexed):
   │             event   — session event stream (replay + live)
   │             pty     — terminal I/O (xterm bytes ↔ sandbox PTY)
   │             browser — screencast frames (binary WebP) + input events
   │             system  — presence, run state, approvals, notifications
   │
   ├─► Redis-Q (dedicated, noeviction): BullMQ queues + Redis Streams (event log)
   ├─► Redis-C (cache, allkeys-lru ok): usage cache, rate windows, LiteLLM cache
   ├─► Postgres 16 (authoritative state, see §10)
   ├─► LiteLLM proxy (kept; ovid_pools.py hook; Postgres for keys/spend)
   └─► ovid-worker (separate process, scales independently)
          ├─ BullMQ workers: agent-runs, schedules, hibernate, hydrate,
          │                  browser, webhooks (Play RTDN), maintenance
          ├─ agent-core (TS): run buckets, never-stop loop, transports
          │     (LiteLLM virtual key | escrowed BYOK direct), tool roster,
          │     approvals, subagents, hooks, compaction, plan mode, skills, memory
          ├─ SandboxManager: bubblewrap jails under /workspaces/users/{uid}
          │     cgroups v2 (cpu.max=100000/100000 burst, memory.max=512M, pids.max=64)
          │     command interceptor + PATH wrapper blockers
          │     shared stores: /opt/ovid-shared-cache/{pnpm-store,uv-cache} (RO + hardlink)
          │     node-pty supervisor per (user, session, terminal tab)
          ├─ browser-engine: Tier1 Lightpanda/headless fetch; Tier2 Playwright
          │     contexts (cap 4 live, FIFO queue), CDP screencast WebP 3–5 fps,
          │     storageState per user (encrypted → R2)
          └─ StateHydrator: zstd-9 per-file-frame tar → R2; 3-min idle eviction;
                file-tree manifest (<5 KB) in Postgres; single-file lazy extract
McpRouter (in gateway+worker): curated shared-singleton MCPs (Free);
  custom stdio-in-sandbox / HTTP / SSE MCPs (Pro gate)
```

### 6.1 Component responsibilities

- **ovid-gateway**: the only public TS process. Stateless; horizontal-scale-ready. Owns auth,
  REST, WS multiplexing, event replay from Redis Streams, approval round-trips, R2 presigned
  artifact URLs. Never executes agent work inline.
- **ovid-worker**: consumes BullMQ. Hosts agent-core, SandboxManager, browser-engine,
  StateHydrator. One OS process; concurrency via per-queue BullMQ concurrency settings.
  Crash of the worker must not lose runs: run state is checkpointed in Postgres + Redis Stream,
  and BullMQ redelivers (stalled-job recovery).
- **agent-core**: faithful TS port of `lib/core/agent_service.dart` semantics: per-session run
  buckets (one active run/session), mid-run message queue/steering, never-stop turn loop with
  transient-retry/backoff (5 attempts, 3/9/27/60 s), no-progress retries (6), loop guards
  (nudges at 3/5/8 identical calls, escalation after 3 consecutive errors), per-tool timeouts
  that kill exactly that call's processes, dual transports (OpenAI-compatible SSE via LiteLLM;
  Anthropic Messages for native-Anthropic BYOK), prompt-cache-stable prefix (sorted tools,
  byte-stable system prompt), lossless compaction (ledger + checkpoint), plan mode (default-deny
  allowlist, read-only shell classifier, path jail), subagents (depth-limited child runs),
  hooks engine (session_start, user_prompt_submit, pre_request/post_request, pre_tool gate with
  updatedInput rewrite, post_tool, Stop/SubagentStop veto, circuit breaker), skills (SKILL.md),
  memory files, session ledger (JSONL → Postgres `session_events` mirror).
- **SandboxManager**: jail lifecycle (create/attach/hibernate/hydrate/destroy), command
  interception (§7), PTY sessions, background jobs (`job_*` tools) with event-sourced output,
  workspace quotas (500 MB default; Pro 2 GB).
- **browser-engine**: research tier serves `fetch_url`/`web_search`/`browser_read`-class tools
  cheaply; live tier gives the agent a real Chromium it can hand to the user (screencast +
  input injection). Per-user `storageState` persists logins across sessions (encrypted at rest).
- **StateHydrator**: archive format = tar with **one zstd frame per file** + a JSON frame index
  appended (enables single-file extraction without full decompression); manifest (path, size,
  mtime, hash) stored in Postgres at archive time; R2 keys under `users/{uid}/…` (§10).
- **McpRouter**: MCP protocol client (stdio/http/sse/native) ported from `mcp_service.dart`
  incl. OAuth PKCE with server-side callback (`https://ovidsi.com/oauth/callback`) relayed to
  the client; elicitation/sampling forwarded over WS `system` channel; tier gate enforced in
  router middleware (Free: curated allowlist only; Pro: custom servers, in-sandbox stdio).

### 6.2 Client protocol essentials

- Every server→client event carries `(session_id, seq, type, payload)`; `seq` is the Redis
  Stream ID. Client reconnects with `last_event_id` per session; gateway replays from the
  stream (retention: 24 h / 50 MB per session stream, then Postgres is the source for history).
- Approvals: worker publishes an approval request event; gateway pushes over WS + FCM; client
  answers via REST/WS; default policy on timeout = deny (120 s, matching current app behavior).
- Terminal: WS `pty` channel carries raw bytes + resize messages; server keeps a scrollback
  ring (256 KB) so a reconnecting client can repaint.
- Browser: WS `browser` channel, binary WebP frames (3–5 fps, quality-tuned to bandwidth),
  JSON input events (tap/scroll/keys), `takeover` handoff flag.

## 7. Command Guardrail (Anti-Crash Firewall)

Three layers, all in SandboxManager:
1. **Pre-parse interceptor** on every agent/user command string: shell-grammar-aware parse
   (split on `;`, `&&`, `||`, `|`, subshells, here-docs) + regex denylist. BLOCKED (exact set
   from the brief): `gradle`, `./gradlew`, `assembleDebug`, `assembleRelease`,
   `flutter build apk|appbundle|ios`, `kotlinc`, `javac`, `cargo build`, `gcc`, `g++`, `make`,
   `docker build`, `sdkmanager`, `ndk-build`, fork-bomb patterns (`:(){ :|:& };:` and variants).
   Response (exact copy): *"Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on
   live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead."*
   The refusal is returned to the agent as the tool result (agent can adapt), and to the user
   as a system note.
2. **PATH wrapper binaries** for the same list (installed ahead of real binaries in the jail),
   so interactive terminal use and indirect invocations also refuse with the same message.
3. **cgroups v2 hard caps** as backstop: `cpu.max=100000 100000` (1 core sustained; burst via
   `cpu.weight` within a parent slice capped at 6 cores total), `memory.max=512M`,
   `memory.swap.max=0`, `pids.max=64` per active sandbox; parent slice
   `ovid-sandboxes.slice` protects gateway/DB.

Allowed (must NOT be blocked): interpreters (`node`, `python`, `dart` if present, `ts-node`),
package installs (`npm/pnpm i`, `pip/uv add`, `apt-get` jailed), `git`, linters/formatters,
`flutter analyze|test` (non-native-build subcommands).

## 8. Scheduler (Muse-style autonomous tasks) — G8/D8

**Model.** A `schedule` = `{ id, user_id, session_id?, title, description (what to do, natural
language), trigger, autonomy, status, next_run_at, last_result, max_retries (0–3) }`.
Triggers: `at` (one-off ISO datetime), `every` (interval seconds, min 300), `daily_at` (HH:MM +
tz), `cron` (5-field, Pro tier only). Session binding optional: bound schedules post into that
session; unbound schedules create/continue a dedicated per-schedule session.

**Creation paths.** (a) Schedule screen CRUD (description + date/time pickers); (b) agent tool
`schedule_create|schedule_list|schedule_update|schedule_delete` — the agent parses natural
language ("every morning at 9 check my inbox and summarize", "finish the report by Friday 5pm")
into a structured trigger and **echoes the parsed trigger back for user confirmation** before
persisting; (c) REST API from the thin client.

**Execution.** Postgres is authoritative. A scheduler tick (every 15 s in worker) loads due
schedules `FOR UPDATE SKIP LOCKED`, enqueues an `agent-runs` job with prompt
`[schedule: {title}] {description}`, claims at-most-once (idempotency key = schedule_id +
scheduled_for). BullMQ delayed/repeatable jobs are a fast-path mirror, re-synced from Postgres
on boot (never authoritative). Runs execute with **no user present**:
- Autonomy profile per schedule: `safe` (read-only tools; default) or `auto` (session's stored
  grants apply; user must explicitly opt in at creation). Approval requests during unattended
  runs auto-deny after 120 s and are reported in the result.
- Result → FCM push + in-app schedule feed + session message. Failure → retry per
  `max_retries` with backoff, then `pauseForReview`.

**Missed-run policy** (port of Dart `MissedRunPolicy`): catch-up tolerance 2 min; one-off
grace 24 h (run late, flag `ran_late`); recurring grace ≤6 h → `runNow` if ≤1 missed,
`skipToNext` if more; beyond grace → `pauseForReview`. Server reboots never duplicate effects
(claim ledger keyed by `(schedule_id, scheduled_for)`).

## 9. Capacity Model (≥100 concurrent on 8 vCPU / 22 GB)

> **Revised 2026-10-16 by P10 Task 1.** The box migrated to
> `vps-6bc54f43-vps-ovh-ca` — **8 vCPU / 22 GB / 193 GB** (ledger ENVIRONMENT
> SHIFT 2026-10-16). The earlier 12 vCPU / 30 GB budget is superseded. These
> numbers adopt the converged sibling-plan artifacts — P2's sandbox slice,
> P6's worker unit and browser knobs, and the ledger's `MAX_WARM_GB` — never
> a pre-convergence draft.

"Concurrent" = connected users with live sessions. Assumed profile: 30–50 agent runs in
flight; ~80% of run wall-time is LLM streaming (near-zero CPU); 10–20 sandboxes executing
commands at any instant. Memory envelope: host+Docker+systemd 2 GB, Postgres 3 GB,
Redis-Q 1.5 GB (`mem_limit 1536m` / `maxmemory 1400mb`), Redis-C 0.5 GB, LiteLLM 1 GB,
Caddy+misc 0.5 GB, gateway container 1 GB, worker systemd unit **`MemoryMax=4096M`**
(worker proper ~2 GB + browser pool ~2 GB — 4 live Tier-2 contexts ≤600 MB + the Tier-1
Lightpanda pool + chromium fallback; planned peak ≈1.3 GB, hard ceiling 2 GB) ⇒
**non-sandbox ceilings ≈12 GB** (P2's envelope; caps are ceilings, not reservations —
jails are ~2 MB resident per the P2 spike; P10 Task 5 measures the real envelope).
Sandbox slice `ovid-sandboxes.slice` **`MemoryMax=10G`, `MemorySwapMax=0`** (P2's shipped
artifact); 24 × 512 MB worst case binds at the 10 G slice first (per-env OOM, host
protected) ⇒ `OVID_MAX_ACTIVE_SANDBOXES=24` (P2's env name; was 32). Per-jail caps
unchanged: `memory.max=512M`, `memory.swap.max=0`, `pids.max=64`,
`cpu.max="100000 100000"`. CPU: `ovid-sandboxes.slice` **`CPUQuota=600%`** (was 1000%;
6 of 8 cores, leaving ~2 for gateway/DB/browser/LiteLLM). Browser knobs (P6 landed
defaults): `MAX_LIVE_BROWSERS=4`, `MAX_ACTIVE_SCREENCASTS=3`, `MAX_TIER1_PROCESSES=8`.
Disk: `MAX_WARM_GB=8` warm-workspace LRU cap (the single converged P2↔P7 knob; the owner
may retune 8→12 at activation); disk alert at 80% (the box currently shows 136 GB free —
the earlier 45 GB envelope note is superseded, but the cap/alert stay). Load profile
(G11 on the revised box): **100 connected users, 30–50 in-flight runs, 10–20
environments executing at any instant (cap 24 ⇒ admission queues, never rejects),
browser tier ≤4 live, scheduled fires interleaved**. Hibernation (3-min idle) keeps warm
jails ≪ user count. Concurrency admission: worker enforces `OVID_MAX_ACTIVE_SANDBOXES`
(default 24) and `MAX_LIVE_BROWSERS` (default 4) with queues; Free tier = 1 concurrent
run, Pro = 3 (queue priority via BullMQ priority).

## 10. Data Layer

**Postgres 16** (existing container; new database `ovid_cloud`, separate from LiteLLM's):
tables (Drizzle-managed): `users`, `byok_keys` (envelope-encrypted), `sessions`, `messages`,
`session_events` (ledger mirror), `schedules`, `schedule_runs` (claim ledger), `runs`
(checkpoints/state), `file_manifests`, `workspace_objects` (R2 index), `browser_states`,
`grants`, `plans`/`usage_windows`/`billing_purchases`/`image_jobs` (money ledgers ported with
exact Decimal semantics), `shares`, `reports`, `collab_sessions`/`collab_events`/`collab_members`,
`account_deletions`, `devices` (FCM tokens). Backups: nightly `pg_dump` + WAL archiving to R2
(fixes the "no backups" P0).

**Redis** — two containers: `redis-q` (`maxmemory-policy noeviction`, AOF everysec; BullMQ +
Redis Streams + idempotency) and `redis-c` (`allkeys-lru`; caches only). Existing gateway Redis
stays for LiteLLM/mint until cutover.

**R2 layout:** `users/{uid}/workspaces/{session_id}.tar.zst`, `users/{uid}/workspaces/{session_id}.manifest.json`,
`users/{uid}/browser/{profile_id}.zst`, `users/{uid}/artifacts/{…}`, `images/{uid}/{request_id}.png`,
`backups/pg/{date}.dump.zst`. Owner creates bucket `ovid-cloud` + scoped API token; configured
via env (`OVID_R2_ACCOUNT_ID`, `OVID_R2_ACCESS_KEY_ID`, `OVID_R2_SECRET_ACCESS_KEY`,
`OVID_R2_BUCKET`).

**Hydration SLA:** manifest-first (<100 ms UI), single-file extract <500 ms (frame index seek),
full workspace hydrate <5 s for ≤200 MB.

## 11. Security

- Jail: bubblewrap, unprivileged per-user uid (range 200000+), `--unshare-user/pid/ipc/uts`,
  private `/etc` (minimal, generated), RO bind of a versioned base rootfs
  (`/opt/ovid-rootfs/ubuntu-noble-min` with node/python/git/curl/pnpm/uv), RW bind of
  `/workspaces/users/{uid}` as the jail's working root, `--die-with-parent`, no host `/proc`
  view of other users (pid ns), network allowed but nftables blocks RFC1918/169.254/metadata +
  the VPS's own public IP from sandbox egress; all agent/BYOK HTTP goes through one
  SSRF-guarded egress client (DNS-resolution check, port 443/80 only).
- Secrets: escrow + browser-state encryption = AES-256-GCM envelope (per-record DEK wrapped by
  `OVID_MASTER_KEY` from env; documented risk: master key on same host — v1 accepted).
- Auth: Firebase ID token + App Check on every REST/WS handshake (firebase-admin Node);
  WS gets short-lived (60 s) tickets minted over REST to avoid token replay in URLs.
- GitHub OAuth (Studio): device flow proxied server-side; tokens encrypted in Postgres.
- MCP OAuth: PKCE server-side; tokens per user, encrypted.
- VPS hardening (Phase 0): disable root VNC/noVNC + vsftpd, key-only SSH, `trusted_proxies`
  for Cloudflare in Caddy, container mem/cpu limits, log rotation, pinned images, healthchecks
  + uptime alerting, Redis split per above.

## 12. Flutter Thin-Client Refactor

**Removed:** Termux/proot bootstrap + `sandbox_setup.dart`, `pty_service`, local agent loop
(`agent_service.dart` execution half), Control mode + `device_*`, on-device WebView browser +
pool, background reliability apparatus (FGS keep-alive, AlarmManager, battery cards), local
scheduler runtime, private_sync client, local plugin/MCP runtimes.
**Kept:** chat UI (renders server event stream), voice input (on-device STT → text), Studio
(remote file tree/editor/terminal over WS), Schedule screen (CRUD + results feed), Browser
screen (screencast canvas + input), billing/usage/settings/shares/collab/reports UI, FCM push.
**Offline:** read-only cache of last transcript; prompt queue flushed on reconnect.
The Dart test suite is ported to Vitest case-by-case as each agent-core module is rewritten
(AG4); UI tests stay Dart.

## 13. Migration Strategy (strangler)

1. TS stack is built alongside the live Python stack; Caddy routes flip per service once the TS
   twin passes its parity tests (contracts pinned in `server/mint/README.md` §usage, images
   money rules, billing verify/RTDN semantics, shares/sync/collab wire formats where kept).
2. Old app builds in the wild keep working against Python routes until forced-update; the
   thin-client build ships only after Phases 1–6 pass.
3. `private_sync` and on-device history: one-time import tool uploads existing local transcripts
   to the server (optional, user-consented) at first thin-client login.
4. Python `account-dev`, shares, reports, collab, billing, images, mint are decommissioned in
   that order (least money-critical first; mint+images last).

## 14. Plans Breakdown (one plan per subsystem, in build order)

| Plan | Scope | Working software at the end |
|---|---|---|
| P0 | VPS re-provision + repo scaffold (`cloud/` pnpm monorepo, CI, compose at `/opt/ovid-cloud`, dual Redis, `ovid_cloud` DB, backups, hardening checklist) | hardened box; `pnpm test` green in empty monorepo |
| P1 | **Cloud spine**: auth, Postgres schema, Redis Streams event log, BullMQ, gateway REST+WS, worker agent-run job with tool-less loop streaming via LiteLLM, message persistence + cursor paging, reconnect replay | end-to-end server-side chat from a test client |
| P2 | **SandboxManager**: bwrap jails, cgroups, command blocker (3 layers), shared pnpm/uv stores, `ovid install`, shell/file/git/job tools, PTY over WS, terminal repaint | agent writes and runs code in a jail; user terminal works |
| P3 | **Agent-core parity**: full tool roster, subagents, hooks, skills, memory, compaction, plan mode, approvals, presets, catalog tools | behavioral parity per ported Dart test suite |
| P4 | **Scheduler + notifications**: §8 in full, FCM push, schedule feed | unattended autonomous tasks run and report |
| P5 | **MCP + plugins + tier gate**: McpRouter, curated MCP set (port native handlers + top REST descriptors), custom MCP (Pro), plugin pipeline, MCP OAuth | Free/Pro gating live |
| P6 | **Browser engine**: Tier1 research, Tier2 screencast + takeover, storageState persistence | agent browses; user watches/takes over |
| P7 | **StateHydrator + R2**: archive format, hibernation, manifests, lazy files, artifacts, R2 provisioning runbook (owner task: bucket+token) | 3-min eviction + instant studio open |
| P8 | **Flutter thin-client refactor**: strip local execution, WS state sync, remote Studio/Browser/Schedule screens, one-time history import | zero-setup app against staging |
| P9 | **Money & accounts**: TS mint, Play billing verify+RTDN, images ledger, BYOK escrow, account deletion, shares/reports/collab v2; decommission Python | full cutover |
| P10 | **Hardening & load**: 100-concurrent load test, reconnect/chaos suite, security review, runbooks | production cutover |

Each plan gets its own `docs/superpowers/plans/2026-10-15-ovid-cloud-pN-*.md` written just-in-time
(next plan written when the previous is ~done), because later plans depend on interfaces that
earlier execution firms up.

## 15. Global Constraints

- Node 22 (installed), pnpm workspaces, TypeScript `strict`, Vitest, Drizzle ORM, Fastify 5,
  `@fastify/websocket`, BullMQ 5, Redis Streams, `node-pty`, Playwright (chromium), Lightpanda
  (Tier 1; fallback: shared headless chromium pool if Lightpanda proves immature),
  bubblewrap, zstd 1.5, AWS SDK v3 (S3 client for R2), firebase-admin.
- New code lives under `/root/OvidAI/cloud/`; deploy target `/opt/ovid-cloud`; existing Flutter
  app and Python server remain untouched until their phase.
- Money paths use integer cents or `Decimal`-equivalent exact arithmetic — never binary floats
  (port of images-ledger rule).
- Every TS package ships tests; CI runs `pnpm -r test` + `tsc --noEmit`.
- Client-visible error contracts preserved verbatim where the service is ported
  (`daily_limit_reached` + `x-ovid-resets-at`, 402/409 image semantics, etc.).

## 16. Builder's Latitude

Left to each plan's builder: internal module layout within packages, exact Drizzle table DDL
(shapes above are authoritative, column details are not), test file organization, Lightpanda vs
chromium-pool final call for Tier 1 (decide in P6 with a spike), curated-MCP initial lineup
(target 15–25; start with the 4 existing native handlers + highest-used REST descriptors),
scrollback/ring-buffer sizes beyond the minimums stated.

## 17. Risks

- R1. Agent-core rewrite parity (26k LOC of behavior) — mitigated by AG4 (ported tests) and
  P3's checklist-driven tasking.
- R2. Lightpanda maturity — fallback defined in §15.
- R3. 100-concurrent on a shared box — mitigated by §9 admission caps + Phase 0 hardening
  (remove root desktop/VNC); honest ceiling: ~24 simultaneous active sandboxes.
- R4. Escrow master key co-located with data — accepted v1 risk; documented for future KMS.
- R5. Repo was flipped public once (signing key/Firebase config exposure noted in
  HARDENING_TRACKER) — Phase 0 includes secret rotation checklist (owner task).
- R6. Data Safety / privacy policy must be updated before shipping the thin client (code and
  repos now transit Ovid infra) — owner task in P8.
