# Ovid Cloud — Managed LLM Gateway (production design)

> Status: DESIGN. Scope: give Ovid users server-provided models (custom base
> URL + model IDs), a per-user key minted at signup, a keyless "Auto" tier,
> IP/spam/abuse protection, subscription-tiered quotas, and an owner admin
> dashboard — without ever shipping a provider secret to the client.

## 0. Honest scale correction (read first)

The brief says "20 million people may use this at once" and "host LiteLLM on
this one VPS". These two cannot both be true. One VPS (the current box is 12
vCPU / 30 GB) handles **low-thousands of concurrent in-flight requests**, not
20 million. 20M *concurrent* is hyperscale (bigger than most public AI apps at
peak). The design below is built to **scale horizontally to that ceiling** —
but the single VPS is the **staging / first-launch tier**, and production is a
documented scale-out path, not one machine.

Two numbers that matter more than the VPS:

1. **Provider rate limits.** OpenAI/Anthropic enforce per-account TPM/RPM.
   20M concurrent requests would be rejected by the provider long before any
   VPS is stressed. Real hyperscale requires multiple provider accounts +
   load-balanced key pools — LiteLLM supports this, but it is a provider
   commercial problem, not an infra one.
2. **Money.** At 20M active users, even $0.50/user/month of tokens is
   **$10M/month** of provider spend. The quota engine is what stops this from
   being an open-ended bill; it is the single most important component here.

So the design has two deployment profiles, same code:

- **Profile A — Staging / launch (this VPS):** one LiteLLM + one Postgres +
  Caddy, Firebase key-mint function. Handles the first thousands of users.
- **Profile B — Production scale-out:** N stateless LiteLLM behind a load
  balancer, managed HA Postgres, Redis for shared rate-limit state, provider
  key pools, multi-region. Documented, not built on day one.

## 0b. Owner decisions (locked 2026-10-01)

- **Auth:** Google sign-in only (Firebase Auth). **Login is MANDATORY — no app
  use without logging in. Anonymous/keyless Auto mode is REMOVED.** Every user
  is a real Google account → one per-user key → one tier.
- **Models (owner-configured):** the owner adds the models by hand in the
  LiteLLM dashboard:
  - **Auto mode (DEFAULT in Ovid):** 2–3 models, each with its own base URL +
    key, exposed to the client only as the alias `auto`.
  - **Manual mode:** 5–8 models, each with its own base URL + key, exposed as
    owner-named model IDs the user can pick.
  - Every real base URL/key stays server-side; the client sees only aliases.
  - Ovid fetches the model list live from `/v1/models`, so dashboard additions
    appear in the app with no update.

## 0c. Plans, limits & free credit (locked 2026-10-01)

Four tiers. Limits are enforced by LiteLLM key budgets; the daily window resets
every 24h (opencode-style). Payment CODE is skipped for now — only the tier
structure, limits, and the free-credit engine are built; billing wires in later
as a webhook → `/key/update`.

| Tier | Daily limit | Monthly ceiling | Price (later) | Reset |
|------|-------------|-----------------|---------------|-------|
| **Free** (default) | base daily `X` | **$10 / month hard cap** | ₹0 | 24h daily; $10 monthly |
| **5x**  | `5·X`  | — | ₹499 | 24h |
| **10x** | `10·X` | — | ₹899 | 24h |
| **20x** | `20·X` | — | ₹1699 | 24h |

Rules:
- **Free tier:** a daily free limit that resets every 24h, PLUS a hard
  **$10-per-calendar-month** ceiling. When the month's free spend reaches $10,
  free use stops until the next month (or until the user buys a plan). The
  $10/month is the owner-funded free allowance per user.
- **Paid tiers (5x/10x/20x):** multiply the daily limit by 5/10/20, 24h reset,
  like opencode's daily plans. Prices ₹499/₹899/₹1699 are recorded for later.
