# Ovid Cloud Gateway — implementation plan

> Spec: `docs/superpowers/specs/2026-10-01-ovid-cloud-gateway-design.md`
> Decisions locked: Google + anonymous auth only; subscriptions skipped;
> owner hand-configures 2–3 Auto models + 5–8 manual models, each with its own
> base URL + key, all server-side.

## Global constraints
- No provider secret, base URL, or admin key ever ships in the APK.
- Every gateway + function request requires a valid Firebase ID token AND an
  App Check token; failing either = reject before any provider call.
- Spend is authoritative in LiteLLM Postgres; Firestore holds only identity +
  tier + abuse signals.
- Each task ends with a concrete verification (curl / test / dashboard check).
- The single VPS is the staging/launch tier (Profile A). Nothing in the code
  assumes one box — Postgres URL, Redis URL, provider keys are all env-driven
  so Profile B scale-out is config, not a rewrite.

---

## Phase 1 — Gateway on the VPS (Profile A)

### Task 1.1 — Docker compose skeleton
- `docker-compose.yml`: services `litellm` (:4000, bound to 127.0.0.1),
  `postgres` (internal network only, no published port), `caddy` (:443).
- `.env` (git-ignored): `LITELLM_MASTER_KEY`, `DATABASE_URL`,
  `UI_USERNAME`/`UI_PASSWORD`, provider keys referenced by config.
- Verify: `docker compose up -d` → `curl -s localhost:4000/health` returns ok.

### Task 1.2 — LiteLLM `config.yaml` (owner model wiring)
- `model_list`: one entry per real model. Each entry = owner model ID +
  `litellm_params.model` + `api_base` (the per-model base URL) + `api_key`
  (env ref). Example skeleton (owner fills real values):
  ```yaml
  model_list:
    # ── Auto pool (hidden behind ovid-auto) ──
    - model_name: ovid-auto
      litellm_params: { model: openai/<real1>, api_base: <url1>, api_key: os.environ/AUTO1_KEY }
    - model_name: ovid-auto
      litellm_params: { model: openai/<real2>, api_base: <url2>, api_key: os.environ/AUTO2_KEY }
    # ── Manual models (owner-named, user-pickable) ──
    - model_name: ovid-pro-1
      litellm_params: { model: openai/<realA>, api_base: <urlA>, api_key: os.environ/MAN_A_KEY }
    # … up to 5–8 …
  router_settings:
    routing_strategy: simple-shuffle   # ovid-auto load-balances its pool
    num_retries: 2
    fallbacks: [{ ovid-auto: [ovid-pro-1] }]
  general_settings:
    master_key: os.environ/LITELLM_MASTER_KEY
    database_url: os.environ/DATABASE_URL
  ```
- Verify: `curl /v1/models` lists `ovid-auto` + manual IDs ONLY (no base URLs
  leaked); a direct `ovid-auto` completion returns a response.

### Task 1.3 — Caddy TLS + edge auth gate
- Caddyfile: domain → reverse_proxy 127.0.0.1:4000; automatic HTTPS.
- Edge check (Caddy `forward_auth` to a tiny verifier, or a LiteLLM
  pre-call hook) that rejects requests missing a valid App Check header.
- Verify: HTTP→HTTPS redirect works; a request without App Check header 403s.

### Task 1.4 — Per-IP rate limit + firewall
- Caddy rate_limit (or `ufw` + fail2ban) sliding window per IP.
- Firewall: allow 443 + SSH key-only; Postgres never exposed.
- Verify: a burst past the limit returns 429; Postgres port closed from
  outside.

### Task 1.4b — Redis: caching + distributed limits + anti-spam (FB/IG-style)
> Spec §7a is the authority. Redis is the hot-path brain; Postgres stays for
> durable spend only.
- Add `redis` service to compose: `appendonly yes`, `maxmemory` + policy
  `allkeys-lru` (a flood evicts cache, never OOMs), bound to the internal
  network only. Separate logical DBs / key prefixes: `cache:*`, `rl:*`,
  `user:*`, `abuse:*`, `ban:*`, `cb:*` so a cache flush never wipes limits.
- Point LiteLLM at Redis: `REDIS_URL` env + `cache: true, type: redis` so
  (a) native rpm/tpm limits are shared across all gateway instances and
  (b) the prompt→completion response cache is on (TTL per model).
- Edge verifier adds the extra layers LiteLLM does not own:
  - distributed sliding-window / token-bucket on `rl:ip:*`, `rl:uid:*`
    (atomic INCR+EXPIRE or a Lua token-bucket script);
  - idempotency `SET NX` on `idem:{clientRequestId}` (dedupe retries/replays);
  - hot identity cache `user:{uid}` (tier/budget/banned, short TTL,
    write-through from mint/webhook) → no Firestore read per request;
  - abuse counters `abuse:ip|uid:*` → threshold trips a TTL `ban:*` key +
    a durable Firestore strike; verifier checks `ban:*` first;
  - provider circuit-breaker flag `cb:provider:{name}` for instant fallback.
