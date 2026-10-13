# Ovid mint service

`mint.py` is the source of the live mint verifier (`/opt/ovid-gateway/verifier/mint.py`,
FastAPI on `127.0.0.1:8090`). It verifies Firebase ID + App Check tokens, mints one
LiteLLM virtual key per user per platform (android `user:{uid}:keyid`, web
`user:{uid}:web:keyid`), owns the plans and usage limits, serves `/usage` and `/plans`,
and hosts the owner admin console at `/admin`. It also mounts the image routes
(`images_gateway.py`).

| File | Runs in | Purpose |
|---|---|---|
| `mint.py` | mint container | API, settings, budgets, slow mode, admin |
| `ovid_plans.py` | mint **and** LiteLLM | Pure plan/pool math shared by both |
| `litellm_hook/ovid_pools.py` | LiteLLM proxy | Enforces the pools in the request path |

The first commit on this path is a byte-for-byte copy of the live file
(sha256 `1c54ee74fc009569f90aa2d3ef8a4c0a32d5dca679875f306a047922484b6148`). All secrets
come from the environment. A test checks that no secret literals are in the source.

## Plans

Plans are data. They are a list in the settings, and the owner can add, rename,
re-price or disable them, and edit their pools, in `/admin`. Every number is a runtime
setting: changes apply on the next request, with no rebuild or restart, and are
re-applied to every key. The values below are only first-run seeds.

| Plan (aliases) | Kind | Seed limits (USD per 24h, LiteLLM prices) | Seed price |
|---|---|---|---|
| `free` | shared | allowance = global free allowance (`config:base_daily_usd`; live value kept, 0.15 for new installs); frontier ≤ 25% of it | $0 |
| `starter` (`3x`) | shared | allowance = user's free allowance × 3; frontier ≤ 25% | $5 |
| `pro` (`7x`) | split | oss fair-use 2.00 + frontier 1.50 | $25 |
| `max` (`15x`) | split | oss fair-use 3.00 + frontier 3.50 | $60 |

- **shared:** one allowance. When it is used up, every request gets `daily_limit_reached`.
  When the frontier share is used up, frontier models and images get
  `frontier_limit_reached`, but auto and open-source models keep the remainder.
- **split:** past the oss pool the user goes into **slow mode** instead of being
  blocked: key `rpm/tpm/max_parallel` drop to the slow-mode knobs (seed 20 / 200k / 2)
  until the window resets. When the frontier pool is used up, frontier models and
  images get `frontier_limit_reached`, and the app falls back to auto/oss.
- **Window:** `window_hours` per plan. Amounts are per 24h and scale with the window
  (720h = 30 days gives ×30). A window starts at the user's first request and restarts
  when the admin resets it. New installs seed 24h for every plan. An existing install
  (one that already has users or a base budget) seeds paid plans at **720h**, which is
  the behaviour before plans existed, so deploying changes nothing until the owner
  switches them to 24h in `/admin`.
- **Model classes:** the `oss_models` list (seed: `glm-5.3-flash`, `deepseek-v4.1-flash`,
  `minimax-m3`) is the oss class. Every other model is frontier, including kimi,
  gemini/gpt flash and all image models. Auto is counted by the class of the model that
  actually served the request; if that model is unknown it counts as frontier, to be safe.
- **Auto on pro/max:** set `auto_oss_group` to a LiteLLM model group that contains only
  the oss deployments (for example `auto-oss`, created in the LiteLLM dashboard), and
  the hook rewrites `auto` to it for split plans. Until that group exists, `auto` keeps
  routing to all six members and spend is counted by the model that served it. After a
  pro/max frontier pool is used up, auto requests served by a frontier member still
  count as frontier.
- **Disable** means stop selling: the plan disappears from `/plans`, and `/upgrade` to it
  falls back to free. Users already on it keep it until the admin changes their plan.
- **Aliases:** `user:{uid}:tier` stores the plan's first alias (`3x`/`7x`/`15x`), so
  billing (which writes and ranks these ids) and older app builds keep working. A plan
  with no alias is stored by its id.
- **Per-user overrides:**
  - custom free limit (`user:{uid}:dailyUsd`; it scales shared plans)
  - custom plan pools (`user:{uid}:pools`, any of `mult`, `frontier_share`, `oss_usd`,
    `frontier_usd`, `window_hours`)
  - custom monthly backstop (`user:{uid}:monthlyCapUsd`)

  Each has a clear button.
