# P9 decommission + cutover runbook (owner-gated)

Status: **WRITTEN, NOT EXECUTED.** Every command below that touches the live
box is owner-gated (plan Task 18 Step 6). This file is the auditable runbook;
the Caddy snippets live in `cloud/deploy/caddy-flips/` and are never applied
by a script in this repo.

Live-stack facts this runbook assumes (verified read-only 2026-10-16):

- Caddy site: `api.ovidsi.com`, with `@images` (`/v1/images/*`, `/v1/models`
  → 8090), `@mint` (`/mint`, `/healthz`, `/upgrade` → 8090), `@usage`
  (→ 8090), `@account` (`/account/*`, `/sync/v1/*`, `/chat*`, `/shares*`,
  `/s/*`, `/.well-known/assetlinks.json` → 8080 account-dev), `@api`
  (`/v1/*` → LiteLLM 4000).
- Containers: `ovid-gateway-{caddy,mint,litellm,account-dev,redis,img-edit-shim,postgres}`.
- **Port correction:** the plan's Task-18 text says "gateway 8081", but on the
  live box 8081 is Caddy's own admin-dashboard listener. The cloud gateway
  publishes on `127.0.0.1:${GATEWAY_HOST_PORT:-8082}`. Every flip below uses
  **8082**. The TS mint listens on **8091** (admin 8092, loopback only).

Dual-run rule: while both mints are up they share db2 + LiteLLM. The TS mint's
first boot must be `MINT_PROJECTION_MODE=import-first` (installed base only).
**Never FLUSH db2** (Python-written state is the import source).

## 0. Preconditions (all must hold before flip 1)

- [ ] P9 final-review blockers closed: C1 `delete_after` double precision;
      H2 real R2 prefix deleter configured (`OVID_R2_*`); H3 terminal cleanup
      re-asserts child deletes; H4 LiteLLM `/key/list?user_id=` enumeration.
- [ ] Owner answered **Q1** (clean break vs installed base) and **Q6**
      (collab v2) — see the parent ledger.
- [ ] `docker compose -f cloud/deploy/docker-compose.yml config -q` clean.
- [ ] `cloud/deploy/.env` filled (never committed; `chmod 600`), including
      `MINT_PROJECTION_MODE`, `OVID_MASTER_KEY`, `OVID_INTERNAL_API_SECRET`,
      `OVID_LITELLM_MASTER_KEY`, R2 vars, Play service account.
- [ ] Alert watch is live (spend, new-key spike, slow mode, deletion errors).
- [ ] Rollback rehearsed: every flip restores a timestamped Caddyfile backup
      and reloads; Python containers stay running until their soak passes.

## 1. Flip procedure (repeat for each group, in this order)

For **each** numbered snippet in `caddy-flips/`:

```sh
# (a) back up — UTC timestamp, never overwrite an earlier backup
cp /opt/ovid-gateway/caddy/Caddyfile \
   /opt/ovid-gateway/caddy/Caddyfile.bak-$(date -u +%Y%m%dT%H%M%S)

# (b) apply the snippet by hand (the snippets are documentation, not an
#     auto-patcher): edit the api.ovidsi.com site block to match.

# (c) validate BEFORE reloading
docker exec ovid-gateway-caddy-1 caddy validate --config /etc/caddy/Caddyfile

# (d) reload (never restart; reload is zero-downtime)
docker exec ovid-gateway-caddy-1 caddy reload --config /etc/caddy/Caddyfile

# (e) run the group's smokes (below); on ANY unexpected output, ROLL BACK
```

Rollback for every group:

```sh
cp /opt/ovid-gateway/caddy/Caddyfile.bak-<timestamp> \
   /opt/ovid-gateway/caddy/Caddyfile
docker exec ovid-gateway-caddy-1 caddy validate --config /etc/caddy/Caddyfile
docker exec ovid-gateway-caddy-1 caddy reload --config /etc/caddy/Caddyfile
# re-run the previous group's smoke and confirm the old target answers
```

### Flip 1 — `@account` group → gateway 127.0.0.1:8082

Snippet: `caddy-flips/1-account.conf`.

- Move `/account/*`, `/shares*`, `/s/*`, `/.well-known/assetlinks.json` from
  account-dev (8080) to the cloud gateway (8082).
- **DELETE** the `/sync/v1/*` and `/chat*` rules — sync is deleted per spec D6.
  **GATED ON Q1:** if any installed app build still calls sync, keep those two
  rules until the forced-update ships. Do not delete them blind.