- **Zen-style free UX:** free-tier users see **no usage numbers at all** — the
  $10/month free allowance is never shown (opencode Zen behaviour). Usage-screen
  display rules:
  - **Free tier (Ovid Cloud, no plan):** hide usage entirely. No $10, no bar.
  - **Paid plan (Ovid Cloud 5x/10x/20x):** show the plan's usage + remaining.
  - **Custom provider (user's own key):** show usage as today (unchanged —
    the user brought their own key, so their own spend is theirs to see).
- **Globally + per-user:** tier defaults live in `tiers/{tierId}` (one global
  source of truth the admin edits once); each user's effective limits live in
  `users/{uid}` and can be **overridden per-user by the admin** (bump one
  user's limit without touching the global tier).

### How the limits map to LiteLLM + Redis
- Daily limit → the user's virtual key `max_budget` with `budget_duration: 24h`
  (LiteLLM resets it each day).
- Monthly $10 free cap → a Redis counter `freecap:{uid}:{YYYY-MM}` incremented
  on each free-tier spend; when it reaches $10 the mint/edge check marks the
  key spent for the month (durable mirror in `users/{uid}.monthFreeSpentUsd`).
- Tier change (admin or future purchase) → `/key/update` with the new budget;
  instant, no app redeploy.
- Per-user admin override → `users/{uid}.limitOverrideUsd`; the edge/mint
  prefers it over the tier default.

## 1. Goals / non-goals

**Goals**
- Users see "Ovid Cloud" models (names/IDs the owner controls); the real
  provider + base URL is server-side only.
- Every signup silently mints a per-user virtual key; stored in device secure
  storage, never hardcoded, never shared.
- A keyless "Auto" tier for anonymous users (Firebase anonymous auth) with its
  own cheap model routing and tight budget.
- Per-IP and per-key rate limits; abuse/spam resistant.
- Subscription tiers change a key's budget via one API call; no app redeploy.
- Owner admin dashboard: per-user spend, quota, tier, abuse signals.
- Zero provider secrets in the APK (reverse-engineer-safe by construction).

**Non-goals**
- Not building our own quota/billing engine — LiteLLM owns spend + budgets.
- Not promising "unhackable". The guarantee is: a leaked user key wastes only
  that user's own quota; master keys never leave the server.
- Not 20M concurrent on one box (see §0).

## 2. Architecture

> **No Blaze.** Key-minting runs on the VPS (next to LiteLLM), NOT in a
> Firebase Cloud Function. Firebase stays on the free Spark plan and is used
> only for Google Auth + App Check (both free). User/tier/free-cap data lives
> in the VPS Postgres/Redis, not Firestore.

```
Ovid app (Android)
  │  Firebase Auth (Google) — MANDATORY login + App Check (Play Integrity)
  │  → ID token + App Check token on EVERY mint/API request
  ▼
VPS "mint" verifier service (same box as LiteLLM)
  │  verifies Google ID token (Google public JWKS) + App Check token
  │  (Firebase public JWKS) — standard JWT verification, no Blaze/Admin billing
  │  mints/returns the user's LiteLLM virtual key, applies tier + $10/mo free cap
  ▼
LiteLLM Proxy (same box) — key→user→tier→budget check → provider → spend log
  ▼
Provider base URLs + keys (encrypted in LiteLLM Postgres; added via dashboard)
  ▼  real upstream models
```

Trust boundaries:
- **APK**: holds only the user's own virtual key + Firebase tokens. Leaking any
  of these harms only that user's own quota.
- **VPS mint + gateway**: holds the LiteLLM admin key (to mint) and the
  provider master keys (encrypted in Postgres). Isolated, locked-down box.
- **Firebase**: identity only (Google Auth + App Check). No secrets, no Blaze.

## 3. Why LiteLLM (and what we build around it)

LiteLLM gives us ready-made: OpenAI-compatible endpoint, virtual keys with
`max_budget` + `budget_duration` + `rpm_limit` + `tpm_limit`, spend tracking
in Postgres, model routing/aliasing/fallbacks, provider key load-balancing,
and an admin UI. We build only three small pieces:

1. **Key-mint / tier-sync Cloud Function** (Firebase Auth + App Check verify →
   LiteLLM `/key/generate` or `/key/update`).
2. **Subscription webhook** (Play Billing / RevenueCat → budget update).
3. **Ovid app wiring** — an "Ovid Cloud" provider entry + silent key fetch.

## 4. Data model

**Firestore (business/identity state only — spend lives in LiteLLM Postgres):**
- `users/{uid}`: `{ tier, litellmKeyId, budgetUsd, budgetWindow, createdAt,
  subscriptionId?, subscriptionExpiry?, banned:bool }`
- `tiers/{tierId}`: `{ budgetUsd, budgetWindow, rpm, tpm, models:[alias…] }`
- `abuse/{uid}`: `{ ipHits, lastFlaggedAt, strikes }` (anti-spam signals)

**LiteLLM Postgres (authoritative spend):** virtual keys, per-key spend,
budgets, request logs. Backed up daily, off-box.

## 5. Request lifecycle (per call)

1. App sends `/v1/chat/completions`, `Authorization: Bearer <user key>`, plus
   `X-Firebase-AppCheck` and `X-Firebase-Auth` headers (checked at the edge).
2. Caddy terminates TLS, forwards to LiteLLM.
3. LiteLLM resolves key → user_id, tier, budget, rpm/tpm.
4. Budget/limit check **before** the provider call → 429 on exceed (no spend).
5. Route by model alias (`auto` → tier-appropriate real model).
6. Provider responds; actual token cost logged to that key's spend.
7. Dashboard reflects live spend/quota.

## 6. Auto mode (keyless, secured)

- App uses Firebase **anonymous auth** → still a real UID, still App Check
  gated. The key-mint function issues an invisible, tight-budget key
  (`auto`, cheap model, e.g. $0.50 / 30d, low rpm).
- Model choice is **server-side** (`auto` alias). Client never names the
  real model → no misuse surface.
- Anonymous→signup migration carries usage forward by UID.

## 7. Abuse / spam / reverse-engineering defense (layered)

1. **App Check (Play Integrity):** only the genuine signed app passes. Blocks
   cloned/repacked APKs and raw curl attacks at the function + gateway edge.
2. **Per-IP rate limit** at Caddy (and/or Cloud Armor in Profile B): sliding
   window; anonymous-farming defense.
3. **Per-key rpm/tpm + budget** in LiteLLM: worst case for a leaked key is its
   own quota, never a bill blow-up.
4. **Global `max_parallel_requests`** cap per key.
5. **Firestore `banned`/`strikes`:** function refuses to mint/serve for a
   flagged UID.
6. **No provider secret in the client** → reverse engineering yields only a
   quota-limited user key.
7. **Billing alerts + provider spend caps** as the final backstop.

## 7b. Key-assignment, cloud usage & ban rules (locked 2026-10-01)

- **Key only after a verified Google sign-in.** The VPS mint verifier checks
  the Firebase ID token against Google's public keys before issuing anything.
  A reverse engineer cannot reach `/mint` without a real signed-in token, and
  even then receives only THEIR OWN quota-limited virtual key — never a master
  key, never another user's key.
- **Usage is cloud-based, not app-side.** Spend/limits are read from the server
  (`/usage` → LiteLLM spend for that user's key). Reasons:
  - Same numbers across all of a user's devices (login anywhere, same usage).
  - A reverse engineer cannot fake/inflate usage — the device never computes it.
  - If a key is somehow extracted, it is still only that user's own key, capped
    by that user's own server-side budget.
- **Spam-signup defense (per IP):** `enforce_ip_signup_quota` caps NEW free
  accounts per IP per rolling window (`MAX_ACCOUNTS_PER_IP`, default 3 / 24h).
  Returning users on the same IP are never throttled (set-membership check).
  Crossing the cap records an abuse strike.
- **Abuse strikes → auto-ban:** `abuse:ip:*` / `abuse:uid:*` counters; crossing
  `ABUSE_STRIKE_LIMIT` within the window writes a TTL `ban:ip:*` or a durable
  `user:{uid}:banned`. The mint edge checks bans first and refuses (403).
- **Admin ban/unban/tier controls** (master-key protected): `/admin/ban`,
  `/admin/unban`, `/admin/set-tier` — the admin can ban a uid or IP, lift a
  ban, change one user's tier, and set per-user `dailyUsd` / `monthlyCapUsd`
  overrides without touching the global tier.

## 7b2. Base×multiplier budgets, caps, per-model pricing & plan-spoof defense

- **Base × multiplier, per user (not shared):** admin sets ONE base daily
  budget; each tier's budget is `base × {1,5,10,20}`, applied to each user's OWN
  key independently (never a shared pool). Base $10 → free $10, 5x $50, 10x
  $100, 20x $200 — each user, their own.
- **24h cap is FREE-only.** Paid tiers (5x/10x/20x) have **no 24h wall** — they
  draw a MONTHLY budget pool (base × multiplier × ~30); only free users reset
  every 24h.
- **Base is admin-editable at runtime** (Redis `config:base_daily_usd`);
  `/admin/set-base-budget {reapply:true}` re-applies to EVERY existing user at
  once — the thing LiteLLM "Default User Settings" cannot do (new users only).
- **Admin console** `/admin/ui` (mint service) — reachable ONLY via SSH tunnel
  to 127.0.0.1:8090 (Caddy never routes `/admin` publicly → internet 404).
- **Plan-spoofing is impossible:** tier is NEVER sent by the client. `/mint` and
  `/usage` read it server-side from Redis (`user:{uid}:tier`), changed only by
  `/admin/set-tier` (master key) or a future payment webhook. No client tier
  input exists to forge; a leaked key spends only its own tier budget.
- **Per-model pricing** set in LiteLLM per deployment
  (`input_cost_per_token` / `output_cost_per_token`); spend is metered by real
  token cost. The usage screen shows each available model's remaining-% of the
  user's monthly budget pool: a costly model drains the pool faster (every
  model's remaining-% drops together); a cheap model leaves more % for all.

## 7a. Redis — the backbone for high traffic + spam (FB/IG-style)

Redis is NOT optional at scale and NOT just a LiteLLM add-on here. It is the
shared, in-memory brain that lets many stateless gateway instances enforce one
truth and absorb spam without touching Postgres or the provider. Every big
consumer app (FB/IG pattern) uses this layering; we mirror it.

**Why:** rate limits, dedupe, and hot-config checks must be consistent across
N gateway instances and must happen in sub-millisecond memory, not a DB round
trip. Postgres is for durable spend; Redis is for the per-request hot path.

Six concrete Redis uses, each defeating a specific traffic/spam problem:

1. **Distributed rate limiting (sliding-window / token-bucket).**
   Keys: `rl:ip:{ip}:{window}`, `rl:key:{virtualKey}:{window}`,
   `rl:uid:{uid}:{window}`. Atomic `INCR` + `EXPIRE` (or a Lua token-bucket
   script for exactness). This is the primary spam throttle and works
   identically across every gateway instance — one global limit, not N local
   ones. LiteLLM already uses Redis for its own rpm/tpm when `REDIS_URL` is
   set; we add the IP/uid layers in the edge verifier.

2. **Response cache (prompt → completion).** Key:
   `cache:{model}:{sha256(normalized messages + params)}`. Identical requests
   (very common in spam floods and in retries) return the cached answer in
   memory with **zero provider cost**. TTL by model (e.g. 5–60 min). LiteLLM
   has native Redis caching — enable `cache: true, type: redis`. This is the
   single biggest lever against both cost and provider rate-limit pressure
   under a flood.

3. **Idempotency / dedupe.** Key: `idem:{clientRequestId}` with short TTL +
   `SET NX`. A client retry or a spam replay of the same request id is served
   once, not N times. Stops duplicate-submit storms.

4. **Hot identity/tier cache.** Key: `user:{uid}` (tier, budget, banned),
   short TTL, write-through from the mint/webhook functions. Avoids a Firestore
   read on every request; a `banned` flag flips in Redis instantly across all
   instances (instant kill-switch for an abuser).

5. **Abuse counters + auto-ban.** Keys: `abuse:ip:{ip}`, `abuse:uid:{uid}`
   incremented on 429s / malformed / flagged requests; when a threshold trips
   within a window, write a `ban:{ip|uid}` key with TTL (temporary) and
   escalate to a Firestore `strike` (durable). The edge verifier checks
   `ban:*` first → cheap, instant shield during an active attack.

6. **Circuit-breaker / provider-health flags.** Key: `cb:provider:{name}`.
   When a provider starts failing or rate-limiting, set a short-TTL flag so all
   instances route to fallbacks immediately instead of each discovering the
   failure independently.

**Topology & resilience (so Redis itself is not the weak point):**
- Profile A (VPS): single Redis container, `appendonly yes`, `maxmemory` set
  with `allkeys-lru` eviction so a flood evicts cache, never OOM-kills.
- Profile B (scale): managed Redis with HA (primary + replica, automatic
  failover) or Redis Cluster for sharding at very high key volume.
- **Fail-open vs fail-closed per use:** if Redis is unreachable, rate limiting
  fails **closed-ish** (fall back to conservative per-instance local limits so
  an attacker cannot bypass by killing Redis), while the response cache fails
  **open** (just a cache miss → provider call). Never let a Redis outage either
  open the floodgates or hard-down the whole service.
- Separate logical DBs/prefixes for cache vs limits vs identity so a cache
  flush never wipes rate-limit or ban state.

**What this buys under 20M-scale spam:** a flood of identical/replayed
requests is absorbed by the response cache + idempotency (no provider cost),
abusive IPs/UIDs are banned in-memory across all instances in milliseconds,
and genuine users keep flowing because limits are per-identity, not global.

## 8. Subscriptions

Play Billing (or RevenueCat) purchase → webhook (Cloud Function) verifies the
receipt → updates `users/{uid}.tier` and calls LiteLLM `/key/update` with the
new budget/limits. Tier change is instant; no app redeploy.

## 9. Admin dashboard

- LiteLLM admin UI (built-in): per-key/user spend, logs, key management.
- Small Firebase Hosting admin page for business metrics (signups, tier
  distribution, abuse strikes) via Firestore aggregates + Cloud Logging.
- Protected by Firebase Auth custom claim `admin:true`.

## 10. Deployment — Profile A (this VPS, staging/launch)

`docker-compose`: `litellm` (:4000, internal), `postgres` (internal only),
`caddy` (:443, Let's Encrypt → :4000). Firewall: 443 + SSH key-only. Provider
keys in env/Secret Manager, never in git. Daily off-box Postgres backup.
Health check + alert on `/health`.

## 11. Deployment — Profile B (production scale-out)

- N stateless LiteLLM instances behind a load balancer.
- Managed HA Postgres (Cloud SQL / Neon) for spend durability.
- Redis for cross-instance rate-limit + parallel-request state.
- Provider **key pools** (multiple accounts) load-balanced to beat provider
  TPM/RPM ceilings.
- Multi-region if latency/availability demands it.
- Autoscaling on request depth. This is where the 20M ceiling is actually met.

## 12. Ovid app changes (minimal, fits existing provider abstraction)

- New seeded provider "Ovid Cloud": `api_format: openai`, baseURL = gateway,
  models = `auto` + tier models (fetched from `/v1/models`).
- Auth: on first launch, call the key-mint function; store the returned
  virtual key in `flutter_secure_storage`; attach it + Firebase tokens on
  requests.
- Existing sandbox/tools/subagents/hooks untouched.

## 13. Open questions / risks

- Provider commercial limits at scale (key pools, rate-limit negotiations).
- Cost ceiling discipline — free/anon tier budgets must stay tiny.
- App Check cannot stop a rooted device fully; it raises cost of abuse, not to
  infinity. IP + per-key limits are the real throttle.
- Spend data = money data: Postgres backup/HA is non-negotiable before launch.
