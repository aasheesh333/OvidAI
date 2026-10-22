# Ovid Si — production readiness, scale and security

An honest assessment of what is built, what breaks first at scale, and what to
do in what order. Every "done" line cites a file that exists in this repo;
every gap names the file that would have to change. Where a claim is a console
or deployment fact the repository cannot prove, it is marked **unverified**.

**Verified against the code on 2026-10-22.** Method: static reading only —
`grep`/file inspection of `lib/`, `server/`, `cloud/` and `android/`. No build,
no test run, no Flutter command was executed for this revision. A claim that
says "wired" means a production call site was found; it does not mean the
end-to-end flow was exercised.

The gap list in §6 is rebuilt from
[`docs/audit/FEATURE_GAPS.md`](../audit/FEATURE_GAPS.md) (audited 2026-10-22
against `lib/ui/v2/` and the adapters). The older
[`docs/architecture/FEATURE_GAPS.md`](FEATURE_GAPS.md) (2026-10-21) is kept for
history; several of its P0s have since been fixed and are called out below.

---

## 1. Where the product actually stands

| Area | State | Evidence |
|---|---|---|
| Chat, sessions, send path | Done | `lib/ui/v2/app/v2_app_shell.dart`; `test/v2/app/shell_chat_send_test.dart`; 50 screens in `docs/audit/SCREEN_INVENTORY.md` |
| Session isolation (filesystem) | **P0 gap** | Agent tools attach per **user**, not per session: `cloud/packages/sandbox/src/manager.ts` (`attach(userId)`, `workspaceDir = {uid}/workspace`); per-session dirs exist only for browser/Studio (`workspaceDirFor`) |
| Subagents (50 cap, no nesting, 8 h, 300-token JSON) | Done | `cloud/packages/agent-core/src/subagents.ts`, `subagentSummary.ts`, `subagentLog.ts` |
| Studio (clone, branch, sync, credential helper) | Partial | `cloud/apps/worker/src/studioGit.ts`, `studioGitQueue.ts`; no app-side diff/commit client (`lib/ui/v2/app/v2_studio_routes.dart`) |
| Browser (agent tabs, 3–5 fps, takeover, transfers) | Done for the backend; screen wired | `cloud/packages/browser/src/*`; `lib/ui/v2/browser/browser_live_page.dart`; missing history/upload/download/close-tab (FEATURE_GAPS A10) |
| Plans, caps, metering | Partial | `server/mint/ovid_plans.py` (free token caps), `cloud/apps/gateway/src/planGate.ts` (**now called** by `cloud/apps/gateway/src/routes/messages.ts`, `cloud/apps/gateway/src/routes/accountSettings.ts`, `cloud/apps/gateway/src/routes/schedules.ts`); connector/storage quotas not wired; free USD allowance still gates first (C15) |
| Billing | Partial | RevenueCat + Play code: `lib/core/revenuecat_billing.dart`, `lib/core/billing_products.dart`; **no Play subscription (monthly or yearly) exists yet** — FEATURE_GAPS D1/D2 |
| Memory (session, global, project) | Partial | DB-backed `private_memory_files`; no global store, no project write path (architecture FEATURE_GAPS §5.3–5.5); screens in `lib/ui/v2/settings/memory_page.dart` |
| Sharing (collab 50, read-only fork) | Partial | Server: `server/collaboration/repository.py` + `postgres.py` enforce 50 members and the turn lease; app collab runtime is device-local (`lib/core/collaboration/production.dart`); the production sheet is `ShareChatSheet` in `lib/ui/v2/app/v2_app_shell.dart`, which composes `ShareSheet` as its creator surface (FEATURE_GAPS C4 resolved) |
| Security (lock, keys, IP guard, SSRF) | Done for the app; see §4 | `lib/core/app_lock.dart`, `server/security/ip_hop.py`, `cloud/packages/browser/src/tools/transfers.ts` |
| Observability | Weak | Crash + diag exist (`lib/core/firebase_service.dart`); no traces, SLOs, or user-visible failure alerting |
| i18n | Missing | English only; 101 `TODO(l10n)` markers in `lib/ui/v2` (FEATURE_GAPS C1) |

**The honest headline:** the product is feature-complete enough for an internal
test, and not yet ready for a public launch. The blockers are operational
(observability, billing products, load proof) plus one real isolation bug
(per-user agent workspace), not a missing architecture.

---

## 2. What breaks first, in order

Scaling to 100 M users is not one problem; it is six, and they fail in this
order. Fix them in this order.