- **Free monthly backstop** (seed $10/30d, editable): the LiteLLM *user* budget for free
  users, across all their keys. With a high daily free amount it cuts users off after a
  few days; the console explains this next to the field.

### Enforcement

| Mechanism | What it enforces |
|---|---|
| `litellm_hook/ovid_pools.py` (LiteLLM `CustomLogger`, checked against LiteLLM **1.105.0**, the image behind the unpinned `main-latest` tag) | Pre-call: `daily_limit_reached` / `frontier_limit_reached`, and auto→oss routing. Success: adds `response_cost` to `pool:{uid}:spend:{oss,frontier}` by the served model's class, and flags slow mode. Fails open if Redis is down. |
| mint | Slow mode: lowers the key `rpm/tpm/max_parallel` on android + web keys. The sweeper applies it within 30 s of the hook's flag, `/usage` applies it immediately, and it is lifted when the window ends. Budgets, windows, resets. |
| LiteLLM key budget | Backstop per key per window: shared plans = allowance; split plans = `hard_ceiling_mult` (seed 3) × oss + frontier |
| LiteLLM user budget | Free plan: monthly backstop. Other plans: same as the key budget |

Why a hook rather than `model_max_budget` or one key per class: `model_max_budget` is
per model, so it cannot express one frontier pool shared across about 10 models (each
model would get its own 25%). Separate keys per class would need the app to pick a key
per model, and LiteLLM's generic budget error would not carry `frontier_limit_reached`
or `resets_at`. A pre-call hook is a stable public LiteLLM API. It sees the requested
model before any provider call, can return an exact OpenAI-shaped error, and its
success callback gets the served model and LiteLLM's own cost. Its counters also make
the daily allowance per *user* across android + web, which fixes L1.

Rejection (HTTP 429):
```json
{"error": {"message": "frontier_limit_reached: this plan's frontier allowance is used up; resets_at=2026-10-14T05:23:15Z",
           "type": "frontier_limit_reached", "param": "model", "code": "429",
           "provider_specific_fields": {"ovid_error": "frontier_limit_reached", "resets_at": "2026-10-14T05:23:15Z"}}}
```
The headers `x-ovid-error`, `x-ovid-resets-at` and `retry-after` are also set. The app
should switch to `auto` (or an oss model) on `frontier_limit_reached`, and show the
reset time on `daily_limit_reached`.

### Economics (for the owner)

Owner cost is 20% of the official price, and the LiteLLM price is 35% of official
(65% off), so **owner cost ≈ 0.571 × LiteLLM spend**. Every amount in the plans is in
LiteLLM dollars. With the seeds at 100% daily use for 30 days, before Play's fee:

| Plan | LiteLLM $/24h | Owner $/30d at full use | Price | Break-even use (after 15% Play fee) |
|---|---|---|---|---|
| free (0.15) | 0.15 | 2.57 (capped by the backstop: 10 → 5.71) | 0 | — |
| starter | 0.45 | 7.71 | 5 | ~55% |
| pro | 3.50 (oss fair-use + frontier) | 60.00 | 25 | ~35% |
| max | 6.50 | 111.43 | 60 | ~46% |

Slow mode lets split plans exceed the oss pool, up to `hard_ceiling_mult` × oss. At the
seed of 3× that is 7.50/24h for pro and 12.50/24h for max, which is the real worst case.
Tune it in `/admin`.

### Settings storage

| Where | Keys |
|---|---|
| Redis db 2 | `config:base_daily_usd`: global free allowance (same key as before) |
| | hash `config:limits`: `plans` (JSON list), `oss_models` (JSON), `auto_oss_group`, `free_monthly_cap_usd`, `normal_rpm/tpm/parallel`, `slow_rpm/tpm/parallel`, `hard_ceiling_mult`, `est_input_tokens`, `est_output_tokens`, `est_image_tokens` |
| | per user: `user:{uid}:tier`, `:dailyUsd`, `:pools`, `:monthlyCapUsd`, `:banned`, `:email`; `email:{email}` → uid |
| | pools: `pool:{uid}:start` (epoch, TTL = window), `pool:{uid}:spend:oss`, `pool:{uid}:spend:frontier`, `pools:slow` (hash uid → until), `pools:slow_pending` (set), `config:model_public_map` (served model → public name, published by mint for the hook) |
| | `audit:admin` (list, newest first, capped at 5000), `config:reapply_status`, `config:reset_status`, `usagecache:{uid}` (15 s) |
| mint volume `/data` | `limits.json` (settings mirror, restored at startup if Redis lost them) and `admin-audit.jsonl` (append-only, never trimmed) |

