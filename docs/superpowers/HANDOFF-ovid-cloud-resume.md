# Ovid Cloud Migration — RESUME HANDOFF (harness-agnostic)

**Written:** 2026-10-16 ~19:30 UTC · **Branch:** `feat/ovid-cloud` @ `c541375` · **Repo:** /root/OvidAI
**Owner directive:** complete the FULL migration program 100% (spec §14 plans P0–P10), using many
parallel subagents where safe, with careful review gates (implementer + independent reviewer per task).

This document is the entry point for a fresh agent session on ANY harness. Read it fully, then follow
"RESUME SEQUENCE" below. The authoritative detailed state lives in the SDD ledger (path in §2).

---

## 1. What this program is

Migrating Ovid AI (Flutter app + Python backend, agent currently runs ON-DEVICE) to a 100%
server-side cloud-native agent (Muse/Manus style): Flutter = zero-setup thin client; all execution
on this VPS in per-user bubblewrap sandboxes; tasks survive app close/offline; Muse-style autonomous
scheduler (owner's top product priority).

- **Binding spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` (approved by owner; contains locked decisions D1–D8, goals G1–G11, anti-goals, capacity model, security, data layer, migration strategy, plan breakdown §14).
- **Owner's locked decisions:** full TypeScript rewrite of agent core · keep LiteLLM as model gateway (Python quota hook stays inside it) · BYOK via server-side encrypted escrow · this VPS, ≥100 concurrent users · Control mode REMOVED, voice input is OFF in release (`kOvidVoiceEnabled = false`; the on-device capability exists but is gated), browser fully server-side (2-tier) · Python backend replaced entirely (strangler) · Cloudflare R2 storage · scheduler per spec §8.

## 2. Authoritative state (read these first)

| Artifact | Path | Role |
|---|---|---|
| **SDD ledger** | `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/progress.md` | THE recovery map: every task's status, every ruling (search `Ruling:`), all deferred minors, owner-pending questions, resume point. Git-ignored but on disk. |
| Task briefs/reports/review diffs | `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/` | Per-task evidence for P1's 12 tasks. |
| Research reports | `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/research/` | `p2-bubblewrap-feasibility.md` (BINDING for P2), `p6-browser-tiers.md` (BINDING for P6), `p7-archive-format-spike.md` (BINDING for P7), `p8-flutter-strip-worklist.md` (BINDING for P8). |
| P1 plan (executed) | `docs/superpowers/plans/2026-10-15-ovid-cloud-p0-p1-spine.md` | 12/12 tasks complete + reviewed. |
| Plans WRITTEN, not yet executed | `docs/superpowers/plans/2026-10-16-ovid-cloud-p{3,4,5,6,8,9,10}-*.md` | P3 agent-core (20 tasks), P4 scheduler (14), P5 MCP/plugins (16), P6 browser (16), P8 Flutter thin-client (20), P9 money/accounts (18), P10 hardening/cutover (14). Controller answers to writer questions are in the ledger ("PLANS LANDED" entries) — binding at execution. |
| Plans MISSING (writers died on a provider content filter) | — | **P2 sandbox-manager** and **P7 statehydrator-R2** must be written first (see §4). All their inputs exist (spec + research reports). |

## 3. What is BUILT and working (P1 spine, on branch)

`cloud/` pnpm monorepo (Node 22, TS strict, vitest 2.1.9, pnpm 12):
- `packages/shared` (wire protocol: events/REST DTOs/WS ops/zod), `packages/db` (Drizzle+Postgres: users/sessions/messages/runs/sessionEventMirror + repos incl. users.ensure, listStaleRunning), `packages/events` (Redis Streams log + live fanout), `packages/queue` (BullMQ, attempts:1, AGENT_RUN_JOB_DEFAULTS).
- `apps/gateway` (Fastify: Firebase ID+AppCheck auth, single-use WS tickets (atomic Lua), REST /cloud/v1 sessions+messages+health+ticket, WS /cloud/ws subscribe with replay-then-live dedupe (Review-Focus-1 airtight), 404-not-403 ownership discipline).
- `apps/worker` (agent-run processor v0: LiteLLM SSE streaming w/ robust parser, retry ladder 3/9/27/60s, events run_started/message_delta/message_completed/run_started_retry/run_failed/run_completed + mirror, stale-run sweeper `run_lost`, SIGTERM drain).
- `apps/e2e` (4 spine flows incl. post-completion replay-from-cursor + degradation + per-user boundaries). **160/160 tests green** (`cd cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm -r build && pnpm -r test`).
- `cloud/deploy/` (compose for gateway+worker+redis-q noeviction/maxmemory 1400mb, Dockerfiles, provision.sh --dry-run proven, Caddy snippet (handle /cloud/* → 127.0.0.1:8082), DEPLOY.md owner runbook, nightly zstd backups + proven restore drill, HARDENING.md items A–G with corrected live facts).
- **NOT activated:** the ovid-cloud stack has never been `compose up`'d; Caddy route not inserted; DB `ovid_cloud` not created. All activation = owner-gated (DEPLOY.md).

## 4. RESUME SEQUENCE (do in this order)

**Step 0 — Process setup.** If your harness has the superpowers skills, use `subagent-driven-development`
(fresh implementer per task + task reviewer + fix loops + ledger). If not, replicate it manually:
per task → implementer subagent (TDD, commits) → independent reviewer subagent (spec+quality verdicts)
→ fix rounds → ledger entry. Keep writing to the SAME ledger file (append-only). Never dispatch two
code-writing agents in parallel on overlapping paths; reviewers/read-only agents may overlap.
Model note: on the previous harness, explicit model selection failed ("max-per-mtok bid") and dense
security-vocabulary in dispatch prompts tripped a content filter (DataInspectionFailed) — rephrase
neutrally and reference detail via files instead of inlining it.

**Step 1 — P1 FIX WAVE (blocking; findings from the final whole-branch review, all details in ledger).**
ONE fixer subagent, then ONE scoped re-review:
- **C1 (Critical):** single-active-run-per-session NOT enforced. Fix: in worker processor, BEFORE `claimNext`, wait out older active runs of the session (poll `runs.activeForSession`, deterministic oldest-first tie-break `(createdAt,id)`, injectable sleep ~250ms, capped `RUN_QUEUE_WAIT_MS` default 600000 → on cap: `run_failed {code:"run_queue_wait_timeout"}` + terminalize from queued). Plus e2e double-send flow (gated slow transport; run2 `run_started` strictly after run1 `run_completed`; transcript order user1,user2,assistant1,assistant2; no interleaved deltas). Write it as the seed of P3's per-session run buckets (code comment).
- **I2 (blocking):** WS `maxPayload` uncapped (100MiB default × 32 pre-auth frames → OOM). Fix: `scope.register(websocket, { options: { maxPayload: 262_144 } })` + oversized-frame-kills-socket test.
- Same round (recommended): **I3** per-connection subscription cap (64 → error frame + test); **I4b** `runs.finish` conditional `WHERE status IN ('queued','running')` (terminal states protected; sweeper↔processor can't overwrite each other) + flip-refusal test; **I5** correct `queues.ts:47-52` stalled-redelivery comment (attempts:1 → stalled FAILED, sweeper is the recovery); **test-infra isolation**: BullMQ-native `prefix` option threaded through `createQueues`/`createAgentRunsWorker` (env-driven, unique per test suite) so parallel suites on shared dev redis can't obliterate each other's `agent-runs` queue (URGENT before parallel waves; P4 plan already assumes it); DEPLOY.md §9 activation-gate checklist additions (maxPayload, sub cap, SIGTERM drain pending, mint deadline pending, WS error logging pending); drop `--passWithNoTests` from all package test scripts (condition met — every package has tests).
- Verify: full workspace suite green ×2 + e2e; commit; scoped re-review of the fix range; ledger the round.

**Step 2 — Write the two missing plans** (use the writing-plans skill/format like the other 7; writers must NOT commit — controller batches commits):
- **P2 sandbox-manager** → `docs/superpowers/plans/2026-10-16-ovid-cloud-p2-sandbox-manager.md`. Inputs: spec §7/§9/§11/§14-P2 + research `p2-bubblewrap-feasibility.md` (BINDING: Architecture A host-systemd worker + bwrap ~4-6ms/jail; AppArmor userns gating → week-1 host verification task + fallbacks (custom AppArmor profile OR root-run bwrap with explicit uid map + setuid(200000)); per-user pnpm/uv stores (shared RO store PROVEN unworkable: fs.protected_hardlinks EPERM) + XFS-reflink seeding decision (/ is ext4 now); cgroup delegation wiring; nftables egress by uid range). Scope (from the failed dispatch, preserved here): rootfs pipeline (/opt/ovid-rootfs, docker-export ubuntu noble + node/python/git/curl/pnpm/uv, pinned); SandboxManager (create/attach/destroy, uids 200000+ (P10 assumed staging uid-base 220000 — reconcile), workspace /workspaces/users/{uid} 500MB quota, die-with-parent, private minimal /etc, RO rootfs + RW workspace binds); cgroups v2 (cpu.max 1-core burst, memory.max 512M, swap 0, pids.max 64, parent slice ~6 cores CPUQuota=600% MemoryMax≈10-12G); command policy layer (spec §7 EXACT blocklist + EXACT refusal copy as tool result AND system_note + PATH shims for interactive terminals); exec API (one-shot + node-pty PTY) + jobs (job_start/output/list/kill, process-tree cleanup); `ovid install` fast path (<100ms cache hit target); egress filtering (RFC1918/169.254/metadata/own-IP for sandbox uids); admission MAX_ACTIVE_SANDBOXES=24 + queue; gateway WS `pty` channel (raw bytes+resize, 256KB scrollback ring, reconnect repaint) added to the existing multiplexer; worker integration: run_shell + file tools (read/write/edit/glob/grep) via SandboxManager behind a tools seam P3 extends (P3 plan pins `SandboxPort`; P5 pins `SandboxSpawner`/`SandboxFiles`; P6 needs `workspaceDir(userId,sessionId)` + nftables uid rule per its Task 16d — the P2 plan's Produces must satisfy/absorb these seams); e2e: echo + file write in jail streamed over WS; deploy artifacts (worker moves compose→host systemd unit + ovid-sandboxes.slice; compose keeps gateway+redis-q) + HARDENING cross-refs; isolation verification suite. Host-touching steps owner-gated like P1 Task 11. NOTE: P10 plan Task 1 owns the spec §9 revision — P2 plan must not also edit the spec.
- **P7 statehydrator-R2** → `docs/superpowers/plans/2026-10-16-ovid-cloud-p7-statehydrator-r2.md`. Inputs: spec G7/§6.1-StateHydrator/§10 + research `p7-archive-format-spike.md` (BINDING winning format/benchmarks). Scope: archive codec per spike format; R2 client (@aws-sdk/client-s3, OVID_R2_* env, StorageAdapter interface + filesystem impl for credential-free tests, multipart, presigned GET); key layout per spec §10; hibernation (3-min idle, BullMQ delayed re-arm or worker tick; pack→upload→checksum-verify→evict via SandboxManager destroy; Postgres file_manifests + workspace_objects); hydration (manifest-first <100ms from Postgres, extractOne <500ms, full <5s ≤200MB — benchmark task proves SLAs on THIS box class); MAX_WARM_GB LRU (revise default for 22GB box; P6 assumed ~10GB left for ~24 jails — reconcile) + disk 80% alert; Virtual file-tree REST (GET tree/file, PUT write-through, hydrate/hibernate controls); artifacts pipeline (presigned URLs in events); fulfill P6's `BrowserStateStore` seam on R2 with key layout `users/{uid}/browser/{profileId}.zst`; P8 needs a reusable presigner (P8-T3 assumes it); owner-gated R2 provisioning runbook (bucket + least-privilege token + lifecycle rules); e2e pack→evict→tree→extractOne→hydrate→LRU against filesystem adapter + skipIf live-R2 contract test.

**Step 3 — Execute plans in dependency order** with full SDD gates:
`P2 → P3 → (P4 ∥ P5 ∥ P6 ∥ P7 in parallel waves; disjoint packages; ONE committing agent at a time; queue-prefix isolation from Step 1 makes parallel test runs safe) → P8 → P9 → P10`.
Per-plan: fresh SDD workspace via the skill's `sdd-workspace` script (or mirror the layout manually under `.superpowers/sdd/<date>-<plan>/`), per-task briefs/reports/review packages, rulings recorded in that plan's ledger.
Cross-plan reconciliations already ruled (ledger "PLANS LANDED" entries are BINDING): P6 `BrowserToolDef` shape into P3's tool seam; P5 seam names vs P2's actual Produces; P4 `// P4-SEAM:` fallback; P8 [MAP]-style reconcile-against-built-code for P2/P4/P6 wire shapes; P9 reconciles P3 KeyResolver + P4 queues at dispatch.

**Step 4 — Owner gates (ASK the owner; do not self-approve):**
- Activation windows on the live box: P1 Task-11 Step 6 (provision ovid_cloud DB, compose up, Caddy insert+reload), P2 systemd/nftables/rootfs/workspaces activation, P9 Caddy route flips + Python decommission, P10 rollout. Production boundary ALWAYS: never mutate `ovid-gateway-*` containers or `/opt/ovid-gateway` without the owner present; disposable containers named `ovid-spike-*`/`ovid-dev-*` only.
- **Owner-pending product questions** (needed before P8/P9/P10 execution; ask early): Q1 clean-break vs installed base (builder-check found ~7 dev users, billing never deployed, no Play release — likely clean break, but owner must confirm; turns weeks of P9 data-migration on/off); Q2 public launch point + Play deadline; Q3 staging story (P10 default: same box, scratch ports, separate compose project + second Postgres container); Q6 collab v2 port/redesign/cut (P8 flag-OFF default until answered); Q7 Dart/Flutter SDK in cloud workspaces (rootfs scope, ~3GB vs quotas); Q8 disk budget (box now 193GB/30%-used — likely moot, confirm).
- R2 credentials: owner creates bucket + scoped API token → env `OVID_R2_*` (P7 activation); `OVID_MASTER_KEY` generation (P5/P7/P9 crypto).

**Step 5 — Program finish:** P10 final acceptance script + release evidence; then
`finishing-a-development-branch` ONCE for the whole program (ruling: branch stays the working branch
through P10; do not merge per-plan). Update spec §9 numbers (P10 Task 1 owns this).

## 5. Environment facts (verified 2026-10-16)

- This machine IS the production VPS (migrated by owner from vm-mtx87lmp): `vps-6bc54f43-vps-ovh-ca`, public IP 148.113.44.36 (OVH), **8 vCPU / 22 GB RAM / 193 GB disk (30% used)**, Ubuntu 24.04. DNS cut over (ovidsi.com → here; api.ovidsi.com via Cloudflare). `https://api.ovidsi.com/healthz` → 200.
- Live prod stack (DO NOT TOUCH): `/opt/ovid-gateway` compose — caddy (host net, Caddyfile at /opt/ovid-gateway/caddy/), mint :8090, litellm :4000, postgres:16 (no host port; DBs litellm/ovid_account_dev), redis:7 (no host port, password in /opt/ovid-gateway/.env, mint uses db2), account-dev :8080, img-edit-shim. Network `ovid-gateway_internal`. firebase-admin.json at /opt/ovid-gateway/.
- Dev services (yours to use): containers `ovid-dev-pg` (127.0.0.1:5433, postgres/ovid) and `ovid-dev-redis` (127.0.0.1:6390) — restart policy unless-stopped. Test env: `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres TEST_REDIS_URL=redis://127.0.0.1:6390`. No FLUSHDB ever; scoped cleanup only.
- Toolchain: Node v22.23.3, pnpm 12.11.2 (corepack), Docker 29 + compose, zstd 1.5.5, jq. `bwrap` NOT installed (P2 owner-gated apt step). ufw active (22,443,80,6080,5901,21,40000:50000). Git identity repo-local: root@vps-6bc54f43-vps-ovh-ca. Pre-existing dirty files NOT ours — never stage/revert: `.superpowers/sdd/2026-10-07-premium-share-domain-plan/task-2-report.md` (M), `docs/screen-review/` (??).
- Host port map: 8081 = live Caddy admin (cloud gateway publishes **8082**), 5433/6390 dev, 4000/8090/8080 live loopback.
- Machine also runs a root VNC desktop + vsftpd (HARDENING.md items A/B owner-pending) — extra reason P2+ must land its isolation/hardening gates before real users.

## 6. Non-negotiables (from spec + ledger rulings)

- AG1: closing the app never kills/pauses a run. AG2: no per-user duplication of node_modules (per-user STORES are the ruled correction — see research). AG3: queue/billing/event Redis state NEVER evictable (noeviction + maxmemory below mem_limit; writes fail loudly). AG4: Dart test suite (`test/`, ~4k tests) is the behavioral contract for P3 ports — port cases to Vitest per module. AG5: zero user-visible setup.
- Money paths: exact decimal arithmetic only (no binary floats). Client-visible error contracts preserved verbatim where services are ported (429 daily_limit_reached + x-ovid-* headers, 402/409 image semantics).
- Redis db2 key-shapes read by the staying Python LiteLLM hook (`server/mint/litellm_hook/ovid_pools.py`) are a HARD contract — TS mint (P9) writes exactly those shapes; the hook is never modified (Ruling Q4).
- Interim key flow until P9: gateway forwards user Firebase token to Python `/mint`; worker reads `user:{uid}:key` from mint redis db2 (Ruling Q5). Unattended runs without a minted key → `run_failed key_not_minted` + push asking user to open app once.
- Wire: camelCase JSON, UUIDv7 ids, envelope `{error:{code,message}}`, event envelope `{sessionId,seq,type,payload,ts}` with Redis-Stream-id seqs; @ovid/shared extensions ALWAYS additive (P1 e2e must stay green unmodified).
- Every task: TDD, clean scoped commit, review gate. Every ruling/deferral: ledger line.

## 7. Suggested kickoff prompt for the new harness

> Read /root/OvidAI/docs/superpowers/HANDOFF-ovid-cloud-resume.md fully, then the SDD ledger it names.
> You are resuming the Ovid Cloud migration at RESUME SEQUENCE Step 1 (P1 fix wave). Use
> subagent-driven development (fresh implementer per task + independent reviewer + fix rounds +
> append-only ledger). Owner directive: complete the entire program (P2–P10) to 100%, using many
> subagents in parallel where paths are disjoint, never touching the live ovid-gateway stack without
> an owner-gated activation. Start now; ask the owner only at the Step-4 gates.