- Smokes (expect the listed status; bodies are the contract):
  - `GET /account/deletion` (no auth) → **401** `{"detail":"sign_in_required"}`
  - `GET /shares` (no auth) → **401** (gateway envelope)
  - `GET /s/unknown` → **404** hardened viewer page (not account-dev's 404)
  - `GET /.well-known/assetlinks.json` → **503** until
    `OVID_ANDROID_PACKAGE_NAME` + `OVID_ANDROID_RELEASE_CERT_SHA256` are set,
    then **200** with uppercased `sha256_cert_fingerprints`
  - `GET /sync/v1/ping` → **404** (only after the Q1 gate allows deletion)
- Soak **≥ 24 h** with alert watch before stopping account-dev.

### Flip 2 — NEW exact-path `/v1/reports` → gateway 8082

Snippet: `caddy-flips/2-reports.conf`. Must be an **exact** matcher ordered
ahead of `@api` (`/v1/*` → LiteLLM 4000); otherwise reports land in LiteLLM.

- Smoke: `POST /v1/reports` with a valid bearer and an unknown `kind` →
  **422**-shaped rejection (not a LiteLLM 404). `OPTIONS` is not part of the
  contract; do not add CORS here.
- Soak ≥ 24 h.

### Flip 3 — NEW `/billing/*` → mint-ts 8091

Snippet: `caddy-flips/3-billing.conf`. This is an **activation**, not a
migration: the live Python mint never mounted billing (verified 2026-10-16).

- Smoke: `POST /billing/verify` with no token → **401**
  `{"ok":false,"error":{"code":"sign_in_required"}}`; with
  `OVID_PLAY_SERVICE_ACCOUNT_FILE` unset → **503 billing_unavailable**.
- Soak ≥ 24 h before flip 4.

### Flip 4 — `@images` → mint-ts 8091

Snippet: `caddy-flips/4-images.conf`. `/v1/images/*` and `/v1/models` move from
Python mint (8090) to TS mint (8091). The LiteLLM `/v1/*` proxy stays.

- Smokes:
  - `GET /v1/images/capabilities` with a valid key → **200** with an ETag;
    repeat with `If-None-Match` → **304**
  - `POST /v1/images/generations` without `ovid-image` scope → **403**
    `{"error":{"code":"image_access_denied"}}`
  - `POST /v1/images/generations` with a free account at cap → **402
    image_limit_reached** (no upstream call)
  - `GET /v1/models` with a valid key → **200** and no private backend names
- Soak ≥ 24 h before flip 5.

### Flip 5 — `@mint` + `@usage` + `/healthz` + `/upgrade` → mint-ts 8091 (LAST)

Snippet: `caddy-flips/5-mint.conf`. Most money-critical: last.

- Smokes:
  - `GET /healthz` → **200** `{"ok":true}`
  - `POST /mint` with no bearer → **401** exact `{"detail":"missing bearer id token"}`
  - `POST /mint` twice with a valid token → same `key`, one `/key/generate`
    in the LiteLLM audit log, `budget_duration` absent on the second call
  - `POST /usage` with a valid token → **200** and the pinned field set
  - `POST /upgrade` with `ALLOW_TEST_UPGRADE` unset → **403**
  - admin console `https://api.ovidsi.com/admin` is **not** exposed by Caddy
    (admin stays loopback-only on 8092)
- Soak ≥ 24 h.

## 2. Stop the old containers (owner-gated, in this order)

```sh
# after flip 1–2 soak (account-dev still serves nothing now):
docker stop ovid-gateway-account-dev-1
# after flip 4–5 soak (Python mint still serves nothing now):
docker stop ovid-gateway-mint-1
```

**KEEP** `litellm`, `img-edit-shim`, `redis`, `postgres`, `caddy`. The
unmodified Python LiteLLM hook (`server/mint/litellm_hook/`) stays per D2/G10;
the images edit shim stays per Q9. Do not delete the Python mint image until a
7-day soak has passed (rollback path).

## 3. Migration branch (Task 18 Step 3)

- **Clean break (Q1 = thin client):** run `seedFresh.ts` only; skip the
  imports; the owner sets live values (free allowance, paid windows) in the
  ported admin console. Redis db2 user state is abandoned with the Python
  stack — document this data-loss boundary to the owner in writing.
- **Installed base (Q1 = migrate):** drain image workers, then run
  `importRedisDb2.ts`, `importImagesLedger.ts`, `importSharesSqlite.ts`
  (scripts in `cloud/scripts/migrate/`; unit-tested against fixture DBs, never
  live in CI), then `verifyMigration.ts` with **zero** mismatches required
  before any flip. First TS mint boot with `MINT_PROJECTION_MODE=import-first`;
  switch to `authoritative` afterwards.

`verifyMigration.ts` requires: row-count parity per table, sampled receipt
equality (exact strings), `config:limits` field-by-field equality
Postgres ↔ Redis, and `/usage` body equality for sampled uids between Python
:8090 and TS :8091 (read-only POSTs).

## 4. Account-deletion activation (separate owner gate)

Do **not** set `OVID_ACCOUNT_FIREBASE_APP_IDS` until:

1. `OVID_LITELLM_MASTER_KEY` is set (key block/delete + `/key/list`);
2. `OVID_R2_*` is set so `createR2PrefixDeleterFromEnv` returns a real
   ListObjectsV2+DeleteObjects deleter (otherwise the gateway/worker log a
   loud warning and private objects survive — final review H2);
3. a staging deletion completes end to end (initiate → 24 h grace → sweep →
   Firebase auth deleted → users row gone → LiteLLM key gone).

## 5. Secrets checklist (never committed)

`LITELLM_MASTER_KEY`, `OVID_ADMIN_MASTER_KEY`, `OVID_INTERNAL_API_SECRET`
(≥ 32 bytes, same value in mint/gateway/worker), `OVID_MASTER_KEY` (64 hex),
Play service-account file, RTDN OIDC audience/service account (or the
shared-secret fallback), R2 token pair, Firebase App Check app IDs.