Startup only **adds** unset fields (`ensure_default_settings`). It never overwrites a
stored value. Env vars (`BASE_DAILY_USD`, `FREE_MONTHLY_CAP_USD`, `KEY_RPM`, `KEY_TPM`,
`KEY_MAX_PARALLEL`, `EST_*`) are seeds only. Operational env vars, unchanged:
`FIREBASE_*`, `APPCHECK_*`, `OVID_APPCHECK_APPS`, `LITELLM_*`, `REDIS_URL`,
`PUBLIC_BASE_URL`, `ALLOW_TEST_UPGRADE`, `WEB_TEAM_DAILY_USD`, `DAILY_SPEND_ALERT_USD`,
`ALERT_*` and the anti-abuse knobs. New ones: `MINT_STATE_DIR` (/data),
`REAPPLY_SYNC_MAX` (200), `AUDIT_MAX` (5000), `USAGE_CACHE_S` (15), `MINT_SWEEP_S` (30),
`MINT_SPEND_MONITOR` (true), `MINT_MOUNT_IMAGES` (true). Hook: `OVID_POOLS_REDIS_DB` (2),
`OVID_POOLS_SETTINGS_TTL_S` (5), plus LiteLLM's existing `REDIS_HOST/PORT/PASSWORD`.

## Billing product mapping (verified in the repo)

`server/billing/products.py` `DEFAULT_PRODUCTS` and `lib/core/play_billing.dart`
`kOvidPlayProducts` (which can be overridden by `OVID_PLAY_PRODUCTS`):
`ovid_plus_monthly → 3x`, `ovid_pro_monthly → 7x`, `ovid_max_monthly → 15x`.
`server/billing/store.py` writes `user:{uid}:tier` = `3x`/`7x`/`15x` with an expiry
(`exat`) plus `user:{uid}:tier_expires_at`. Mint resolves those through the aliases
(`3x→starter`, `7x→pro`, `15x→max`), so billing needs no change.

Two gaps for the billing/app owners:
1. The Play id says "plus" while the plan is now named "Starter".
2. `DEFAULT_PLAN_FEATURES` copy ("About 7x the Free allowance, pooled over 30 days")
   no longer describes the plans. Drive the plan screen from mint `GET /plans` instead.

## Admin console (`/admin`) and JSON API

The console is still reachable only on localhost / an SSH tunnel (Caddy does not route
`/admin`), with the LiteLLM master key pasted into the tab. It is a pure client of the
JSON API below; everything it can do, the API can do. The page is `no-store` and
`frame-ancestors 'none'`, and all user data is rendered as text.

Console sections:
- **Global limits:** free allowance, monthly backstop (with explanation), key ceiling
  multiplier, normal and slow-mode rpm/tpm/parallel, estimate tokens, `auto_oss_group`.
- **Plans table:** id, name, price (admin and plan-screen metadata only), enabled,
  aliases, kind, window hours, mult / frontier share / oss $ / frontier $. Rows can be
  edited and new plans added.
- **Model classes:** one oss/frontier selector per LiteLLM model. The table shows
  LiteLLM prices to the admin only.
- **User lookup** (uid or email): plan, overrides, window, pools (spent / cap / left),
  slow mode, usage (requests, tokens, images, auto, spend), backstop, keys (budget, rpm,
  blocked), and the per-model table exactly as the app sees it. Actions: set plan,
  custom free limit, custom backstop, custom pools (each with a clear button),
  **reset window now** (optionally also the monthly backstop), ban/unban.
- **All users:** **reset window for ALL users now** runs in the background, and the UI
  polls the progress. IP ban/unban.
- **Audit log:** time, action, target, before/after and result.

API (all calls need `Authorization: Bearer <master key>`; 401 if the header is missing,
403 if the key is wrong):

