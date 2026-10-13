# Ovid mint service

`mint.py` is the source of the live mint verifier (`/opt/ovid-gateway/verifier/mint.py`,
FastAPI on `127.0.0.1:8090`). It verifies Firebase ID + App Check tokens, mints one
LiteLLM virtual key per user per platform (android `user:{uid}:keyid`, web
`user:{uid}:web:keyid`), owns the usage limits, serves `/usage`, and hosts the owner
admin console at `/admin`. It also mounts the image routes (`images_gateway.py`).

The first commit on this path is a byte-for-byte copy of the live file
(sha256 `1c54ee74fc009569f90aa2d3ef8a4c0a32d5dca679875f306a047922484b6148`). All secrets
come from the environment; the source contains no secret literals (a test checks this).

## Usage limits

| Setting | Meaning | Default |
|---|---|---|
| Free allowance | USD per user per 24h (each user independently, never pooled) | `BASE_DAILY_USD` = 0.50 |
| Per-user override | That user's *free* allowance; paid plans scale it | none |
| Plan multipliers | `3x`, `7x`, `15x` plan ids are fixed; their multipliers are editable | 3 / 7 / 15 |
| Paid window | `30d`: monthly pool = allowance × mult × 30. `24h`: allowance × mult per 24h | `30d` (current behaviour) |
| Free monthly backstop | LiteLLM *user* budget for free users over 30 days, across all their keys | `FREE_MONTHLY_CAP_USD` = 10 |
| Typical message | Tokens used to turn the remaining budget into a message count | 2,000 in / 600 out |
| Typical image | Output tokens per image when a model has no per-image price | 1,500 |

Paid allowance = the user's free allowance × plan multiplier. Paid users' LiteLLM
user budget equals their key budget. With a high daily free amount the monthly
backstop binds after a few days (e.g. $3/day and a $10 backstop stop a heavy
free user on day 4); the console shows this next to the field.

Every change (global or per user) is re-applied right away to **every key in both
namespaces** (android + web) and to the LiteLLM user budget, and is written to the
audit log. Above `REAPPLY_SYNC_MAX` users (200) the re-apply runs in the background;
progress is in `GET /admin/reapply-status`.

`budget_duration` is sent to LiteLLM **only when it changes**. LiteLLM restarts a
key's budget clock (`budget_reset_at = now + duration`) whenever the field is sent,
so the old mint, which sent it on every `/mint`, pushed users' resets further out on
each app launch. Before you rely on this, check it against the deployed LiteLLM version.

### Settings storage

| Where | Keys |
|---|---|
| Redis (db 2) | `config:base_daily_usd` (free allowance, the same key as before) |
| | hash `config:limits`: `mult:3x`, `mult:7x`, `mult:15x`, `paid_window`, `free_monthly_cap_usd`, `est_input_tokens`, `est_output_tokens`, `est_image_tokens` |
| | per user: `user:{uid}:tier`, `:dailyUsd` (free-allowance override), `:monthlyCapUsd`, `:banned`, `:email` (new), `email:{email}` → uid (new, filled on `/mint` and `/usage`) |
| | `audit:admin` (list, newest first, capped at `AUDIT_MAX` = 5000), `config:reapply_status`, `usagecache:{uid}` (15 s) |
| mint volume (`mintdata:/data`) | `limits.json`: mirror of the settings, restored at startup if Redis lost them. `admin-audit.jsonl`: append-only audit log, never trimmed |

`GET /admin/export` returns settings + every user's plan, overrides, ban and email.
Save it off-box as the L8 backup, because entitlements still live only in Redis.

### Environment

Existing: `FIREBASE_PROJECT_ID`, `FIREBASE_PROJECT_NUMBER`, `APPCHECK_ENABLED`,
`OVID_APPCHECK_APPS`, `LITELLM_BASE`, `LITELLM_MASTER_KEY`, `REDIS_URL`,
`FREE_MONTHLY_CAP_USD`, `BASE_DAILY_USD`, `PUBLIC_BASE_URL`, `ALLOW_TEST_UPGRADE`,
`KEY_RPM`, `KEY_TPM`, `KEY_MAX_PARALLEL`, `WEB_TEAM_DAILY_USD`, `DAILY_SPEND_ALERT_USD`,
`ALERT_*`, plus the anti-abuse knobs. All of them now only seed defaults; Redis wins.

New and optional (the defaults are right for production): `PAID_WINDOW` (30d),
`EST_INPUT_TOKENS` (2000), `EST_OUTPUT_TOKENS` (600), `EST_IMAGE_TOKENS` (1500),
`MINT_STATE_DIR` (/data), `REAPPLY_SYNC_MAX` (200), `AUDIT_MAX` (5000),
`AUTO_MODEL_GROUP` (auto), `USAGE_CACHE_S` (15), `MINT_SPEND_MONITOR` (true),
`MINT_MOUNT_IMAGES` (true).

## Admin console (`/admin`)

It stays reachable on localhost / an SSH tunnel only (Caddy does not route `/admin`)
and is authorized by the LiteLLM master key pasted into the tab. The page is
`no-store`, `frame-ancestors 'none'`, and all user data is rendered as text.