### 2.1 The agent run loop (first at ~1 k concurrent runs)

A run is one long-lived BullMQ job pinned to one worker for its whole life
(`cloud/apps/worker/src/runProcessor.ts`: "One BullMQ job = one run"; `attempts:
1`, retry ladder inside the engine). At 1 k concurrent runs the worker pool
saturates and queue latency explodes.

- **Now:** a run cannot move between workers and cannot resume mid-turn.
- **Fix:** split a run into durable steps — a queue job per model turn, with
  state in Redis/Postgres between turns. A turn that dies resumes from the last
  persisted step instead of restarting.
- **Ceiling today:** roughly the worker count × 2. Measure with
  `cloud/apps/load`.

### 2.2 The WebSocket fan-out (~10 k sockets)

Fan-out already goes through Redis pub/sub: `cloud/apps/gateway/src/ws.ts`
subscribes per session and publishes through the event log
(`cloud/packages/events/src/eventLog.ts`). The cost is the shape of that
subscription: **every subscription holds a dedicated Redis pub/sub connection**
(`ws.ts` "Every subscription holds a dedicated redis pub/sub connection"), and
a connection may hold up to `MAX_SUBSCRIPTIONS_PER_CONNECTION = 64`.

- **Ceiling:** 10 k sockets × up to 64 subscriptions is up to 640 k Redis
  connections — the connection count, not the socket count, is what kills the
  node first.
- **Fix:** one shared subscriber per gateway process with an in-process
  fan-out to sockets, so Redis connections scale with sessions watched, not
  with sockets × subscriptions. Keep gateways stateless behind the load
  balancer; sticky sessions are not required.
- **Also:** the per-connection cap of 64 already exists; keep it and add a
  per-account cap so one account cannot pin a node.

### 2.3 Postgres write amplification (~100 k sessions/day)

This one is mostly **already right** and should not be "fixed" again:

- Streamed deltas are ephemeral. `message_delta` goes to a capped Redis stream
  (`DEFAULT_MAX_LEN = 10_000`, TTL via `OVID_EVENT_STREAM_TTL_S`) through
  `cloud/packages/events/src/eventLog.ts`; there is no per-delta DB write.
- Only the assistant message is appended once per turn
  (`cloud/apps/worker/src/runProcessor.ts` → `messages.append`).

- **Remaining work:** partition `messages` by month at ~100 k sessions/day, and
  give the artifact and memory tables the same treatment — they grow with
  usage, not with users. Do not reintroduce per-delta persistence.

### 2.4 Object storage egress (~1 M artifacts/day)

The data path is already off the gateway for stored objects:

- Artifacts and attachments mint **presigned R2 URLs**
  (`cloud/apps/gateway/src/routes/artifacts.ts` `GET .../url`;
  `cloud/apps/gateway/src/routes/attachments.ts` presigned PUT), with an
  optional signed-token CDN in front (`cloud/apps/gateway/src/routes/artifactCdn.ts`,
  `cloud/deploy/cdn/worker.js`).
- **Remaining egress:** the live browser stream (screencast frames over the
  WebSocket) and any legacy proxied download. Keep signed URLs for everything
  that is a file.
- **Cost lever:** lifecycle rules — screenshots older than 30 days move to
  infrequent access; artifacts follow the user's plan retention.

### 2.5 Model spend (~the real constraint)

This is the binding constraint, not infrastructure. Free users at 50 M tokens
per day, 1.5 B per month (`server/mint/ovid_plans.py` `FREE_DAILY_TOKENS`,
`FREE_MONTHLY_TOKENS`), is a hard cost ceiling per account — but the free USD
allowance (`free_daily_usd = 0.15`) still trips first (FEATURE_GAPS C15).

- **Guardrail already built:** the LiteLLM pre-call hook reserves budget and
  fails closed (`server/mint/litellm_hook/`), and `token_decision` in
  `server/mint/mint.py` enforces the free caps.
- **Add:** a per-model cost dashboard, a daily spend alert per environment, and
  an automatic kill switch that flips a model to a cheaper tier when a provider
  price changes by more than 20 %.
- **Add:** request-level idempotency so a retried turn cannot double-charge.

### 2.6 The database for collaboration

Collab rooms write presence and turn state frequently. Presence is modelled as
an event (`server/collaboration/events.py` `_presence`), not a durable row, but
the app-side projection is device-local and the turn lease is a Postgres row.