| Endpoint | Purpose |
|---|---|
| `GET /admin/settings` | All settings, user count, reapply/reset status |
| `POST /admin/settings` | Partial update of any setting (`free_daily_usd`, scalars, `oss_models`, `auto_oss_group`, `plans`); `reapply` defaults to true |
| `GET /admin/plans`, `POST /admin/plans` | List; upsert one plan by `id` (partial edit merges) |
| `POST /admin/plans/{id}/enable` · `/disable` | Toggle selling |
| `GET /admin/models` | LiteLLM models with class (and prices, admin only) |
| `GET /admin/user?q=` | Lookup by uid or email |
| `POST /admin/user/update` (= `/admin/set-tier`) | `uid`, `tier`, `daily_usd`, `monthly_cap_usd`, `pools{}`, `clear_daily_usd`, `clear_monthly_cap_usd`, `clear_pools` |
| `POST /admin/reset-window` | `{uid}` for one user, `{}` for all; `reset_month_free` optional |
| `GET /admin/reset-status` | Progress of the global reset |
| `POST /admin/reset-usage` | Legacy: a window reset that also zeroes the monthly backstop |
| `POST /admin/ban` · `/unban` | `uid` and/or `ip` |
| `POST /admin/set-base-budget` | Legacy global free allowance |
| `GET /admin/audit?limit=`, `GET /admin/reapply-status`, `POST /admin/sweep`, `GET /admin/export` | Audit, status, run the slow-mode sweep now, backup |

A **window reset** (one user or all):
- deletes the pool counters and sets `pool:{uid}:start` = now;
- clears slow mode and restores the normal limits;
- sends `/key/update` with `spend: 0` **and** `budget_duration` to every key the user
  has (android + web), so LiteLLM's budget clock restarts now, and re-applies budgets;
- zeroes the LiteLLM user spend for non-free plans. On the free plan this happens only
  with `reset_month_free`, because that budget is the 30-day backstop.

It is audited, and `/usage` shows the new `resets_at`.

### Admin v2 defects (11-web-app-plan.md L1–L8)

| # | Status |
|---|---|
| L1 per-key daily budget (2× across android + web) | Fixed by the hook: pool counters are per user across all keys. Key budgets remain a per-key backstop. |
| L2 override replaced the plan amount | Fixed: the custom free limit scales shared plans; split plans have their own custom pools |
| L3 web keys never updated | Fixed (settings, user changes, upgrade, reset, slow mode, ban) |
| L4 monthly reset did nothing | Fixed (`reset_month_free` zeroes the LiteLLM user spend) |
| L5 `/usage` saw the android key only | Fixed (all keys, plus pools) |
| L6 console showed ×5/10/20 | Fixed (data-driven plans) |
| L7 master key in browser, no audit | Partly: audit log, constant-time compare, hardened headers. SSO/2FA is still to do. |
| L8 entitlements only in Redis | Partly: settings mirror, audit file, `/admin/export` |

## API contract for the app

### `POST /usage`

Headers are unchanged: `Authorization: Bearer <Firebase ID token>`, `X-Firebase-AppCheck`.
Every earlier field is kept. Example for a pro user (`tier` "7x"), trimmed to 4 models:

```json
{
 "tier": "7x",
 "is_paid": true,
 "daily_spent_usd": 1.84,
 "daily_budget_usd": 3.5,
 "daily_remaining_usd": 1.66,
 "month_free_spent_usd": 0.0,
 "month_free_cap_usd": 10.0,
 "requests_today": 4,
 "budget_window": "24h",
 "remaining_pct": 0.4743,
 "plan": "pro",
 "plan_name": "Pro",
 "window": "24h",
 "resets_at": "2026-10-14T05:23:15Z",
 "today": {
  "requests": 4,
  "input_tokens": 34040,
  "output_tokens": 7900,
  "images": 1,
  "auto_requests": 1,
  "by_model": {
   "glm-5.3-flash": {
    "requests": 1,
    "input_tokens": 21000,
    "output_tokens": 5200,
    "images": 0,
    "via_auto": 0,
    "class": "oss"
   },
   "ovid-image": {
    "requests": 1,
    "input_tokens": 40,
    "output_tokens": 0,
    "images": 1,
    "via_auto": 0,
    "class": "frontier"
   },
   "minimax-m3": {
    "requests": 1,
    "input_tokens": 9000,
    "output_tokens": 1800,
    "images": 0,
    "via_auto": 1,
    "class": "oss"
   },
   "gemini-3.8-flash": {
    "requests": 1,
    "input_tokens": 4000,
    "output_tokens": 900,
    "images": 0,
    "via_auto": 0,
    "class": "frontier"
   }
  }
 },
 "remaining_fraction": 0.4743,
 "pools": [
  {
   "class": "oss",
   "remaining_fraction": 0.4,
   "resets_at": "2026-10-14T05:23:15Z",
   "slow_mode": false
  },
  {
   "class": "frontier",
   "remaining_fraction": 0.5733,
   "resets_at": "2026-10-14T05:23:15Z",
   "slow_mode": false
  }
 ],
 "models": [
  {
   "id": "auto",
   "name": "auto",
   "kind": "chat",
   "auto": true,
   "estimate": "conservative",
   "class": "auto",
   "members": [
    "deepseek-v4.1-flash",
    "gemini-3.7-flash",
    "gemini-3.8-flash",
    "glm-5.3-flash",
    "gpt-5.6-luna",
    "minimax-m3"
   ],
   "slow_mode": false,
   "pool": "mixed",
   "priced": true,
   "remaining_messages": 409,
   "model": "auto",
   "input_cost_per_token": 2.5e-07,
   "output_cost_per_token": 2e-06,
   "remaining_pct": 0.4743
  },
  {
   "id": "gemini-3.8-flash",
   "name": "gemini-3.8-flash",
   "kind": "chat",
   "auto": false,
   "estimate": "typical",
   "class": "frontier",
   "slow_mode": false,
   "pool": "frontier",
   "priced": true,
   "remaining_messages": 409,
   "model": "gemini-3.8-flash",
   "input_cost_per_token": 3e-07,
   "output_cost_per_token": 2.5e-06,
   "remaining_pct": 0.4743
  },
  {
   "id": "glm-5.3-flash",
   "name": "glm-5.3-flash",
   "kind": "chat",
   "auto": false,
   "estimate": "typical",
   "class": "oss",
   "slow_mode": false,
   "pool": "oss",
   "priced": true,
   "remaining_messages": 909,
   "model": "glm-5.3-flash",
   "input_cost_per_token": 2e-07,
   "output_cost_per_token": 8e-07,
   "remaining_pct": 0.4743
  },
  {
   "id": "ovid-image",
   "name": "ovid-image",
   "kind": "image",
   "auto": false,
   "estimate": "typical",
   "class": "frontier",
   "slow_mode": false,
   "pool": "frontier",
   "priced": true,
   "remaining_images": 21,
   "model": "ovid-image",
   "input_cost_per_token": null,
   "output_cost_per_token": null,
   "remaining_pct": 0.4743
  }
 ]
}
```

The pools for a free user, whose 25% frontier share is used up (the app should steer
to auto/oss):
```json
{
 "tier": "free",
 "plan": "free",
 "plan_name": "Free",
 "window": "24h",
 "remaining_fraction": 0.7333,
 "pools": [
  {
   "class": "all",
   "remaining_fraction": 0.7333,
   "resets_at": "2026-10-14T05:23:15Z",
   "slow_mode": false
  },
  {
   "class": "frontier",
   "remaining_fraction": 0.0,
   "resets_at": "2026-10-14T05:23:15Z",
   "slow_mode": false
  }
 ]
}
```

**Display-safe fields (no money):**