- **Usage limits:** free allowance per 24h, free monthly backstop (with explanation),
  3x/7x/15x multipliers, paid window, typical message/image tokens, and a live preview
  of each plan's allowance and of when the backstop cuts in. Saving re-applies to all users.
- **User:** look up by uid or email. Shows plan and multiplier, ban state, free
  allowance (override or global), window allowance, window start and reset,
  usage in the window (requests, tokens in/out, images, auto requests), spend and
  remaining, monthly backstop, and each key (android/web) with its budget and blocked
  flag. It also shows the **per-model table exactly as the app sees it** (remaining
  messages/images, estimate type, per-model requests/tokens/images).
  Actions: set plan, set/clear the free-allowance override, set/clear the monthly
  backstop override, reset usage, ban/unban.
- **Reset all users**, **IP ban/unban** (30 days).
- **Audit log:** time, action, target, before/after and re-apply result.

Admin API (all need `Authorization: Bearer <master key>`; 401 if missing, 403 if wrong):
`GET/POST /admin/settings`, `GET /admin/user?q=`, `POST /admin/set-tier`
(`uid, tier, daily_usd, monthly_cap_usd, clear_daily_usd, clear_monthly_cap_usd`),
`POST /admin/reset-usage` (`uid?`, `reset_month_free`), `POST /admin/ban|unban`
(`uid?`, `ip?`), `POST /admin/set-base-budget` (legacy), `GET /admin/audit?limit=`,
`GET /admin/reapply-status`, `GET /admin/export`.

### Admin v2 defects (11-web-app-plan.md L1–L8)

| # | Status |
|---|---|
| L1 per-key daily budget (2× across android + web) | **Not fixed here.** LiteLLM has one user budget, and it already carries the free monthly backstop. `/usage` now sums both keys, so the app shows the true combined remaining (conservative). The real fix is to move the daily allowance onto the LiteLLM user (or a shared budget) and enforce the backstop in mint. |
| L2 override replaces the plan amount | Fixed: the override is the user's free allowance × multiplier. **Existing overrides on paid users get multiplied after deploy.** Check them first (see the deploy steps). |
| L3 web keys never updated | Fixed: settings, set-tier, upgrade, reset and ban touch both namespaces. |
| L4 monthly reset was a no-op | Fixed: it sets the LiteLLM user `spend` to 0. |
| L5 `/usage` saw only the android key; `daily_*` mislabelled for 30d | Fixed: spend and counts cover all keys, and `window` states the period. `daily_*` names are kept for back-compat. |
| L6 console said ×5/10/20 | Fixed: multipliers are read from settings. |
| L7 master key in browser, no audit | Partly: there is now an audit log, a constant-time key compare and hardened headers. SSO/2FA (Admin v2 behind Cloudflare Access) is still to do. |
| L8 entitlements only in Redis | Partly: settings mirror and audit file on the volume, plus `/admin/export`. |

## API contract for the app: `POST /usage`

Headers are unchanged: `Authorization: Bearer <Firebase ID token>`, `X-Firebase-AppCheck: <token>`.

```json
{
  "tier": "free",
  "is_paid": false,
  "daily_spent_usd": 0.75,
  "daily_budget_usd": 3.0,
  "daily_remaining_usd": 2.25,
  "month_free_spent_usd": 0.0,
  "month_free_cap_usd": 10.0,
  "requests_today": 4,
  "budget_window": "24h",
  "remaining_pct": 0.75,
  "window": "24h",
  "resets_at": "2026-10-13T13:54:37Z",
  "today": {
    "requests": 4,
    "input_tokens": 34040,
    "output_tokens": 7900,
    "images": 1,
    "auto_requests": 2,
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
      "deepseek-v4.1-flash": {
        "requests": 1,
        "input_tokens": 4000,
        "output_tokens": 900,
        "images": 0,
        "via_auto": 1
      }
    }
  },
  "remaining_fraction": 0.75,
  "models": [
    {
      "id": "auto",
      "name": "auto",
      "kind": "chat",
      "auto": true,
      "estimate": "conservative",
      "members": [
        "deepseek-v4.1-flash",
        "gemini-3.7-flash",
        "gemini-3.8-flash",
        "glm-5.3-flash",
        "gpt-5.6-luna",
        "minimax-m3"
      ],
      "priced": true,
      "remaining_messages": 1071,
      "model": "auto",
      "input_cost_per_token": 2.5e-07,
      "output_cost_per_token": 2e-06,
      "remaining_pct": 0.75
    },
    {
      "id": "big-pro",
      "name": "big-pro",
      "kind": "chat",
      "auto": false,
      "estimate": "typical",
      "priced": true,
      "remaining_messages": 102,
      "model": "big-pro",
      "input_cost_per_token": 5e-06,
      "output_cost_per_token": 2e-05,
      "remaining_pct": 0.75
    },
    {
      "id": "glm-5.3-flash",
      "name": "glm-5.3-flash",
      "kind": "chat",
      "auto": false,
      "estimate": "typical",
      "priced": true,
      "remaining_messages": 2556,
      "model": "glm-5.3-flash",
      "input_cost_per_token": 2e-07,
      "output_cost_per_token": 8e-07,
      "remaining_pct": 0.75
    },
    {
      "id": "mystery",
      "name": "mystery",
      "kind": "chat",
      "auto": false,
      "estimate": "typical",
      "priced": false,
      "remaining_messages": null,
      "model": "mystery",
      "input_cost_per_token": null,
      "output_cost_per_token": null,
      "remaining_pct": 0.75
    },
    {
      "id": "ovid-image",
      "name": "ovid-image",
      "kind": "image",
      "auto": false,
      "estimate": "typical",
      "priced": true,
      "remaining_images": 56,
      "model": "ovid-image",
      "input_cost_per_token": null,
      "output_cost_per_token": null,
      "remaining_pct": 0.75
    }
  ]
}
```