- Fail modes (critical): if Redis is down, rate limiting falls back to
  conservative per-instance LOCAL limits (fail-closed-ish — an attacker must
  not bypass by killing Redis), while the response cache fails OPEN (cache
  miss → provider). Never let a Redis outage open the floodgates or hard-down
  the service.
- Verify:
  1. two gateway instances sharing one Redis enforce ONE global per-key limit
     (hit the limit via instance A, instance B also 429s);
  2. an identical repeated prompt returns from cache with no provider call
     (check LiteLLM logs show a cache hit, spend unchanged);
  3. a replayed `clientRequestId` is served once;
  4. tripping the abuse counter writes a `ban:*` key and the next request from
     that IP/UID is refused in-memory;
  5. killing Redis → rate limiting still enforces (local fallback), cache
     degrades to misses, service stays up.

### Task 1.5 — Backups + health alerting
- Daily `pg_dump` to off-box storage; retention policy.
- Uptime check hitting `/health`; alert on failure.
- Verify: a restore from backup into a scratch DB succeeds.

---

## Phase 2 — Firebase (Blaze) key-mint + identity

### Task 2.1 — Firebase project wiring
- Enable Auth (Google provider + Anonymous), App Check (Play Integrity),
  Firestore, Cloud Functions (Blaze).
- Firestore security rules: a user can read only their own `users/{uid}`;
  writes are function-only.
- Verify: rules unit test — cross-UID read denied.

### Task 2.2 — Key-mint Cloud Function (`mintKey`)
- HTTPS callable. Verifies ID token + App Check. On first call for a UID:
  calls LiteLLM `/key/generate` with `user_id=uid`, tier budget/limits from
  `tiers/{tier}`, stores `litellmKeyId` in `users/{uid}`, returns the virtual
  key. On later calls: returns the existing key (never a new one unless
  rotated).
- Anonymous UID → mints the `ovid-auto`, tight-budget key.
- Never returns the LiteLLM master key.
- Verify: callable test mints once, is idempotent on second call, rejects a
  missing/invalid App Check token.

### Task 2.3 — Abuse gate
- `mintKey` refuses if `users/{uid}.banned` or `abuse/{uid}.strikes >=
  threshold`. A scheduled function rolls up IP-hit anomalies into strikes.
- Verify: a banned UID gets 403 from mint; strike rollup increments correctly.

---

## Phase 3 — Ovid app integration

### Task 3.1 — "Ovid Cloud" seeded provider
- Add a seeded provider in `state.dart`: `api_format: openai`, baseURL =
  gateway domain, models fetched from `/v1/models`. No key in source.
- Verify: provider appears; model list populates from the gateway.

### Task 3.2 — Silent key fetch + secure storage
- On first launch / login, call `mintKey`; store the returned virtual key in
  `flutter_secure_storage`; attach it as the provider's bearer + Firebase
  tokens as headers on every request.
- Anonymous path runs with no explicit login (Auto mode).
- Verify: a fresh install gets a working key with no manual entry; the key is
  in secure storage, not in prefs/plaintext.

### Task 3.3 — Auto vs manual UX
- Auto mode uses model `ovid-auto`; manual mode shows the owner model IDs.
- Verify: switching Auto↔manual changes the model sent; Auto never exposes a
  real model name.

### Task 3.4 — Quota/429 handling
- On a 429 "budget exceeded", show a clear "you've hit your limit" message
  (not a raw error); surface remaining quota if the gateway returns it.
- Verify: a key driven past budget shows the friendly message.

---

## Phase 4 — Admin dashboard
- Use LiteLLM admin UI for spend/keys (behind UI auth, VPN/allowlist).
- Small Firebase Hosting page (custom claim `admin:true`) for signups, tier
  counts, abuse strikes from Firestore.
- Verify: non-admin is denied; admin sees live aggregates.

---

## Phase 5 — Production scale-out (Profile B, when needed)
- Managed HA Postgres; Redis for shared rate-limit/parallel state; N stateless
  LiteLLM behind a load balancer; provider key pools; autoscaling; multi-region.
- Redis grows from the single container to **managed HA Redis (primary +
  replica, auto-failover)** or **Redis Cluster** (sharded) when key volume or
  throughput demands it; cache + limits + identity may split onto separate
  Redis deployments so a cache-heavy flood never starves the limit/ban state.
- Trigger: approaching provider TPM/RPM ceilings or VPS CPU/conn saturation.
- Verify: load test sustains target RPS with shared Redis limits enforced
  across instances; failover of the Redis primary does not drop limit
  enforcement.

---

## Sequencing
Phase 1 → 2 → 3 give a working end-to-end system on the VPS. Phase 4 any time
after 2. Phase 5 only when metrics demand it. Subscriptions slot in after
Phase 3 as a webhook + `/key/update` call with zero schema change.
