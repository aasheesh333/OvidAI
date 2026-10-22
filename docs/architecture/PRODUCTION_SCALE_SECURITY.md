# Ovid Si — production readiness, scale and security

An honest assessment of what is built, what breaks first at scale, and what to
do in what order. No claim here is aspirational: every "done" line maps to code
in this repo, and every gap names the file that would need to change.

---

## 1. Where the product actually stands

| Area | State | Evidence |
|---|---|---|
| Chat, sessions, isolation | Done | `_submit` → facade → projection; 50-screen audit; `shell_chat_send_test` |
| Subagents (50 cap, no nesting, 8 h, 300-token JSON) | Done | `agent-core/subagents.ts`, `subagentSummary.ts`; 767 tests |
| Studio (clone, branch, sync, credential helper) | Mostly | `studioGit.ts`; no app-side diff/commit client |
| Browser (agent tabs, 3–5 fps, takeover, transfers) | Done | `packages/browser`; SSRF and path jails closed |
| Plans, caps, metering | Done | `ovid_plans.py`, `planGate.ts`, LiteLLM hook |
| Billing | Partial | RevenueCat wired; yearly SKUs and Play subscriptions not created |
| Memory (session `.md`, global, project) | Done | `memory` screens; per-entry forget wired |
| Sharing (collab 50, read-only fork) | Done | `share_sheet`; server enforces cap and turn lock |
| Security (lock, keys, IP guard, SSRF) | Done for the app; see §4 | app lock covers every route; keys never leave the server |
| Observability | Weak | crash + diag exist; no traces, no SLOs, no alerting on user-visible failure |
| i18n | Missing | English only; language picker is a voice preference |

**The honest headline:** the product is feature-complete enough for an internal
test, and not yet ready for a public launch. The blockers are operational
(observability, billing products, load proof), not architectural.

---

## 2. What breaks first, in order

Scaling to 100 M users is not one problem; it is six, and they fail in this
order. Fix them in this order.

### 2.1 The agent run loop (first at ~1 k concurrent runs)

Today a run is a long-lived process holding a model stream. At 1 k concurrent
runs the worker pool saturates and queue latency explodes.

- **Now:** runs are pinned to a worker for their whole life.
- **Fix:** split a run into durable steps — a queue job per model turn, with
  state in Redis/Postgres between turns. A turn that dies resumes from the last
  persisted step instead of restarting.
- **Ceiling today:** roughly the worker count × 2. Measure with
  `cloud/apps/load`.

### 2.2 The WebSocket fan-out (~10 k sockets)

Every open app holds a socket. A single gateway node holds ~10 k before file
descriptors and memory become the limit.

- **Fix:** move fan-out to a dedicated pub/sub layer (Redis Streams or NATS) and
  make gateway nodes stateless so they scale horizontally behind the load
  balancer. Sticky sessions are not required once subscriptions live in pub/sub.
- **Also:** cap subscriptions per connection and drop the oldest, or one client
  with 200 open sessions pins a node.

### 2.3 Postgres write amplification (~100 k sessions/day)

Every token event is currently folded and could be persisted. At 100 k sessions
a day that is billions of rows.

- **Fix:** persist only message boundaries (start, delta coalesced every 250 ms,
  end) and keep the token stream ephemeral. Partition `messages` by month.
- **Also:** the artifact and memory tables need the same treatment; both grow
  with usage, not with users.

### 2.4 Object storage egress (~1 M artifacts/day)

Screenshots, downloads and artifacts all pass through the gateway today.

- **Fix:** signed URLs straight to R2, never proxied. The gateway should mint a
  URL and get out of the data path.
- **Cost lever:** lifecycle rules — screenshots older than 30 days move to
  infrequent access; artifacts follow the user's plan retention.

### 2.5 Model spend (~the real constraint)

This is the binding constraint, not infrastructure. Free users at 50 M tokens
per day, 1.5 B per month, is a hard cost ceiling per account.

- **Guardrail already built:** the LiteLLM pre-call hook reserves budget and
  fails closed. Keep it.
- **Add:** a per-model cost dashboard, a daily spend alert per environment, and
  an automatic kill switch that flips a model to a cheaper tier when a provider
  price changes by more than 20 %.
- **Add:** request-level idempotency so a retried turn cannot double-charge.

### 2.6 The database for collaboration

Collab rooms write presence and turn state frequently.

- **Fix:** presence belongs in Redis with a TTL, not Postgres. The turn lock
  stays in Postgres because it needs durability; presence does not.

---

## 3. Architecture that already supports 100 M (keep it)

These choices are correct and should not be revisited:

1. **Per-session isolation by construction.** A session id is the only handle;
   there is no cross-session read path without an explicit `@`. This is why
   collab and sharing could be added without weakening anything.
2. **Subagent contract.** The 300-token JSON return is what keeps 50 parallel
   workers from blowing the main agent's context. Do not relax it.
