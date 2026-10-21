# Ovid mint service

`mint.py` is the source of the live mint verifier (`/opt/ovid-gateway/verifier/mint.py`,
FastAPI on `127.0.0.1:8090`). It verifies Firebase ID + App Check tokens, mints one
LiteLLM virtual key per user per platform (android `user:{uid}:keyid`, web
`user:{uid}:web:keyid`), owns plans and allowances, serves `/usage` and `/plans`, and
hosts the owner admin console at `/admin`. It also mounts the image routes
(`images_gateway.py`).

| File | Runs in | Purpose |
|---|---|---|
| `mint.py` | mint container | API, settings, budgets, windows, slow mode, admin |
| `ovid_plans.py` | mint **and** LiteLLM | Pure plan/allowance math shared by both |
| `litellm_hook/ovid_pools.py` | LiteLLM proxy | Enforces the allowance in the request path; hidden auto routing |

The first commit on this path is a byte-for-byte copy of the live file
(sha256 `1c54ee74fc009569f90aa2d3ef8a4c0a32d5dca679875f306a047922484b6148`). All secrets
come from env; a test checks the source for secret literals.

## Plans: one allowance, priced by LiteLLM

There are no model classes. The only thing that matters is each model's price, which
the owner sets in LiteLLM (`model_info` input/output cost per token, cost per image).
Every plan is **one allowance per window**, and each request consumes it at its
model's LiteLLM price. Users never see amounts. They see a remaining percentage (as a
bar or graph) and, per model, an estimate of the messages or images left.

| Plan (aliases) | Allowance per 24h (seed) | At the suggested 0.15 base | Seed price |
|---|---|---|---|
| `free` | free allowance × 1 | 0.15 | $0 |
| `starter` (`3x`) | free × 3 | 0.45 | $5 |
| `pro` (`7x`) | free × 23 | 3.45 | $25 |
| `max` (`15x`) | free × 43 | 6.45 | $60 |

- **Free allowance:** `config:base_daily_usd`. The live value (0.50) is kept; new
  installs seed 0.15. The pro and max multipliers are seeded so their daily allowances
  roughly match the earlier pro (3.50) and max (6.50) totals.
- **When the allowance is used up:** `daily_limit_reached` with `resets_at` until the
  window resets.
- **Slow mode:** an optional per-plan `slow_mode`, off by default. If it is on, requests
  continue with the slow-mode limits (rpm 20 / tpm 200k / parallel 2, editable) up to
  the key ceiling (`hard_ceiling_mult` × allowance, seed 3).
- **Window:** `window_hours` per plan. Amounts are per 24h and scale with the window
  (720h = 30 days gives ×30). A window starts at the user's first request; an admin
  reset restarts it now. New installs seed 24h everywhere. An existing install seeds
  paid plans at **720h**, which is today's 30-day behaviour, so deploying changes
  nothing until the owner flips the windows.
- **Hidden auto routing:** a per-plan toggle, "auto uses auto-oss". It is on for pro and
  max and off for free and starter. With it on, the hook rewrites `auto` to a
  weighted-random member of `auto_oss_members` (seed: `glm-5.3-flash`,
  `deepseek-v4.1-flash`, `minimax-m3`, weight 1 each; these are existing LiteLLM models,
  so no new group or provider key is needed). The other members are sent as
  per-request fallbacks.
  - Members that LiteLLM does not know are skipped. If no member is usable, or the
    setting is empty or invalid, the request stays plain `auto`. This never fails a
    request.
  - The app never sees the name: `/usage` reports these requests as `auto`, attributed
    to the model that served them (`today.by_model[m].via_auto`, `today.auto_requests`).
    No `auto-oss` model exists in `/v1/models` or `/usage`.
  - Admins can add and remove members in `/admin`. Names are validated against LiteLLM
    `/model/info`.
- **Plans are data:** add, rename, re-price, disable, change aliases, multiplier,
  window, slow mode and auto-oss, all in `/admin` or the JSON API. Every number is a
  runtime setting that applies on the next request (the hook picks it up within 5 s)
  and is re-applied to every key. The values above are only first-run seeds, written
  only when unset.