| Field | Type | Meaning |
|---|---|---|
| `plan`, `plan_name` | string | Canonical plan id (`free`/`starter`/`pro`/`max`/…) and display name. `tier` stays the legacy alias |
| `window` | string | Plan window: `"24h"`, `"30d"`, or `"<N>h"`/`"<N>d"` for custom lengths |
| `resets_at` | ISO-8601 UTC | When the window restarts. It starts at the first request and moves when the admin resets it |
| `remaining_fraction` | 0..1 | Overall remaining. Shared plans: the allowance (with the free monthly backstop). Split plans: (oss left + frontier left) / (oss + frontier) |
| `pools[]` | list | `{class: "all"\|"oss"\|"frontier", remaining_fraction, resets_at, slow_mode}`. Shared plans: `all` + `frontier` (frontier is capped by `all`). Split plans: `oss` + `frontier`. `slow_mode: true` on `oss` means it still works, more slowly |
| `today.*` | int | requests / input_tokens / output_tokens / images / auto_requests in the current window, all keys. `by_model[id]` adds `via_auto` and `class` |
| `models[].class` | `"oss"`\|`"frontier"`\|`"auto"` | |
| `models[].pool` | `"all"`\|`"oss"`\|`"frontier"`\|`"mixed"` | Which pool this model draws from (`mixed`: auto on split plans without an oss-only group) |
| `models[].remaining_messages` / `remaining_images` | int \| null | That pool's remaining budget ÷ the typical message (2,000 in + 600 out, editable) or image cost at **this model's** LiteLLM price. `null` when the model is unpriced |
| `models[].slow_mode` | bool | The model's pool is in slow mode |
| `models[].auto`, `estimate`, `members`, `priced`, `kind`, `name`, `id` | | As before (`auto` is `"conservative"`) |

**Back-compat / internal (never render):** `daily_*_usd` (now the totals of the current
window's pools), `month_free_*_usd`, `requests_today`, `budget_window`, `remaining_pct`,
and per model `model`, `input_cost_per_token`, `output_cost_per_token`, `remaining_pct`.

### `GET /plans` (public)

`{"plans": [{"id","name","price_usd","aliases","kind","window"}]}` lists the enabled
plans for the plan screen. The price is the subscription's list price as metadata; Play
shows its own localized price.

### Chat/image errors from the gateway

These come back as HTTP 429 with `error.type` set to `frontier_limit_reached` (switch to
auto/oss) or `daily_limit_reached` (wait until `resets_at`), plus the `x-ovid-resets-at`
header. See the Enforcement section above.

## Tests

```
/tmp/collab-venv/bin/python -m pytest -q server/mint/tests
```

The tests use fakeredis if it is installed, else an in-memory stub (plus an async
facade for the hook), and an `httpx.MockTransport` fake of the LiteLLM admin API. There
are no network calls and no services.

## Deploy (owner, manual)

1. Back up `/opt/ovid-gateway/verifier/mint.py`, `Dockerfile`, `docker-compose.yml` and
   `litellm/config.yaml`.
2. Mint:
   `cp server/mint/mint.py server/mint/ovid_plans.py /opt/ovid-gateway/verifier/`, then add
   `COPY ovid_plans.py /app/ovid_plans.py` to `verifier/Dockerfile` after the `mint.py`
   COPY.
3. LiteLLM hook:
   `cp server/mint/ovid_plans.py server/mint/litellm_hook/ovid_pools.py /opt/ovid-gateway/litellm/`.
   In `docker-compose.yml`, under the `litellm` service `volumes:`, add
   `- ./litellm/ovid_pools.py:/app/ovid_pools.py:ro` and
   `- ./litellm/ovid_plans.py:/app/ovid_plans.py:ro`. In `litellm/config.yaml` under
   `litellm_settings:`, add `callbacks: ["ovid_pools.proxy_handler_instance"]`. LiteLLM
   already has `REDIS_HOST/PORT/PASSWORD`; the hook uses db 2, the same as mint.
   Consider pinning the LiteLLM image to the 1.105.0 digest that was checked.
4. Rebuild and restart:
   `cd /opt/ovid-gateway && docker compose build mint && docker compose up -d mint litellm`.
   Startup seeds only unset settings. The existing install keeps 0.50/day and 720h paid
   windows.
5. Verify:
   - `curl -s 127.0.0.1:8090/healthz` and `curl -s 127.0.0.1:8090/plans`
   - open the console through the tunnel and check the plans, classes and a known user
   - `docker compose logs litellm | grep -i ovid_pools` should show no import errors
6. Owner decisions, all in `/admin`, no restart:
   - set paid plan windows to 24h
   - set the free allowance (0.15 suggested)
   - create the LiteLLM `auto-oss` group and set `auto_oss_group`
   - save `GET /admin/export` off-box

Rollback: restore the backups from step 1 and restart mint and litellm. The hook can
also be disabled on its own by removing the `callbacks` line.