3. **Keys never reach the client.** Every user has a server-side LiteLLM key,
   bound to their account hash. Even a reverse-engineered key is the user's own
   and is blocked on IP spread.
4. **Ephemeral git credentials.** The token is injected per operation, never in
   `.git/config`, never in argv. This survives an agent that runs arbitrary
   commands.
5. **Fail-closed abuse controls.** Unresolved IPs fall into a shared bucket, the
   geo resolver raises instead of silently disabling, and the plan gate is
   server-side. These are the parts most products get wrong.

---

## 4. Security — what is done and what to add

### Done

| Control | Where |
|---|---|
| App lock above the Navigator (covers every route) | `AppLockGate` in `MaterialApp.builder` |
| PIN: 6 digits, PBKDF2 100 k, escalating lockout, re-auth at 25 failures | `app_lock.dart` |
| Session id from the bearer token only (header ignored) | `ip_hop.py` |
| Proxy headers honoured only from a trusted proxy | `ip_hop.py`, `mint.py` |
| Per-user git token; host allowlist; remote re-derived server-side | `studioGit.ts` |
| Browser SSRF: every redirect hop re-gated; loopback and metadata blocked | `transfers.ts`, `pool.ts` |
| Browser/workspace path jail with realpath containment | `transferPolicy.ts` |
| Subagent log filename sanitised, `O_NOFOLLOW`, containment | `subagentLog.ts` |
| Purchase verified server-side; tier never taken from the client | `billing/api.py` |
| RTDN auth fails closed; replay rejected | `billing/store.py` |
| Admin uses a dedicated key, not the LiteLLM master key | `mint.py` |
| Account deletion: 24 h grace, server-owned, revocable | `account/domain.py` |

### Add before public launch

1. **Cloudflare WAF + bot management** in front of the gateway, with a rate
   limit rule per IP and per account on `/messages`, `/sessions`, `/mint`.
2. **Play Integrity / App Check required in production**, not optional. A stolen
   ID token should not be enough to drive the API.
3. **Certificate pinning actually enabled.** Today `kCertPinningEnabled` is
   false and the pin table is empty; either populate it or delete the claim from
   the data-safety form.
4. **Refresh-token revocation on account fence.** Deletion currently waits for
   token expiry; publish a uid deny-list to the gateway and mint.
5. **Secret rotation.** One deployment PAT serves all git jobs and is never
   rotated. Move to short-lived installation tokens.
6. **Audit log for privileged actions** — tier changes, bans, exports — written
   to append-only storage, not just the app log.
7. **Dependency and image scanning** in CI, with a fail on a critical CVE.

### Never do

- Never put a provider key in the app, even obfuscated.
- Never trust a client-supplied tier, price, or model entitlement.
- Never let an agent install a plugin or MCP from a chat message. Connectors are
  installed from the Connectors screen only.
- Never let a subagent dispatch another subagent.

---

## 5. What to add to the product (ranked by user value per unit of work)

### Tier 1 — closes a loop the user already expects

1. **Studio diff + commit client.** The screen is honest-empty today. Without
   it Studio stops at "I edited files"; with it the user ships.
2. **Live preview producer.** A tunnel plus a frame source turns "Ovid built it"
   into "here it is".
3. **Play yearly products + server mapping.** Yearly is code-ready and would
   raise ARPU immediately.
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

| Gap | User-visible consequence |
|---|---|
| Studio changes/commit | Studio cannot finish a change |
| Live preview | "Preview" waits forever |
| Yearly billing | Yearly shows but buys monthly — guarded, but the feature is off |
| Account health devices/2FA | Sections are absent |
| Connector per-tool permissions | Hidden until a tool manifest exists |
| i18n | English only |
| Collab turn queue | "Wait for your turn", no queue position |
| Free-tier cost exposure | 50 M tokens/day is generous; watch spend per cohort |

---

## 7. Launch sequence

**Phase 0 — internal (now).** Internal testing track, 4 testers, Test Store
billing. Goal: crash-free sessions above 99 %.

**Phase 1 — closed beta, 500 users.** Add WAF, enable App Check, wire crash
reporting dashboards, run a 50-user collab soak. Goal: p95 first token under
3 s, no cross-tenant read in an audit.

**Phase 2 — open beta, 10 k users.** Split the run loop into durable steps,
move presence to Redis, put signed URLs in front of R2. Goal: model spend per
paying user inside plan margin.

**Phase 3 — public, 100 k.** Stateless gateways behind pub/sub, partitioned
messages, per-model spend alerts. Goal: 99.9 % availability, queue wait under
10 s at peak.

**Phase 4 — 1 M+.** Only after the above is boring. At that point the work is
cost engineering and support tooling, not architecture.

Each phase has one gate. Do not start the next phase while the gate is red.