- **Disable** means stop selling: the plan disappears from `/plans`, and `/upgrade` to
  it falls back to free. Users already on it keep it.
- **Aliases:** `user:{uid}:tier` stores the plan's first alias (`3x`/`7x`/`15x`), so
  billing and older apps keep working.
- **Per-user overrides**, each with a clear button:
  - custom free limit (`user:{uid}:dailyUsd`), which scales whatever plan the user is on;
  - custom plan fields (`user:{uid}:pools`: `mult`, `window_hours`, `slow_mode`,
    `auto_oss`);
  - custom monthly backstop.
- **Free monthly backstop** (seed $10/30d, editable): the LiteLLM user budget for free
  users across all their keys. With a high daily amount it stops users after a few days;
  the console explains this.

### Enforcement

| Mechanism | What it does |
|---|---|
| `litellm_hook/ovid_pools.py` (LiteLLM `CustomLogger`; checked against the LiteLLM **1.105.0** source that `main-latest` currently resolves to) | Pre-call: `daily_limit_reached` (HTTP 429, OpenAI-shaped, `error.type` = code, `x-ovid-error` / `x-ovid-resets-at` / `retry-after`) and the hidden auto rewrite. Success: adds `response_cost` to `pool:{uid}:spend` (**one counter per user across android + web**, which fixes L1), tallies rewritten-auto requests in `pool:{uid}:auto`, and flags slow-mode plans that crossed their allowance. Fails open. |
| mint | Windows, budgets, resets. Slow mode: lowers the key `rpm/tpm/max_parallel` on both keys (the sweeper acts within 30 s of the hook's flag, `/usage` acts at once) and lifts it when the window ends. Publishes LiteLLM model names (`config:model_groups`) for the hook. |
| LiteLLM key budget | Per-key backstop per window: the allowance, or `hard_ceiling_mult` × allowance for slow-mode plans |
| LiteLLM user budget | Free plan: monthly backstop. Other plans: same as the key budget |

**Per-request fallbacks, checked in the 1.105.0 source:**
- `Router.async_function_with_retries` and `async_function_with_fallbacks` read
  `kwargs.get("fallbacks", self.fallbacks)` / `kwargs.pop(...)`, and the proxy calls
  `llm_router.acompletion(**data)` after the pre-call hook. So `data["fallbacks"]` set by
  the hook is honoured.
- `get_fallback_model_group` keeps only the *last* entry of a plain string list, so the
  hook uses the dict form `[{picked: [other members]}]`.
- Body fallbacks are validated against the key at auth time, before the hook runs. Ovid
  keys are not model-restricted, so the hook's fallbacks need no extra permission.
- This was verified by reading the source, not by running against a live proxy.
  Re-check after LiteLLM upgrades (or pin the image).

### Economics (for the owner)

Owner cost is 20% of the official price, and the LiteLLM price is 35% of official
(65% off), so **owner cost ≈ 0.571 × LiteLLM spend**. Allowances are in LiteLLM
dollars. The table assumes the 0.15 seed base, 100% daily use for 30 days, and Play's
15% fee:

| Plan | LiteLLM $/24h | Owner $/30d at full use | Price | Net after Play | Break-even use |
|---|---|---|---|---|---|
| free | 0.15 | 2.57 (backstop 10 caps it at 5.71) | 0 | 0 | — |
| starter | 0.45 | 7.71 | 5 | 4.25 | ~55% |
| pro | 3.45 | 59.14 | 25 | 21.25 | ~36% |
| max | 6.45 | 110.57 | 60 | 51.00 | ~46% |

On a slow-mode plan the worst case is `hard_ceiling_mult` × these figures. Routing
pro/max `auto` to the cheaper members lowers the real cost per message without
changing the allowance.

### Settings storage

| Where | Keys |
|---|---|
| Redis db 2 | `config:base_daily_usd`: global free allowance (same key as before) |
| | hash `config:limits`: `plans` (JSON list), `auto_oss_members` (JSON), `free_monthly_cap_usd`, `normal_rpm/tpm/parallel`, `slow_rpm/tpm/parallel`, `hard_ceiling_mult`, `est_input_tokens`, `est_output_tokens`, `est_image_tokens` |
| | per user: `user:{uid}:tier`, `:dailyUsd`, `:pools`, `:monthlyCapUsd`, `:banned`, `:email`; `email:{email}` → uid |
| | window: `pool:{uid}:start` (TTL = window), `pool:{uid}:spend`, `pool:{uid}:auto` (hash), `pools:slow`, `pools:slow_pending`, `config:model_groups` |
| | `audit:admin` (capped at 5000), `config:reapply_status`, `config:reset_status`, `usagecache:{uid}` (15 s) |
| | M1: `alerts:pending:user_spend` (queue), `alert:user_spend:queued:<uid>:<day>`, `alert:user_spend:sent:<uid>:<day>`, `alerts:recent` (capped at `M1_ALERTS_MAX`, 200), `config:kill_switch` (runtime flag) |
| | key-IP fan-out (`server/security/key_ip_fanout.py`): `security:keyip:obs:<key_ref>` (hash, 2 h TTL), `security:keyip:block:<key_ref>` (hash, TTL = block), `security:keyip:blocks` (set), `security:keyip:alert:<event_id>`, `security:key_ip:emails` (queue, capped at `KEY_IP_EMAIL_QUEUE_MAX`, 1000) |
| mint volume `/data` | `limits.json` (settings mirror, restored at startup if Redis lost them) and `admin-audit.jsonl` (append-only) |

Startup only **adds** unset fields; it never overwrites a stored value. Unknown stored
fields are ignored. Env vars (`BASE_DAILY_USD`, `FREE_MONTHLY_CAP_USD`, `KEY_RPM`,
`KEY_TPM`, `KEY_MAX_PARALLEL`, `EST_*`) are seeds only. Other env vars: `MINT_STATE_DIR`,
`REAPPLY_SYNC_MAX` (200), `AUDIT_MAX`, `USAGE_CACHE_S` (15), `MINT_SWEEP_S` (30),
`MINT_SPEND_MONITOR`, `MINT_MOUNT_IMAGES`. M1: `M1_ALERT_WEBHOOK_URL` (structured
per-user alerts; log fallback), `M1_ALERTS_MAX` (200), and
`OVID_PAID_MODELS_KILL_SWITCH` on mint **and** LiteLLM (hard env override; the runtime
flag is `config:kill_switch`). Key/IP: `KEY_IP_FANOUT_LIMIT` (5),
`KEY_IP_FANOUT_WINDOW_S` (900), `KEY_IP_FANOUT_BLOCK_S` (86400),
`KEY_IP_EMAIL_QUEUE_MAX` (1000). Hook: `OVID_POOLS_REDIS_DB` (2),
`OVID_POOLS_SETTINGS_TTL_S` (5), plus LiteLLM's `REDIS_HOST/PORT/PASSWORD`.

## Billing product mapping (verified in the repo)

`server/billing/products.py` and `lib/core/play_billing.dart` map `ovid_plus_monthly → 3x`,
`ovid_pro_monthly → 7x` and `ovid_max_monthly → 15x`. `server/billing/store.py` writes
those ids to `user:{uid}:tier` with an expiry. Mint resolves them through the aliases
(starter / pro / max), so billing needs no change.

Two gaps for the billing/app owners:
1. The Play id says "plus" while the plan is named "Starter".
2. The `DEFAULT_PLAN_FEATURES` copy is stale. Drive the plan screen from `GET /plans`.

## Admin console (`/admin`) and JSON API

The console is still reachable only on localhost / an SSH tunnel, with the master key
pasted into the tab. It is a pure client of the JSON API. The page is `no-store` and
`frame-ancestors 'none'`, and all data is rendered as text.

Console sections:
- **Global limits:** free allowance, monthly backstop (with explanation), slow-mode key
  ceiling, normal and slow-mode rpm/tpm/parallel, typical message and image sizes.
- **Plans:** id, name, price (admin and plan-screen metadata only), on/off, aliases,
  window hours, mult, the computed allowance per 24h, the **slow** checkbox and the
  **auto uses auto-oss** checkbox. Plans can be edited and added.
- **Auto-oss members:** add or remove LiteLLM models and set their weights. Names are
  validated against `/model/info`.
- **Model prices:** read-only, from LiteLLM, admin only, including the estimated cost
  per typical message or image that drives the app's counts.
- **User** (uid or email): plan, overrides, window, allowance (spent / cap / left, %),
  slow mode, auto routing, usage (requests, tokens, images, auto, spend), backstop,
  keys, and the per-model table exactly as the app sees it. Actions: plan, custom free
  limit, custom plan (mult / window / slow / auto-oss), custom backstop (each with a
  clear button), **reset window now**, ban/unban.
- **All users:** **reset window for ALL users now** runs in the background with live
  progress. IP ban.
- **Audit log.**

API (all calls need `Authorization: Bearer <master key>`; 401 if missing, 403 if wrong):

| Endpoint | Purpose |
|---|---|
| `GET/POST /admin/settings` | Read; partial update (`free_daily_usd`, scalars, `plans`, `auto_oss_members`), re-applied by default |
| `GET/POST /admin/plans`, `POST /admin/plans/{id}/enable` · `/disable` | Plans as data |
| `GET /admin/models` | LiteLLM models, prices and per-message estimates |
| `GET /admin/user?q=` | Lookup by uid or email |
| `POST /admin/user/update` (= `/admin/set-tier`) | `uid`, `tier`, `daily_usd`, `monthly_cap_usd`, `pools{mult,window_hours,slow_mode,auto_oss}`, `clear_*` |
| `POST /admin/reset-window` · `GET /admin/reset-status` | `{uid}` or `{}` (all users, background); optional `reset_month_free` |
| `POST /admin/reset-usage` | Legacy: window reset plus the monthly backstop |
| `POST /admin/ban` · `/unban`, `POST /admin/set-base-budget` (legacy) | |
| `GET /admin/audit`, `GET /admin/reapply-status`, `POST /admin/sweep`, `GET /admin/export` | |
| `GET /admin/alerts` | Recent M1 alerts (sanitized payloads + delivery), pending queue depth, webhook configured |
| `GET/POST /admin/kill-switch` | Read env/runtime/effective state; `{"enabled": true|false}` flips the runtime flag (audited). The env flag remains the hard override. |
| `GET /admin/blocked-keys` | Keys blocked for IP fan-out: `key_ref`, uid, platform, reason, distinct prefixes, block window, policy |
| `GET /admin/blocked-keys/{key_ref}` | One block's reason, evidence and expiry (404 when not blocked) |
| `POST /admin/blocked-keys/unblock` | `{"key_ref", "reason"}` — clears the block and its observation window, unblocks the LiteLLM key, audited |

### Key/IP contract

- `POST /mint` is the ONLY response that carries a key (and the gateway base
  URL). It is `no-store`.
- No other response contains a raw key, a key hash, a LiteLLM key id or a base
  URL: `/usage`, `/plans` and every `/admin/*` response are passed through
  `redact_sensitive()`, which drops sensitive field names and scrubs secret
  values, `sk-…` patterns and bearer tokens.
- Per-key IP fan-out (spec §12): a key seen from more than
  `KEY_IP_FANOUT_LIMIT` (5) distinct `/24`s in `KEY_IP_FANOUT_WINDOW_S`
  (900 s) is blocked for `KEY_IP_FANOUT_BLOCK_S` (24 h), returns
  `403 key_ip_fanout` (header `x-ovid-error`), is blocked in LiteLLM, and
  queues exactly one email event. `/mint` and `/usage` both enforce an existing
  block, and `/usage` also feeds LiteLLM spend-log `requester_ip` values into
  the same guard, so a key used directly against the gateway is covered.
- Email events are queued in `security:key_ip:emails`, drained by the sweeper
  (and `POST /admin/sweep`) into `KEY_IP_EMAIL_SENDER` when configured, else
  logged; every event is kept in the sanitized `/admin/alerts` history.

A **window reset** (one user or all):
- clears `pool:{uid}:spend`, `pool:{uid}:auto` and slow mode, and sets the window start
  to now;
- sends `/key/update` with `spend: 0` plus `budget_duration` to every key (android +
  web), so LiteLLM's clock restarts, and re-applies budgets;
- zeroes the LiteLLM user spend for non-free plans, and for free only with
  `reset_month_free`.

It is audited, and `/usage` shows the new `resets_at`.

### Admin v2 defects (11-web-app-plan.md L1–L8)

| # | Status |
|---|---|
| L1 per-key daily budget | Fixed by the hook's per-user counter across both keys |
| L2 override replaced the plan amount | Fixed: the custom free limit scales the plan |
| L3 web keys never updated | Fixed |
| L4 monthly reset no-op | Fixed |
| L5 `/usage` saw the android key only | Fixed |
| L6 console showed ×5/10/20 | Fixed (data-driven) |
| L7 master key in browser | Partly: audit log, constant-time compare, hardened headers. SSO/2FA is still to do. |
| L8 Redis-only entitlements | Partly: settings mirror, audit file, `/admin/export` |

## API contract for the app

### `POST /usage`

Headers are unchanged. Every earlier field is kept. Example for a pro user (`tier` "7x"),
trimmed to 4 models:

```json
{
 "tier": "7x",
 "is_paid": true,
 "daily_spent_usd": 1.84,
 "daily_budget_usd": 3.45,
 "daily_remaining_usd": 1.61,
 "month_free_spent_usd": 0.0,
 "month_free_cap_usd": 10.0,
 "requests_today": 4,
 "budget_window": "24h",
 "remaining_pct": 0.4667,
 "plan": "pro",
 "plan_name": "Pro",
 "window": "24h",
 "resets_at": "2026-10-14T06:05:01Z",
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
    "via_auto": 0
   },
   "ovid-image": {
    "requests": 1,
    "input_tokens": 40,
    "output_tokens": 0,
    "images": 1,
    "via_auto": 0
   },
   "minimax-m3": {
    "requests": 1,
    "input_tokens": 9000,
    "output_tokens": 1800,
    "images": 0,
    "via_auto": 1
   },
   "gemini-3.8-flash": {
    "requests": 1,
    "input_tokens": 4000,
    "output_tokens": 900,
    "images": 0,
    "via_auto": 0
   }
  }
 },
 "remaining_fraction": 0.4667,
 "pools": [
  {
   "class": "all",
   "remaining_fraction": 0.4667,
   "resets_at": "2026-10-14T06:05:01Z",
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
   "members": [
    "deepseek-v4.1-flash",
    "glm-5.3-flash",
    "minimax-m3"
   ],
   "priced": true,
   "slow_mode": false,
   "remaining_messages": 1610,
   "model": "auto",
   "input_cost_per_token": 2.5e-07,
   "output_cost_per_token": 2e-06,
   "remaining_pct": 0.4667
  },
  {
   "id": "big-pro",
   "name": "big-pro",
   "kind": "chat",
   "auto": false,
   "estimate": "typical",
   "priced": true,
   "slow_mode": false,
   "remaining_messages": 73,
   "model": "big-pro",
   "input_cost_per_token": 5e-06,
   "output_cost_per_token": 2e-05,
   "remaining_pct": 0.4667
  },
  {
   "id": "glm-5.3-flash",
   "name": "glm-5.3-flash",
   "kind": "chat",
   "auto": false,
   "estimate": "typical",
   "priced": true,
   "slow_mode": false,
   "remaining_messages": 1829,
   "model": "glm-5.3-flash",
   "input_cost_per_token": 2e-07,
   "output_cost_per_token": 8e-07,
   "remaining_pct": 0.4667
  },
  {
   "id": "ovid-image",
   "name": "ovid-image",
   "kind": "image",
   "auto": false,
   "estimate": "typical",
   "priced": true,
   "slow_mode": false,
   "remaining_images": 40,
   "model": "ovid-image",
   "input_cost_per_token": null,
   "output_cost_per_token": null,
   "remaining_pct": 0.4667
  }
 ]
}
```

**Display-safe fields (no money):**

| Field | Meaning |
|---|---|
| `plan`, `plan_name` | Canonical plan id and name (`tier` stays the legacy alias) |
| `window`, `resets_at` | Plan window (`"24h"`, `"30d"`, `"<N>h"`) and when it restarts (ISO UTC) |
| `remaining_fraction` | 0..1 of the allowance left (free: also honours the monthly backstop). Use it for the bar or graph |
| `pools` | Always a single `{"class": "all", remaining_fraction, resets_at, slow_mode}`, kept for compatibility. `slow_mode: true` means the allowance is used up and requests still work, more slowly |
| `today.*` | requests / input_tokens / output_tokens / images / auto_requests in the window, all keys. `by_model[id]` adds `via_auto` |
| `models[]` | `id`, `name`, `kind` (`chat`/`image`), `priced`, `auto`, `estimate` (`typical`, or `conservative` for auto and the image alias), `members` (auto only), `slow_mode`, and `remaining_messages` (chat) or `remaining_images` (image): remaining allowance ÷ that model's cost per typical message (2,000 in + 600 out tokens, editable) or per image. `null` means unpriced |

Back-compat / internal (never render): `daily_*_usd` (the current window),
`month_free_*_usd`, `requests_today`, `budget_window`, `remaining_pct`, and per model
`model`, `input_cost_per_token`, `output_cost_per_token`, `remaining_pct`.

Removed since the previous contract (never shipped to production): `models[].class`,
`models[].pool`, `today.by_model[].class`, and the `oss`/`frontier` pool entries.

### `GET /plans` (public)

`{"plans": [{"id","name","price_usd","aliases","window"}]}` lists the enabled plans.

### Gateway errors

HTTP 429 with `error.type: "daily_limit_reached"`, `provider_specific_fields.resets_at`
and the `x-ovid-resets-at` header. Show the reset time; there is no model fallback
because every model draws on the same allowance.

## Tests

```
/tmp/collab-venv/bin/python -m pytest -q server/mint/tests
```

The tests use fakeredis if it is installed, else an in-memory stub (with an async
facade for the hook), and an `httpx.MockTransport` fake of LiteLLM. There are no
network calls and no services.

## Deploy (owner, manual)

1. Back up `verifier/mint.py`, `verifier/Dockerfile`, `docker-compose.yml` and
   `litellm/config.yaml`.
2. Mint: `cp server/mint/mint.py server/mint/ovid_plans.py server/mint/m1_alerts.py /opt/ovid-gateway/verifier/`,
   then add `COPY ovid_plans.py /app/ovid_plans.py` and
   `COPY m1_alerts.py /app/m1_alerts.py` to `verifier/Dockerfile`. Set
   `M1_ALERT_WEBHOOK_URL` (and optionally `OVID_PAID_MODELS_KILL_SWITCH`) in the mint
   service env; see `docs/ops/M1_RUNBOOK.md`.
3. LiteLLM hook:
   `cp server/mint/ovid_plans.py server/mint/litellm_hook/ovid_pools.py /opt/ovid-gateway/litellm/`.
   Under the `litellm` service `volumes:`, add
   `- ./litellm/ovid_pools.py:/app/ovid_pools.py:ro` and
   `- ./litellm/ovid_plans.py:/app/ovid_plans.py:ro`. Under `litellm_settings:`, add
   `callbacks: ["ovid_pools.proxy_handler_instance"]`. The hook uses Redis db 2 through
   LiteLLM's existing `REDIS_*` env. Consider pinning the checked 1.105.0 image digest.
4. `cd /opt/ovid-gateway && docker compose build mint && docker compose up -d mint litellm`.
   Startup seeds only unset fields; the live 0.50 base and 720h paid windows are kept.
5. Verify:
   - `curl -s 127.0.0.1:8090/healthz` and `/plans`
   - in the console: plans, members, a known user
   - `docker compose logs litellm | grep ovid_pools` should show no import errors
6. Owner decisions in `/admin`, no restart needed: free allowance (0.15 suggested),
   paid windows → 24h, multipliers and prices, slow mode per plan.

Rollback: restore the step 1 backups and restart mint and litellm. The hook can be
disabled on its own by removing the `callbacks` line.