- **Fix:** presence belongs in Redis with a TTL, not Postgres. The turn lock
  stays in Postgres (`collab_turns`, `_claim_turn`) because it needs
  durability; presence does not.
- **Also:** the app's collab runtime must be pointed at the server projection
  before any "50 people in one room" claim is made (architecture
  FEATURE_GAPS §13.2).

---

## 3. Architecture that already supports 100 M (keep it)

These choices are correct and should not be revisited:

1. **Per-session isolation by construction — in the database.** A session id is
   the only handle and ownership is checked in repository queries
   (`cloud/packages/db/src/repos.ts`, `cloud/apps/gateway/src/routes/*`).
   **Caveat:** the agent's *filesystem* is per-user, not per-session (see §6);
   fix that before repeating the isolation claim.
2. **Subagent contract.** The 300-token JSON return is what keeps 50 parallel
   workers from blowing the main agent's context. Do not relax it.
3. **Keys never reach the client.** Every account gets a server-side LiteLLM
   key bound to its Firebase uid (`server/mint/mint.py`: `user_id: uid`,
   `metadata.ovid_uid`). Even a reverse-engineered key is that user's own and is
   blocked on IP spread (`server/security/ip_hop.py`).
4. **Ephemeral git credentials.** The token is injected per operation, never in
   `.git/config`, never in argv
   (`cloud/packages/sandbox/src/gitCredential.ts`). Tokens are now resolved
   **per user** from the user's GitHub connector credential, with no
   deployment-wide fallback (`cloud/apps/worker/src/studioGit.ts`
   `createPerUserGithubTokenResolver`, wired in `main.ts`); a missing or
   undecryptable token fails the job instead of borrowing another identity.
5. **Fail-closed abuse controls.** Unresolved IPs fall into a shared bucket, the
   geo resolver raises instead of silently disabling, and the plan gate is
   server-side (`server/security/ip_hop.py`, `cloud/apps/gateway/src/planGate.ts`).
   These are the parts most products get wrong.

---

## 4. Security — what is done and what to add

### 4.1 Edge and platform primitives

| Primitive | State | Evidence |
|---|---|---|
| Cloudflare (edge, TLS, DDoS) | Code expects it; **live rules unverified** | `server/security/ip_hop.py` reads `cf-ipcountry` only from a trusted proxy; `server/mint/mint.py` walks `X-Forwarded-For` from the right |
| R2 object storage | Done, fails loud | `cloud/packages/storage/src/storageEnv.ts` refuses `fs` when `NODE_ENV=production`; `r2Adapter.ts`; presigned GET/PUT |
| FCM push | Done | `cloud/apps/worker/src/notify.ts` (dead-token pruning), `cloud/apps/gateway/src/routes/devices.ts`, `lib/core/background_notifications.dart` |
| App Check | Default `required` | `cloud/apps/gateway/src/env.ts` `OVID_APPCHECK_MODE` |
| IP-hop guard | Done in code; live GeoIP unverified | `server/security/ip_hop.py` (country burst, impossible travel, session block, admin unblock), `server/account/runtime.py` |
| Key issuance | Done | `server/mint/mint.py` — idempotent per-uid key, per-uid creation lock, global new-key breaker |

### 4.2 Done

| Control | Where |
|---|---|
| App lock above the Navigator (covers every route) | `AppLockGate` in `MaterialApp.builder` (`lib/main.dart:479`, `lib/ui/v2/app/app_lock_gate.dart`) |
| PIN: 6 digits, PBKDF2 100 k, escalating lockout, re-auth at 25 failures | `lib/core/app_lock.dart` (`pinLength = 6`, `kdfIterations = 100000`, `lockoutLadder`, `reauthThreshold = 25`) |
| Session id from the bearer token only (header ignored) | `server/security/ip_hop.py` |
| Proxy/geo headers honoured only from a trusted proxy | `server/security/ip_hop.py`, `server/mint/mint.py` |
| Per-user git token; no deployment-wide fallback | `cloud/apps/worker/src/studioGit.ts`, `cloud/apps/worker/src/main.ts` |
| Browser SSRF: every redirect hop re-gated; loopback and metadata blocked | `cloud/packages/browser/src/tools/transfers.ts` |
| Browser/workspace path jail with realpath containment | `cloud/packages/browser/src/tools/transferPolicy.ts` |
| Subagent log filename sanitised, `O_NOFOLLOW`, containment | `cloud/packages/agent-core/src/subagentLog.ts` |
| Purchase verified server-side; tier never taken from the client | `server/billing/api.py`, `server/billing/domain.py` |
| RTDN auth fails closed; replay rejected | `server/billing/api.py` (`verify_push`, OIDC), `server/billing/store.py` |
| Admin uses a dedicated key, not the LiteLLM master key | `server/mint/mint.py` (`OVID_ADMIN_KEY` takes precedence) |
| Account deletion: 24 h grace, server-owned, revocable | `server/account/domain.py` (`GRACE_SECONDS`), `server/account/deletion.py` |
| Delete-account action is now wired end to end | `lib/ui/v2/app/v2_settings_actions.dart` → `FirebaseService.requestAccountDeletion` (the older "v2 delete is a stub" P0 is fixed) |