(The example is trimmed to 5 models. The real response lists every model LiteLLM publishes.)

**Display-safe fields (no money):**

| Field | Type | Meaning |
|---|---|---|
| `window` | `"24h"` \| `"30d"` | The allowance period. Free is always `24h`; paid follows the owner setting |
| `resets_at` | ISO-8601 UTC (`Z`) | When the allowance refills. This is the earliest reset across the user's keys; with no key it is now + window |
| `remaining_fraction` | 0..1 | Share of the allowance left. For free users this also honours the monthly backstop |
| `today.requests/input_tokens/output_tokens/images` | int | Counted from LiteLLM spend logs for **all** of the user's keys within the **current window** (so for `30d`, "today" means "this window"). Failed requests are excluded |
| `today.auto_requests` | int | Requests made with `auto` |
| `today.by_model[id]` | object | The same counts per model plus `via_auto`. Auto requests are attributed to the member LiteLLM actually used, else to `"auto"` |
| `models[].id` | string | Model id to send in requests |
| `models[].name` | string | Display name (`model_info.display_name` if set, else the id) |
| `models[].kind` | `"chat"` \| `"image"` | |
| `models[].priced` | bool | `false`: the owner has not set a price. Show no count (`remaining_*` is `null`) |
| `models[].remaining_messages` | int \| null | Chat models only. Remaining budget ÷ the cost of a typical message (2,000 in + 600 out tokens, owner-configurable) at **this model's** price |
| `models[].remaining_images` | int \| null | Image models only. Remaining budget ÷ `output_cost_per_image` (else typical/measured image tokens × output price) |
| `models[].auto` | bool | `true` for the `auto` router |
| `models[].estimate` | `"typical"` \| `"conservative"` | `auto` is priced at its most expensive member, so its count is a floor |
| `models[].members` | string[] | `auto` only: the models it routes to |

All models draw on one shared allowance. Using an expensive model lowers every
model's remaining count, and counts are estimates.

**Back-compat / internal (never render):** `daily_spent_usd`, `daily_budget_usd`,
`daily_remaining_usd` (these refer to the current window, not just a day),
`month_free_spent_usd`, `month_free_cap_usd`, `requests_today` (= `today.requests`),
`budget_window` (= `window`), `remaining_pct` (= `remaining_fraction`), and per model
`model`, `input_cost_per_token`, `output_cost_per_token`, `remaining_pct`. They are kept
for builds that already parse them. New app code should use only the display-safe fields.

## Tests

```
/tmp/collab-venv/bin/python -m pytest -q server/mint/tests
```

The tests use fakeredis if it is installed, else an in-memory stub, and an
`httpx.MockTransport` fake of the LiteLLM admin API. They make no network calls and
start no services.

## Deploy (owner, manual)

1. Back up: `cp /opt/ovid-gateway/verifier/mint.py /opt/ovid-gateway/verifier/mint.py.bak-$(date -u +%Y%m%dT%H%M%SZ)`.
2. L2 check. List paid users that have an override, since those overrides are now multiplied by the plan:
   `docker compose -f /opt/ovid-gateway/docker-compose.yml exec redis sh -c 'redis-cli -a "$REDIS_PASSWORD" -n 2 --no-auth-warning --scan --pattern "user:*:dailyUsd"'`.
   For each one with a paid `user:{uid}:tier`, divide the stored value by the multiplier (or clear it in the console after the deploy).
3. Copy: `cp server/mint/mint.py /opt/ovid-gateway/verifier/mint.py`. The Dockerfile and its dependencies are unchanged.
4. Rebuild and restart only mint: `cd /opt/ovid-gateway && docker compose build mint && docker compose up -d mint`.
5. Verify: `curl -s 127.0.0.1:8090/healthz`, then open the console through the tunnel
   (`ssh -L 8090:127.0.0.1:8090 <vps>` → http://127.0.0.1:8090/admin), load, check the
   settings (0.50 / 3·7·15 / 30d / 10), look up a known user, and confirm the model table.
6. Optional: save `GET /admin/export` off-box.

Rollback: restore the backup from step 1 and repeat step 4. The new Redis keys are
ignored by the old code, except that `config:base_daily_usd` keeps its meaning.