### 4.3 Add before public launch

1. **Cloudflare WAF + bot management** in front of the gateway, with a rate
   limit rule per IP and per account on `/messages`, `/sessions`, `/mint`.
2. **Rate limits wired.** `server/security/rate_limits.py` implements per-uid
   token buckets with Redis Lua checks, but **nothing outside the helper and
   its tests imports it** (`route_limiter` is only used inside the module). The
   gateway has no limiter of its own. Wire it into account/shares/collab and
   add a gateway equivalent before launch.
3. **Postgres RLS.** No `ROW LEVEL SECURITY` / `CREATE POLICY` exists in
   `cloud/packages/db` or `server/account/schema*.sql`; ownership is
   query-level only.
4. **Play Integrity / App Check enforced in production**, not optional. App
   Check already defaults to `required`; make the Play Integrity provider
   mandatory in the console too.
5. **Certificate pinning actually enabled.** `kCertPinningEnabled` is false and
   `kOvidSpkiPins` is empty (`lib/core/cert_pinning.dart`); either populate the
   pins or delete the claim from the data-safety form.
6. **Refresh-token revocation on account fence.** Finalize deletes the Firebase
   user (`cloud/packages/account/src/adapters.ts` `deleteUser`), which revokes
   refresh tokens, but already-issued ID tokens stay valid until they expire
   (up to 1 h). Publish a uid deny-list to the gateway and mint for the fence
   window.
7. **GitHub token lifetime.** Tokens are per-user now, but they are long-lived
   connector secrets with no automatic refresh; GitHub App installation tokens
   would remove the manual re-auth.
8. **Audit log for privileged actions** — tier changes, bans, exports — written
   to append-only storage, not just the app log.
9. **Dependency and image scanning** in CI, with a fail on a critical CVE.

### 4.4 Never do

- Never put a provider key in the app, even obfuscated.
- Never trust a client-supplied tier, price, or model entitlement.
- Never let an agent install a plugin or MCP from a chat message. Connectors are
  installed from the Connectors screen only.
- Never let a subagent dispatch another subagent.

---

## 5. What to add to the product (ranked by user value per unit of work)

### Tier 1 — closes a loop the user already expects

1. **Studio diff + commit client.** The screen is honest-empty today
   (FEATURE_GAPS A2). Without it Studio stops at "I edited files"; with it the
   user ships.
2. **Live preview producer.** A tunnel plus a frame source turns "Ovid built it"
   into "here it is" (FEATURE_GAPS A1).
3. **Play yearly products + server mapping.** Yearly is code-ready and would
   raise ARPU immediately (FEATURE_GAPS D2).
4. **Notification permission flow at the right moment** (after the first
   answer), which is when a user actually cares.

### Tier 2 — makes it feel finished

5. **Onboarding that teaches by doing** — first chat pre-filled with a real task
   the user picked, instead of an empty box.
6. **A "what Ovid is doing" sheet** from the ⋮ menu: live trajectory, subagent
   count, elapsed time. The data exists; only the surface is missing.
7. **Search across everything** — sessions, artifacts, memory — from one field
   in the sidebar. Inline session search exists; widening it is cheap.
8. **Message actions**: copy, retry, edit-and-resend, branch from here.

### Tier 3 — differentiation

9. **Scheduled agents that report** — a schedule already runs; make the result a
   notification with a summary card, not a silent chat message.
10. **Team projects** — a project with more than one member, shared memory, and
    per-member attribution. The collab primitives already exist.
11. **Voice-first mode** — the composer already records and transcribes; a
    hands-free loop (speak, hear, speak) is the Muse-shaped differentiator.
12. **Model comparison** — send one prompt to two models, show both answers.
    The routing layer supports it; it is a UI feature.

---

## 6. Gaps in the current build (be explicit with users)

### 6.1 P0 — blocks a release claim

| Gap | Consequence | Evidence |
|---|---|---|
| Agent workspace is per **user**, not per session | A prompt in session B can read session A's files; acceptance test "a second session cannot read the first session's files" fails | `cloud/packages/sandbox/src/manager.ts` (`workspaceDir = {join(userRoot, "workspace")}`, `attach(userId)`); `cloud/apps/worker/src/runProcessor.ts` |
| "Delete all data" is local-only but the dialog says "this device **and the cloud**" | A user believes server data is gone; it is not | `lib/ui/v2/app/v2_settings_actions.dart` `deleteAllData` copy; `lib/core/state.dart` `deleteAllData` clears prefs/history/drafts only |
| Monthly subscriptions do not exist in Play | Nothing can be bought in a Play build (only the debug Test Store demo works) | FEATURE_GAPS D1; `lib/core/billing_products.dart` |
| Production track is empty | No public app | FEATURE_GAPS D3 |
| RevenueCat credentials not validated end to end | Purchases may fail at launch | FEATURE_GAPS D4 |
| Release keystore is owner-blocked | Cannot sign a store build | FEATURE_GAPS D6 |
| Free-plan USD allowance vs token cap | `free_daily_usd = 0.15` gates before the 50 M token cap | FEATURE_GAPS C15; `server/mint/ovid_plans.py` |

### 6.2 P1 — a shipped screen is visibly incomplete

| Gap | Consequence | Evidence |
|---|---|---|
| Studio changes/commit | Studio cannot finish a change | FEATURE_GAPS A2 |
| Studio workspace change/sync counts always 0 | The chip lies by omission (always "0") | FEATURE_GAPS A3 |
| Live preview | "Preview" waits forever | FEATURE_GAPS A1 |
| Connector tool manifest empty | Permissions screen lists grants, not tools | FEATURE_GAPS A4 |
| No collab turn queue | "Wait for your turn", no queue position | FEATURE_GAPS A5 |
| Account health has no devices or 2FA | Sections are absent, not disabled | FEATURE_GAPS A6 |
| Browser cannot do history/upload/download/close-tab | Controls removed | FEATURE_GAPS A10 |
| Crash reports row leads nowhere | Consent toggle is unreachable from that row | FEATURE_GAPS A13 |
| Share-fork needs the share backend | Fork only works when collab is configured | FEATURE_GAPS A14 |
| Subagent progress fields not rendered | Generic tool row instead of a live card | FEATURE_GAPS B2 |
| English-only UI | No Hindi despite the picker | FEATURE_GAPS C1 |
| Yearly billing is a product choice, not just a SKU | Yearly shows but cannot sell | FEATURE_GAPS C16, D2 |

### 6.3 P2 — a designed convenience is absent

Connector per-tool permissions (A4), response-wait auto-extend (A7), payment
history (A8), artifact version history (A9, B3), avatar upload (B4),
per-schedule notification override (B6), memory accuracy
card (C6), schedule summary card (C8),
run stat tiles (C9), collab priority control (C10), top-bar notification/avatar
entry points (C11), message edit/branch/regenerate (C12), live model
latency/price (C13), usage request/image counters (C17), usage model chart
(C18). Full list with file citations: `docs/audit/FEATURE_GAPS.md`.

---

## 7. Launch sequence

**Phase 0 — internal (now).** Internal testing track, 4 testers. Purchases are
either the debug/profile RevenueCat Test Store demo or a Play license-tester
purchase; no Play subscription exists yet. Goal: crash-free sessions above
99 %. This is the only phase the repo supports today.

**Phase 1 — closed beta, 500 users.** Fix the per-session workspace (§6.1), add
WAF, wire rate limits, enable App Check, wire crash-reporting dashboards, run a
50-user collab soak. Goal: p95 first token under 3 s, no cross-tenant read in an
audit.

**Phase 2 — open beta, 10 k users.** Split the run loop into durable steps,
move presence to Redis, finish the CDN/presigned path for every object type.
Goal: model spend per paying user inside plan margin.

**Phase 3 — public, 100 k.** Shared-subscriber WebSocket fan-out, partitioned
messages, per-model spend alerts. Goal: 99.9 % availability, queue wait under
10 s at peak.

**Phase 4 — 1 M+.** Only after the above is boring. At that point the work is
cost engineering and support tooling, not architecture.

Each phase has one gate. Do not start the next phase while the gate is red.
